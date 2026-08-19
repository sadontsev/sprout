#if os(macOS)
import AppKit
import SwiftUI

/// The menu bar item's label (§5.1).
///
/// **Text, not an icon.** The percentage while printing, the app mark alone when idle. There is
/// deliberately no progress ring: the menu bar is 22 pt tall, and a ring at that size is a dot —
/// it reads as a status light, not as progress, which is the one thing it would be there to say.
struct MacMenuBarLabel: View {
    let model: AppModel
    @AppStorage("mac.menuBar.showWhenIdle") private var showWhenIdle = false

    var body: some View {
        // No `Image` fallback with `Text`: mixing them makes the item's width jump every time the
        // print starts or ends. The mark is the template asset the iOS tab bar uses.
        if let percent {
            Text(verbatim: "\(percent) %").monospacedDigit()
        } else {
            Image("TabNozzle")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: Self.glyphHeight)
        }
    }

    /// How tall the nozzle mark is drawn in the menu bar.
    ///
    /// **It used to be drawn at its INTRINSIC size**, which for this asset is a 17.6 x 26 pt SVG — 26
    /// pt of artwork in a menu bar whose slot is 22 pt on most Macs. That is why it read as enormous
    /// beside every system item. The two other Mac call sites for the same asset (`MacSidebar`,
    /// `MacJobsSection`) both `.resizable().scaledToFit()` into a frame; this one did not, and it is
    /// the one place where nothing else constrains it — a `MenuBarExtra` label has no container to
    /// shrink it to fit.
    ///
    /// 14, and the number is smaller than it first looks like it should be because **this asset has
    /// no internal padding**. An SF Symbol at 16 pt draws perhaps 12 pt of actual ink — the rest of
    /// the box is margin the symbol carries with it, which is why the system's own menu bar glyphs sit
    /// comfortably. `TabNozzle` is a bare 17.6 x 26 pt outline that fills its own bounds, so its frame
    /// height IS its ink height. Matching the neighbours' ink, not their nominal point size, is what
    /// makes it stop standing out; at 16 it was still visibly the tallest thing in the bar.
    ///
    /// At 14 the mark is about 9.5 pt wide, which also keeps the item from taking more width than it
    /// needs — measured through `SPROUT_WINDOW_PROBE`, the status item goes from 44 pt to 34 pt.
    static let glyphHeight: CGFloat = 14

    private var percent: Int? {
        let vm = model.vm
        // The switch is labelled "Show the percentage when idle" and its footer says "Off, an idle
        // printer shows just the glyph" — so the question it asks is about IDLE. The guard asked
        // about `.complete`, which is a different state: a finished print that nobody has cleared.
        // An actually-idle printer therefore showed no percentage however the switch was set, and
        // the one state it did govern was not the one named on the control.
        guard vm.kind == .live
                || (showWhenIdle && (vm.kind == .idle || vm.kind == .complete)) else { return nil }
        return vm.progressInt
    }
}

/// The panel behind the menu bar item (§5.1) — the Mac's answer to the iOS Live Activity.
///
/// It reads the **existing** `PrinterStatusStore` through the shared `AppModel`, which is exactly
/// why `AppModel` was hoisted out of `Shell` into `SproutApp`. Two invariants come from §5.1 and
/// both are structural rather than defensive:
///
///  - It must not open a second connection. There is no client, no store and no polling in this
///    file; every value below is read from state the app already maintains.
///  - It must keep working with the main window closed. Nothing here reaches for a window, and
///    `MacAppDelegate` returns false from `applicationShouldTerminateAfterLastWindowClosed`.
struct MacMenuBarPanel: View {
    @Environment(\.openSettings) private var openSettings
    let model: AppModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

    /// Raised when a LAN-locked control is clicked. The panel owns the flag and attaches the alert
    /// once, which is the contract `LockedActions` documents.
    @State private var explainingLock = false

