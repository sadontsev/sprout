#if os(macOS)
import AppKit
import QuickLookUI
import SwiftUI
import WebKit

// Space in Files previews the selected file (§5.4).
//
// **What `QLPreviewPanel` can show is a FILE URL, and nothing else.** There is no way to put a view
// of ours inside the shared panel — that is what a Quick Look generator EXTENSION is for, and an
// extension would need its own copy of the client, the credentials and the renderer. So this builds
// the preview as an image and hands the panel that image: one page, rendered from the same palette
// and the same facts the Files inspector draws, so the space bar and the inspector never disagree
// about what a file is.
//
// The mesh case is the one that earns its complexity. §5.4 asks that an `.stl` preview in the same
// renderer the viewer window uses — which is `StlPage` in a WKWebView, and neither Quick Look's own
// HTML preview (a `file://` document cannot fetch the Bambuddy origin: no CORS headers, and the
// header of `StlViewerOverlay.swift` says why that is structural) nor a downloaded `.stl` handed to
// the system (whose 3D support is not something this app may assume) can stand in for it. So the
// page is loaded offscreen, photographed, and the photograph becomes the hero of the same card.
// When that does not work, the card SAYS the mesh could not be rendered and names what will show
// it — it never shows an empty frame.

// MARK: - Entry points

/// Quick Look for a library file.
///
/// `MacFilesSection` owns the space bar; this owns everything after it.
enum MacQuickLook {

    /// Space. Previews `file`, or closes the panel if it is already showing that file — which is
    /// what the space bar does in Finder, and the only behaviour that makes it a toggle rather than
    /// a one-way door.
    ///
    /// `unavailable` is the sentence shown when there is nothing to preview. It is a parameter
    /// because "nothing is selected" and "this surface has nothing previewable on it" are different
    /// facts and only the caller knows which one applies.
    @MainActor
    static func toggle(
        file: LibraryFile?,
        model: AppModel,
        unavailable: String = "Select a file to preview."
    ) {
        MacQuickLookController.shared.toggle(file: file, model: model, unavailable: unavailable)
    }

    /// Close the panel — for a caller that has just deleted or navigated away from what it shows.
    @MainActor
    static func dismiss() {
        MacQuickLookController.shared.dismiss()
    }
}

// MARK: - The panel

