import SwiftUI
import UniformTypeIdentifiers

// MARK: - File kinds

private enum UploadFileKind {
    /// What the document browser will let you pick.
    ///
    /// Built with `UTType(tag:tagClass:conformingTo:)` rather than `UTType(filenameExtension:)`
    /// because `gcode` (and, on most systems, `3mf`) is not a registered type: the extension
    /// initialiser returns nil for those and the browser would end up filtering them out. The tag
    /// initialiser mints a dynamic type instead, which still matches by extension.
    static let all: [UTType] = ["3mf", "gcode", "stl"].compactMap {
        UTType(tag: $0, tagClass: .filenameExtension, conformingTo: .data)
    }
}

// MARK: - Progress box

/// Upload progress, in a reference box.
///
/// `BambuddyClient.uploadFile`'s callback is `@Sendable` and fires from URLSession's delegate queue,
/// so it cannot touch `@State` (or capture the view) directly. A main-actor-isolated class is
/// implicitly `Sendable`, so the callback can hold *this* and hop.
@MainActor
@Observable
private final class UploadProgressBox {
    /// 0...1.
    var fraction: Double = 0
    var percent: Int { Int((fraction * 100).rounded()) }
}

// MARK: - Error text

/// The API's own `{"detail": …}` sentence, or nil.
///
/// Deliberately narrower than `BambuddyError.detail`, which falls back to the raw body: a proxy's
/// HTML error page is not something to put in front of a person, so callers keep their own wording
/// when there is no structured detail.
private func uploadApiDetail(_ error: Error) -> String? {
    guard let e = error as? BambuddyError,
          let data = e.body.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let d = obj["detail"] as? String,
          !d.isEmpty
    else { return nil }
    return d
}

// MARK: - Staging

/// Copy a picked document into our own temp directory and return the copy.
///
/// Two reasons this is not optional. The picker hands back a security-scoped URL that is only
/// readable between `start`/`stopAccessingSecurityScopedResource`, and the upload outlives that
/// window; and the server takes the library's display name from the multipart `filename`, so the
/// copy has to keep the original basename — hence the per-upload subdirectory instead of a unique
/// filename.
///
/// Free function, not a method, so it can run off the main actor: copying tens of megabytes is not
/// something to do while the sheet is trying to animate.
private func stageUploadCopy(_ picked: URL) throws -> URL {
    let scoped = picked.startAccessingSecurityScopedResource()
    defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("upload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent(picked.lastPathComponent)
    try FileManager.default.copyItem(at: picked, to: dest)
    return dest
}

// MARK: - Upload sheet

/// The "Add a file" bottom sheet: pick a document from Files and upload it to the library with real
/// byte progress, or step into the MakerWorld panel and import a model from a link.
///
/// Presented in a `fullScreenCover`, so it paints its own scrim and card. The scrim fades in on
/// appear; the card's slide is the presentation's own, which is why nothing here animates its
/// offset — doing both moved it twice as far.
@MainActor
struct UploadSheet: View {
    let model: AppModel
    /// Fires once a file has landed in the library, so a list already on screen can refetch.
    var onUploaded: (() -> Void)?

    @Environment(\.palette) private var c

    @State private var showMakerWorld = false
    @State private var picking = false
    @State private var busy = false
    @State private var progress = UploadProgressBox()
    @State private var uploadError: String?
    @State private var scrimIn = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.5)
                    .opacity(scrimIn ? 1 : 0)
                    .contentShape(.rect)
                    .onTapGesture { close() }

                card(bottomInset: geo.safeAreaInsets.bottom, maxHeight: geo.size.height * 0.88)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // `.container` only: ignoring the keyboard region too would let it cover the MakerWorld
        // link field.
        .ignoresSafeArea(.container)
        .presentationBackground(.clear)
        .onAppear { withAnimation(.easeOut(duration: 0.22)) { scrimIn = true } }
        .fileImporter(isPresented: $picking, allowedContentTypes: UploadFileKind.all) { (result: Result<URL, any Error>) in
            switch result {
            case .success(let url):
                startUpload(url)
            case .failure(let error):
                // Cancelling the browser is reported as a failure; it is not one.
                if (error as? CocoaError)?.code != .userCancelled {
                    uploadError = error.localizedDescription
                }
            }
        }
    }

    private func card(bottomInset: CGFloat, maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let client = model.client {
                if showMakerWorld {
                    MakerWorldPanel(
                        model: model,
                        client: client,
                        onBack: { showMakerWorld = false },
                        onImported: onUploaded,
                        onClose: close
                    )
                } else {
                    addFilePanel
                }
            } else {
                disconnected
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, bottomInset + (showMakerWorld ? 18 : 20))
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                .fill(c.sheet)
        )
        .shadow1()
        // The MakerWorld panel scrolls and can grow tall; the picker is three rows and never does.
        //
        // `alignment: .bottom` is not decoration. The panel's ScrollView is greedy, so this frame
        // takes the full 88 % even when the panel has shrunk to its content — and a `maxHeight` frame
        // CENTRES its child by default. That left the card floating in mid-screen with a square
        // bottom edge and the file grid showing underneath: 841 pt of frame, a 340 pt card, centred.
        // It only showed with short content, which is why a resolved model (tall enough to fill)
        // always looked right.
        .frame(maxHeight: showMakerWorld ? maxHeight : nil, alignment: .bottom)
    }

    // MARK: Pick-a-source panel

    private var addFilePanel: some View {
        VStack(spacing: 0) {
            UploadSheetGrabber()
                .padding(.bottom, 16)

            Text("Add a file")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(c.t1)
                .padding(.bottom, 14)

            Tap(disabled: busy) {
                uploadError = nil
                picking = true
            } content: {
                HStack(spacing: 13) {
                    UploadSourceTile(symbol: "folder")
                    Text(busy ? "Uploading… \(progress.percent)%" : "From Files")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if busy {
                        ProgressView().tint(c.t3)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(c.t3)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
                .contentShape(.rect)
            }

            if busy {
                // The app's own fill bar rather than a second progress primitive — the 600 ms ease
                // also smooths out URLSession's bursty per-chunk callbacks.
                HeatBar(pct: progress.fraction * 100, heating: false, color: c.accent, track: c.s3, height: 4)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }

            if let uploadError {
                UploadErrorCard(text: uploadError)
                    .padding(.top, 12)
            }

            Tap(disabled: busy) {
                showMakerWorld = true
            } content: {
                HStack(spacing: 13) {
                    UploadSourceTile(symbol: "globe")
                    // No subtitle: it said "Paste a model link", which stopped being the whole story
                    // when the panel gained search, browse and collections — and a subtitle that
                    // names one of four ways in is worse than none.
                    Text("From MakerWorld")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(c.t3)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
                .contentShape(.rect)
            }
            .padding(.top, 10)

            Tap(action: close) {
                Text("Cancel")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(c.t1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s3))
                    .contentShape(.rect)
            }
            .padding(.top, 14)
        }
    }

    private var disconnected: some View {
        VStack(spacing: 0) {
            UploadSheetGrabber().padding(.bottom, 16)
            Text("Not connected")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(c.t1)
            Text("The app has no Bambuddy server configured, so there is nowhere to put a file.")
                .font(.system(size: 12.5, weight: .medium))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(c.t2)
                .padding(.top, 8)
            Tap(action: close) {
                Text("Close")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(c.t1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s3))
                    .contentShape(.rect)
            }
            .padding(.top, 14)
        }
    }

    // MARK: Actions

    private func close() {
        model.overlay = nil
    }

    /// Stage the picked document, then upload it with progress.
    ///
    /// The transfer survives the sheet being dismissed — the task holds the client, not the view —
    /// so a mid-upload backdrop tap costs nothing and the toast still lands.
    private func startUpload(_ picked: URL) {
        guard let client = model.client, !busy else { return }
        uploadError = nil
        progress.fraction = 0
        busy = true

        let box = progress
        Task {
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try stageUploadCopy(picked)
                }.value
                defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }

                let name = staged.lastPathComponent
                _ = try await client.uploadFile(staged, name: name) { fraction in
                    Task { @MainActor in box.fraction = fraction }
                }
                busy = false
                onUploaded?()
                model.toast = "\(name) added to your library"
                close()
            } catch {
                busy = false
                uploadError = "Upload failed — " + (uploadApiDetail(error) ?? error.localizedDescription)
            }
        }
    }
}

