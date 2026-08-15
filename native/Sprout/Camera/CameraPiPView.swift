#if os(iOS)
// The UIKit host for the renderer's display layer, and its SwiftUI wrapper. iOS-only because PiP is
// (§6) — the layer has to be in a live UIKit hierarchy for `AVPictureInPictureController` to start
// at all. The AppKit counterpart is `CameraNSView.swift`; the renderer and the observable model are
// shared and live in `CameraRenderer.swift` / `CameraStreamModel.swift`.
// See docs/native-rewrite/18-mac-port-architecture.md.
import AVFoundation
import SwiftUI
import UIKit

/// Hosts the `AVSampleBufferDisplayLayer`. The layer must be in a visible view hierarchy for PiP to
/// be startable at all, so this is a real view even when the user only ever wants the floating
/// window.
final class CameraPiPUIView: UIView {
    let renderer = CameraRenderer()

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

/// SwiftUI wrapper over the MJPEG + PiP renderer.
struct CameraPiPView: UIViewRepresentable {
    let url: URL?
    var active: Bool
    var model: CameraStreamModel

    func makeUIView(context: Context) -> CameraPiPUIView {
        let view = CameraPiPUIView(frame: .zero)
        model.renderer = view.renderer
        view.onEvent = { event in model.apply(event) }
        view.setURL(url)
        view.setActive(active)
        return view
    }

    func updateUIView(_ view: CameraPiPUIView, context: Context) {
        model.renderer = view.renderer
        view.setURL(url)
        view.setActive(active)
    }

    static func dismantleUIView(_ view: CameraPiPUIView, coordinator: ()) {
        view.setActive(false)
    }
}
#endif