/// Data source and delegate for the shared `QLPreviewPanel`.
///
/// **The panel is driven directly rather than through the responder chain.** AppKit's designed route
/// is a `QLPreviewPanelController` that `acceptsPreviewPanelControl` when it is the first responder,
/// which needs an `NSResponder` in the chain — SwiftUI gives a section view no such thing without
/// wrapping the whole surface in an `NSViewRepresentable`. Setting `dataSource`/`delegate` and
/// ordering the panel front works because nothing else in this app ever claims it.
///
/// The corollary is that `updateController()` must never be called: it re-walks the responder chain,
/// finds no controller, and clears the data source out from under the panel.
///
/// `@preconcurrency` on the data-source conformance, and only on that one. QuickLookUI predates
/// Swift concurrency and its protocols carry no isolation annotation at all, so a `@MainActor`
/// conformer "crosses into main actor-isolated code" as far as the compiler can see. The panel does
/// in fact call these on the main thread — it is an `NSWindow` — and `@preconcurrency` is the way to
/// say so while KEEPING a runtime check, which marking the methods `nonisolated` and reaching for
/// `assumeIsolated` would throw away. `QLPreviewPanelDelegate` needs no such annotation: every one
/// of its members is optional, so nothing is being promised across the boundary.
@MainActor
private final class MacQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = MacQuickLookController()

    private var item: MacQuickLookItem?
    private var showingFileId: Int?
    private var renderTask: Task<Void, Never>?
    /// Bumped per render so each pass writes a NEW URL. Quick Look caches a preview against the URL
    /// it was given, so re-rendering into the same path shows the first version forever.
    private var generation = 0

    // MARK: Presenting

    func toggle(file: LibraryFile?, model: AppModel, unavailable: String) {
        guard let panel = QLPreviewPanel.shared() else { return }
        guard let file else {
            model.toast = .failure(unavailable)
            return
        }
        if panel.isVisible, showingFileId == file.id {
            dismiss()
            return
        }
        present(file, model: model, panel: panel)
    }

    func dismiss() {
        renderTask?.cancel()
        renderTask = nil
        showingFileId = nil
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    private func present(_ file: LibraryFile, model: AppModel, panel: QLPreviewPanel) {
        renderTask?.cancel()
        showingFileId = file.id
        let title = MacFileBrowse.displayName(file)
        // `?? .dark` here would light-theme users a dark preview panel: this is the one resolution site
        // with no view to read `@Environment(\.colorScheme)` from, so the system half comes from AppKit
        // directly rather than being assumed.
        let systemScheme: ColorScheme =
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let palette = Palette.forScheme(model.theme.colorScheme ?? systemScheme)

        // Phase one, synchronous: the facts are already in hand, so the panel opens on the keypress
        // rather than after a fetch. A space bar that pauses before showing anything is not a quick
        // look at all.
        write(card(file, title: title, palette: palette, hero: .pending), title: title)
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }

        // Phase two: the picture.
        renderTask = Task { [weak self] in
            let hero = await MacQuickLookHero.load(file, model: model)
            guard !Task.isCancelled, let self, self.showingFileId == file.id else { return }
            self.write(self.card(file, title: title, palette: palette, hero: hero), title: title)
            guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
            panel.reloadData()
        }
    }

    // MARK: Rendering

    private func card(
        _ file: LibraryFile,
        title: String,
        palette: Palette,
        hero: MacQuickLookHero.State
    ) -> some View {
        MacQuickLookCard(file: file, title: title, hero: hero)
            // `ImageRenderer` inherits nothing from any view hierarchy, so the tokens have to be
            // handed to it explicitly or the card renders against the environment defaults.
            .environment(\.palette, palette)
            .environment(\.metrics, .mac)
            .environment(\.colorScheme, palette == .dark ? .dark : .light)
    }

    private func write(_ view: some View, title: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let png = image.pngRepresentationData() else { return }
        generation += 1
        let dir = FileManager.default.temporaryDirectory.appending(path: "quicklook", directoryHint: .isDirectory)
        let url = dir.appending(path: "preview-\(generation).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            // A preview that cannot be written is not worth an alert — the panel simply keeps
            // whatever it had, which is either the phase-one card or nothing.
            return
        }
        // Previous generations are dead the moment this one lands, and a session of previews would
        // otherwise leave one PNG per keypress in the container.
        if let old = item?.previewItemURL, old != url {
            try? FileManager.default.removeItem(at: old)
        }
        item = MacQuickLookItem(url: url, title: title)
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        item == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        item
    }

    // MARK: Panel lifetime

    /// `QLPreviewPanelDelegate` refines `NSWindowDelegate`, so the panel's own close reaches here.
    /// If a future SDK stops doing that this simply never fires — which costs nothing, because
    /// `present` already checks `panel.isVisible` before reloading.
    @objc func windowWillClose(_ notification: Notification) {
        renderTask?.cancel()
        renderTask = nil
        showingFileId = nil
    }
}

/// One preview item. `QLPreviewItem` is an ObjC protocol, so this has to be a class.
private final class MacQuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}

// MARK: - The picture at the top of the card

/// Where a preview's hero image comes from, and what to say when there isn't one.
enum MacQuickLookHero {

    enum State {
        /// Still being fetched or rendered.
        case pending
        case image(PlatformImage)
        /// Nothing to show, and the reason — never an empty frame.
        case none(String)
    }

    /// How long the mesh render is given before the card gives up on it.
    ///
    /// A quick look that takes half a minute has stopped being one, and the fallback still names
    /// where the mesh CAN be seen — so the cap costs the user a sentence, not the model.
    static let meshTimeout: Duration = .seconds(12)

    @MainActor
    static func load(_ file: LibraryFile, model: AppModel) async -> State {
        // `isStl` is the mesh renderer's exact capability — it is an STL parser, and a `.3mf` is a
        // zip container it cannot open. Not `isSliced`, which is a label, and not `hasGcode`, which
        // is the layer viewer's question.
        if LibraryFileCaps.isStl(file) {
            return await MacMeshSnapshot.render(file, model: model)
        }
        guard let url = model.client?.fileThumbUrl(
            file.id, token: model.cameraToken, thumbnailPath: file.thumbnailPath
        ) else {
            return .none(noThumbnailNote)
        }
        // Token in the query, never `X-API-Key` — the thumbnail endpoint 401s on the header.
        guard let image = await ThumbCache.shared.image(for: url) else {
            return .none(noThumbnailNote)
        }
        return .image(image)
    }

    /// Deliberately not "this file has no preview": Bambuddy renders thumbnails for files it has
    /// processed, and a failed fetch and an absent thumbnail arrive here identically. Saying which
    /// one it was would be a claim nothing here has checked.
    static let noThumbnailNote =
        "No plate preview came back for this file."
}

// MARK: - Photographing the mesh page