// MARK: - MakerWorld panel

/// Import a model straight from a MakerWorld link: the server resolves the URL, and this shows the
/// design plus its printable profiles so the right one gets pulled into the library.
///
/// Importing needs a Bambu Cloud token on the *server*; resolving does not. That split is why the
/// panel stays usable — preview, profiles and all — when an import is blocked, with only the final
/// button unavailable and a reason attached to it.
@MainActor
private struct MakerWorldPanel: View {
    let model: AppModel
    let client: BambuddyClient
    let onBack: () -> Void
    var onImported: (() -> Void)?
    let onClose: () -> Void

    @Environment(\.palette) private var c
    @Environment(\.openURL) private var openURL

    @State private var url = ""
    @State private var access: MakerWorldAccess = .checking
    @State private var resolving = false
    @State private var resolved: MakerWorldResolved?
    @State private var rows: [MWProfileRow] = []
    @State private var picked: MWProfileRow?
    /// The failure plus which call produced it — the step decides where it is rendered, because an
    /// import failure has to appear beside the button that caused it rather than at the top of a
    /// scroll the user is 7 000 points down.
    @State private var failure: (step: MakerWorld.Step, detail: MWFailure)?
    @State private var importing = false
    @State private var recent: [MakerWorldRecentImport] = []
    @State private var licenceExpanded = false

    // Search and browse talk to MakerWorld DIRECTLY, through their own client — see
    // `MakerWorldSearchClient` for why none of this shares Bambuddy's transport.
    private let searchClient = MakerWorldSearchClient()
    @State private var hits: [MWSearchHit] = []
    @State private var hitTotal: Int?
    @State private var searching = false
    @State private var loadingMore = false
    @State private var searchError: String?
    @State private var navs: [MWNav] = []
    /// The browse category currently listed, or nil when the grid is showing a text search.
    @State private var activeNav: String?
    /// The query the visible hits belong to — paging has to repeat it, and the field may have moved on.
    @State private var activeQuery: String?

