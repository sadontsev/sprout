#if os(macOS)
import SwiftUI
import os

// The layer / mesh viewer as its own window (prototype `1g`), and the only place on macOS that
// hosts either page.
//
// Everything expensive is shared and unchanged: `LayerPage` and `StlPage` build the same
// self-contained documents iOS ships, `ViewerJS` supplies the injected literals and the bridge, and
// `MacViewerWebView` is the AppKit twin of iOS's `ViewerWebView`. What is new here is chrome — a
// toolbar segment, a 236 pt sidebar, keyboard stepping and playback — plus the one thing a window
// has that a `fullScreenCover` does not: it can be opened for a file that cannot be viewed the way
// it was asked for, so it has to SAY so.

// MARK: - The request

/// What the viewer window (1g) is showing. `Codable` + `Hashable` because `WindowGroup(for:)`
/// persists its value across launches, so a restored window can reopen the same file.
///
/// **Identity is the file, and only the file.** `openWindow(id:value:)` reuses a window when the
/// value compares equal, so a synthesised `Hashable` over `fileId`, `name` *and* `mode` made "View
/// in 3D" then "View layers" on one file open two windows — which §5.4 explicitly does not want,
/// and which `MacFilesSection.openViewer` and `MacFilesInspector.openViewer` both filed against this
/// file. The value answers two questions — "which window is this?" and "which segment does it open
/// on?" — and only the first may take part in identity.
///
/// The second question is then carried by `MacViewerRoute`, because equal values do not deliver a
/// new `mode`: without it, clicking the other menu item on a file whose window is already open would
/// merely raise that window, which is the same silent no-op in a different costume.
struct MacViewerRequest: Codable, Hashable, Identifiable {
    enum Mode: String, Codable, Hashable, CaseIterable, Identifiable {
        case layers, model

        var id: String { rawValue }

        /// Segment titles, from `1g`.
        var label: String { self == .layers ? "Layers" : "3D model" }
        /// The window title's suffix — `1g` reads "lamp-shade-hex.3mf — layers".
        var titleSuffix: String { self == .layers ? "layers" : "3D model" }
    }

    /// WHICH file, and therefore which endpoint serves its G-code.
    ///
    /// This used to be a bare `fileId: Int`, and that single field is the entire reason the Mac
    /// refused "View layers" for a file on the printer's card while iOS had offered it all along. The
    /// inspector even said so as though it were a fact about the server —
    /// *"layer preview work on library files, not on the printer's own storage"* — when
    /// `GET /printers/{id}/files/gcode?path=…` exists and answers. The limitation was this type.
    ///
    /// Two cases rather than an optional path, so a request cannot be half of each: a library file has
    /// no path and an SD entry has no id, and every branch that builds a URL must state which it is.
    enum Target: Codable, Hashable {
        case library(fileId: Int)
        case printer(printerId: Int, path: String)

        /// The identity string. Prefixed per case so a library file with id 7 and a printer path that
        /// happens to stringify the same way can never collide.
        var key: String {
            switch self {
            case .library(let fileId): "library:\(fileId)"
            case .printer(let printerId, let path): "printer:\(printerId):\(path)"
            }
        }

        /// The library id, when there is one. The mesh viewer and the library listing both need it,
        /// and both must get `nil` — not a sentinel — for an SD entry.
        var libraryFileId: Int? {
            if case .library(let fileId) = self { return fileId }
            return nil
        }
    }

    let target: Target
    let name: String
    var mode: Mode = .layers

    var id: String { target.key }

    /// **Identity is the file, and only the file.** `openWindow(id:value:)` reuses a window when the
    /// value compares equal, so a synthesised `Hashable` over the target, `name` *and* `mode` made
    /// "View in 3D" then "View layers" on one file open two windows — which §5.4 explicitly does not
    /// want. The value answers two questions — "which window is this?" and "which segment does it open
    /// on?" — and only the first may take part in identity.
    ///
    /// The second question is then carried by `MacViewerRoute`, because equal values do not deliver a
    /// new `mode`: without it, clicking the other menu item on a file whose window is already open
    /// would merely raise that window, which is the same silent no-op in a different costume.
    static func == (lhs: MacViewerRequest, rhs: MacViewerRequest) -> Bool { lhs.target == rhs.target }
    func hash(into hasher: inout Hasher) { hasher.combine(target) }
}

/// Which segment a viewer window was last ASKED for, per file.
///
/// A window that already exists is raised, not rebuilt, so the request value cannot deliver a
/// changed `mode` to it — the values compare equal by design (see `MacViewerRequest`). This is the
/// side channel that does, and `seq` is why asking for the SAME mode twice still registers: a user
/// who switched the window to 3D by hand and then clicked "View layers" in Files is asking for
/// something, and a plain mode comparison would call that no change at all.
@MainActor
@Observable
final class MacViewerRoute {
    static let shared = MacViewerRoute()

    struct Ask: Equatable {
        var mode: MacViewerRequest.Mode
        var seq: Int
    }

    /// Keyed by `MacViewerRequest.Target.key`, not by a library id — an SD entry has no id, and this
    /// map has to hold both kinds for the same reason the request does.
    private(set) var asks: [String: Ask] = [:]
    private var seq = 0

