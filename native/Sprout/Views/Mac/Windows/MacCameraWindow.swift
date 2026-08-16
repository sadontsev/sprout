#if os(macOS)
import AppKit
import SwiftUI

/// The chamber camera in its own window (prototype `1c`).
///
/// Reuses `MJPEGStream` + `CameraRenderer` unchanged (§5.2); only the chrome differs from iOS. The
/// PiP path is not involved at all — this window IS the Mac's answer to PiP (§6).
struct MacCameraWindow: View {
    let model: AppModel
    let printerId: Int

    @Environment(\.colorScheme) private var scheme

    @State private var cam = CameraStreamModel()
    @State private var paused = false
    @State private var floating = false
    @State private var showOverlayStats = true
    /// Carries its own title. Both frame buttons can fail, for the same reason, and an alert headed
    /// "Couldn't save the frame" over a *copy* failure names the wrong action.
    @State private var failure: MacCameraFailure?
    /// Whether the renderer has ever handed us a frame **on this mount**. See `MacCameraFrameLatch`.
    @State private var frames = MacCameraFrameLatch()
    /// The window this view is actually in. See `MacHostWindow`.
    @State private var host = MacHostWindow()

    private var printer: Printer? { model.printers.first { $0.id == printerId } }

    // MARK: Palette

    /// Resolved from the theme, **not** read out of `@Environment(\.palette)`.
    ///
    /// A window scene inherits nothing from `MacRoot`, so `@Environment(\.palette)` here is the
    /// key's default — `Palette.dark` — whatever the user's theme is, and setting the environment
    /// for the children below does not change what this view itself reads. Every token in this file
    /// is used by a computed property of *this* view, so the whole window rendered dark-on-dark for
    /// anyone on the light theme: `c.s1` under the control row, `c.bg` behind everything, `c.t1` on
    /// the badges. `MacViewerWindow` carries the same note and the same fix; this window predates it.
    private var c: Palette { Palette.forScheme(model.theme.colorScheme ?? scheme) }

    private var m: Metrics { .mac }

    /// Always the full rate. The dashboard tile deliberately asks for a low rate on a metered path
    /// (`CameraRate.tileMetered`); a window the user opened on purpose is the case that wants
    /// frames, and a Mac is not on a phone plan.
    private var streamURL: URL? {
        guard let client = model.client, let token = model.cameraToken else { return nil }
        return client.streamUrl(printerId, token: token, fps: CameraRate.fullscreen)
    }

    var body: some View {
        VStack(spacing: 0) {
            stream
            controls
        }
        .background(c.bg)
        .background { MacHostWindowReader(host: host) }
        // Palette + density + appearance, together and inseparably — see `macSceneChrome`. This
        // window is where the missing appearance half was first caught: it drew a white switch
        // capsule and invisible near-black label text on `c.s1`.
        .macSceneChrome(model, systemScheme: scheme)
        .navigationTitle("Chamber camera — \(printer?.name ?? "Printer")")
        .onAppear {
            model.cameraOwnership.setWindowStreaming(!paused, printerId: printerId)
            // A fresh mount is a fresh `CameraNSView`, hence a fresh `CameraRenderer` with an empty
            // stash. Nothing else resets this.
            frames.mount()
        }
        // Pausing hands the claim BACK. The window keeps its last frame and stops using the
        // upstream, so the inspector tile can have it — one printer, one live stream, and the
        // claim follows what is actually streaming rather than what is merely on screen.
        .onChange(of: paused) { _, isPaused in
            model.cameraOwnership.setWindowStreaming(!isPaused, printerId: printerId)
        }
        // The latch also resets when the STREAM changes, not only on mount.
        //
        // `frames.mount()` alone assumed a cleared stash always means a fresh view, and it does not:
        // `cameraToken` is nilled on reconnect and sign-out, so `streamURL` goes nil, `setURL(nil)`
        // stops the renderer, and `teardown(clearImage: true)` clears the stash — all without this
        // view remounting, because `CameraStreamView` is unconditional here. Snapshot and Save frame
        // stayed lit and undimmed over a blanked window, then answered "there is no frame to save".
        .onChange(of: streamURL) { _, _ in frames.mount() }
        .onChange(of: cam.isLive) { _, live in frames.note(isLive: live) }
        .onDisappear {
            // Explicit rather than relying on `dismantleNSView`: the claim must be handed back the
            // moment the window goes, or the inspector tile never resumes.
            model.cameraOwnership.setWindowStreaming(false, printerId: printerId)
        }
        .alert(failure?.title ?? "", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(verbatim: failure?.message ?? "")
        }
    }

