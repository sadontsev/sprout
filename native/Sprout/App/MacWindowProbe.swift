#if os(macOS) && DEBUG
import AppKit

/// Reports — and photographs — the app's own windows, on request. Development only, never shipped.
///
/// It exists because **inspecting a Mac app from outside is blind by default.** Every external route
/// needs a TCC permission a terminal usually lacks, and none of them fails loudly:
///
///  - `System Events` window enumeration needs Accessibility. Without it it does not error — it
///    returns `0 windows`, for every app, including Finder.
///  - `CGWindowListCopyWindowInfo` needs Screen Recording for names, and returns a restricted list
///    that omits other apps' windows entirely.
///  - `screencapture` needs Screen Recording.
///
/// So a perfectly healthy app reports as having no windows and cannot be photographed. That false
/// negative cost real time once: the onboarding window and the menu bar item were both up and
/// correct while two separate probes insisted nothing was on screen.
///
/// The way out is that **an app needs no permission to look at itself**. `cacheDisplay(in:to:)`
/// renders a window's own content into a bitmap the app already owns, which is why `SPROUT_SHOT`
/// works headlessly where `screencapture` does not.
///
/// **`SPROUT_SHOT` has one important blind spot, and it is a convincing one.** `cacheDisplay` does
/// not render `NSVisualEffectView`, and on macOS 26 both the sidebar and the inspector are backed by
/// `NSContainerConcentricGlassEffectView`. Those regions come back as whatever bytes were already in
/// the bitmap — in practice a flat white block where the sidebar is and leftover framebuffer content
/// (the desktop wallpaper) where the inspector is. It looks exactly like a broken sidebar beside an
/// empty inspector, and it was read that way once. `SPROUT_TREE` is the answer: it dumps the AppKit
/// hierarchy, where both panes are plainly present at their spec widths (220 and 320).
///
/// So: use `SPROUT_SHOT` to check the CONTENT column, and `SPROUT_TREE` to check the panes. A
/// screenshot alone cannot settle a question about either of them.
///
/// Same shape as `AttestCapture.runIfRequested()` — DEBUG-only and opt-in through the environment,
/// so it costs nothing when it is not wanted:
///
///     SPROUT_WINDOW_PROBE=1 Sprout.app/Contents/MacOS/Sprout          # report, then exit
///     SPROUT_SHOT=/tmp/sprout Sprout.app/Contents/MacOS/Sprout        # write /tmp/sprout-<n>.png
///     SPROUT_SHOT_DELAY=8 …                                           # wait longer before shooting
enum MacWindowProbe {
    @MainActor
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        let wantsReport = env["SPROUT_WINDOW_PROBE"] != nil
        let shotPrefix = env["SPROUT_SHOT"]
        guard wantsReport || shotPrefix != nil else { return }