/// Renders `StlPage` offscreen and photographs it.
///
/// This is the same document, the same bridge and the same configuration the viewer window loads —
/// `MacViewerWebView.makeConfiguration` is shared with it precisely so a preview and the window
/// cannot render differently.
///
/// **It needs a window.** WebKit drives its compositor off a view that is in one, and
/// `takeSnapshot` on a detached view comes back blank. The window is borderless, fully transparent,
/// mouse-transparent, sits far off any screen and is torn down in the same function — but it is a
/// real window for the length of one render, and that is worth knowing about before changing it.
@MainActor
enum MacMeshSnapshot {
    /// Rendered at the card's hero size, so the snapshot is not resampled twice.
    static let size = CGSize(width: 660, height: 440)

    static func render(_ file: LibraryFile, model: AppModel) async -> MacQuickLookHero.State {
        guard let client = model.client else { return .none("Not connected to Bambuddy.") }

        let name = MacFileBrowse.displayName(file)
        let html: String
        let base = ViewerJS.documentBase(of: client.baseUrl)
        do {
            // Single-use and short-lived, exactly as in the viewer window: minted once, for this
            // render, and never reused.
            let safe = LibraryDownloadName.pathSegment(name, fallback: "model-\(file.id).stl")
            let url = try await client.mintFileDownloadUrl(file.id, filename: safe)
            html = StlPage.html(url: url.absoluteString, name: name, compact: true, headers: [:])
        } catch let e as BambuddyError {
            return .none(e.detail)
        } catch {
            return .none(error.localizedDescription)
        }
        guard !Task.isCancelled else { return .none(cancelledNote) }

        let inbox = Inbox()
        let coordinator = MacViewerWebView.Coordinator(handle: MacViewerPageHandle()) { event in
            inbox.receive(event)
        }
        let web = WKWebView(
            frame: CGRect(origin: .zero, size: size),
            configuration: MacViewerWebView.makeConfiguration(handler: coordinator)
        )
        web.underPageBackgroundColor = NSColor(Palette.dark.bg)

        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView?.addSubview(web)
        window.orderFrontRegardless()
        defer {
            web.stopLoading()
            web.configuration.userContentController.removeScriptMessageHandler(forName: ViewerJS.bridgeName)
            web.configuration.userContentController.removeAllUserScripts()
            web.removeFromSuperview()
            window.orderOut(nil)
        }

        web.loadHTMLString(html, baseURL: base)

        // Polled rather than continuation-passed on purpose: a `CheckedContinuation` needs a
        // `Sendable` result and every value in flight here — the outcome, the image — is AppKit's.
        // Everything in this function is `@MainActor`, so a poll costs one hop and no bridging.
        let deadline = ContinuousClock.now.advanced(by: MacQuickLookHero.meshTimeout)
        while inbox.outcome == nil, ContinuousClock.now < deadline {
            if Task.isCancelled { return .none(cancelledNote) }
            try? await Task.sleep(for: .milliseconds(120))
        }

        switch inbox.outcome {
        case .failed(let message, _):
            return .none(message)
        case .none:
            return .none(timeoutNote)
        default:
            break
        }

        // One frame after `loaded` the page has uploaded its buffers but may not have drawn; the
        // snapshot would then be the empty clear colour.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return .none(cancelledNote) }
        guard let image = try? await web.takeSnapshot(configuration: nil) else {
            return .none(snapshotNote)
        }
        return .image(image)
    }

    /// Collects the first terminal event the page posts.
    ///
    /// A class rather than a captured `var` because the bridge callback is escaping, and the point
    /// of it is that the poll loop below reads what the callback wrote.
    @MainActor
    private final class Inbox {
        private(set) var outcome: ViewerEvent?

        func receive(_ event: ViewerEvent) {
            guard outcome == nil else { return }
            switch event {
            case .loaded, .failed: outcome = event
            // The mesh page never posts `ready` — that is the layer viewer's event — but a page
            // that did would not be finished parsing, so it is not an outcome.
            case .ready: break
            }
        }
    }

    static let cancelledNote = "The preview was cancelled."
    static let timeoutNote =
        "This mesh took too long to render for a preview. Open it with View in 3D, which has no time limit."
    static let snapshotNote =
        "Couldn’t photograph the mesh. Open it with View in 3D."
}

// MARK: - The card