    private var request: MacCameraStreamRequest {
        MacCameraStreamRequest.make(streamURL: streamURL, paused: paused)
    }

    private var stream: some View {
        CameraStreamView(
            url: request.url,
            active: request.active,
            model: cam,
            holdLastFrameWhenInactive: request.holdLastFrame
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.thumb)
        .overlay(alignment: .topLeading) { if showOverlayStats { liveBadge } }
        .overlay(alignment: .topTrailing) { if showOverlayStats { layerBadge } }
        .overlay { if streamURL == nil { noTokenNote } }
    }

    private var liveBadge: some View {
        HStack(spacing: 7) {
            // A dot that pulses red beside the word PAUSED claims a stream that has been torn down.
            // The colour and the motion both carry meaning here, so both have to stop.
            if cam.isLive {
                PulseDot(color: c.error, size: 6)
            } else {
                Circle().fill(c.idle).frame(width: 6, height: 6)
            }
            Text(verbatim: MacCameraBadge.label(isLive: cam.isLive, paused: paused))
                .font(.mono(10, weight: .semibold))
                .foregroundStyle(c.t1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.bg.opacity(0.7)))
        .padding(14)
    }

    /// This window's OWN printer, not the app's selection.
    ///
    /// `model.vm` is `Dash.present(status?.status)` for the printer the MAIN WINDOW has selected.
    /// This window is bound to `printerId` — its title, its stream and its camera claim all use it —
    /// so reading `model.vm` meant opening the camera for printer B and then selecting printer A in
    /// the main window put A's layer count and state word over B's video, under a title naming B.
    /// `statuses` is keyed by printer for exactly this.
    private var windowVM: DashVM {
        Dash.present(model.status?.statuses[printerId])
    }

