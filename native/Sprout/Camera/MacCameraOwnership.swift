#if os(macOS)
import Foundation
import Observation

/// Which surface currently owns the live camera stream for each printer (§5.2).
///
/// Bambuddy runs ONE ffmpeg per printer and fans it out; its output rate is fixed by whichever
/// viewer *created* the broadcaster, and every later viewer's `?fps=` is accepted and ignored
/// (see `CameraUpstreamClaim` for the full account). Two live claims on one printer therefore does
/// not mean "two nice pictures" — it means the second viewer silently inherits the first's frame
/// rate, and the app is paying for two HTTP streams to get one.
///
/// On iOS that could not arise: the tile and the fullscreen camera are the same screen, so only one
/// is ever mounted. On Mac the camera window is a **separate scene** and can be open while the
/// Printer inspector is also on screen, so the exclusion has to be made explicit.
///
/// The rule (§5.2): **the window wins.** Opening it takes the claim; the inspector tile falls back
/// to its last frame with a `PLAYING IN WINDOW` label, which is honest about where the live picture
/// went. Closing the window hands the claim back.
///
/// Deliberately a set of printer ids rather than an enum of owners: the question every caller
/// actually asks is "may I stream printer N right now", and a set answers exactly that. An
/// `Owner` enum would also have to encode "which window", which nothing needs — there is one camera
/// window per printer by construction (`WindowGroup(id:"camera", for: Int.self)`).
@Observable
@MainActor
final class MacCameraOwnership {
    /// Printers whose camera window is **currently streaming**.
    ///
    /// Streaming, not open. An open-but-PAUSED window holds no claim: it is not using the upstream,
    /// so there is nothing for the tile to collide with, and leaving it claimed would caption the
    /// tile `PLAYING IN WINDOW` while neither surface showed video. "A window exists" and "a window
    /// is using the camera" are two questions, and only the second one is this type's business.
    private(set) var windowsStreaming: Set<Int> = []

    /// The camera window's single report. Called when it appears, when it is paused or resumed, and
    /// when it goes away — one entry point so the three cannot answer differently.
    ///
    /// Idempotent: SwiftUI may run `onDisappear` for a window being replaced rather than closed,
    /// and a double release must not leave a printer claimed by a window that no longer exists.
    func setWindowStreaming(_ streaming: Bool, printerId: Int) {
        if streaming { windowsStreaming.insert(printerId) }
        else { windowsStreaming.remove(printerId) }
    }

    /// May an in-window **tile** stream this printer?
    ///
    /// Asked by BOTH tiles now — the inspector's and the content column's fallback — which is why it
    /// is no longer called `inspectorMayStream`. One printer, one live stream: whoever asks, the
    /// answer is "not while a camera WINDOW is streaming it".
    ///
    /// The window itself never asks. It always may, because it is the owner by definition.
    func tileMayStream(printerId: Int) -> Bool {
        !windowsStreaming.contains(printerId)
    }
}
#endif
