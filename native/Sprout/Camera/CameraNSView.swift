#if os(macOS)
// The AppKit host for the renderer's display layer, and its SwiftUI wrapper — the counterpart of
// `CameraPiPUIView` + `CameraPiPView`. Everything below the layer is the SAME code as on iOS:
// `CameraRenderer`, `MJPEGStreamClient` and `MJPEGParser` are shared, per §5.2 of
// docs/native-rewrite/18-mac-port-architecture.md ("reused unchanged" apart from the window chrome).
//
// There is no Picture in Picture here and no audio keep-alive: macOS does not suspend an app behind
// a floating window, because there is no floating window. The camera gets its own window (spec 1c)
// and an inspector tile instead.
import AVFoundation
import AppKit
import SwiftUI

/// Hosts the `AVSampleBufferDisplayLayer`. Layer-backed, and it hosts the renderer's layer as a
/// sublayer rather than becoming it, so the same hot-swap rules as iOS apply: the layer outlives any
/// number of URL changes.
final class CameraNSView: NSView {
    let renderer = CameraRenderer()

    /// Set by the SwiftUI wrapper; always called on the main queue.
    var onEvent: ((CameraEvent) -> Void)?

    private var url: URL?
    private var active = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The backing layer is assigned BEFORE `wantsLayer`, which is the order AppKit documents for
        // a custom layer. Doing it the other way round means reaching for the optional `layer` right
        // after asking for one, and an optional-chained `layer?.addSublayer` that silently does
        // nothing is exactly the failure this file has no way to notice — a black view.
        let backing = CALayer()
        backing.backgroundColor = NSColor(white: 0.02, alpha: 1).cgColor
        layer = backing
        wantsLayer = true
        backing.addSublayer(renderer.displayLayer)

        renderer.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.onEvent?(event) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `layout()` is AppKit's `layoutSubviews()`.
    override func layout() {
        super.layout()
        // No implicit animation: the layer would otherwise slide into place on every layout pass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.displayLayer.frame = bounds
        CATransaction.commit()
    }

    /// Hot-swap the URL. Deliberately does NOT rebuild the display layer — the camera token refreshes
    /// on a timer (every 45 minutes), and tearing the layer down would kill a stream that is running
    /// perfectly well. Same rule as iOS, where it additionally took any active PiP window with it.
    func setURL(_ next: URL?) {
        guard next != url else { return }
        url = next
        if active { restart() }
    }

    /// `holdLastFrame` distinguishes "this view is going away" from "something else took the
    /// stream". Only the second wants the picture left behind.
    func setActive(_ next: Bool, holdLastFrame: Bool = false) {
        guard next != active else { return }
        active = next
        if next {
            restart()
        } else if holdLastFrame {
            renderer.pauseHoldingLastFrame()
        } else {
            renderer.stop()
        }
    }

    private func restart() {
        guard let url else {
            renderer.stop()
            return
        }
        renderer.start { done in done(.success(url)) }
    }

    deinit {
        renderer.stop()
    }
}

/// SwiftUI wrapper over the MJPEG renderer. Same `(url:active:model:)` shape as the iOS
/// `CameraPiPView`, so a call site reads identically on both platforms.
struct CameraStreamView: NSViewRepresentable {
    let url: URL?
    var active: Bool
    var model: CameraStreamModel
    /// When `active` goes false, keep the last frame on screen rather than blanking. The inspector
    /// tile sets this so handing the claim to the camera window leaves a still, not a black box.
    var holdLastFrameWhenInactive = false

    func makeNSView(context: Context) -> CameraNSView {
        let view = CameraNSView(frame: .zero)
        model.renderer = view.renderer
        view.onEvent = { event in model.apply(event) }
        view.setURL(url)
        view.setActive(active, holdLastFrame: holdLastFrameWhenInactive)
        return view
    }

    func updateNSView(_ view: CameraNSView, context: Context) {
        model.renderer = view.renderer
        view.setURL(url)
        view.setActive(active, holdLastFrame: holdLastFrameWhenInactive)
    }

    static func dismantleNSView(_ view: CameraNSView, coordinator: ()) {
        view.setActive(false)
    }
}
#endif
