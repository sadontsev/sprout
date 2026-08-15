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
    /// Printers whose camera window is currently open.
    private(set) var windowsOpen: Set<Int> = []

    /// Called by the camera window when it appears.
    func windowOpened(printerId: Int) {
        windowsOpen.insert(printerId)
    }

    /// Called by the camera window when it goes away. Idempotent: SwiftUI may run `onDisappear`
    /// for a window that is being replaced rather than closed, and double-releasing must not leave
    /// a printer marked as claimed by a window that no longer exists.
    func windowClosed(printerId: Int) {
        windowsOpen.remove(printerId)
    }

    /// May the **inspector tile** stream this printer?
    ///
    /// The window never asks — it always may, because it is the owner by definition.
    func inspectorMayStream(printerId: Int) -> Bool {
        !windowsOpen.contains(printerId)
    }
}
#endif
