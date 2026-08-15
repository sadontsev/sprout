// The observable handle SwiftUI drives the camera stream through — SHARED.
//
// It used to be `CameraPiPModel`, declared inside `CameraPiPView.swift` under that file's whole-file
// `#if os(iOS)`. Only a minority of it was ever about PiP: `isLive`, `lastError` and `frameCount`
// describe an MJPEG stream, which the macOS camera window (spec 1c) and the Mac inspector tile need
// exactly as much as the iOS overlay does. It lives in its own file now so the UIKit host can stay
// iOS-only without taking the model with it, and the PiP-only members are guarded in place.
import SwiftUI
#if os(iOS)
import AVKit
#endif

/// Observable handle on the live stream, so SwiftUI can drive PiP and read stream health.
@MainActor
@Observable
final class CameraStreamModel {
    /// Whether the CURRENT connection has delivered a frame. It must go back to false when the
    /// renderer reconnects: consumers drive their state machines off a *change* of this flag, and
    /// while it was a write-once latch a reconnect (Retry, or the 45-minute camera-token rotation)
    /// left them waiting on an edge that could never happen again — the overlay decayed to
    /// "NO SIGNAL" over a picture that was still moving.
    var isLive = false
    var lastError: String?
    #if os(iOS)
    var pipActive = false
    #endif
    /// Frames decoded so far. Distinguishes "the stream stalled" from "frames arrive but nothing
    /// renders" — the exact ambiguity that made the earlier static-frame bug hard to pin down.
    var frameCount = 0
    #if os(iOS)
    /// Whether the near-silent audio session armed. If this is false, PiP will freeze the moment the
    /// app is backgrounded, because nothing is keeping the process alive.
    var audioKeepAliveOK = true
    var isPictureInPictureSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    #endif

    /// The renderer belonging to the platform view currently hosting the stream. Weak: the host view
    /// owns it, and the model outlives individual hosts (a `UIViewRepresentable`/`NSViewRepresentable`
    /// may be dismantled and remade). Was a reference to the iOS host view itself, which cannot be
    /// shared — every use was `view.renderer` anyway.
    weak var renderer: CameraRenderer?

    /// Fold a renderer event into the observable state.
    ///
    /// Shared, and called by both platform wrappers, so the mapping from `CameraEvent` to UI state
    /// exists once. Splitting it per platform would mean two switches over one enum that have to be
    /// kept in step — the shape this codebase keeps getting bitten by.
    func apply(_ event: CameraEvent) {
        switch event {
        case .live:
            isLive = true
        case .connecting:
            isLive = false
        case .error(let message, _):
            lastError = message
        case .stats(let frames, _):
            frameCount = frames
        case .pipStart, .pipStop, .audio:
            break
        }
        applyPictureInPicture(event)
    }

    /// The PiP-only half of `apply`. On macOS this is deliberately empty rather than absent: the
    /// renderer there never emits `.pipStart`, `.pipStop` or `.audio`, so there is nothing to record,
    /// and keeping one shared `CameraEvent` beats forking a `Sendable` enum that crosses the
    /// network→main hop.
    private func applyPictureInPicture(_ event: CameraEvent) {
        #if os(iOS)
        switch event {
        case .pipStart:
            pipActive = true
        case .pipStop:
            pipActive = false
        case .stats(_, let active):
            pipActive = active
        case .audio(let ok, let message):
            audioKeepAliveOK = ok
            if !ok { lastError = message }
        case .live, .connecting, .error:
            break
        }
        #endif
    }

    #if os(iOS)
    func startPiP() {
        guard let renderer else { return }
        // AVKit is main-thread-only. The RN build crashed here because Expo ran AsyncFunction bodies
        // on a background queue; in SwiftUI this method is already @MainActor, which is the fix.
        do {
            try renderer.enablePiP()
            renderer.startPiP()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopPiP() {
        renderer?.stopPiP()
    }
    #endif
}