/// What the panel shows: the plate preview (or the mesh), the name, and the facts the Files
/// inspector lists.
///
/// It is a still image by the time Quick Look sees it, so nothing here may be interactive or async.
private struct MacQuickLookCard: View {
    let file: LibraryFile
    let title: String
    let hero: MacQuickLookHero.State

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// Fixed width so the render is deterministic; the height follows the content, because a file
    /// with no slicer metadata has three fewer rows and should not be padded out to match one that
    /// has them.
    private static let width: CGFloat = 720

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroView
                .frame(height: 440)
                .frame(maxWidth: .infinity)
                .background(c.thumb)
                .overlay(alignment: .bottom) {
                    // The file's own thumbnail is ONE image whether the 3MF holds one plate or six,
                    // and nothing here has read `/plates`. Captioning it "PLATE 1 OF 1" would be a
                    // claim about the file; the type is a claim about the picture.
                    Text(verbatim: (file.fileType ?? "file").uppercased())
                        .font(.mono(m.monoLabel, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(c.t3)
                        .padding(.bottom, 10)
                }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: title)
                        .scaledFont(19, weight: .semibold)
                        .foregroundStyle(c.t1)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: MacQuickLookFacts.identity(file))
                        .scaledMono(12, weight: .medium)
                        .foregroundStyle(c.t3)
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(MacQuickLookFacts.rows(file), id: \.label) { row in
                        factRow(row.label, row.value)
                    }
                    if !slots.isEmpty { materials }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.width)
        .background(c.bg)
    }

    private var slots: [FileMetadata.FilamentSlot] { file.metadata?.filamentSlots ?? [] }

    @ViewBuilder
    private var heroView: some View {
        switch hero {
        case .image(let image):
            Image(platform: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .pending:
            heroNote("Loading preview…")
        case .none(let reason):
            heroNote(reason)
        }
    }

    private func heroNote(_ text: String) -> some View {
        Text(verbatim: text)
            .scaledFont(13)
            .foregroundStyle(c.t3)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .padding(.horizontal, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var materials: some View {
        HStack(spacing: 0) {
            Text("Materials")
                .scaledFont(12, weight: .medium)
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Indexed, not by value: two slots of the same colour are ordinary, and identifying
            // swatches by their contents would collapse them into one.
            HStack(spacing: 5) {
                ForEach(slots.indices, id: \.self) { i in
                    Swatch(value: FilamentColor.norm(slots[i].color), size: 15, radius: Metrics.swatchRadius(15))
                }
            }
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: label)
                .scaledFont(12, weight: .medium)
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value)
                .scaledMono(12, weight: .medium)
                .foregroundStyle(c.t1)
                .monospacedDigit()
        }
    }
}

// MARK: - The facts

/// The rows the Files inspector lists, as data.
///
/// Pure and separate from the card so the two surfaces cannot drift: the inspector draws these
/// questions in `statsCard`, and this is the same set of answers with the same absence rules —
/// a row appears only when the file actually carries it, and `Dash.fmtDuration` gives one opinion
/// about what a missing estimate looks like.
///
/// The inspector's explanatory prose under the divider is deliberately NOT reproduced. A preview is
/// a glance, and those sentences answer "why is this row missing?", which needs the room the panel
/// does not have — reproducing them here would be a second copy of reasoning that has already been
/// wrong once.
enum MacQuickLookFacts {

    struct Row {
        let label: String
        let value: String
    }

    /// "3MF · 4.2 MB · for Bambu Lab H2C".
    ///
    /// `slicedForModel` names the machine a file was PREPARED for. It is a label, not a capability —
    /// a plain project `.3mf` carries one and holds no toolpaths at all — so it is shown and gates
    /// nothing.
    static func identity(_ f: LibraryFile) -> String {
        var parts = [(f.fileType ?? "file").uppercased()]
        let size = MacFileBrowse.bytes(f.fileSize?.double)
        if !size.isEmpty { parts.append(size) }
        if let machine = f.slicedForModel, !machine.isEmpty { parts.append("for \(machine)") }
        return parts.joined(separator: " · ")
    }

    static func rows(_ f: LibraryFile) -> [Row] {
        var out = [
            Row(label: "Print time", value: printTime(f)),
            Row(label: "Filament", value: filament(f)),
        ]
        // Layer height lives in `metadata`, which only `GET /library/files/{id}` populates. Drawn
        // when it is there, and simply absent when it is not — never "0.20 mm" derived from nothing.
        if let layer = f.metadata?.layerHeight?.double, layer > 0 {
            out.append(Row(label: "Layer height", value: String(format: "%.2f mm", layer)))
        }
        return out
    }

    static func printTime(_ f: LibraryFile) -> String {
        guard let seconds = f.printTimeSeconds?.double else { return "—" }
        return Dash.fmtDuration(seconds / 60)
    }

    static func filament(_ f: LibraryFile) -> String {
        guard let grams = f.filamentUsedGrams?.double, grams > 0, grams.isFinite else { return "—" }
        return String(format: "%.0f g", grams)
    }
}
#endif