    // The owner's own MakerWorld collections, served by their la-push — see `CollectionsClient`.
    @State private var collections: [MakerWorldCollection] = []
    /// True while the folder list is what the panel is showing.
    @State private var showingCollections = false
    /// The folder whose designs are in the grid, if any.
    @State private var activeCollection: MakerWorldCollection?
    /// Measured height of the scroll's content — see `body` for why the scroll needs it.
    @State private var contentHeight: CGFloat = 0

    private var alreadyImported: Bool { !(resolved?.alreadyImportedLibraryIds?.isEmpty ?? true) }
    private var trimmedUrl: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            UploadSheetGrabber()
                .padding(.bottom, 12)

            header

            accessBanner

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    linkField
                    // A resolve failure belongs under the field that caused it; the content is short
                    // at that point, so it is on screen. An import failure is rendered by
                    // `importButton` instead — see `failure`.
                    if let failure, failure.step == .resolve {
                        failureCard(failure.detail)
                    }
                    if let resolved {
                        designBlock(resolved)
                    } else {
                        discoverBlock
                    }
                }
                .padding(.bottom, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // A ScrollView takes every point it is offered, and the card is allowed 88 % of the
            // screen — so without this cap an unresolved link sat in a near-full-height sheet of
            // empty space. Capping at the measured content height lets the card hug what is in it
            // and only start scrolling once the design block makes it taller than the 88 %.
            .frame(maxHeight: contentHeight > 0 ? contentHeight : nil)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)

            if let resolved {
                importButton(resolved)
            }
        }
        .task {
            // Two questions, because `can_download` alone cannot say WHICH remedy applies.
            access = await client.makerWorldAccess()
        }
        .task {
            // A cold panel with an empty text field says nothing about what this screen is for.
            recent = await client.recentMakerWorldImports()
        }
        .task {
            // MakerWorld's own taxonomy rather than a hardcoded copy — the categories are theirs to
            // change. A failure here is silent on purpose: browse simply does not appear, and the
            // field above it still searches and still opens links.
            navs = MakerWorldSearch.browsable((try? await searchClient.navs()) ?? [])
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 0) {
            Tap(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(c.t2)
                    .frame(width: 40, height: 40, alignment: .leading)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Back")

            Text("From MakerWorld")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(c.t1)
                .frame(maxWidth: .infinity)

            // Mirrors the back button so the title stays optically centred.
            Color.clear.frame(width: 40, height: 1)
        }
        .padding(.bottom, 14)
    }

    /// One banner, three possible reasons, each naming the thing that actually has to change. The
    /// previous single message sent the owner to sign in to Bambu Cloud when the server was already
    /// signed in and the gap was a scope on the API key — a remedy that would have changed nothing.
    @ViewBuilder
    private var accessBanner: some View {
        if access == .checking {
            HStack(spacing: 10) {
                ProgressView().tint(c.t3)
                Text("Checking your MakerWorld connection…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(c.t3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 14)
        } else if let message = access.message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(c.heating)
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(c.t2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.heatingDim))
            .padding(.bottom, 14)
            .accessibilityElement(children: .combine)
        }
    }

    /// One field, two jobs — see `MakerWorldSearch.Intent`.
    ///
    /// Pasting a link must stay a first-class way in, permanently: search rides an undocumented
    /// endpoint that Bambu can gate at any time, and the day it does, search is removed rather than
    /// worked around. Making the link a *mode of the same field* means it cannot decay into a
    /// fallback nobody maintains. The button says which of the two will happen.
    private var intent: MakerWorldSearch.Intent { MakerWorldSearch.intent(for: url) }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 0) {
            UploadSectionLabel("SEARCH OR PASTE A LINK")

            HStack(spacing: 10) {
                TextField(
                    "",
                    text: $url,
                    // `verbatim:` is load-bearing. A Text STRING LITERAL is a LocalizedStringKey, so
                    // SwiftUI parses it as Markdown — and Markdown autolinks a bare URL, which
                    // rendered this placeholder as a blue tappable link and ignored `foregroundStyle`
                    // entirely. Settings' fields escape it only by accident: they pass a String
                    // variable, which picks the verbatim overload.
                    prompt: Text(verbatim: "benchy, or a makerworld.com link").foregroundStyle(c.t3)
                )
                .font(.system(size: 14))
                .foregroundStyle(c.t1)
                .tint(c.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.search)
                .onSubmit(submit)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))

                Tap(disabled: resolving || searching || trimmedUrl.isEmpty, action: submit) {
                    Group {
                        if resolving || searching {
                            ProgressView().tint(c.accentInk)
                        } else {
                            Text(intent.buttonLabel)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(c.accentInk)
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.accent))
                    .contentShape(.rect)
                }
                .opacity(trimmedUrl.isEmpty ? 0.4 : 1)
            }
        }
    }

    // MARK: Discover — browse, search results, recents

    /// What fills the panel before a model has been resolved.
    @ViewBuilder
    private var discoverBlock: some View {
        if let searchError {
            // Not an `UploadErrorCard`: this is MakerWorld failing, not the owner's own server, and
            // conflating the two would send them looking at the wrong machine.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(c.t3)
                Text(searchError)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(c.t2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
            .padding(.top, 14)
            .accessibilityElement(children: .combine)
        }

        if !navs.isEmpty || collectionsClient.isAvailable {
            browseChips
        }

        if showingCollections {
            collectionsList
        } else if !hits.isEmpty {
            resultsGrid
        } else if hits.isEmpty, !searching, activeQuery != nil || activeNav != nil, searchError == nil {
            Text("Nothing on MakerWorld matched that.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)
        } else if hits.isEmpty, activeQuery == nil, activeNav == nil, !recent.isEmpty {
            recentBlock
        }
    }

    private var browseChips: some View {
        VStack(alignment: .leading, spacing: 0) {
            UploadSectionLabel("BROWSE")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    // First, because it is the only one that is the owner's own. Shown only when a
                    // push server is configured — without one there is nothing holding the Bambu
                    // Cloud token, so the chip would lead somewhere that cannot answer.
                    if collectionsClient.isAvailable {
                        let on = showingCollections || activeCollection != nil
                        Tap(action: openCollections) {
                            HStack(spacing: 6) {
                                Image(systemName: "bookmark")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("My collections")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(on ? c.accent : c.t2)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(on ? c.accentDim : c.s2))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(c.accent, lineWidth: on ? 1.5 : 0)
                            }
                            .contentShape(.rect)
                        }
                        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                    }

                    ForEach(navs) { nav in
                        let on = activeNav == nav.key
                        Tap { browse(nav) } content: {
                            Text(nav.name ?? nav.key)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(on ? c.accent : c.t2)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(on ? c.accentDim : c.s2))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(c.accent, lineWidth: on ? 1.5 : 0)
                                }
                                .contentShape(.rect)
                        }
                        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 18)
    }

    /// The owner's collection folders. A list rather than a grid: these are containers with a count,
    /// and the count is the thing worth reading.
    @ViewBuilder
    private var collectionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            UploadSectionLabel("MY COLLECTIONS" + (collections.isEmpty ? "" : "  ·  \(collections.count)"))
            if searching {
                HStack(spacing: 10) {
                    ProgressView().tint(c.t3)
                    Text("Reading your collections…")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(c.t3)
                }
                .padding(.vertical, 12)
            } else if collections.isEmpty, searchError == nil {
                // Only reachable when la-push actually answered with an empty list. A missing token
                // or a refused request raises instead, so this line never stands in for "signed out".
                Text("You haven’t collected anything on MakerWorld yet.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(c.t3)
                    .padding(.top, 4)
            } else {
                VStack(spacing: 9) {
                    ForEach(collections) { folder in
                        collectionRow(folder)
                    }
                }
            }
        }
        .padding(.top, 18)
    }

    private func collectionRow(_ folder: MakerWorldCollection) -> some View {
        // An empty folder opens to nothing, so it says so instead of pretending to be a way forward.
        let empty = folder.count == 0
        return Tap(disabled: empty) { openCollection(folder) } content: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(c.thumb)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Group {
                            if let url = client.makerworldThumbUrl(folder.cover) {
                                AsyncImage(url: url) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Color.clear
                                }
                            } else {
                                Image(systemName: "bookmark")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(c.t3)
                            }
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .lineLimit(1)
                    Text(empty ? "Empty" : "\(folder.count) model\(folder.count == 1 ? "" : "s")")
                        .font(.mono(11.5, weight: .medium))
                        .foregroundStyle(c.t3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !empty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(c.t3)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
            .opacity(empty ? 0.55 : 1)
            .contentShape(.rect)
        }
        .accessibilityLabel("\(folder.title), \(empty ? "empty" : "\(folder.count) models")")
    }

    private var resultsGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Inside a collection there has to be a visible way out. The "My collections" chip does
            // go back, but it renders as already-selected while its folder is open, so it reads as
            // where-you-are rather than a way to leave.
            if let folder = activeCollection {
                Tap(action: backToCollections) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("All collections")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(c.accent)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .accessibilityLabel("Back to all collections, leaving \(folder.title)")
                .padding(.bottom, 10)
            }

            UploadSectionLabel(gridLabel)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(hits) { hit in
                    resultTile(hit)
                }
            }

            if MakerWorldSearch.hasMore(loaded: hits.count, total: hitTotal) {
                Tap(disabled: loadingMore, action: loadMore) {
                    HStack(spacing: 8) {
                        if loadingMore { ProgressView().tint(c.t3) }
                        Text(loadingMore ? "Loading…" : "Load more")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(c.t2)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
                    .contentShape(.rect)
                }
                .padding(.top, 10)
            }
        }
        .padding(.top, 18)
    }

    private var gridLabel: String {
        let name = activeCollection?.title
            ?? activeNav.flatMap { key in navs.first { $0.key == key }?.name }
            ?? activeQuery
        let scope = (name?.uppercased()).map { "  ·  \($0)" } ?? ""
        // The API's own total, not the number loaded — saying "20" for a 7 076-hit search would be a
        // smaller lie but a lie.
        let count = hitTotal.map { "  ·  \(MakerWorldSearch.compact($0))" } ?? ""
        return "RESULTS\(scope)\(count)"
    }

    /// One grid tile. Everything on it comes from a field the hit actually carries — a search hit is
    /// a thin projection, and the design's proposed "not printable" marker had no field behind it.
    private func resultTile(_ hit: MWSearchHit) -> some View {
        Tap { open(hit) } content: {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(c.thumb)
                    // 4:3 rather than square: MakerWorld covers are landscape and many have the
                    // model's name set into the image, which a square centre-crop cuts in half.
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        // Through Bambuddy's proxy, so browsing does not put this phone's IP in
                        // MakerWorld's CDN logs for every tile on screen.
                        if let url = client.makerworldThumbUrl(hit.cover) {
                            AsyncImage(url: url) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Color.clear
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if MakerWorldSearch.isAdult(hit) {
                            Text("18+")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.black.opacity(0.65)))
                                .padding(7)
                        }
                    }

                Text(hit.title ?? "Model \(hit.id)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(c.t1)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)

                if let creator = hit.designCreator?.name?.nonEmpty {
                    Text("@\(creator)")
                        .font(.mono(10.5, weight: .medium))
                        .foregroundStyle(c.t3)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }

                let stats = MakerWorldSearch.stats(hit)
                if !stats.isEmpty {
                    Text(stats)
                        .font(.mono(10.5, weight: .medium))
                        .foregroundStyle(c.t3)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityLabel("\(hit.title ?? "Model \(hit.id)"), \(MakerWorldSearch.stats(hit))")
    }

    // MARK: Resolved design

    @ViewBuilder
    private func designBlock(_ r: MakerWorldResolved) -> some View {
        let design = r.design

        cover(design)
            .padding(.top, 18)

        Text(design.title ?? "Model \(r.modelId)")
            .font(.system(size: 18, weight: .bold))
            .tracking(-0.3)
            .foregroundStyle(c.t1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)

        // MakerWorld sometimes returns a design with no creator and no download count; an empty
        // line would still take a row's height under the title.
        let byline = byline(design)
        if !byline.isEmpty {
            Text(byline)
                .font(.mono(12, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 5)
        }

        chips(r)

        // Attribution the licence asks for, and that the `makerworld-1400373.3mf` filename destroys.
        if let original = r.design.originals?.first,
           let title = original.title?.nonEmpty {
            Text("Remix of “\(title)”" + (original.author?.nonEmpty.map { " by \($0)" } ?? ""))
                .font(.system(size: 11.5, weight: .medium))
                .lineSpacing(2)
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }

        // MakerWorld's own licence prose, disclosed rather than paraphrased.
        if licenceExpanded, let l = MakerWorld.licence(r.design), l.title != nil || l.body != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let t = l.title {
                    Text(t)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(c.t2)
                }
                if let b = l.body {
                    Text(b)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineSpacing(3)
                        .foregroundStyle(c.t3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
            .padding(.top, 10)
        }

        // A paid / points / exclusive model resolves fine and refuses at import. Saying so before a
        // download beats "Import failed" after one.
        if let caution = MakerWorld.availability(r.design).caution {
            Text(caution)
                .font(.system(size: 11.5, weight: .medium))
                .lineSpacing(2)
                .foregroundStyle(c.heating)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
        }

        if rows.isEmpty {
            Text("No printable profiles listed for this model — importing brings it in as published.")
                .font(.system(size: 12, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                UploadSectionLabel("PROFILE" + (rows.count > 1 ? "  ·  \(rows.count)" : ""))
                // Lazy: a popular model resolves to 88 rows, and an eager stack built every one of
                // them at once — 88 AsyncImage views firing 88 concurrent requests at the thumbnail
                // proxy for rows that are thousands of points off screen.
                LazyVStack(spacing: 9) {
                    ForEach(rows) { row in
                        profileRow(row)
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    /// Licence and library-state chips. The licence is shown BEFORE the download, which is the
    /// difference between an informed print and a surprise.
    @ViewBuilder
    private func chips(_ r: MakerWorldResolved) -> some View {
        let licence = MakerWorld.licence(r.design)
        if licence != nil || alreadyImported {
            HStack(spacing: 8) {
                if let l = licence {
                    let hasProse = l.title != nil || l.body != nil
                    Tap(disabled: !hasProse) { licenceExpanded.toggle() } content: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11, weight: .semibold))
                            Text(l.label)
                                .font(.system(size: 11.5, weight: .semibold))
                            if hasProse {
                                Image(systemName: licenceExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .foregroundStyle(c.t2)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.s2))
                        .contentShape(.rect)
                    }
                    .accessibilityLabel("Licence \(l.label)" + (hasProse ? ", show details" : ""))
                }

                if alreadyImported {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                        // MODEL-level, and worded as such. `already_imported_library_ids` matches any
                        // profile of this model, so "Already in your library" beside a profile picker
                        // read as a claim about the selected profile that the data cannot support.
                        Text("This model is in your library")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(c.accent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.accentDim))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        }
    }

    private func cover(_ design: MWDesign) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(c.thumb)
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                Group {
                    if let url = client.makerworldThumbUrl(design.coverUrl) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            case .empty:
                                ProgressView().tint(c.t3)
                            default:
                                coverFallback
                            }
                        }
                    } else {
                        coverFallback
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Clipped HERE, on the composite, not inside the overlay. A `.fill` image is flexible, so
            // a maxWidth/maxHeight frame does not constrain it — the Group grew to the image's size
            // and the clip inside it therefore clipped nothing. A portrait cover then spilled out of
            // its 16:10 box and painted over the model title. The row thumbnails escaped this only by
            // using a FIXED .frame(width:height:), which does constrain.
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(c.line)
            }
    }

    private var coverFallback: some View {
        Image(systemName: "shippingbox")
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(c.t3)
    }

    /// A row for one profile.
    ///
    /// The meta line is either MakerWorld's numbers or an explicit statement that MakerWorld has
    /// none. It is never "—": on a popular model the majority of profiles carry no published
    /// metadata, and rendering a dash for all of them is what made the whole picker look broken.
    private func profileRow(_ row: MWProfileRow) -> some View {
        let selected = picked?.id == row.id
        let detail = row.detail
        let materials = MakerWorld.materialsLine(detail)

        return Tap {
            picked = row
        } content: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(c.thumb)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Group {
                            if let url = client.makerworldThumbUrl(row.coverUrl) {
                                AsyncImage(url: url) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Color.clear
                                }
                            } else {
                                Image(systemName: "square.stack.3d.up")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(c.t3)
                            }
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(MakerWorld.metaLine(detail))
                            .font(.mono(11.5, weight: .medium))
                            .foregroundStyle(c.t3)
                            .lineLimit(2)
                        if let detail {
                            HStack(spacing: 3) {
                                ForEach(Array(detail.slots.prefix(4).enumerated()), id: \.offset) { _, s in
                                    Swatch(value: FilamentColor.norm(s.color), size: 9, radius: 5)
                                }
                            }
                        }
                    }

                    if !materials.isEmpty {
                        Text(materials)
                            .font(.mono(11, weight: .medium))
                            .foregroundStyle(c.t3)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(c.accent)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(c.accent, lineWidth: selected ? 1.5 : 0)
            }
            .contentShape(.rect)
        }
        .accessibilityLabel("\(row.title). \(MakerWorld.metaLine(detail)). \(materials)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    /// What has been imported before — the panel's cold-start state, so an empty text field is not
    /// the only thing this screen ever says.
    @ViewBuilder
    private var recentBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            UploadSectionLabel("IMPORTED BEFORE")
            VStack(spacing: 9) {
                ForEach(recent) { item in
                    Tap {
                        // Re-resolving is the only thing this row can honestly offer: the file is
                        // already in the library, and this panel imports rather than browses.
                        guard let source = item.sourceUrl else { return }
                        url = source
                        resolve()
                    } content: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(c.t3)
                                .frame(width: 28)
                            Text(item.filename ?? "Imported model")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(c.t2)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if item.sourceUrl != nil {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(c.t3)
                            }
                        }
                        .padding(11)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
                        .contentShape(.rect)
                    }
                    .disabled(item.sourceUrl == nil)
                }
            }
        }
        .padding(.top, 20)
    }

    /// A failure plus, where a browser can succeed where the server cannot, the way out.
    @ViewBuilder
    private func failureCard(_ f: MWFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            UploadErrorCard(text: f.message)
            if f.offerWebLink, let modelId = resolved?.modelId ?? parsedModelId,
               let link = MakerWorld.webUrl(modelId: modelId) {
                Tap { openURL(link) } content: {
                    HStack(spacing: 6) {
                        Text("Open on MakerWorld")
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(c.accent)
                    .contentShape(.rect)
                }
            }
        }
        .padding(.top, 12)
    }

    /// The model id out of whatever was typed, so **Open on MakerWorld** still works when the failure
    /// happened before anything resolved.
    private var parsedModelId: Int? {
        guard let match = trimmedUrl.firstMatch(of: /models\/(\d+)/) else { return nil }
        return Int(match.1)
    }

    @ViewBuilder
    private func importButton(_ r: MakerWorldResolved) -> some View {
        let allowed = !access.blocksImport
        VStack(spacing: 8) {
            // Pinned with the button, not buried at the top of the scroll: on an 88-profile model the
            // user is thousands of points down when an import is refused, and the whole remedy ("try
            // another profile") was being written where they had no reason to look.
            if let failure, failure.step == .importing {
                failureCard(failure.detail)
                    .padding(.bottom, 2)
            }

            Tap(disabled: importing || !allowed, action: doImport) {
                HStack(spacing: 9) {
                    if importing {
                        ProgressView().tint(c.accentInk)
                    } else if !allowed {
                        // A padlock that explains itself beats a live-looking control that refuses.
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(c.t3)
                    }
                    Text(importLabel(allowed: allowed))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(allowed ? c.accentInk : c.t3)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(allowed ? c.accent : c.s3))
                .contentShape(.rect)
            }
            .accessibilityLabel("\(importLabel(allowed: allowed)), model \(r.modelId)")
            .accessibilityHint(access.message ?? "")

            // One line, under the button, before the download — not a modal and not a checkbox.
            if let l = MakerWorld.licence(r.design) {
                Text(l.obligation)
                    .font(.system(size: 11, weight: .medium))
                    .lineSpacing(2)
                    .foregroundStyle(c.t3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 14)
    }

    /// Always "Import to library" once allowed.
    ///
    /// It used to say "Import again" whenever ANY profile of this model had been imported, which is
    /// a claim about the selected profile that `already_imported_library_ids` cannot support — the
    /// ids are library files, and nothing maps them back to a profile. A duplicate is deduped
    /// server-side and reported honestly by the toast, so the label has nothing to add.
    private func importLabel(allowed: Bool) -> String {
        if importing { return "Importing…" }
        guard allowed else { return access == .checking ? "Checking…" : "Import unavailable" }
        return "Import to library"
    }

    // MARK: Actions

    /// Dispatch on what is actually in the field. The button already said which this would be.
    private func submit() {
        switch intent {
        case .idle:
            return
        case .resolve(let id):
            // Normalised through the model id rather than passed through verbatim, so a locale path,
            // a slug or a `#profileId-` fragment all reach `resolve` in the one shape it parses.
            resolve(MakerWorldSearch.modelUrl(id: id))
        case .search(let query):
            search(query)
        }
    }

    /// The owner's own collections, from their la-push. Built from the same config the Live Activity
    /// registration uses, so there is one answer to "where is my push server".
    private var collectionsClient: CollectionsClient {
        CollectionsClient(baseUrl: model.config.flatMap(ConfigRules.resolvePushUrl),
                          apiKey: model.config?.apiKey ?? "")
    }

    private func openCollections() {
        guard !searching, !importing else { return }
        showingCollections = true
        activeCollection = nil
        activeNav = nil
        activeQuery = nil
        hits = []
        hitTotal = nil
        searchError = nil
        searching = true
        Task {
            defer { searching = false }
            do {
                collections = try await collectionsClient.collections()
            } catch {
                // The server's own sentence — it names which machine to go and look at.
                searchError = error.localizedDescription
                showingCollections = false
            }
        }
    }

    /// Leave a folder for the folder list. Only refetches if the list was somehow lost — going back
    /// should be instant, and the collections have not changed in the seconds since they loaded.
    private func backToCollections() {
        activeCollection = nil
        hits = []
        hitTotal = nil
        searchError = nil
        if collections.isEmpty {
            openCollections()
        } else {
            showingCollections = true
        }
    }

    private func openCollection(_ folder: MakerWorldCollection) {
        guard !searching, !importing else { return }
        showingCollections = false
        activeCollection = folder
        activeNav = nil
        activeQuery = nil
        hits = []
        hitTotal = nil
        searchError = nil
        searching = true
        Task {
            defer { searching = false }
            do {
                let page = try await collectionsClient.designs(in: folder.id)
                guard activeCollection?.id == folder.id else { return }
                hits = page.hits ?? []
                hitTotal = page.total
            } catch {
                searchError = error.localizedDescription
            }
        }
    }

    private func search(_ query: String) {
        guard !searching, !importing else { return }
        searching = true
        searchError = nil
        showingCollections = false
        activeCollection = nil
        activeNav = nil
        activeQuery = query
        hits = []
        hitTotal = nil
        Task {
            defer { searching = false }
            do {
                let page = try await searchClient.search(query)
                guard activeQuery == query else { return }   // a newer query won
                hits = page.hits ?? []
                hitTotal = page.total
            } catch {
                searchError = error.localizedDescription
            }
        }
    }

    private func browse(_ nav: MWNav) {
        guard !searching, !importing else { return }
        searching = true
        searchError = nil
        showingCollections = false
        activeCollection = nil
        activeQuery = nil
        activeNav = nav.key
        hits = []
        hitTotal = nil
        Task {
            defer { searching = false }
            do {
                let page = try await searchClient.browse(navKey: nav.key)
                guard activeNav == nav.key else { return }
                hits = page.hits ?? []
                hitTotal = page.total
            } catch {
                searchError = error.localizedDescription
            }
        }
    }

    /// Paging is by offset, and this endpoint's ordering is not stable between calls — the same query
    /// returned a different leading hit seconds apart — so the page is MERGED rather than appended.
    private func loadMore() {
        guard !loadingMore, !searching else { return }
        let offset = hits.count
        loadingMore = true
        Task {
            defer { loadingMore = false }
            do {
                let page: MWSearchPage
                if let folder = activeCollection {
                    page = try await collectionsClient.designs(in: folder.id, offset: offset)
                } else if let nav = activeNav {
                    page = try await searchClient.browse(navKey: nav, offset: offset)
                } else if let q = activeQuery {
                    page = try await searchClient.search(q, offset: offset)
                } else {
                    return
                }
                hits = MakerWorldSearch.merge(hits, page.hits ?? [])
                if let total = page.total { hitTotal = total }
            } catch {
                searchError = error.localizedDescription
            }
        }
    }

    /// A tapped tile enters the SAME detail flow a pasted link does. Search adds an entry point, not
    /// a second flow — the licence, the profile picker and the import gate all live in one place.
    private func open(_ hit: MWSearchHit) {
        url = MakerWorldSearch.modelUrl(id: hit.id)
        resolve(url)
    }

    private func resolve() { resolve(trimmedUrl) }

    private func resolve(_ u: String) {
        // `!importing` matters: swapping the design out from under an in-flight import left the
        // failure card offering "Open on MakerWorld" for whichever model happened to be on screen,
        // and handed the wizard off for a model the panel was no longer showing.
        guard !u.isEmpty, !resolving, !importing else { return }
        resolving = true
        failure = nil
        resolved = nil
        rows = []
        picked = nil
        licenceExpanded = false
        Task {
            defer { resolving = false }
            do {
                let r = try await client.resolveMakerWorld(u)
                resolved = r
                rows = MakerWorld.rows(r)
                picked = MakerWorld.preselect(rows, defaultInstanceId: r.design.defaultInstanceId)
                // A resolve is proof the server is reachable. Without this, one failed probe at open
                // locked the import for the life of the panel even as the design rendered fine.
                if access.worthRetrying { access = await client.makerWorldAccess() }
            } catch {
                failure = (.resolve, mwFailure(.resolve, error))
            }
        }
    }

    private func doImport() {
        guard let r = resolved, !importing, !access.blocksImport else { return }
        importing = true
        failure = nil
        Task {
            do {
                let res = try await client.importMakerWorld(
                    MakerWorldImportRequest(
                        modelId: r.modelId,
                        // The resolve response's own profile id is the fallback ONLY when no row is
                        // picked at all. Falling back for a picked row that happens to carry no
                        // profileId would quietly import a different profile than the one selected.
                        profileId: picked.map(\.profileId) ?? r.profileId,
                        instanceId: picked?.id,
                        folderId: nil
                    )
                )
                onImported?()
                // A toast rather than an alert: the outcome arrives as the sheet is closing, and an
                // alert owned by a view that is going away has nowhere to live.
                let what = res.filename ?? "The model"
                model.toast = res.wasExisting == true
                    ? "\(what) was already in your library"
                    : "\(what) added to your library"

                // Hand straight off into the print wizard rather than dropping the user back on the
                // Files list to find the file they just asked for. It is the SAME wizard — the LAN
                // gate, the wrong-printer guard, the plate review and the enqueue all already live
                // there, and a second print path would drift from every one of them.
                //
                // A MakerWorld import is never printable as-is: measured, the file is a plain `3mf`
                // whose `/gcode` answers 404 and whose embedded profile targets someone else's
                // machine. So the wizard opens at its first step and slices, exactly as it would for
                // any unsliced upload.
                // Replacing the overlay rather than closing and reopening it: `onClose` sets it to
                // nil, and going nil → .wizard in the same turn flashes an empty frame.
                if let file = try? await client.getFileDetail(res.libraryFileId) {
                    model.overlay = .wizard(file)
                } else {
                    onClose()
                }
            } catch {
                importing = false
                failure = (.importing, mwFailure(.importing, error))
            }
        }
    }

    /// Turn a thrown request into copy that blames the right hop. `BambuddyError` carries the status
    /// and the API's own `detail`; anything else never reached the server.
    private func mwFailure(_ step: MakerWorld.Step, _ error: Error) -> MWFailure {
        MakerWorld.failure(step: step,
                           status: (error as? BambuddyError)?.status ?? 0,
                           detail: uploadApiDetail(error))
    }

    // MARK: Field fallbacks

    private func byline(_ design: MWDesign) -> String {
        var s = ""
        if let name = design.designCreator?.name, !name.isEmpty { s = "@\(name)" }
        if let downloads = design.downloadCount {
            s += s.isEmpty ? "\(downloads) downloads" : "  ·  \(downloads) downloads"
        }
        return s
    }
}

// MARK: - Shared sheet furniture

/// The bottom sheet's drag handle. Decorative only — the sheet is dismissed by the backdrop or
/// Cancel, so it carries no gesture and is hidden from assistive tech.
private struct UploadSheetGrabber: View {
    @Environment(\.palette) private var c

    var body: some View {
        Capsule()
            .fill(c.line2)
            .frame(width: 38, height: 5)
            .accessibilityHidden(true)
    }
}

/// A 36 pt accent tile behind a row's glyph.
private struct UploadSourceTile: View {
    let symbol: String
    @Environment(\.palette) private var c

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(c.accentDim)
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(c.accent)
            }
    }
}

/// The one failure card used by both panels.
private struct UploadErrorCard: View {
    let text: String
    @Environment(\.palette) private var c

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(c.error)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(c.t2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.errorDim))
    }
}

/// Small uppercase section heading.
private struct UploadSectionLabel: View {
    let text: String
    @Environment(\.palette) private var c

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.mono(11))
            .tracking(1)
            .foregroundStyle(c.t3)
            .padding(.bottom, 10)
    }
}
