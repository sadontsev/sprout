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
        // Branch on the STATE, not on whether a number happens to exist.
        //
        // This read `if let percent`, which answers "is there a percentage to display?" — a different
        // question from "does this state replace the glyph with a number?", and `MacStatusMark`
        // already answers the second one. The two diverge exactly where `showWhenIdle` is on: an idle
        // machine then has a percentage, so the old branch showed `62 %` and the idle mark never
        // rendered. `showsGlyph` existed and nothing consulted it — both halves of CLAUDE.md's
        // recurring bug in four lines.
        if !state.showsGlyph || (showWhenIdle && percent != nil) {
            Text(verbatim: "\(percent ?? 0) %").monospacedDigit()
        } else if let mark = MacStatusMarkArt.image(state) {
            Image(nsImage: mark)
        } else if let glyph = Self.glyph {
            Image(nsImage: glyph)
        } else {
            // The asset is missing from the bundle. Say something rather than draw an empty item that
            // cannot be clicked because it has no width.
            Text(verbatim: "Sprout")
        }
    }

    /// The nozzle mark, sized for the menu bar.
    ///
    /// **A SwiftUI `.frame(height:)` does not work here, and appearing to work is the trap.** The
    /// asset is a 17.6 x 26 pt SVG and the label used to draw it at that intrinsic size — 26 pt of
    /// artwork in a 22 pt bar, towering over every system item. The obvious fix is
    /// `.resizable().scaledToFit().frame(height:)`, which is exactly what the other two Mac call
    /// sites for this asset do, and in a `MenuBarExtra` label it changes NOTHING: the status item
    /// takes its size from the `NSImage`, so the modifier is discarded and the glyph stays 26 pt.
    ///
    /// That was shipped once as a fix. It was "verified" by watching the status item's window shrink
    /// from 44 pt to 34 pt — but 44 was the PERCENTAGE branch (demo mode always has a live print, so
    /// the glyph never rendered) and 34 is simply what the unfixed glyph occupies. The A/B compared
    /// two different branches and called it a result. The way to actually settle it is to set an
    /// absurd height and look: at 4 pt the item still measured 34, which is the proof that the frame
    /// is inert.
    ///
    /// So the size is set on the image itself. `isTemplate` is what lets the menu bar tint it for
    /// light, dark and the highlighted state, and it must be re-set because it does not survive the
    /// copy.
    ///
    /// 14 pt, which looks low until you notice the asset carries no internal padding. An SF Symbol at
    /// 16 pt draws perhaps 12 pt of ink and keeps the rest as margin, which is why the system's own
    /// glyphs sit comfortably; this one fills its bounds, so its height IS its ink. Matching the
    /// neighbours' ink rather than their nominal size is what stops it standing out.
    static let glyphHeight: CGFloat = 14

    /// Built once. `NSImage(named:)` hits the asset catalog on every call, and this is read on every
    /// status update.
    static let glyph: NSImage? = {
        guard let base = NSImage(named: "TabNozzle") else { return nil }
        guard let sized = base.copy() as? NSImage, base.size.height > 0 else { return nil }
        let aspect = base.size.width / base.size.height
        sized.size = NSSize(width: (glyphHeight * aspect).rounded(), height: glyphHeight)
        sized.isTemplate = true
        return sized
    }()

    /// Which mark this label should draw. Drying is read off the AMS units rather than the dashboard
    /// kind, because a dry cycle is a concurrent activity and not a `DashKind` — on an otherwise idle
    /// machine it is the only thing the bar has to report.
    private var state: MacStatusMark {
        // `dryingMinLeft > 0` is THE active signal, and it is the same one `Dryer` and
        // `LiveActivityController.dryingUnitIds` use — `dryStatus` was measured stuck at 0 mid-cycle
        // on the live machine. Asking the question a second way here would eventually disagree with
        // the card on the phone about whether the same machine is drying.
        MacStatusMark.mark(LAState.of(vm: model.vm,
                                      drying: model.vm.amsUnits.contains { $0.dryingMinLeft > 0 }))
    }

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

            // The panel's OWN failure line.
            //
            // Pause, Stop and Camera report failure through `AppModel.perform`, which writes
            // `model.toast` — and the only macOS presenter of a toast is `MacToast` inside `MacRoot`,
            // i.e. inside the main WINDOW. This panel is documented to keep working with that window
            // closed, and that is its whole point: a menu bar extra is what you use when the app is
            // not open. So the one surface most likely to have no window was the one whose failures
            // had nowhere to render. Clicking Pause on a printer that refuses it did nothing, said
            // nothing, and looked exactly like success.
            //
            // Row 5 of CLAUDE.md's recurring-bug table is this panel, for the neighbouring reason.
            if let toast = model.toast {
                panelToast(toast)
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

    /// A failure, said inside the panel, with a way to dismiss it.
    ///
    /// Deliberately not the full `MacToast`: that is a floating banner sized for a window, and this
    /// is a 300 pt popover. Same source of truth, same copy, appropriate shape.
    private func panelToast(_ toast: Toast) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: toast.kind == .failure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .scaledFont(11)
                .foregroundStyle(toast.kind == .failure ? c.error : c.running)
            Text(verbatim: toast.text)
                .scaledFont(11)
                .foregroundStyle(c.t2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.toast = nil
            } label: {
                Image(systemName: "xmark").scaledFont(8, weight: .bold).foregroundStyle(c.t3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.mac.controlRadius, style: .continuous).fill(c.s2))
        .padding(.top, 10)
    }

    private var header: some View {
        HStack(spacing: 9) {
            PulseDot(color: vm.stateColor.resolve(c), size: 7, meaning: vm.stateLabel)
            Text(model.printer?.name ?? "Printer")
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(c.t1)
            Spacer(minLength: 6)
            if vm.kind == .live {
                Text(verbatim: "layer \(vm.layer)/\(vm.totalLayers)")
                    .scaledMono(11, weight: .medium)
                    .foregroundStyle(c.t3)
            } else {
                Text(vm.stateLabel)
                    .scaledMono(11, weight: .medium)
                    .foregroundStyle(c.t3)
            }
        }
    }

    private var liveBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(vm.heroSub.isEmpty ? "—" : vm.heroSub)
                .scaledFont(12, weight: .semibold)
                .foregroundStyle(c.t2)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 11)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(verbatim: "\(vm.progressInt) %")
                    .scaledMono(22, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(c.t1)
                Spacer(minLength: 0)
                Text(etaLine)
                    .scaledFont(11.5)
                    .foregroundStyle(c.t2)
            }
            .padding(.top, 10)

            // The same extrusion bar the phone card draws (design 1e), not a stock `ProgressView`.
            // 13x17 glyph and 10 pt of headroom here rather than the card's 15x20 and 11 — the panel
            // is denser. `ExtrusionBar` had no Mac call site at all until now, which is why this was
            // the one surface still showing a plain track.
            ExtrusionBar(
                progress: Double(vm.progressInt) / 100,
                tint: vm.stateColor.resolve(c),
                riding: ExtrusionRider.rides(tintHex: LAState.of(vm: vm).tintHex,
                                             finished: vm.kind == .complete),
                glyphSize: CGSize(width: 13, height: 17),
                headroom: 10
            ) {
                NozzleMark(bead: vm.stateColor.resolve(c))
            }
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
                .scaledFont(12)
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
                .scaledMono(11, weight: .medium)
                .foregroundStyle(c.t3)
            Text(value)
                .scaledMono(11, weight: .medium)
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
                    .scaledFont(12)
                    .foregroundStyle(c.t1)
                Spacer(minLength: 8)
                Text(verbatim: shortcut)
                    .scaledMono(10.5, weight: .medium)
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
