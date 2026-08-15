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
            Image("TabNozzle").renderingMode(.template)
        }
    }

    private var percent: Int? {
        let vm = model.vm
        guard vm.kind == .live || (showWhenIdle && vm.kind == .complete) else { return nil }
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
    let model: AppModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

    private var c: Palette { Palette.forScheme(model.theme.colorScheme ?? scheme) }
    private var vm: DashVM { model.vm }

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
        .environment(\.palette, c)
        .environment(\.metrics, .mac)
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
                HStack(spacing: 7) {
                    Button(vm.isPaused ? "Resume" : "Pause") {
                        if vm.isPaused {
                            model.perform("Resume") { try await $0.resume($1) }
                        } else {
                            model.perform("Pause") { try await $0.pause($1) }
                        }
                    }
                    .buttonStyle(MacPrimaryButtonStyle())
                    .frame(maxWidth: .infinity)

                    Button("Stop") { model.perform("Stop") { try await $0.stop($1) } }
                        .buttonStyle(MacSecondaryButtonStyle(role: .destructive))
                        .frame(maxWidth: .infinity)
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
            row("Open Sprout", "⌘↩") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            row("Camera window", "⌘0") { openWindow(id: "camera", value: model.printerId) }
            row("Settings…", "⌘,") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
