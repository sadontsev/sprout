import ExpoModulesCore
import AVFoundation
import AVKit
import UIKit

/// Hosts the AVSampleBufferDisplayLayer. The layer must be in a visible view hierarchy for PiP to be
/// startable at all, so this is a real view even when the user only ever wants the floating window.
public final class CameraPiPView: ExpoView {
  let renderer = CameraPiPRenderer()

  private let onLive = EventDispatcher()
  private let onError = EventDispatcher()
  private let onPipStart = EventDispatcher()
  private let onPipStop = EventDispatcher()

  private var url: URL?
  private var active = false

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = UIColor(white: 0.02, alpha: 1)
    layer.addSublayer(renderer.displayLayer)

    renderer.onEvent = { [weak self] name, body in
      guard let self else { return }
      switch name {
      case "live": self.onLive(body)
      case "error": self.onError(body)
      case "pipStart": self.onPipStart(body)
      case "pipStop": self.onPipStop(body)
      default: break
      }
    }
  }

  public override func layoutSubviews() {
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
