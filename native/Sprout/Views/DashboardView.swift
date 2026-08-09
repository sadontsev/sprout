import SwiftUI

/// The Printer tab: header, hero state, camera tile, and one block per print state.
///
/// Section order is deliberate and matches the design: the LAN banner sits BELOW the live/idle
/// content but ABOVE complete/error/offline/connecting. It is not a fixed banner.
struct DashboardView: View {
    let model: AppModel
    var onSettings: () -> Void

    @Environment(\.palette) private var c
    @State private var switcherOpen = false
    @State private var speedOpen = false
    @State private var camLoaded = false
    @State private var snapshotTick = 0
    @State private var maintenance: (due: Int, warn: Int) = (0, 0)
    @State private var speedOverride: Int?
    @State private var confirmStop = false
    @State private var explainingLock = false

    private var vm: DashVM { model.vm }
    private var lock: LockedActions {
        LockedActions(mode: model.lanMode, explaining: $explainingLock)
    }

    private var showCamera: Bool {
        [.live, .idle, .complete, .error].contains(vm.kind)
    }

    private var alerts: [AlertVM] {
        Alerts.present(
            model.status?.status,
            caps: AlertCaps(connected: vm.kind != .offline, canControl: true, model: model.printer?.model)
        )
    }

    private var speedIdx: Int { speedOverride ?? vm.speedIdx }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                if switcherOpen { fleetSwitcher }
                if maintenance.due > 0 || maintenance.warn > 0 { maintenanceChip }
                if let summary = Alerts.summary(alerts) { alertChip(summary) }
                hero
                if showCamera { cameraTile }
                // Only after a print, and only when the model is willing to say something honest.
                if let cool = model.cooldown?.vm, cool.phase != .none { CooldownCard(vm: cool) }

                switch vm.kind {
                case .live: liveBlock
                case .idle: idleBlock
                default: EmptyView()
                }

                if model.lanMode == .off { lanBanner }