    func ask(_ mode: MacViewerRequest.Mode, for target: MacViewerRequest.Target) {
        seq += 1
        asks[target.key] = Ask(mode: mode, seq: seq)
    }
}

/// The single entry point for opening the viewer. Callers use this rather than `openWindow`
/// directly, so the mode always reaches a window that already exists.
enum MacViewer {
    @MainActor
    static func open(_ f: LibraryFile, mode: MacViewerRequest.Mode, using openWindow: OpenWindowAction) {
        open(target: .library(fileId: f.id), name: MacFileBrowse.displayName(f), mode: mode, using: openWindow)
    }

    /// Open the viewer on a file that lives on the printer's own storage.
    ///
    /// Always `.layers`: the mesh page reads an STL and no endpoint turns a printer path into one, so
    /// there is no mode to choose. `MacViewerWindow` refuses the 3D segment for this target rather
    /// than trusting every caller to remember, because "the caller always passes the right mode" is
    /// not a gate — it is a convention, and this file already records what happens when identity is
    /// left to a convention.
    @MainActor
    static func open(sd pf: PrinterFile, printerId: Int, using openWindow: OpenWindowAction) {
        open(target: .printer(printerId: printerId, path: pf.path),
             name: SdFileCaps.displayName(pf), mode: .layers, using: openWindow)
    }

    @MainActor
    private static func open(
        target: MacViewerRequest.Target,
        name: String,
        mode: MacViewerRequest.Mode,
        using openWindow: OpenWindowAction
    ) {
        MacViewerRoute.shared.ask(mode, for: target)
        openWindow(id: "viewer", value: MacViewerRequest(target: target, name: name, mode: mode))
    }
}

// MARK: - Copy

/// The sentences that explain a refused viewer, in one place.
///
/// `MacFilesInspector` carries private copies of the first two for its dimmed buttons. They must say
/// the same thing — two wordings of one refusal is how a user learns to distrust both — so these are
/// `internal` and that file should adopt them; it is not a file this pass owns.
enum MacViewerCopy {
    static let noLayers =
        "View layers needs toolpaths, and only a sliced .gcode.3mf has them."
    static let noMesh =
        "View in 3D reads STL meshes. A .3mf is a zip container it can’t open."
    /// Both refused. Said as one sentence rather than two stacked ones, because the file is not
    /// half-viewable — there is nothing here to offer.
    static let neither =
        "This file has no toolpaths to scrub and no mesh to render. Layers need a sliced .gcode.3mf; the 3D view reads .stl."
}

// MARK: - The window

