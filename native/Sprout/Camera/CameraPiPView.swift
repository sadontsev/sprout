#if os(iOS)
// PiP is iOS-only (§6).
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Hosts the `AVSampleBufferDisplayLayer`. The layer must be in a visible view hierarchy for PiP to
/// be startable at all, so this is a real view even when the user only ever wants the floating
/// window.
final class CameraPiPUIView: UIView {
    let renderer = CameraPiPRenderer()

    /// Set by the SwiftUI wrapper; always called on the main queue.
    var onEvent: ((CameraEvent) -> Void)?

    private var url: URL?
    private var active = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.02, alpha: 1)
        layer.addSublayer(renderer.displayLayer)

        renderer.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.onEvent?(event) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // No implicit animation: the layer would otherwise slide into place on every layout pass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.displayLayer.frame = bounds
        CATransaction.commit()
    }

    /// Hot-swap the URL. Deliberately does NOT rebuild the display layer — the camera token refreshes
    /// on a timer, and tearing the layer down would take an active PiP window with it.
    func setURL(_ next: URL?) {
        guard next != url else { return }
        url = next
        if active { restart() }
    }

    func setActive(_ next: Bool) {
        guard next != active else { return }
        active = next
        if next { restart() } else { renderer.stop() }
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

/// Observable handle on the live stream, so SwiftUI can drive PiP and read stream health.
@MainActor
@Observable
final class CameraPiPModel {
    /// Whether the CURRENT connection has delivered a frame. It must go back to false when the
    /// renderer reconnects: consumers drive their state machines off a *change* of this flag, and
    /// while it was a write-once latch a reconnect (Retry, or the 45-minute camera-token rotation)
    /// left them waiting on an edge that could never happen again — the overlay decayed to
    /// "NO SIGNAL" over a picture that was still moving.
    var isLive = false
    var lastError: String?
    var pipActive = false
    /// Frames decoded so far. Distinguishes "the stream stalled" from "frames arrive but nothing
    /// renders" — the exact ambiguity that made the earlier static-frame bug hard to pin down.
    var frameCount = 0
    /// Whether the near-silent audio session armed. If this is false, PiP will freeze the moment the
    /// app is backgrounded, because nothing is keeping the process alive.
    var audioKeepAliveOK = true
    var isPictureInPictureSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    fileprivate weak var view: CameraPiPUIView?

    func startPiP() {
        guard let view else { return }
        // AVKit is main-thread-only. The RN build crashed here because Expo ran AsyncFunction bodies
        // on a background queue; in SwiftUI this method is already @MainActor, which is the fix.
        do {
            try view.renderer.enablePiP()
            view.renderer.startPiP()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopPiP() {
        view?.renderer.stopPiP()
    }
}

/// SwiftUI wrapper over the MJPEG + PiP renderer.
struct CameraPiPView: UIViewRepresentable {
    let url: URL?
    var active: Bool
    var model: CameraPiPModel

    func makeUIView(context: Context) -> CameraPiPUIView {
        let view = CameraPiPUIView(frame: .zero)
        model.view = view
        view.onEvent = { event in
            switch event {
            case .live:
                model.isLive = true
            case .connecting:
                model.isLive = false
            case .error(let message, _):
                model.lastError = message
            case .pipStart:
                model.pipActive = true
            case .pipStop:
                model.pipActive = false
            case .stats(let frames, let pipActive):
                model.frameCount = frames
                model.pipActive = pipActive
            case .audio(let ok, let message):
                model.audioKeepAliveOK = ok
                if !ok { model.lastError = message }
            }
        }
        view.setURL(url)
        view.setActive(active)
        return view
    }

    func updateUIView(_ view: CameraPiPUIView, context: Context) {
        model.view = view
        view.setURL(url)
        view.setActive(active)
    }

    static func dismantleUIView(_ view: CameraPiPUIView, coordinator: ()) {
        view.setActive(false)
    }
}
#endif