    private var layerBadge: some View {
        let vm = windowVM
        return Text(verbatim: vm.kind == .live
                    ? "LAYER \(vm.layer) · \(vm.progressInt) %"
                    : vm.stateLabel.uppercased())
            .font(.mono(10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(c.t2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.bg.opacity(0.7)))
            .padding(14)
    }

    /// The camera is gated by a stream TOKEN, not by the API key — a missing token is a specific,
    /// recoverable state and saying "no signal" for it would send someone to look at the printer.
    private var noTokenNote: some View {
        Text(verbatim: "Waiting for a camera token from Bambuddy.")
            .font(.system(size: m.body))
            .foregroundStyle(c.t2)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 9) {
            pauseButton

            Button("Snapshot", action: copyFrameToPasteboard)
                .buttonStyle(MacSecondaryButtonStyle())
                .disabled(!frames.hasFrame)
                .help(frames.hasFrame
                      ? "Copy the frame on screen to the clipboard"
                      : "Nothing has been decoded yet — the frame appears a few seconds after the camera wakes.")

            Button("Save frame…", action: saveFrame)
                .buttonStyle(MacSecondaryButtonStyle())
                .disabled(!frames.hasFrame)
                .help(frames.hasFrame
                      ? "Write the frame on screen to a PNG"
                      : "Nothing has been decoded yet — the frame appears a few seconds after the camera wakes.")

            Spacer(minLength: 0)

            controlToggle("Float on top", isOn: $floating,
                          help: "Keep this window above other apps")
                .onChange(of: floating) { _, on in host.setFloating(on) }

            controlToggle("Overlay stats", isOn: $showOverlayStats,
                          help: "Show the LIVE and LAYER badges over the picture")
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(c.s1)
        .overlay(alignment: .top) { Rectangle().fill(c.line).frame(height: 1) }
    }

    /// `.plain`, never `.borderless`/`.bordered`.
    ///
    /// A bordered or borderless button draws chrome of its OWN on macOS 26, so the hand-drawn
    /// `RoundedRectangle` behind it produced a second shape — the stray capsule the owner reported
    /// under the picture. `.borderless` also tints its label with the *system* accent colour, which
    /// is whatever the user picked in System Settings rather than anything in `Palette`. `.plain`
    /// draws nothing and tints nothing, so the shape and the glyph colour below are the only two
    /// that exist. Every other button in the Mac tree already uses it.
    private var pauseButton: some View {
        Button {
            paused.toggle()
        } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 12, weight: .semibold))
                // Matches `MacSecondaryButtonStyle`'s height so the four controls sit on one line.
                .frame(width: 34, height: m.primaryControlHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(c.t1)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.s3))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(c.line2))
        .help(paused ? "Resume the stream" : "Pause the stream")
        .accessibilityLabel(paused ? "Resume the stream" : "Pause the stream")
    }

    /// Both switches, drawn once.
    ///
    /// The label colour is set from the palette rather than inherited: this window forces its own
    /// ground (`c.s1`), so a label left on the system's `.primary` is only legible by coincidence.
    /// `.tint` is the same reason — an untinted switch turns the user's macOS accent colour on, not
    /// Sprout's teal, which is the convention every other switch in the Mac tree already follows.
    private func controlToggle(
        _ title: String,
        isOn: Binding<Bool>,
        help: String
    ) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(c.accent)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(c.t2)
            .help(help)
    }

    private func copyFrameToPasteboard() {
        guard let image = currentFrame() else {
            // Reachable despite the button's gate: the renderer can be torn down between the render
            // that enabled it and the click. Saying so beats a click that does nothing at all.
            failure = MacCameraFailure(title: "Couldn’t copy the frame",
                                       message: "There is no frame to copy yet.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// A save PANEL, not a silent write to Photos. The Mac has no photo library by default, and the
    /// app is sandboxed — `files.user-selected.read-write` is what the panel grants, so this is both
    /// the idiomatic and the only permitted path.
    private func saveFrame() {
        guard let image = currentFrame(), let png = image.pngRepresentationData() else {
            failure = MacCameraFailure(title: Self.saveFailed,
                                       message: "There is no frame to save yet.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(printer?.name ?? "printer")-frame.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
        } catch {
            failure = MacCameraFailure(title: Self.saveFailed,
                                       message: error.localizedDescription)
        }
    }

    private static let saveFailed = "Couldn’t save the frame"

    /// The most recent frame, decoded on demand from the renderer's stash.
    private func currentFrame() -> PlatformImage? {
        guard let jpeg = cam.renderer?.frameStash.latest() else { return nil }
        return PlatformImage.decoded(from: jpeg)
    }
}

// MARK: - Window-free logic

/// A failed frame operation, with the name of the operation that failed.
struct MacCameraFailure: Equatable {
    let title: String
    let message: String
}

/// What the stream view is asked for, given the pause state.
///
/// Extracted so the pause contract can be asserted without a window, because it was wrong and the
/// comment above `onChange(of: paused)` said otherwise: the window claimed to keep its last frame
/// while paused, and did not.
///
/// Two things had to be true for that promise to hold, and neither was:
///
///  - **`holdLastFrame`.** `CameraStreamView` defaults it to `false`, so `setActive(false)` ran
///    `renderer.stop()` → `flushAndRemoveImage()` **and** `frameStash.clear()`. Pause blanked the
///    picture and destroyed the very frame Snapshot and Save frame hand out.
///  - **Keeping the URL.** Passing `nil` while paused looks harmless, but `updateNSView` calls
///    `setURL` *before* `setActive`, so the view is still active when the URL changes: `setURL(nil)`
///    → `restart()` → `guard let url else { renderer.stop() }`. The unconditional stop happened
///    there too, one step earlier, and `holdLastFrame` cannot reach it.
///
/// The URL is inert while inactive (`setURL` only restarts an *active* view), so keeping it costs
/// nothing and additionally means a camera-token rotation that lands during a pause is picked up on
/// resume rather than dropped.
struct MacCameraStreamRequest: Equatable {
    let url: URL?
    let active: Bool
    let holdLastFrame: Bool

    static func make(streamURL: URL?, paused: Bool) -> MacCameraStreamRequest {
        MacCameraStreamRequest(url: streamURL, active: !paused, holdLastFrame: true)
    }
}

/// Whether there is a decoded frame to hand out.
///
/// **Not `cam.isLive`.** Two questions that a paused window separates completely:
///
///  - *"Is the stream running right now?"* — `isLive`. What the badge asks.
///  - *"Is there a frame in the renderer's stash?"* — what Snapshot and Save frame ask.
///
/// Gating the two buttons on `isLive` disabled them the instant the user paused, which is exactly
/// when someone reaches for "save this frame". `MacPrinterInspector`'s tile already carries the same
/// correction and the same note.
///
/// A latch rather than a read of `frameStash.latest()`, because the stash is lock-guarded plain
/// state, not `@Observable`: a view that read it would never re-render when the first frame landed
/// and the buttons would stay dim over a live picture. `isLive` *is* observable, and the renderer
/// only publishes it after a frame has been stashed, so its rising edge is the signal.
struct MacCameraFrameLatch: Equatable {
    private(set) var hasFrame = false

    /// A fresh mount is a fresh renderer with an empty stash.
    mutating func mount() { hasFrame = false }

    /// Deliberately one-way. `isLive` going false means the stream stopped, not that the frame went
    /// away — under `holdLastFrame` the picture and the stash both survive a pause.
    mutating func note(isLive: Bool) { if isLive { hasFrame = true } }
}

/// The word over the picture.
///
/// `paused` is checked FIRST, and that ordering is the point: `paused` is known the moment the
/// button is clicked, while `isLive` only falls when the renderer's `.connecting` event arrives. The
/// old `isLive ? "LIVE" : (paused ? …)` order left the badge claiming LIVE over a stream the user
/// had already stopped.
enum MacCameraBadge {
    static func label(isLive: Bool, paused: Bool) -> String {
        if paused { return "PAUSED" }
        return isLive ? "LIVE · MJPEG" : "CONNECTING…"
    }
}

/// A handle on the window this view is actually in.
///
/// Two questions, and the code this replaces answered neither reliably:
///
///  - *"Which window is the user typing into right now?"* — `NSApp.keyWindow`.
///  - *"Which window is THIS view in?"* — what "Float on top" needs.
///
/// They part company as soon as a second camera window exists, and §5.2 keys the scene by printer id
/// (`WindowGroup(id:"camera", for: Int.self)`), so two printers means two windows with the same title
/// prefix. The old lookup took `isKeyWindow` and fell back to `title.hasPrefix("Chamber camera")`,
/// which floats whichever one AppKit happened to return — and the fallback also matches the *other*
/// printer's window. `viewDidMoveToWindow` cannot be wrong about it.
///
/// State is held here, in a plain class, rather than in `@State`: `viewDidMoveToWindow` fires inside
/// SwiftUI's own update pass, and writing observable state from there is the "Modifying state during
/// view update" trap. Nothing needs to re-render when the window arrives — only `setFloating` needs
/// to be able to find it.
@MainActor
final class MacHostWindow {
    private weak var hosted: NSWindow?
    private var floats = false

    func attach(_ window: NSWindow?) {
        hosted = window
        // Re-applied on attach, not only on toggle, so an order where the switch is flipped before
        // the view lands in a window cannot silently lose the setting.
        apply()
    }

    func setFloating(_ on: Bool) {
        floats = on
        apply()
    }

    private func apply() {
        hosted?.level = floats ? .floating : .normal
    }
}

/// The zero-size AppKit view that reports which window it landed in.
private struct MacHostWindowReader: NSViewRepresentable {
    let host: MacHostWindow

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.host = host
        return view
    }

    func updateNSView(_ view: Reader, context: Context) { view.host = host }

    final class Reader: NSView {
        var host: MacHostWindow?

        /// Called on insertion AND on removal (with a nil window), which is why `attach` takes an
        /// optional rather than being two methods.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.attach(window)
        }

        /// Invisible to the mouse. A real `NSView` in a `.background` is a sibling in AppKit's view
        /// hierarchy, and AppKit hit-tests subviews rather than the SwiftUI content drawn over them
        /// — so a plain `NSView` spanning the window is a way to swallow every click in it. This one
        /// exists only to be told which window it is in.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