                switch vm.kind {
                case .complete: completeBlock
                case .error: errorBlock
                case .offline: offlineBlock
                case .connecting: connectingBlock
                default: EmptyView()
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 120)   // clearance for the floating tab bar
        }
        .scrollIndicators(.hidden)
        .background(c.bg)
        .lockedActionAlert($explainingLock)
        .confirmationDialog("Stop print?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { model.perform("Stop") { try await $0.stop($1) } }
            Button("Keep printing", role: .cancel) {}
        } message: {
            Text("This cancels the current job. It can't be undone.")
        }
        // The camera poller is deliberately NOT gated on PiP state. It was, and a stuck "PiP active"
        // flag froze this tile on a cached frame.
        .task(id: model.tab) {
            while !Task.isCancelled, model.tab == .printer {
                try? await Task.sleep(for: .seconds(2))
                snapshotTick &+= 1
            }
        }
        .task(id: model.printerId) {
            maintenance = (0, 0)
            while !Task.isCancelled {
                if let client = model.client,
                   let m = try? await client.getMaintenance(model.printerId) {
                    maintenance = (m.dueCount ?? 0, m.warningCount ?? 0)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // An open list of enabled-looking speed rows over a blocked control is exactly the bug this
        // prevents.
        .onChange(of: model.lanMode) { _, _ in
            if lock.blocked(.speed) { speedOpen = false }
        }
        .onChange(of: vm.speedIdx) { _, server in
            if server == speedOverride { speedOverride = nil }
        }
    }

    // MARK: - Header

    private var brand: String {
        model.printer.map { "BAMBU LAB \($0.model.uppercased())" } ?? "BAMBU LAB"
    }

    private var canSwitch: Bool { model.printers.count > 1 }

    private var header: some View {
        HStack(alignment: .top) {
            Tap(disabled: !canSwitch) {
                if canSwitch { switcherOpen.toggle() }
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(brand)
                        .font(.mono(11))
                        .tracking(1.4)
                        .foregroundStyle(c.t3)
                    HStack(spacing: 7) {
                        PulseDot(color: vm.stateColor.resolve(c), size: 8)
                        Text(model.printer?.name ?? "Printer")
                            .font(.system(size: 17, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(c.t1)
                        if canSwitch {
                            Image(systemName: switcherOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(c.t3)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Spacer()

            Tap(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundStyle(c.t2)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(c.s2))
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
    }

    private var fleetSwitcher: some View {
        FadeRise(dy: -6, duration: 0.18) {
            VStack(spacing: 0) {
                ForEach(model.printers) { p in
                    let entry = Dash.present(model.status?.statuses[p.id])
                    let isCurrent = p.id == model.printerId
                    Tap {
                        switcherOpen = false
                        if !isCurrent { model.printerId = p.id }
                    } content: {
                        HStack(spacing: 11) {
                            PulseDot(color: entry.stateColor.resolve(c), size: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(c.t1)
                                Text(switcherSubtitle(p, entry))
                                    .font(.mono(11, weight: .medium))
                                    .foregroundStyle(c.t3)
                            }
                            Spacer()
                            if isCurrent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(c.accent)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(isCurrent ? c.s3 : .clear))
                        .contentShape(.rect)
                    }
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(c.line2))
            .shadow1()
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    private func switcherSubtitle(_ p: Printer, _ entry: DashVM) -> String {
        let location = p.location.map { " · \($0)" } ?? ""
        let state = entry.kind == .live ? "\(entry.stateLabel) \(entry.progressInt)%" : entry.stateLabel
        return "\(p.model)\(location) · \(state)"
    }

    // MARK: - Chips

    private var maintenanceChip: some View {
        let due = maintenance.due
        let tint = due > 0 ? c.error : c.heating
        let label = due > 0
            ? "\(due) maintenance \(due == 1 ? "task is" : "tasks are") due"
            : "\(maintenance.warn) maintenance \(maintenance.warn == 1 ? "task is" : "tasks are") coming up"
        return FadeRise {
            Tap { model.tab = .ams } content: {
                chipRow(icon: "wrench.and.screwdriver", tint: tint, label: label, verticalPadding: 12)
            }
        }
    }

    private func alertChip(_ summary: AlertSummary) -> some View {
        let tint: Color = switch summary.level {
        case .error: c.error
        case .warning: c.heating
        case .info: c.accent
        }
        let icon = summary.level == .info ? "info.circle" : "exclamationmark.circle"
        return FadeRise {
            Tap { model.overlay = .alerts } content: {
                chipRow(icon: icon, tint: tint, label: summary.label, verticalPadding: 13)
            }
        }
    }

    /// Shared shape for the maintenance and alert chips — a tinted pill with a leading glyph and a
    /// trailing chevron. They differ only by 1 pt of vertical padding, which is real, not a typo.
    private func chipRow(icon: String, tint: Color, label: String, verticalPadding: CGFloat) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(tint)
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.t1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(c.t3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, verticalPadding)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint))
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .contentShape(.rect)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(vm.stateLabel)
                .font(.system(size: 36, weight: .bold))
                .tracking(-1)
                .foregroundStyle(vm.stateColor.resolve(c))
            if !vm.heroSub.isEmpty {
                Text(vm.heroSub)
                    .font(.mono(13, weight: .medium))
                    .lineSpacing(4)
                    .foregroundStyle(c.t2)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 2)
    }

    // MARK: - Camera tile

    private var snapshotURL: URL? {
        guard let client = model.client, let token = model.cameraToken else { return nil }
        guard let base = client.snapshotUrl(model.printerId, token: token) else { return nil }
        // The picture only changes when the URL changes, so the tick is the cache-bust.
        return URL(string: base.absoluteString + "&_t=\(snapshotTick)")
    }

    private var cameraTile: some View {
        Tap { model.overlay = .camera } content: {
            ZStack(alignment: .topLeading) {
                c.thumb
                if let url = snapshotURL {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.12))) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                                .onAppear { camLoaded = true }
                        } else {
                            Color.clear
                        }
                    }
                } else {
                    Text("CHAMBER · SNAPSHOT")
                        .font(.mono(10, weight: .medium))
                        .tracking(1.6)
                        .foregroundStyle(c.t3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HStack(spacing: 5) {
                    if camLoaded {
                        PulseDot(color: c.running, size: 6, period: 2.0)
                    } else {
                        Circle().fill(c.t3).frame(width: 6, height: 6)
                    }
                    // "1 fps" is nominal — the poll is every 2 s. Keep the string.
                    Text(camLoaded ? "LIVE · 1 fps" : "WAKING…")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.55)))
                .padding(11)
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(c.line))
            .overlay(alignment: .bottomLeading) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.5)))
                    .padding(.leading, 11)
                    .padding(.bottom, 9)
            }
            .shadow1()
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        // A cold camera takes seconds to produce a frame; the badge must not claim LIVE over a blank
        // tile, so the flag resets whenever the URL goes away.
        .onChange(of: snapshotURL == nil) { _, gone in if gone { camLoaded = false } }
    }

    // MARK: - LIVE

    private var liveBlock: some View {
        VStack(spacing: 0) {
            progressCard
            TempGrid(vm: vm, heatingEnabled: true)
            controlsRow1
            controlsRow2
            amsStrip
        }
    }

    private var progressCard: some View {
        HStack(spacing: 18) {
            ProgressRing(
                progress: Double(vm.progressInt) / 100,
                size: 128,
                lineWidth: 9,
                color: vm.stateColor.resolve(c),
                track: c.s3,
                glow: !vm.isPaused
            ) {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    RollingNumber(
                        value: vm.progressInt,
                        font: .system(size: 32, weight: .bold),
                        color: c.t1,
                        digitHeight: 38
                    )
                    Text("%")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(c.t3)
                }
            }

            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 0) {
                    fieldLabel("LAYER")
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        RollingNumber(
                            value: Int(vm.layer) ?? 0,
                            font: .system(size: 19, weight: .semibold),
                            color: c.t1,
                            digitHeight: 23
                        )
                        Text(" / \(vm.totalLayers)")
                            .font(.mono(19, weight: .medium))
                            .foregroundStyle(c.t3)
                    }
                    .padding(.top, 5)
                }
                Rectangle().fill(c.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    fieldLabel("TIME LEFT")
                    Text(vm.etaText)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .contentTransition(.numericText())
                        .animation(Motion.roll(0.6), value: vm.etaText)
                        .padding(.top, 5)
                    Text("done ~ \(vm.doneText)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(c.t3)
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(c.line))
        .shadow1()
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s)
            .font(.mono(10))
            .tracking(1)
            .foregroundStyle(c.t3)
    }

    private var controlsRow1: some View {
        HStack(spacing: 12) {
            let action: ActionId = vm.isPaused ? .resume : .pause
            // Read the flag here, on the main actor, rather than inside the sendable closure.
            let paused = vm.isPaused
            Tap(action: lock.press(action) {
                model.perform(paused ? "Resume" : "Pause") { client, id in
                    paused ? try await client.resume(id) : try await client.pause(id)
                }
            }) {
                HStack(spacing: 9) {
                    Image(systemName: lock.blocked(action) ? "lock.fill" : (vm.isPaused ? "play.fill" : "pause.fill"))
                        .font(.system(size: 15))
                        .foregroundStyle(c.t1)
                    Text(vm.isPaused ? "Resume" : "Pause")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(c.t1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(c.s3))
                .opacity(lock.style(action) ?? 1)
            }
            .frame(maxWidth: .infinity)

            // Stop is NEVER lock-gated: a dead emergency stop on a failing print is worse than a
            // command the printer might reject.
            Tap { confirmStop = true } content: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill").font(.system(size: 13)).foregroundStyle(c.error)
                    Text("Stop").font(.system(size: 16, weight: .semibold)).foregroundStyle(c.error)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(c.errorDim))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    private var controlsRow2: some View {
        HStack(spacing: 12) {
            // The light is system/ledctrl, not a print.* command — never lock-gated.
            Tap {
                let next = !vm.lightOn
                model.perform("Light") { try await $0.setLight($1, on: next) }
            } content: {
                HStack(spacing: 9) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 15))
                        .foregroundStyle(vm.lightOn ? c.accent : c.t1)
                        .shadow(color: vm.lightOn ? c.accent.opacity(0.5) : .clear, radius: 6)
                    Text("Light")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(vm.lightOn ? c.accent : c.t1)
                    Text(vm.lightOn ? "ON" : "OFF")
                        .font(.mono(12))
                        .foregroundStyle(vm.lightOn ? c.accent : c.t1)
                        .opacity(0.7)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(vm.lightOn ? c.accentDim : c.s3))
            }
            .frame(maxWidth: .infinity)

            speedControl
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var speedControl: some View {
        Tap(action: lock.press(.speed) { speedOpen.toggle() }) {
            HStack(spacing: 9) {
                Image(systemName: lock.blocked(.speed) ? "lock.fill" : "bolt.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(c.t1)
                Text(Self.speeds.first { $0.i == speedIdx }?.name ?? vm.speedLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.t1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(c.t3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(speedOpen ? c.s4 : c.s3))
            .opacity(lock.style(.speed) ?? 1)
        }
        .frame(maxWidth: .infinity)
        // The popover opens UPWARD, above the button, so it escapes over the AMS strip below.
        .overlay(alignment: .bottom) {
            if speedOpen { speedPopover.offset(y: -62) }
        }
        .zIndex(speedOpen ? 30 : 0)
    }

    private struct Speed: Identifiable { let i: Int; let name: String; let hint: String; let dot: KeyPath<Palette, Color>; var id: Int { i } }

    private static let speeds: [Speed] = [
        Speed(i: 1, name: "Silent", hint: "50%", dot: \.paused),
        Speed(i: 2, name: "Standard", hint: "100%", dot: \.running),
        Speed(i: 3, name: "Sport", hint: "124%", dot: \.heating),
        Speed(i: 4, name: "Ludicrous", hint: "166%", dot: \.error),
    ]

    private var speedPopover: some View {
        FadeRise(dy: 6, duration: 0.17) {
            VStack(alignment: .leading, spacing: 0) {
                Text("SPEED")
                    .font(.mono(9))
                    .tracking(1)
                    .foregroundStyle(c.t3)
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
                    .padding(.bottom, 6)
                ForEach(Self.speeds) { s in
                    let selected = s.i == speedIdx
                    Tap {
                        setSpeed(s.i)
                        speedOpen = false
                    } content: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 4).fill(c[keyPath: s.dot]).frame(width: 8, height: 8)
                            Text(s.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(c.t1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(s.hint).font(.mono(11, weight: .medium)).foregroundStyle(c.t3)
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 13)).foregroundStyle(c.accent)
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 11).fill(selected ? c.s3 : .clear))
                        .contentShape(.rect)
                    }
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(c.line2))
            .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 12)
            .padding(.horizontal, -6)
        }
    }

    /// Optimistic: show the new mode immediately, and let the server's own value take over when it
    /// catches up. The override also clears on failure and after 15 s, so a dropped command can't
    /// leave the button lying.
    private func setSpeed(_ i: Int) {
        guard let mode = SpeedMode(rawValue: i), let client = model.client else { return }
        speedOverride = i
        let id = model.printerId
        Task {
            do {
                try await client.setSpeed(id, mode: mode)
                try? await Task.sleep(for: .seconds(15))
                if speedOverride == i { speedOverride = nil }
            } catch {
                speedOverride = nil
                model.toast = "Speed failed — \((error as? BambuddyError)?.detail ?? error.localizedDescription)"
            }
        }
    }

    // MARK: - AMS strip

    private var amsStrip: some View {
        // 4 or fewer slots share the width; more than that scrolls, because a fixed row sized for 4
        // collapses to unreadable slivers at 5 (AMS 2 Pro + HT) and at 9.
        let scrolls = vm.ams.count > 4
        return VStack(spacing: 0) {
            HStack {
                Text("AMS").font(.mono(11)).tracking(1.2).foregroundStyle(c.t3)
                Spacer()
                Tap { model.tab = .ams } content: {
                    HStack(spacing: 3) {
                        Text("Details").font(.system(size: 13, weight: .semibold)).foregroundStyle(c.accent)
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(c.accent)
                    }
                }
            }
            .padding(.bottom, 11)

            if scrolls {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) { slotChips(minWidth: 74) }
                }
                .scrollIndicators(.hidden)
            } else {
                HStack(spacing: 10) { slotChips(minWidth: nil) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func slotChips(minWidth: CGFloat?) -> some View {
        ForEach(vm.ams) { slot in
            VStack(spacing: 8) {
                Swatch(value: slot.color, size: 32, radius: 9, empty: slot.empty)
                Text(slot.label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(c.t2)
                Text(slot.pct)
                    .font(.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(c.t1)
                // The invisible dot is a layout spacer, not dead code: without it inactive chips are
                // shorter than active ones and the row jitters.
                PulseDot(color: c.accent, size: 5, glow: slot.active, period: 2.0)
                    .opacity(slot.active ? 1 : 0)
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 8)
            .frame(maxWidth: minWidth == nil ? .infinity : nil)
            .frame(minWidth: minWidth)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(c.s1))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(slot.active ? c.accent : c.line, lineWidth: slot.active ? 1.5 : 1)
            )
        }
    }

    // MARK: - Other state blocks

    private var idleBlock: some View {
        VStack(spacing: 0) {
            TempGrid(vm: vm, heatingEnabled: true)
            controlsRow2
            amsStrip
        }
    }

    private var lanBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "lock.fill").font(.system(size: 14)).foregroundStyle(c.heating)
                Text(Lan.bannerTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.t1)
            }
            Text(Lan.bannerBody)
                .font(.system(size: 12))
                .foregroundStyle(c.t2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.heatingDim))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(c.heating))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var completeBlock: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(c.runningDim).frame(width: 64, height: 64)
                Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundStyle(c.running)
            }
            if vm.awaitingPlateClear {
                Tap {
                    model.perform("Plate cleared") { try await $0.clearPlate($1) }
                } content: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.square").font(.system(size: 15)).foregroundStyle(c.accentInk)
                        Text("Plate cleared — continue queue")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(c.accentInk)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(c.accent))
                }
            }
            Tap(action: lock.press(.printAgain) {
                guard let archive = model.status?.status?.currentArchiveId else { return }
                model.perform("Print again") { client, id in
                    try await client.reprint(archiveId: archive, printerId: id)
                }
            }) {
                HStack(spacing: 8) {
                    if lock.blocked(.printAgain) {
                        Image(systemName: "lock.fill").font(.system(size: 13))
                            .foregroundStyle(vm.awaitingPlateClear ? c.t1 : c.accentInk)
                    }
                    Text("Print again")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(vm.awaitingPlateClear ? c.t1 : c.accentInk)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(vm.awaitingPlateClear ? c.s3 : c.accent))
                .opacity(lock.style(.printAgain) ?? 1)
            }
            TempGrid(vm: vm, heatingEnabled: false)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    private var errorBlock: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(c.errorDim).frame(width: 64, height: 64)
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26)).foregroundStyle(c.error)
            }
            if let code = vm.hmsCode {
                Text(code).font(.mono(12, weight: .medium)).foregroundStyle(c.t2)
            }
            Tap { model.overlay = .alerts } content: {
                Text("See what's wrong")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(c.accentInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(c.accent))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    private var offlineBlock: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(c.s2).frame(width: 64, height: 64)
                Image(systemName: "wifi.slash").font(.system(size: 24)).foregroundStyle(c.idle)
            }
            Text("The printer isn't responding. It may be powered off, or off the network.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(c.t2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private var connectingBlock: some View {
        VStack(spacing: 14) {
            ProgressView().tint(c.accent)
            Text("Reaching the printer…")
                .font(.system(size: 13))
                .foregroundStyle(c.t2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }
}

/// Temperature cards, two per row. A trailing odd card stays half-width rather than stretching.
struct TempGrid: View {
    let vm: DashVM
    let heatingEnabled: Bool
    @Environment(\.palette) private var c

    private struct Card: Identifiable {
        let id = UUID()
        let label: String
        let now: Int
        let target: Int
        let heating: Bool
        var active: Bool = false
    }

    private var cards: [Card] {
        var out: [Card] = []
        if vm.nozzles.count > 1 {
            for (i, n) in vm.nozzles.enumerated() {
                out.append(Card(
                    label: i == 0 ? "Left nozzle" : "Right nozzle",
                    now: n.now, target: n.target,
                    heating: heatingEnabled && n.heating,
                    active: n.active
                ))
            }
        } else {
            out.append(Card(label: "Nozzle", now: vm.nozzleNow, target: vm.nozzleTarget, heating: heatingEnabled && vm.nozzleHeating))
        }
        out.append(Card(label: "Bed", now: vm.bedNow, target: vm.bedTarget, heating: heatingEnabled && vm.bedHeating))
        if vm.hasChamber {
            out.append(Card(label: "Chamber", now: vm.chamberNow, target: vm.chamberTarget, heating: heatingEnabled && vm.chamberHeating))
        }
        return out
    }

    var body: some View {
        let rows = stride(from: 0, to: cards.count, by: 2).map { Array(cards[$0..<min($0 + 2, cards.count)]) }
        VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack(spacing: 12) {
                    ForEach(row) { card in tempCard(card) }
                    if row.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
                .padding(.top, idx == 0 ? 2 : 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func tempCard(_ card: Card) -> some View {
        let barColor = card.heating ? c.heating : c.running
        // A 4 % floor so a cold or unset card still shows a sliver rather than an empty track.
        let pct = card.target > 0 ? max(4, min(100, Double(card.now) / Double(card.target) * 100)) : 4

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(card.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(c.t2)
                Spacer()
                if card.heating {
                    PulseDot(color: barColor, size: 7, period: 1.4)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(barColor).frame(width: 7, height: 7).opacity(0.9)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    RollingNumber(
                        value: card.now,
                        font: .system(size: 26, weight: .bold),
                        color: c.t1,
                        digitHeight: 31
                    )
                    Text("°").font(.system(size: 13, weight: .bold)).foregroundStyle(c.t3)
                }
                Text("→ \(card.target)°").font(.mono(12, weight: .medium)).foregroundStyle(c.t3)
            }
            .padding(.top, 9)

            HeatBar(pct: pct, heating: card.heating, color: barColor, track: c.s3, height: 3)
                .padding(.top, 11)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(card.active ? c.accent : c.line))
    }
}
