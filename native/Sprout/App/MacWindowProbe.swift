#if os(macOS) && DEBUG
import AppKit

/// Reports the app's own windows to stderr, on request. A development diagnostic, never shipped.
///
/// It exists because **inspecting a Mac app's windows from a shell is blind by default.** Both
/// obvious routes need TCC permissions a terminal usually lacks:
///
///  - `System Events` window enumeration needs Accessibility. Without it, it does not error — it
///    returns `0 windows`, for every app, including Finder.
///  - `CGWindowListCopyWindowInfo` needs Screen Recording for window names, and returns a
///    restricted list that omits other apps' windows entirely.
///
/// Both therefore report a perfectly healthy app as having no windows at all. That false negative
/// cost real time once: the onboarding window and the menu bar item were both up and correct while
/// two separate probes insisted nothing was on screen. Asking the app itself needs no permission
/// and cannot lie.
///
/// Same shape as `AttestCapture.runIfRequested()` — DEBUG-only and opt-in through the environment,
/// so it costs nothing when it is not wanted.
///
///     SPROUT_WINDOW_PROBE=1 Sprout.app/Contents/MacOS/Sprout
enum MacWindowProbe {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["SPROUT_WINDOW_PROBE"] != nil else { return }
        // After the first runloop turns, so SwiftUI has actually materialised its scenes — asking
        // inside applicationDidFinishLaunching reports an empty list on a healthy app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            var out = "PROBE windows=\(NSApp.windows.count) policy=\(NSApp.activationPolicy().rawValue)\n"
            for w in NSApp.windows {
                out += "PROBE  \(type(of: w)) visible=\(w.isVisible) frame=\(w.frame) title=\(w.title)\n"
            }
            FileHandle.standardError.write(Data(out.utf8))
            // Exits so a caller can capture the report without leaving a GUI app running.
            exit(0)
        }
    }
}
#endif