        // After the runloop has turned enough for SwiftUI to materialise its scenes AND for the
        // first status poll to land — asking inside `applicationDidFinishLaunching` reports an
        // empty list on a healthy app, and shooting too early photographs spinners.
        // Force a window size before shooting. The default is `.defaultSize(1440, 900)`, but a
        // window restores its persisted frame ahead of that, so a headless run inherits whatever the
        // last one left — which is how the first captures came back at the 1080 pt MINIMUM and made
        // the three-column layout look like a one-column one.
        if let size = env["SPROUT_WINDOW_SIZE"] {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    for window in NSApp.windows where window.isVisible && window.contentView != nil {
                        guard !String(describing: type(of: window)).contains("StatusBar") else { continue }
                        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                        window.center()
                    }
                }
            }
        }

        // Make the app FRONTMOST before measuring anything.
        //
        // Without this a headless run never becomes key, so `@FocusedValue` reads nil and
        // `controlActiveState` is `.inactive` — and every focus-gated control photographs as
        // DIMMED. That is a property of the probe, not of the app, and it is exactly the kind of
        // false negative this file exists to warn about: it makes working navigation links look
        // like the dead controls this codebase keeps hunting.
        NSApp.activate(ignoringOtherApps: true)

        let delay = env["SPROUT_SHOT_DELAY"].flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if wantsReport { report() }
            if env["SPROUT_TREE"] != nil { tree() }
            if let shotPrefix { shoot(prefix: shotPrefix) }
            // `NSApp.terminate`, NOT `exit(0)`.
            //
            // `@SceneStorage` is written through SwiftUI's state restoration, which only runs on a
            // NORMAL termination. Exiting abruptly skips it — so a probe run would never persist the
            // section it was told to open, and the next run would look as though restoration was
            // broken. It very nearly got recorded that way.
            //
            // The hard exit stays as a backstop: `terminate` is cooperative and can be refused, and
            // a probe that hangs is worse than one that skips a save.
            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        }
    }

    @MainActor
    private static func report() {
        var out = "PROBE windows=\(NSApp.windows.count) policy=\(NSApp.activationPolicy().rawValue)\n"
        for w in NSApp.windows {
            out += "PROBE  \(type(of: w)) visible=\(w.isVisible) frame=\(w.frame) title=\(w.title)\n"
        }
        FileHandle.standardError.write(Data(out.utf8))
    }

    /// Dumps the AppKit view tree of the main window.
    ///
    /// This exists because `SPROUT_SHOT` cannot photograph everything: `cacheDisplay(in:to:)` does
    /// not render `NSVisualEffectView`, which backs both the sidebar and the inspector. In a capture
    /// those two regions come back as whatever was already in the bitmap — which looked alarmingly
    /// like a broken sidebar and an empty inspector. The tree says whether they are actually there,
    /// how wide they are, and whether they have content, none of which a screenshot can settle.
    @MainActor
    private static func tree() {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && !String(describing: type(of: $0)).contains("StatusBar")
        }), let root = window.contentView else { return }

        var out = "TREE window=\(Int(window.frame.width))x\(Int(window.frame.height))\n"
        func walk(_ v: NSView, _ depth: Int) {
            // Deep enough to reach the split view's columns and see that they hold something;
            // beyond that it is thousands of lines of SwiftUI internals.
            guard depth <= 14 else { return }
            let name = String(describing: type(of: v))
            // The names worth seeing: the split view and its columns, and the glass/effect views
            // that back the sidebar and inspector — which are exactly the ones `SPROUT_SHOT` cannot
            // photograph, and therefore the ones only this dump can confirm.
            let interesting = name.contains("Inspector") || name.contains("Effect")
                || name.contains("Split") || name.contains("Glass") || name.contains("Hosting")
            if interesting {
                out += "TREE \(String(repeating: "  ", count: depth))\(name) "
                    + "\(Int(v.frame.width))x\(Int(v.frame.height)) @\(Int(v.frame.minX)) "
                    + "subviews=\(v.subviews.count) hidden=\(v.isHidden)\n"
            }
            for sub in v.subviews { walk(sub, depth + 1) }
        }
        walk(root, 0)
        FileHandle.standardError.write(Data(out.utf8))
    }

    /// Writes every visible window's own content to `<prefix>-<n>.png`.
    ///
    /// Skips `NSStatusBarWindow` — the menu bar item's host window is a 34×39 pt shim owned by the
    /// system, and photographing it produces a blank tile rather than the panel, which only exists
    /// while the item is open.
    @MainActor
    private static func shoot(prefix: String) {
        var index = 0
        for window in NSApp.windows where window.isVisible {
            guard !String(describing: type(of: window)).contains("StatusBar"),
                  let view = window.contentView,
                  view.bounds.width > 1, view.bounds.height > 1,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }

            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }

            let path = "\(prefix)-\(index).png"
            do {
                try png.write(to: URL(fileURLWithPath: path))
                FileHandle.standardError.write(Data("SHOT \(path) \(Int(view.bounds.width))x\(Int(view.bounds.height))\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("SHOT FAILED \(path): \(error)\n".utf8))
            }
            index += 1
        }
    }
}
#endif
