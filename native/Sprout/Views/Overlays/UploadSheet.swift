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
        .frame(maxHeight: showMakerWorld ? maxHeight : nil)
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From MakerWorld")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(c.t1)
                        Text("Paste a model link")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(c.t3)
                    }
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
    @State private var failure: MWFailure?
    @State private var importing = false
    @State private var recent: [MakerWorldRecentImport] = []
    @State private var licenceExpanded = false
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
                    if let failure {
                        failureCard(failure)
                    }
                    if let resolved {
                        designBlock(resolved)
                    } else if !recent.isEmpty {
                        recentBlock
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

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 0) {
            UploadSectionLabel("MODEL LINK")

            HStack(spacing: 10) {
                TextField(
                    "",
                    text: $url,
                    prompt: Text("https://makerworld.com/en/models/…").foregroundStyle(c.t3)
                )
                .font(.system(size: 14))
                .foregroundStyle(c.t1)
                .tint(c.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(resolve)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))

                Tap(disabled: resolving || trimmedUrl.isEmpty, action: resolve) {
                    Group {
                        if resolving {
                            ProgressView().tint(c.accentInk)
                        } else {
                            Text("Resolve")
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
                VStack(spacing: 9) {
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
                        Text("Already in your library")
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
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
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

    private func importLabel(allowed: Bool) -> String {
        if importing { return "Importing…" }
        guard allowed else { return access == .checking ? "Checking…" : "Import unavailable" }
        return alreadyImported ? "Import again" : "Import to library"
    }

    // MARK: Actions

    private func resolve() {
        let u = trimmedUrl
        guard !u.isEmpty, !resolving else { return }
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
            } catch {
                failure = mwFailure(.resolve, error)
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
                        // The picked profile wins; the resolve response's own profile id is the
                        // fallback for a model that lists no instances.
                        profileId: picked?.profileId ?? r.profileId,
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
                onClose()
            } catch {
                importing = false
                failure = mwFailure(.importing, error)
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
