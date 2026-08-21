#if os(iOS)
// iOS layout. macOS: Views/Mac/Sections/MacPrinterSection.
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI

/// The Printer tab: header, hero state, camera tile, and one block per print state.
///
/// Section order is deliberate and matches the design: the LAN banner sits BELOW the live/idle
/// content but ABOVE complete/error/offline/connecting. It is not a fixed banner.
struct DashboardView: View {
    let model: AppModel
    var onSettings: () -> Void

    @Environment(\.palette) private var c
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var switcherOpen = false
    @State private var speedOpen = false
    @State private var maintenance: (due: Int, warn: Int) = (0, 0)
    @State private var speedOverride: Int?
    @State private var confirmStop = false
    @State private var explainingLock = false
    /// The tile streams rather than polling stills. The snapshot endpoint only produces fresh frames
    /// while the camera is actually streaming — cold, it replays the last cached frame forever, which
    /// is why a polled tile looked frozen. One low-rate stream is both live and cheaper than a
    /// 266 KB still every two seconds.
    @State private var tileCam = CameraStreamModel()

    private var vm: DashVM { model.vm }
    private var lock: LockedActions {
        LockedActions(mode: model.lanMode, explaining: $explainingLock)
    }

    private var showCamera: Bool {
        // Never in demo mode: the camera is a physical device on a real printer, and the tile's
        // on-demand warm-up would sit on "WAKING…" forever waiting for one. A stated absence beats
        // a control that looks like it is about to work and never does.
        !model.isDemo && [.live, .idle, .complete, .error].contains(vm.kind)
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
                if showCamera { cameraTile } else if model.isDemo { demoCameraNote }
                // Only after a print, and only when the model is willing to say something honest.
                // The card no longer carries its own margins — it is shared with macOS, whose
                // Printer section places it in a different layout and had to cancel these with
                // negative padding. These two are the iOS gutter and section gap it used to bake in.
                if let cool = model.cooldown?.vm, cool.phase != .none {
                    CooldownCard(vm: cool)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }

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
            // End-of-content breathing room only. The system tab bar insets the safe area for us,
            // so the old 120 pt of hand-reserved clearance would now stack on top of that inset.
            .padding(.bottom, 32)
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
                        PulseDot(color: vm.stateColor.resolve(c), size: 8, meaning: vm.stateLabel)
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
                    .glassEffect(.regular.interactive(), in: .circle)
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
                            PulseDot(color: entry.stateColor.resolve(c), size: 8, meaning: entry.stateLabel)
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
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
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
            // Selects the SEGMENT too. Switching to Hardware alone left whichever segment was last
            // open — usually Filament — so a tap on "2 maintenance tasks are due" landed on spools
            // and the user had to find the tasks themselves. The chip names a destination; it should
            // arrive there.
            Tap {
                model.hardware.segment = .service
                model.tab = .ams
            } content: {
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

    /// The thumbnail's frame rate, chosen from what the current network path actually costs — full
    /// rate on wifi, a trickle on cellular or Low Data. `CameraRate` carries the reasoning; the short
    /// version is that `?fps=` never reaches the printer (it is an ffmpeg *output* flag, so the
    /// printer streams at full rate either way and Bambuddy forwards fewer frames), which makes the
    /// only cost of a high rate the phone's own bandwidth — free at home, ~120 MB a minute on
    /// cellular.
    ///
    /// nil until the path resolves. This is the CANDIDATE rate for the next connection, and never the
    /// live one — see `latchedTileFps`, which is what actually reaches the URL.
    private var pathTileFps: Int? {
        let path = model.networkPath
        guard path.resolved else { return nil }
        return CameraRate.tile(isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    /// The rate the CURRENT connection is using, held fixed for as long as that connection lasts.
    ///
    /// The latch is the load-bearing part. This number goes into the stream URL, and
    /// `CameraPiPUIView.setURL` treats a new URL as a reason to restart the connection — so letting a
    /// path update rewrite it mid-stream drops the tile's socket, and because the tile is usually the
    /// camera's only viewer, that also tears the shared upstream down and pays the printer's cold
    /// start over again. Several seconds of "WAKING…" is far too much to pay for re-rating a
    /// thumbnail, so a changed path is picked up at the next natural connect instead: when the tab
    /// comes back, or the fullscreen overlay closes.
    @State private var latchedTileFps: Int?

    private var tileStreamURL: URL? {
        guard let client = model.client, let token = model.cameraToken, let fps = latchedTileFps else { return nil }
        return client.streamUrl(model.printerId, token: token, fps: fps)
    }

    /// Quotes the rate actually streaming rather than the one the path would choose now, so the badge
    /// can never advertise a number the video is not being delivered at — the same reason it reads the
    /// rate instead of keeping its own copy, back when the tile was a 2 s poll labelled "1 fps".
    private var tileBadge: String {
        guard camLoaded, let fps = latchedTileFps else { return "WAKING…" }
        return "LIVE · \(fps) fps"
    }

    /// Fills an EMPTY latch only. Never overwriting a live one is the entire point.
    private func latchTileFpsIfIdle() {
        guard tileStreamActive, latchedTileFps == nil else { return }
        latchedTileFps = pathTileFps
    }

    /// Exactly one consumer of the camera at a time. The fullscreen overlay runs its own stream, so
    /// the tile stands down while it is up rather than both holding a subscriber.
    private var tileStreamActive: Bool {
        model.tab == .printer && model.overlay == nil && showCamera
    }

    /// Derived, never mirrored into a second `@State`: a copy of "a frame has decoded" is a copy
    /// that can be left behind claiming LIVE over a tile that has gone blank.
    private var camLoaded: Bool { tileStreamActive && tileCam.isLive }

    /// What stands in for the camera in demo mode. Named for what it is rather than dressed up as
    /// a feed that is about to arrive.
    private var demoCameraNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "video.slash")
                .font(.system(size: 15))
                .foregroundStyle(c.t3)
            Text("The chamber camera streams from the printer, so it isn’t part of the demo.")
                .font(.system(size: 12))
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var cameraTile: some View {
        // NOT wrapped in `Tap`. SwiftUI may instantiate a `UIViewRepresentable` inside a Button's
        // label more than once, and each instance built its own renderer and opened its own MJPEG
        // connection — two `MJPEG connect` lines milliseconds apart, two viewers attached upstream.
        // The camera allows a limited number, so duplicates cost real frames. A plain tap gesture
        // makes the tile just as tappable without the label being re-evaluated. Losing the press
        // scale on a live video tile is no loss.
        Group {
            ZStack(alignment: .topLeading) {
                c.thumb
                if let url = tileStreamURL {
                    CameraPiPView(url: url, active: tileStreamActive, model: tileCam)
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
                    Text(tileBadge)
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
        .contentShape(.rect)
        .onTapGesture { model.overlay = .camera }
        // A cold camera takes seconds to produce a frame, and the badge must not claim LIVE over a
        // blank tile. Both of these restart the stream: switching machines from the fleet switcher
        // changes the URL (the printer id is in the path) without it ever becoming nil, and leaving
        // the tab or opening the fullscreen overlay stops it outright.
        //
        // Clearing the flag is the load-bearing half. The renderer only ever sets `isLive` TRUE, so
        // this reset is what lets the NEXT connection's first frame register as a change; without it
        // the badge would keep pulsing green over the blank tile of a camera that is still waking.
        // `initial: true` because the tile itself comes and goes with the print state: it is torn
        // down on `connecting`/`offline` and rebuilt with a fresh renderer, and a latch left over
        // from the previous appearance would claim LIVE before the new one has decoded anything.
        .onChange(of: tileStreamURL) { _, _ in tileCam.isLive = false }
        // Take the rate when streaming starts and release it when it stops, so a path update can
        // never rewrite the URL of a live connection. The second hook exists because NWPathMonitor's
        // first callback routinely lands AFTER the tile is already active, leaving the latch empty
        // with nothing else due to fill it.
        .onChange(of: tileStreamActive, initial: true) { _, active in
            tileCam.isLive = false
            if active { latchTileFpsIfIdle() } else { latchedTileFps = nil }
        }
        .onChange(of: pathTileFps, initial: true) { _, _ in latchTileFpsIfIdle() }
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
                        color: c.t1
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
                            color: c.t1
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
                        // Live data, not a loop: this updates on every WebSocket frame — roughly once
                        // a second for the whole print — so under Reduce Motion the rolling digits are
                        // continuous motion during the one activity the app exists for. The VALUE still
                        // updates; only the roll is dropped.
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : Motion.roll(0.6), value: vm.etaText)
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
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
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
                model.toast = .failure("Speed failed – \((error as? BambuddyError)?.detail ?? error.localizedDescription)")
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
                        Text("Plate cleared – continue queue")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(c.accentInk)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(c.accent))
                }
            }
            reprintButton
            TempGrid(vm: vm, heatingEnabled: false)
        }
        // The celebration the RN build shows on every finished print. An overlay so it costs no
        // layout, clipped to the block the way the RN version is clipped to its container, and
        // applied INSIDE the padding so it falls over the card rather than the screen margins.
        // Same five palette colours and the same count of 22.
        .overlay {
            Confetti(colors: [c.accent, c.running, c.heating, c.paused, c.t1], count: 22)
                .clipped()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    /// Re-queue the finished job.
    ///
    /// Gated on `vm.reprintArchiveId`, not on the print being complete: those are two questions, and
    /// a job Bambuddy never archived answers the second yes and the first no. It used to be gated on
    /// the first and `guard`ed on the second, so the button was a full-width accent-filled primary
    /// that swallowed the tap in silence. With no archive it keeps its place and says what it can
    /// actually do — the RN build's fallback, made visible.
    ///
    /// The LAN lock rides the reprint only. Without an archive this control sends the printer
    /// nothing at all, so dimming it and raising "controls are locked" would be the same class of
    /// lie pointing the other way.
    private var reprintButton: some View {
        let archive = vm.reprintArchiveId
        let secondary = vm.awaitingPlateClear
        let isLocked = archive != nil && lock.blocked(.printAgain)
        let ink = secondary ? c.t1 : c.accentInk
        return Tap {
            guard let archive else {
                model.tab = .library
                return
            }
            lock.press(.printAgain) {
                model.perform("Print again") { client, id in
                    try await client.reprint(archiveId: archive, printerId: id)
                }
            }()
        } content: {
            HStack(spacing: 8) {
                if isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(ink)
                }
                Text(archive == nil ? "Print something else" : "Print again")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(secondary ? c.s3 : c.accent))
            .opacity(isLocked ? Lan.lockedOpacity : 1)
        }
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

/// One temperature card, as pure data.
///
/// Temperature cards, two per row. A trailing odd card stays half-width rather than stretching.
///
/// The DATA is `TempCard` in `Domain/` — shared, and what `TempGridTests` pins. This is only the
/// iOS layout; macOS puts the same cards four across at its own metrics (§8).
struct TempGrid: View {
    let vm: DashVM
    let heatingEnabled: Bool
    @Environment(\.palette) private var c

    var body: some View {
        let cards = TempCard.present(vm, heatingEnabled: heatingEnabled)
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

    private func tempCard(_ card: TempCard) -> some View {
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
                        color: c.t1
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
#endif
