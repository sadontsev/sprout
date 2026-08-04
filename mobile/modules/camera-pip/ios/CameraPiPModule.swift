import ExpoModulesCore
import AVKit

/// Expo bridge for the chamber-camera view.
///
/// The camera is MJPEG, which iOS cannot put in Picture-in-Picture: PiP needs a real video track.
/// So instead of transcoding to HLS on a server, this decodes the JPEG frames in-app and feeds an
/// AVSampleBufferDisplayLayer, which AVPictureInPictureController accepts directly as a content
/// source. No transcode hop, no extra service, and no cold-start regression.
public final class CameraPiPModule: Module {
  public func definition() -> ModuleDefinition {
    Name("CameraPiP")

    /// Gate the UI on this — PiP is unavailable on some devices, and a button that silently does
    /// nothing is worse than no button.
    Function("isSupported") { () -> Bool in
      AVPictureInPictureController.isPictureInPictureSupported()
    }

    View(CameraPiPView.self) {
      Events("onLive", "onError", "onPipStart", "onPipStop")

      /// The MJPEG URL, token included. Changing it hot-swaps the network task WITHOUT tearing down
      /// the display layer — the token refreshes hourly, and rebuilding the layer would take the
      /// PiP window down with it.
      Prop("url") { (view: CameraPiPView, url: URL?) in
        view.setURL(url)
      }

      /// True while the view should be pulling frames. Set false to release the camera, which the
      /// printer powers down ~7 s later.
      Prop("active") { (view: CameraPiPView, active: Bool) in
        view.setActive(active)
      }

      AsyncFunction("startPiP") { (view: CameraPiPView) in
        try view.renderer.enablePiP()
        view.renderer.startPiP()
      }

      AsyncFunction("stopPiP") { (view: CameraPiPView) in
        view.renderer.stopPiP()
      }
    }
  }
}