/// Explicitly `@MainActor`. Conforming to `View` isolates `body` and nothing else, so the helpers
/// below would otherwise be nonisolated — and every one of them touches a `WKWebView`, which is
/// main-actor-only. Stating it here is what keeps `Task { await handle.run(…) }` a same-actor call
/// instead of a boundary crossing.
@MainActor
struct MacViewerWindow: View {
    let model: AppModel
    let request: MacViewerRequest?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.metrics) private var m

    /// The segment the user picked by hand. `nil` means "whatever was last asked for".
    @State private var picked: MacViewerRequest.Mode?
    @State private var page: PageState = .idle
    /// Bumped to rebuild the hosted page from scratch — a retry, or a re-mint after a spent token.
    @State private var attempt = 0
    /// One automatic download-token re-mint has already been spent on this file.
    @State private var reminted = false
    /// The absolute URL handed to the page, kept so a failure logs the URL that was actually asked
    /// for rather than the one the reader assumes it was.
    @State private var pageUrl: String?

    @State private var handle = MacViewerPageHandle()
    @State private var stats: MacLayerStats?
    @State private var layer = 0
    @State private var hasSupport: Bool?
    @State private var tris: Int?

    @State private var playTask: Task<Void, Never>?
    @State private var speed: Double = 1
    @State private var shading = "steel"
    @State private var lightBackground = false

    /// 1× advances 24 layers a second — a film rate, chosen so the number means something you can
    /// state rather than "the whole stack in about ten seconds", which would make 1× depend on how
    /// tall the print is.
    private static let baseLayersPerSecond = 24.0
    private static let speeds: [Double] = [0.5, 1, 2, 4, 8]
    /// §7's table: ⇧ steps ten.
    private static let coarseStep = 10

    private enum PageState: Equatable {
        case idle
        /// Built and hosted. The string is the document; the URL is the origin it must load on.
        case ready(html: String, base: URL)
        case failed(String)

        /// Whether there is a page to send commands to. The sidebar's VIEW controls all operate
        /// elements inside the document, so they are dead until one exists.
        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    // MARK: Palette

    /// Resolved rather than read from `@Environment`.
    ///
    /// A window scene inherits nothing from `MacRoot`, so `@Environment(\.palette)` here would be
    /// the key's default (dark) whatever the user's theme is — and setting the environment for the
    /// children below does not change what this view itself reads.
    private var c: Palette { Palette.forScheme(model.theme.colorScheme ?? scheme) }

    // MARK: Resolution

    private var store: LibraryStore { model.library }

    /// The library record behind the request, or nil while it cannot be resolved. `resolution` below
    /// is what says WHY it is nil — the three reasons are not interchangeable.
    ///
    /// Always nil for a printer target, and that is not a failure: an SD entry has no library record
    /// to find. `resolution` knows the difference, so "there is no `LibraryFile`" is never rendered as
    /// "the file is missing".
    private var file: LibraryFile? {
        guard let fileId = request?.target.libraryFileId else { return nil }
        return store.files?.first { $0.id == fileId }
    }

    /// The printer path behind the request, when the request is for one.
    private var printerTarget: (printerId: Int, path: String)? {
        guard case .printer(let printerId, let path) = request?.target else { return nil }
        return (printerId, path)
    }

    /// Why there is nothing to show yet. Deliberately four cases, not one empty state: "the listing
    /// has not been read", "the listing could not be read" and "the file is not in it" are three
    /// different things to do next, and CLAUDE.md records what happens when a view renders "you have
    /// none" from a response that also meant "we could not ask".
    private enum Resolution: Equatable {
        case noRequest
        case notConnected
        case loading
        case listingFailed
        case missing
        case found
    }

    private var resolution: Resolution {
        guard let request else { return .noRequest }
        guard model.client != nil else { return .notConnected }
        // A printer target needs no library listing at all — the path IS the address, and the G-code
        // endpoint takes it directly. Running it through the library's three not-found states would
        // report a file that is right there as `.missing`.
        if case .printer = request.target { return .found }
        if file != nil { return .found }
        if store.files == nil { return store.loadFailed ? .listingFailed : .loading }
        return .missing
    }

    // MARK: Mode

    private var ask: MacViewerRoute.Ask? {
        request.flatMap { MacViewerRoute.shared.asks[$0.target.key] }
    }

    private var mode: MacViewerRequest.Mode {
        picked ?? ask?.mode ?? request?.mode ?? .layers
    }

    /// **`hasGcode`, never `isSliced`.** `isSliced` answers "was this prepared by a slicer?" — a
    /// plain project `.3mf` carries a `slicedForModel` and no toolpaths at all, and asking it for
    /// `/gcode` returns 404. This is the exact predicate CLAUDE.md's recurring-bug table names
    /// against this exact feature.
    ///
    /// The printer branch asks the same question of a name rather than of a type field, because that
    /// is all an SD listing carries: `.gcode.3mf` and not any `.3mf`, which is the identical
    /// distinction under a different spelling. The 3D segment is refused outright there — nothing
    /// turns a printer path into a mesh.
    private func supports(_ mode: MacViewerRequest.Mode) -> Bool {
        if let printerTarget {
            return mode == .layers && PrinterFiles.isSliced3mf(printerTarget.path)
        }
        guard let file else { return false }
        return mode == .layers ? LibraryFileCaps.hasGcode(file) : LibraryFileCaps.isStl(file)
    }

    /// Why one segment is refused, or nil when it is not.
    ///
    /// The single source for both the banner across the canvas and the tooltip on the dimmed segment.
    /// They used to be written out separately, and the tooltip's copy was the library's wording
    /// unconditionally — so an SD file would have been told *"a .3mf is a zip container it can't
    /// open"*, which is true of nothing here. Two wordings of one refusal is how a user learns to
    /// distrust both.
    private func reason(for mode: MacViewerRequest.Mode) -> String? {
        guard !supports(mode) else { return nil }
        // For a printer target the 3D segment is not something this file *happens* to lack — no
        // endpoint serves a mesh for a path at all — so it gets the reason that says so.
        if printerTarget != nil {
            return mode == .model ? SdFileCaps.noMeshNote : MacViewerCopy.noLayers
        }
        return mode == .layers ? MacViewerCopy.noLayers : MacViewerCopy.noMesh
    }

    private var refusal: String? {
        guard !supports(mode) else { return nil }
        // "Neither" is its own sentence: offering the other segment when that one is refused too
        // would be the dead affordance this window exists to avoid. Library-only — a printer target
        // never has two halves to lose, so the pair of sentences would read as one missing feature.
        if printerTarget == nil, !supports(.layers), !supports(.model) { return MacViewerCopy.neither }
        return reason(for: mode)
    }

    private var other: MacViewerRequest.Mode { mode == .layers ? .model : .layers }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(c.line).frame(width: 1)
            sidebar
                // §1g: a 236 pt sidebar. Fixed, because every readout in it is a fixed-width
                // label/value pair — letting it stretch would only widen the gap in the middle.
                .frame(width: 236)
        }
        .background(c.bg)
        .navigationTitle(windowTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { modeSegment }
        }
        // AFTER the toolbar, for the same reason `MacRoot` applies it after the drop target: the
        // environment written by `macSceneChrome` only reaches views BELOW it, and `.toolbar`
        // content attached above it sits outside. `MacViewerSegment` reads `@Environment(\.palette)`,
        // so on the light theme the Layers/3D control drew dark-palette tokens — a charcoal track and
        // near-white label — in a light titlebar, while the IDENTICAL segment 40 pt away in the
        // sidebar drew correctly. The toolbar is also the one region `MacWindowProbe` cannot
        // photograph, so no screenshot review would ever have caught it.
        .macSceneChrome(model, systemScheme: scheme)
        .background { keyEquivalents }
        .task(id: buildKey) { await build() }
        .onChange(of: ask) { _, new in
            // A fresh ask from Files overrides whatever segment the window is on.
            if let new { picked = new.mode }
        }
        .onChange(of: mode) { _, _ in resetForRebuild() }
        .onDisappear { stopPlayback() }
    }

    private var windowTitle: String {
        guard let request else { return "Viewer" }
        return "\(request.name) — \(mode.titleSuffix)"
    }

    // MARK: Canvas

    @ViewBuilder
    private var canvas: some View {
        ZStack {
            // The page paints a fixed dark scene the app's light theme cannot reach, so the well
            // behind it is the dark background rather than a palette token — same reasoning as
            // `ViewerChrome`.
            Palette.dark.bg

            switch resolution {
            case .noRequest:
                notice(icon: "square.3.layers.3d", message: "No file was passed to this window.")
            case .notConnected:
                notice(icon: "wifi.slash", message: "Not connected to Bambuddy.")
            case .loading:
                ViewerLoading(label: "READING THE LIBRARY…")
            case .listingFailed:
                ViewerFailure(
                    icon: "wifi.slash",
                    message: "Couldn’t reach the server, so this file can’t be looked up.",
                    onRetry: { Task { await store.load() } }
                )
            case .missing:
                notice(icon: "questionmark.folder", message: "That file is no longer in the library.")
            case .found:
                if let refusal {
                    refusalCard(refusal)
                } else {
                    hostedPage
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if resolution == .found, refusal == nil { canvasBadge }
        }
    }

    @ViewBuilder
    private var hostedPage: some View {
        switch page {
        case .idle:
            ViewerLoading(label: mode == .layers ? "LOADING G-CODE…" : "LOADING MODEL…")
        case .ready(let html, let base):
            MacViewerWebView(
                html: html,
                baseURL: base,
                // The sidebar owns the scrubber and the shading chips on this platform, so the
                // page's own floating card would be a second copy of both — see `viewerChromeCSS`.
                // The mesh page has a first-class way to say the same thing: `compact: true`.
                injectedCSS: mode == .layers ? MacViewerJS.viewerChromeCSS : "",
                adaptsMouseToTouch: mode == .model,
                handle: handle,
                onEvent: { receive($0) }
            )
            // A new attempt is a NEW host: `updateNSView` deliberately refreshes only the callback,
            // because reloading would restart a 70 MB download or spend a single-use token twice.
            .id(attempt)
            .overlay {
                if mode == .layers, stats == nil {
                    ViewerLoading(label: "PARSING TOOLPATHS…")
                }
            }
        case .failed(let message):
            ViewerFailure(
                icon: mode == .layers ? "square.3.layers.3d" : "cube",
                message: message,
                onRetry: retry
            )
        }
    }

    /// `1g`'s corner readout: "TOOLPATH · LAYER 128 / 207 · Z 25.60 MM".
    private var canvasBadge: some View {
        Text(verbatim: badgeText)
            .font(.mono(10, weight: .medium))
            .tracking(0.6)
            .monospacedDigit()
            .foregroundStyle(Palette.dark.t2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: m.chipRadius, style: .continuous).fill(Palette.dark.bg.opacity(0.7)))
            .padding(14)
    }

    private var badgeText: String {
        if mode == .model {
            guard let tris else { return "MESH · LOADING" }
            return "MESH · \(tris.formatted(.number.grouping(.automatic))) TRIS"
        }
        guard let stats else { return "TOOLPATH · PARSING" }
        var out = "TOOLPATH · LAYER \(layer) / \(stats.total)"
        if let z = stats.z(at: layer) {
            out += String(format: " · Z %.2f MM", z)
        }
        return out
    }

    /// A window opened on a file that cannot be shown the way it was asked for.
    ///
    /// It says which capability is missing and, when the file has the other one, offers it. This is
    /// the whole reason the request carries a mode rather than being two window ids: an empty canvas
    /// here would be indistinguishable from a slow download.
    private func refusalCard(_ reason: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: mode == .layers ? "square.3.layers.3d" : "cube")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(ViewerChrome.glyph)
            Text(verbatim: reason)
                .font(.system(size: 14))
                .foregroundStyle(ViewerChrome.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .padding(.top, 14)
                .fixedSize(horizontal: false, vertical: true)

            if supports(other) {
                Button { picked = other } label: {
                    Text(verbatim: other == .model ? "Open the 3D model" : "Open the layers")
                }
                .buttonStyle(MacPrimaryButtonStyle())
                .padding(.top, 18)
            }
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: 460)
    }

    private func notice(icon: String, message: String) -> some View {
        ViewerFailure(icon: icon, message: message)
    }

    // MARK: Toolbar

    private var modeSegment: some View {
        MacViewerSegment(
            options: MacViewerRequest.Mode.allCases,
            label: { $0.label },
            // Both segments are always drawn, and the one this file cannot do is dimmed with the
            // reason on it. Omitting it would hide that the window has two halves at all; leaving it
            // live would be a control that fails when clicked.
            enabled: { self.resolution != .found || self.supports($0) },
            help: { self.reason(for: $0) },
            selection: Binding(get: { self.mode }, set: { self.picked = $0 })
        )
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if mode == .layers {
                    layerSection
                    showSection
                    plateSection
                } else {
                    meshSection
                }
                viewSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The prototype's sidebar is `#0D0F10`, a shade between `bg` and `s1` that is not a token.
        // `s1` is the nearest one and is what the prototype uses for its title bar, so the sidebar
        // and the toolbar read as one surface rather than three.
        .background(c.s1)
    }

    private var total: Int { stats?.total ?? 0 }
    private var canScrub: Bool { mode == .layers && total > 1 && refusal == nil }

    // MARK: LAYER

    private var layerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("LAYER")

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(verbatim: total > 0 ? "\(layer)" : "—")
                    .font(.mono(26, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(c.t1)
                Text(verbatim: total > 0 ? "of \(total)" : "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c.t3)
                    .monospacedDigit()
            }
            .padding(.top, 12)

            Slider(
                value: Binding(
                    get: { Double(max(layer, 1)) },
                    set: { show(Int($0.rounded())) }
                ),
                // A one-layer range is degenerate for `Slider`, so an unparsed file gets a disabled
                // 1...2 rather than a crash-shaped 1...1.
                in: 1...Double(max(total, 2)),
                step: 1
            )
            .tint(c.accent)
            .controlSize(.small)
            .disabled(!canScrub)
            .padding(.top, 10)

            HStack(spacing: 7) {
                stepButton(-1, symbol: "chevron.left", key: .leftArrow)
                Button(action: togglePlayback) {
                    Text(verbatim: playTask == nil ? "Play" : "Pause")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MacPrimaryButtonStyle())
                .disabled(!canScrub)
                .keyboardShortcut(.space, modifiers: [])
                .help("Play the stack from the bottom — space")

                stepButton(1, symbol: "chevron.right", key: .rightArrow)
                speedMenu
            }
            .padding(.top, 14)
        }
    }

    private func stepButton(_ delta: Int, symbol: String, key: KeyEquivalent) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: m.primaryControlHeight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(c.t2)
        .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.s3))
        .disabled(!canScrub)
        .keyboardShortcut(key, modifiers: [])
        .help(delta < 0 ? "Down one layer — ← (⇧← for ten)" : "Up one layer — → (⇧→ for ten)")
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: $speed) {
                ForEach(Self.speeds, id: \.self) { Text(verbatim: Self.speedLabel($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(verbatim: Self.speedLabel(speed))
                .font(.mono(11.5, weight: .semibold))
                .foregroundStyle(c.t2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!canScrub)
        .help("Playback speed. 1× is \(Int(Self.baseLayersPerSecond)) layers a second.")
    }

    private static func speedLabel(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))×" : String(format: "%.1f×", v)
    }

    /// §7's table, bound as window KEY EQUIVALENTS rather than `.onKeyPress`.
    ///
    /// `.onKeyPress` is delivered to whatever has focus, and the moment the user clicks the canvas
    /// to orbit — which is most of the time in a viewer — focus is inside the WKWebView. A key
    /// equivalent is offered to the window before the first responder ever sees the event, so the
    /// arrows keep stepping layers while the page has focus.
    ///
    /// ← / → and space live on the visible controls above. Only the ⇧ pair has no control of its
    /// own, so only that pair is invisible; two views claiming one equivalent would be ambiguous.
    private var keyEquivalents: some View {
        ZStack {
            Button("Down ten layers") { step(-Self.coarseStep) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("Up ten layers") { step(Self.coarseStep) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
        }
        .disabled(!canScrub)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: SHOW

    /// The legend, and the one place this window could most easily have shipped a lie.
    ///
    /// `1g` draws four coloured keys — Walls, Infill, Supports, Travel moves — as though the
    /// renderer told them apart. **It does not, and it never has.** `LayerPage`'s parser reads the
    /// slicer's `; FEATURE:` comments for exactly one question (`/support/i`), colours everything
    /// else by HEIGHT through one bottom-to-top ramp, and emits no geometry at all for a move that
    /// extrudes nothing — travels are not dimmed, they are absent.
    ///
    /// So the rows keep the prototype's names and vocabulary, and the note under them says which of
    /// the four are actually distinguishable. Drawing Walls teal and Infill blue would have been the
    /// recurring bug in its purest form: a control whose appearance asserts a capability the thing
    /// behind it does not have.
    /// The legend keys are colour swatches, so their corner comes from `Metrics.swatchRadius` — the
    /// same ratio the filament swatches use — rather than from the card/control/chip scale. At 12 pt
    /// a fixed `chipRadius` would round them into lozenges.
    private var legendSwatch: CGFloat { 12 }

    private var showSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("SHOW")

            VStack(alignment: .leading, spacing: 9) {
                legendRow("Walls", swatch: rampSwatch, dim: false)
                legendRow("Infill", swatch: rampSwatch, dim: false)
                legendRow(
                    "Supports",
                    swatch: AnyView(
                        RoundedRectangle(cornerRadius: Metrics.swatchRadius(legendSwatch), style: .continuous)
                            .fill(hasSupport == false ? c.s4 : c.supports)
                            .frame(width: legendSwatch, height: legendSwatch)
                    ),
                    dim: hasSupport == false,
                    trailing: hasSupport == false ? "none" : nil
                )
                legendRow(
                    "Travel moves",
                    swatch: AnyView(
                        RoundedRectangle(cornerRadius: Metrics.swatchRadius(legendSwatch), style: .continuous)
                            .strokeBorder(c.line2)
                            .frame(width: legendSwatch, height: legendSwatch)
                    ),
                    dim: true,
                    trailing: "not drawn"
                )
            }
            .padding(.top, 11)

            Text(verbatim: Self.legendNote)
                .font(.system(size: 10.5))
                .lineSpacing(2)
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private static let legendNote =
        "Colour is height, not feature: walls and infill share one bottom-to-top ramp and the layer you are on is picked out in white. Only supports are told apart. Travel moves extrude nothing, so nothing is drawn for them."

    /// The ramp the shader actually paints, so the legend matches the pixels.
    ///
    /// These are `LayerPage`'s own `TINTS` values, not palette tokens, and that is the point: a
    /// legend keyed to `Palette.accent` would be a swatch of a colour that is nowhere on screen. The
    /// two pairs track the two shading chips, which is why the swatch follows `shading`.
    private var rampSwatch: AnyView {
        // TINTS.ivory {bot:[0.52,0.47,0.40], top:[0.93,0.90,0.83]} and
        // TINTS.steel {bot:[0.33,0.38,0.48], top:[0.78,0.81,0.87]}, rounded to 8-bit.
        let pair = shading == "ivory"
            ? (Color(hex: 0x857866), Color(hex: 0xEDE6D4))
            : (Color(hex: 0x54617A), Color(hex: 0xC7CFDE))
        return AnyView(
            RoundedRectangle(cornerRadius: Metrics.swatchRadius(legendSwatch), style: .continuous)
                .fill(LinearGradient(colors: [pair.0, pair.1], startPoint: .bottom, endPoint: .top))
                .frame(width: legendSwatch, height: legendSwatch)
        )
    }

    private func legendRow(_ label: String, swatch: AnyView, dim: Bool, trailing: String? = nil) -> some View {
        HStack(spacing: 9) {
            swatch
            Text(verbatim: label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(dim ? c.t3 : c.t1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(verbatim: trailing)
                    .font(.mono(9.5, weight: .medium))
                    .foregroundStyle(c.t3)
            }
        }
    }

    // MARK: PLATE

    private var plateSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("PLATE")
            VStack(alignment: .leading, spacing: 9) {
                factRow("Height", heightText)
                factRow("Layer height", stats?.layerHeightText ?? "—")
                factRow("Filament", filamentText)
            }
            .padding(.top, 11)
        }
    }

    /// Measured off the parsed toolpath, not off the file's metadata — this is the height of what is
    /// on screen. Prime and purge lines at an elevated Z are already excluded from the bounds by the
    /// parser, so a purging H2C does not report a taller print than it makes.
    private var heightText: String {
        guard let stats, stats.topZ > 0 else { return "—" }
        return String(format: "%.1f mm", stats.topZ)
    }

    /// From the library listing, because the page never sees it. `—` where the listing carries no
    /// figure, which is common enough that inventing one from the toolpath length would be a guess
    /// wearing a measurement's clothes.
    private var filamentText: String {
        guard let grams = file?.filamentUsedGrams?.double, grams > 0, grams.isFinite else { return "—" }
        return String(format: "%.0f g", grams)
    }

    // MARK: MESH

    private var meshSection: some View {
        // `bytes` answers "" for a size the listing did not carry — deliberately, so a row that
        // shows it takes up no space. This row always exists, so the absence needs a mark.
        let size = MacFileBrowse.bytes(file?.fileSize?.double)
        return VStack(alignment: .leading, spacing: 0) {
            sectionLabel("MESH")
            VStack(alignment: .leading, spacing: 9) {
                factRow("Triangles", tris.map { $0.formatted(.number.grouping(.automatic)) } ?? "—")
                factRow("File", (file?.fileType ?? "stl").uppercased())
                factRow("Size", size.isEmpty ? "—" : size)
            }
            .padding(.top, 11)

            Text(verbatim: Self.meshNote)
                .font(.system(size: 10.5))
                .lineSpacing(2)
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    /// An STL is a bare triangle soup: there is no layer height, no material and no print time
    /// inside it. Saying so is cheaper than a panel of `—` rows that read as missing data.
    private static let meshNote =
        "An STL is a bare mesh. There is no layer height, material or print time inside it — those appear once a file has been through a slicer."

    // MARK: VIEW

    /// The page's own shading chips, moved into the sidebar because this window hides its control
    /// card. The controls are not reimplemented: each one clicks the chip the page already owns, so
    /// "what does Ivory do" still has exactly one answer and it is the one iOS ships.
    private var viewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("VIEW")

            MacViewerSegment(
                options: shadingOptions,
                label: { Self.shadingLabel($0) },
                enabled: { _ in self.page.isReady },
                help: { _ in nil },
                selection: Binding(get: { self.shading }, set: { self.pick(shading: $0) })
            )
            .padding(.top, 11)

            Toggle("Light background", isOn: Binding(
                get: { self.lightBackground },
                set: { _ in self.toggleLightBackground() }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(c.t2)
            .disabled(!page.isReady)
            .padding(.top, 12)

            Button("Reset view") { Task { await handle.run(MacViewerJS.resetView) } }
                .buttonStyle(MacSecondaryButtonStyle())
                .disabled(!page.isReady)
                .padding(.top, 10)
        }
    }

    /// Normals is a mesh-only chip — the layer page has no such mode, and offering it there would be
    /// a control with nothing behind it.
    private var shadingOptions: [String] {
        mode == .model ? ["steel", "ivory", "normals"] : ["steel", "ivory"]
    }

    private static func shadingLabel(_ chip: String) -> String {
        switch chip {
        case "ivory": "Ivory"
        case "normals": "Normals"
        default: "Steel"
        }
    }

    // MARK: Sidebar bits

    private func sectionLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.mono(m.monoLabel, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(c.t3)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value)
                .font(.mono(11.5, weight: .medium))
                .foregroundStyle(c.t1)
                .monospacedDigit()
        }
    }

    // MARK: Building the page

    /// Everything a rebuild depends on. `.task(id:)` reruns on any change to it and on nothing else
    /// — in particular not on a redraw, which would restart the download.
    private struct BuildKey: Equatable {
        var target: String?
        var mode: MacViewerRequest.Mode
        var attempt: Int
        var connected: Bool
        var resolved: Bool
    }

    private var buildKey: BuildKey {
        BuildKey(
            target: request?.target.key,
            mode: mode,
            attempt: attempt,
            // A printer target is resolved the moment there is a client: there is no listing to wait
            // for. Keying on `file != nil` would leave it permanently unresolved and never build.
            connected: model.client != nil,
            resolved: resolution == .found
        )
    }

    private func build() async {
        // The window can be opened with the main window closed — from the menu bar, from a restored
        // scene — in which case nothing has ever listed the library. Ask once; `load()` is a no-op
        // for a listing already in hand. Skipped entirely for a printer target, which needs no
        // listing and should not pull one down to show a file it can already address.
        if printerTarget == nil, model.client != nil, store.files == nil, !store.loadFailed {
            await store.load()
        }
        guard refusal == nil, let client = model.client else { return }
        guard case .idle = page else { return }

        // The printer's own storage: one endpoint, one mode. Same page, same headers, same origin as
        // the library's layers — only the URL differs, which is the whole of what this branch is.
        if let printerTarget {
            let url = client.baseUrl + client.printerGcodePath(printerTarget.printerId, path: printerTarget.path)
            pageUrl = url
            page = .ready(
                html: LayerPage.html(
                    url: url,
                    headers: client.authHeaders(),
                    plate: PrinterProfile.forPrinter(model.printer).plate
                ),
                base: ViewerJS.documentBase(of: client.baseUrl)
            )
            return
        }

        guard let file else { return }

        switch mode {
        case .layers:
            let url = client.baseUrl + client.gcodePath(file.id)
            pageUrl = url
            // The API key rides along in the page source. That is safe here and nowhere else: the
            // document is loaded on the server's own origin from a string we built, so no
            // third-party script can read it — and the G-code endpoints reject the camera stream
            // token outright.
            page = .ready(
                html: LayerPage.html(
                    url: url,
                    headers: client.authHeaders(),
                    plate: PrinterProfile.forPrinter(model.printer).plate
                ),
                base: ViewerJS.documentBase(of: client.baseUrl)
            )

        case .model:
            do {
                // Minted once per attempt: the download token is single-use and short-lived, so a
                // second mint on a re-render would hand the page a URL the first one already spent.
                // The name lands in a PATH SEGMENT, so it has to be reduced to something that can
                // be one.
                let name = MacFileBrowse.displayName(file)
                let safe = LibraryDownloadName.pathSegment(name, fallback: "model-\(file.id).stl")
                let url = try await client.mintFileDownloadUrl(file.id, filename: safe)
                guard !Task.isCancelled else { return }
                pageUrl = url.absoluteString
                page = .ready(
                    html: StlPage.html(
                        url: url.absoluteString,
                        name: name,
                        // The page's own card and reset button are hidden on this platform for the
                        // same reason the layer page's are: the sidebar owns those controls.
                        compact: true,
                        headers: [:]
                    ),
                    base: ViewerJS.documentBase(of: client.baseUrl)
                )
            } catch let e as BambuddyError {
                page = .failed(e.detail)
            } catch {
                page = .failed(error.localizedDescription)
            }
        }
    }

    private func receive(_ event: ViewerEvent) {
        switch event {
        case .ready(let supports):
            hasSupport = supports
            Task { await readStats() }
        case .loaded(let count):
            tris = count
        case .failed(let message, let status):
            viewerLog.error("Mac viewer page failed (HTTP \(status, privacy: .public)) on \(ViewerJS.loggableUrl(self.pageUrl ?? "<no url>"), privacy: .public) — \(message, privacy: .public)")
            // A spent or expired one-shot token answers 401/403; minting another and reloading
            // recovers a perfectly good file from a dead credential. 404 is deliberately excluded:
            // it means the URL's shape is wrong, and a fresh token would rebuild the same broken
            // URL. Layers are fetched with the API key, which does not expire mid-session, so this
            // applies to the mesh page only.
            if mode == .model, !reminted, status == 401 || status == 403 {
                reminted = true
                viewerLog.notice("Mac viewer: re-minting a download token after HTTP \(status, privacy: .public)")
                resetForRebuild()
                attempt += 1
                return
            }
            page = .failed(message)
        }
    }

    private func readStats() async {
        guard let parsed = await handle.layerStats() else { return }
        stats = parsed
        // The page opens showing the whole stack, and so does this.
        layer = parsed.total
    }

    /// The manual Retry. Unlike the automatic re-mint it also re-arms it — the user asking again is
    /// a new decision, not the same attempt continuing.
    private func retry() {
        reminted = false
        resetForRebuild()
        attempt += 1
    }

    /// Everything that describes the page that is going away.
    private func resetForRebuild() {
        stopPlayback()
        page = .idle
        pageUrl = nil
        stats = nil
        layer = 0
        hasSupport = nil
        tris = nil
        // A fresh page starts on Steel with a dark background, so the mirrors have to as well —
        // otherwise the sidebar would claim a shading the page is not using.
        shading = "steel"
        lightBackground = false
    }

    // MARK: Driving the page

    private func show(_ n: Int) {
        guard total > 0 else { return }
        let clamped = min(max(n, 1), total)
        guard clamped != layer else { return }
        layer = clamped
        Task { await handle.run(MacViewerJS.setLayer(clamped)) }
    }

    private func step(_ delta: Int) {
        // A step is a decision to look at a layer, so it takes over from playback rather than
        // fighting it for the next frame.
        stopPlayback()
        show(layer + delta)
    }

    private func pick(shading chip: String) {
        guard chip != shading else { return }
        shading = chip
        Task { await handle.run(MacViewerJS.clickChip(chip)) }
    }

    private func toggleLightBackground() {
        lightBackground.toggle()
        Task { await handle.run(MacViewerJS.clickChip("bg")) }
    }

    // MARK: Playback

    private func togglePlayback() {
        if playTask != nil {
            stopPlayback()
            return
        }
        guard canScrub else { return }
        // Pressing Play at the top means "again", not "nothing" — the alternative is a button that
        // does nothing at the one moment the user has most reason to press it.
        if layer >= total { show(1) }
        playTask = Task {
            while !Task.isCancelled {
                let interval = 1.0 / (Self.baseLayersPerSecond * speed)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                guard layer < total else {
                    stopPlayback()
                    return
                }
                show(layer + 1)
            }
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
    }
}

// MARK: - Segmented control

/// The prototype's pill segmented control, with a disabled state.
///
/// `MacSegmented` in `MacFilesSection.swift` is the same control and is `private` to that file, so
/// this is a second copy of it — which it should not have to be. The difference that forced the
/// copy is real, though: this one has to draw a segment the file cannot do, dimmed and carrying its
/// reason, which the Files copy has no notion of.
///
/// TODO: `MacSegmented` should move to `Views/Mac/` as one shared control with an optional
/// `enabled`/`help` pair. `MacFilesSection.swift` is not a file this pass owns.
private struct MacViewerSegment<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    let enabled: (Value) -> Bool
    let help: (Value) -> String?
    @Binding var selection: Value

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// The trough. Named because the thumb's radius is derived from it below.
    private let trackInset: CGFloat = 2

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                let live = enabled(option)
                Button { selection = option } label: {
                    Text(verbatim: label(option))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(on ? c.t1 : c.t3)
                        .opacity(live ? 1 : 0.45)
                        .padding(.horizontal, 12)
                        .frame(height: m.controlHeight - 4)
                        // CONCENTRIC with the track: the thumb is inset `trackInset` inside it, so
                        // its corner is the track's minus that inset.
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.concentric(inside: m.controlRadius,
                                                                             inset: trackInset),
                                             style: .continuous)
                                .fill(on ? c.s4 : .clear)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!live)
                .help(help(option) ?? label(option))
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(trackInset)
        .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).stroke(c.line))
        // Never let the toolbar compress it.
        //
        // Without this the item is a flexible width, and when the toolbar is short of room the
        // TRAILING label is the one that loses — the track's right corner comes back squared off
        // while the left keeps its radius, which reads as the text having outgrown the control.
        //
        // Height was NOT the problem, though it looked like it: measured with `SPROUT_TREE`, this
        // window's `.primaryAction` items are laid out at 36 pt, so a 28 pt segment has room to
        // spare. Shrinking it — the first fix attempted here — would have made it inconsistent with
        // every other control for no reason. The probe now dumps toolbar item frames precisely so
        // this class of guess can be checked instead of shipped.
        .fixedSize()
        .animation(Motion.standard(0.14), value: selection)
    }
}
#endif