    private var c: Palette { Palette.forScheme(model.theme.colorScheme ?? scheme) }
    private var vm: DashVM { model.vm }
    private var lock: LockedActions {
        LockedActions(mode: model.lanMode, explaining: $explainingLock)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch vm.kind {
            case .live, .complete, .error:
                liveBody
            case .offline:
                offlineBody
            case .idle, .connecting:
                EmptyView()      // §5.1: idle collapses to name, state and Open Sprout
            }
            Divider().padding(.vertical, 11)
            actions
        }
        .padding(14)
        .frame(width: 300)
        .background(c.sheet)
        .macSceneChrome(model, systemScheme: scheme)
        .lockedActionAlert($explainingLock)
    }

    private var header: some View {
        HStack(spacing: 9) {
            PulseDot(color: vm.stateColor.resolve(c), size: 7)
            Text(model.printer?.name ?? "Printer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.t1)
            Spacer(minLength: 6)
            if vm.kind == .live {
                Text(verbatim: "layer \(vm.layer)/\(vm.totalLayers)")
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(c.t3)
            } else {
                Text(vm.stateLabel)
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(c.t3)
            }
        }
    }

    private var liveBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(vm.heroSub.isEmpty ? "—" : vm.heroSub)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(c.t2)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 11)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(verbatim: "\(vm.progressInt) %")
                    .font(.mono(22, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(c.t1)
                Spacer(minLength: 0)
                Text(etaLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(c.t2)
            }
            .padding(.top, 10)

            ProgressView(value: Double(vm.progressInt), total: 100)
                .progressViewStyle(.linear)
                .tint(vm.stateColor.resolve(c))
                .padding(.top, 8)

            HStack(spacing: 16) {
                temp("NOZZLE", "\(vm.nozzleNow)°")
                temp("BED", "\(vm.bedNow)°")
                if let active = vm.ams.first(where: \.active) {
                    // `localId` is the tray index inside its unit and is 0-based; every user-facing
                    // slot number in this app is 1-based (see AmsView's "Slot \(localId + 1)").
                    temp("\(active.unitLabel)\(active.localId + 1)", active.label)
                }
            }
            .padding(.top, 12)

            if vm.kind == .live {
                // `vm.kind == .live` answers "is a print running?". It does NOT answer "will the
                // printer accept a pause?" — in LAN developer mode Bambuddy refuses all three of
                // these, and this panel was the last surface still asking only the first question.
                // Live-looking buttons that silently do nothing is precisely what `LockedActions`
                // exists to prevent, and every other control in the app already routes through it.
                //
                // `press` keeps the button CLICKABLE while locked on purpose: the click is what
                // raises the explanation. A `.disabled` button swallows it and leaves a dead grey
                // square with no reason attached.
                HStack(spacing: 7) {
                    Button(action: lock.press(.pause) {
                        if vm.isPaused {
                            model.perform("Resume") { try await $0.resume($1) }
                        } else {
                            model.perform("Pause") { try await $0.pause($1) }
                        }
                    }) {
                        Text(vm.isPaused ? "Resume" : "Pause")
                    }
                    .buttonStyle(MacPrimaryButtonStyle())
                    .frame(maxWidth: .infinity)
                    .locked(.pause, by: lock)

                    Button(action: lock.press(.stop) {
                        model.perform("Stop") { try await $0.stop($1) }
                    }) {
                        Text("Stop")
                    }
                    .buttonStyle(MacSecondaryButtonStyle(role: .destructive))
                    .frame(maxWidth: .infinity)
                    .locked(.stop, by: lock)
                }
                .padding(.top, 13)
            }
        }
    }

    /// §5.1: offline says so, and offers Retry. A panel that simply showed nothing would be
    /// indistinguishable from a printer that is merely idle.
    private var offlineBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Sprout can’t reach this printer.")
                .font(.system(size: 12))
                .foregroundStyle(c.t2)
            Button("Retry") { Task { await model.refreshLanMode() } }
                .buttonStyle(MacSecondaryButtonStyle())
        }
        .padding(.top, 11)
    }

    private var etaLine: String {
        guard vm.kind == .live else { return vm.stateLabel }
        return vm.doneText == "—" ? vm.etaText : "\(vm.etaText) left · done ~ \(vm.doneText)"
    }

    private func temp(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.mono(11, weight: .medium))
                .foregroundStyle(c.t3)
            Text(value)
                .font(.mono(11, weight: .medium))
                .foregroundStyle(c.t1)
        }
    }

    private var actions: some View {
        VStack(spacing: 2) {
            // The hint said "⌘↩" and nothing bound it — the row was click-only, while
            // `MacAppDelegate` states as fact that "⌘↩ from its panel reopens the window". The other
            // three hints on this panel all resolve to real shortcuts; this one was decoration.
            row("Open Sprout", "⌘↩") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            .keyboardShortcut(.return, modifiers: .command)
            row("Camera window", "⌘0") { openWindow(id: "camera", value: model.printerId) }
            row("Settings…", "⌘,") {
                NSApp.activate(ignoringOtherApps: true)
                // `openSettings`, not the private `showSettingsWindow:` selector — the same bug the
                // toolbar had, and WORSE here: a `MenuBarExtra(.window)` panel is not in the main
                // window's responder chain, and §5.1 requires this to work with no window open at
                // all, where there is certainly nothing to answer a `sendAction`. The `activate`
                // above still fronted the app, so it read as "it blinked and did nothing".
                openSettings()
            }
            row("Quit Sprout", "⌘Q") { NSApp.terminate(nil) }
        }
    }

    private func row(_ title: String, _ shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(c.t1)
                Spacer(minLength: 8)
                Text(verbatim: shortcut)
                    .font(.mono(10.5, weight: .medium))
                    .foregroundStyle(c.t3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
#endif
