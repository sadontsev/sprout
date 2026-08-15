#if os(iOS)
// iOS layout. macOS: Views/Mac/Sections/MacPowerSection.
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI

// MARK: - Screen

/// The Power tab: the printer's smart plug as a hero on/off control with live draw and today's
/// energy, this print's projected cost while one is running, the automations Bambuddy runs on the
/// plug, and every other socket on the strip as a row.
///
/// Every fetch, poll loop and money figure lives in `PowerStore` (Domain/), which the Mac Power
/// section drives too — this view is layout and confirmation plumbing only.
///
/// The automations card is deliberately read-only: writes to `/smart-plugs/{id}` are admin-only and
/// 403 with a scoped API key, so the honest thing the app can do is report them accurately.
struct PowerView: View {
    let model: AppModel
    @Environment(\.palette) private var c

    /// Read off `AppModel` rather than passed in or put in the environment: `Shell` already hands
    /// this view the model, so this is the whole of the wiring.
    private var power: PowerStore { model.power }

    @State private var confirmOff = false

    private var status: PrinterStatus? { model.status?.status }

    // Thin reads of the store, so the layout below says what it means. Nothing is derived twice.
    private var plug: PlugSlot { power.plug }
    private var hero: PlugPoller { power.hero }
    private var sockets: [PlugSocket] { power.sockets }
    private var automations: [PlugAutomation] { power.automations }

    private var price: Double? { power.price }
    private func money(_ amount: Double) -> String { power.money(amount) }
    private var todayCost: Double? { power.todayCost }

    private var running: Bool { PowerStore.isRunning(status) }
    private var remainMin: Double? { PowerStore.remainingMinutes(status) }
    private var projection: (soFar: Double?, projected: Double?) { power.projection(status) }

    var body: some View {
        PowerPage(title: "Power") {
            if plug == .unlinked && sockets.isEmpty {
                PowerEmpty(
                    icon: "power",
                    title: "No smart plug linked",
                    message: "Link the printer's plug in Bambuddy (Settings → Smart Plugs) to control power here."
                )
            } else {
                if plug != .unlinked {
                    printerBlock
                }
                if sockets.count > 1 {
                    socketList
                }
                tariffFooter
            }
        }
        // Keyed on the printer: switching machines has to re-resolve which plug is "the printer's".
        // `AppModel` has already re-attached the store by the time this re-runs.
        .task(id: model.printerId) { await power.reload() }
        // The store owns the poll loops — one per socket, and the SET of them changes with the plug
        // list, which a single `.task` cannot express. So the tab's appearance gates them instead,
        // riding the same events `.task` cancellation used to: leaving the Power tab still genuinely
        // stops the traffic, and nothing is polled before the first visit because a store that has
        // not loaded a plug list has nothing bound to poll.
        .onAppear { power.start() }
        .onDisappear { power.stop() }
        .refreshable { await power.reload() }
        .alert("Switch off the printer?", isPresented: $confirmOff) {
            Button("Cancel", role: .cancel) {}
            Button("Switch off", role: .destructive) { apply(false) }
        } message: {
            Text("This cuts power at the smart plug. If a print is running, it will stop.")
        }
    }

    // MARK: Printer block

    @ViewBuilder
    private var printerBlock: some View {
        Text(plug.value?.name ?? "Printer smart plug")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(c.t3)
            .padding(.horizontal, 20)
            .padding(.top, 7)

        heroCard
        statCards
        if running { thisPrintCard }
        automationCard
    }

    private var heroCard: some View {
        VStack(spacing: 0) {
            PowerBreathe(
                active: hero.on && hero.reachable,
                color: c.accent,
                grow: 0.18,
                maxOpacity: 0.5,
                cornerRadius: 65
            ) {
                // Deliberately NOT LAN-gated: the plug is a different device entirely, and it is the
                // real kill switch precisely when the printer refuses commands.
                Tap(disabled: !hero.reachable || plug == .loading) {
                    toggleHero()
                } content: {
                    ZStack {
                        Circle().fill(hero.on ? c.accent : c.s3)
                        Image(systemName: "power")
                            .font(.system(size: 48, weight: .regular))
                            .foregroundStyle(hero.on ? c.accentInk : c.t2)
                    }
                    .frame(width: 130, height: 130)
                    .opacity(hero.reachable ? 1 : 0.4)
                    .contentShape(Circle())
                }
            }

            Text(hero.on ? "Powered on" : "Powered off")
                .font(.system(size: 19, weight: .bold))
                .kerning(-0.3)
                .foregroundStyle(c.t1)
                .padding(.top, 20)

            HStack(spacing: 7) {
                if hero.reachable {
                    PulseDot(color: c.running, size: 7, period: 2)
                } else {
                    Circle().fill(c.idle).frame(width: 7, height: 7)
                }
                Text(hero.reachable ? "Plug reachable" : "Plug unreachable")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c.t3)
            }
            .padding(.top, 8)

            Text("Tap to toggle the printer's smart plug")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(c.t3)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .powerCard(c, radius: 22)
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private var statCards: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("DRAWING NOW")
                        .font(.mono(10))
                        .kerning(1)
                        .foregroundStyle(c.t3)
                    Spacer(minLength: 4)
                    // Below a few watts the plug is reporting its own standby draw, not the printer.
                    // `liveWatts`: a spark animating "it is drawing" off a frozen reading claims
                    // activity from a plug nothing is measuring.
                    if (hero.liveWatts ?? 0) > 5 {
                        Circle()
                            .fill(c.accent)
                            .frame(width: 5, height: 5)
                            .overlay { PowerSpark(color: c.accent, count: 6, size: 3, spread: 14) }
                    }
                }
                // `liveWatts`, not `watts`: the raw value is deliberately sticky so a momentary
                // blip does not blank the card, which makes it the wrong thing to render under the
                // word "NOW". See `PlugPoller.readingIsCurrent`.
                bigValue(hero.liveWatts.map { RollingNumber(
                    value: Int($0.rounded()),
                    font: .system(size: 28, weight: .bold),
                    color: c.t1
                ) }, unit: "W")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .powerCard(c)

            VStack(alignment: .leading, spacing: 0) {
                Text("TODAY")
                    .font(.mono(10))
                    .kerning(1)
                    .foregroundStyle(c.t3)
                // RollingNumber rolls whole digits only; kWh keeps two decimals, so this one is
                // plain tabular text rather than a roll.
                bigValue(hero.liveKwh.map { kwh in
                    Text(String(format: "%.2f", kwh))
                        .font(.system(size: 28, weight: .bold))
                        .monospacedDigit()
                        .kerning(-1)
                        .foregroundStyle(c.t1)
                }, unit: "kWh")
                Text(todayCostLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(c.accent)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .powerCard(c)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var todayCostLabel: String {
        guard let todayCost else { return price == nil ? "price not set" : "—" }
        return "\(money(todayCost)) today"
    }

    /// A 28 pt figure with its unit on the same baseline, or an em dash when there is no reading.
    private func bigValue<V: View>(_ value: V?, unit: String) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            if let value {
                value
            } else {
                Text("—")
                    .font(.system(size: 28, weight: .bold))
                    .kerning(-1)
                    .foregroundStyle(c.t1)
            }
            Text(unit)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.t3)
                .padding(.bottom, 5)
        }
        .padding(.top, 9)
    }

    private var thisPrintCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                PulseDot(color: c.running, size: 7, period: 2)
                Text("THIS PRINT")
                    .font(.mono(10))
                    .kerning(1)
                    .foregroundStyle(c.running)
            }
            Text(printTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.t1)
                .lineLimit(1)
                .padding(.top, 8)

            HStack(alignment: .top, spacing: 24) {
                projectionColumn("SO FAR", projection.soFar, color: c.t1)
                projectionColumn("PROJECTED", projection.projected, color: c.accent)
            }
            .padding(.top, 12)

            Text(projectionFootnote)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(c.t3)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .powerCard(c, border: c.running, width: 1.5)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func projectionColumn(_ label: String, _ amount: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.mono(10))
                .kerning(0.5)
                .foregroundStyle(c.t3)
            Text(amount.map { money($0) } ?? "—")
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .kerning(-0.5)
                .foregroundStyle(color)
                .padding(.top, 4)
        }
    }

    private var printTitle: String {
        let name = status?.subtaskName ?? ""
        return name.isEmpty ? "Current print" : name
    }

    private var projectionFootnote: String {
        guard price != nil else { return "Set an electricity price in Bambuddy to see cost." }
        // The sentence says "live draw", so the number has to be one.
        let draw = hero.liveWatts.map { String(Int($0.rounded())) } ?? "—"
        let left = remainMin.map { String(Int($0)) } ?? "—"
        return "Estimate from \(draw) W live draw · \(left) min left"
    }

    private var automationCard: some View {
        let cuts = automations.contains { $0.cuts }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: cuts ? "clock" : "shield")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(cuts ? c.heating : c.t3)
                Text("AUTOMATIC SWITCHING")
                    .font(.mono(10))
                    .kerning(1)
                    .foregroundStyle(c.t3)
            }

            if automations.isEmpty {
                Text("Nothing switches this plug automatically — power stays as you leave it.")
                    .font(.system(size: 12, weight: .medium))
                    // RN `lineHeight: 17` on 12 pt text: SwiftUI's natural leading is ~14, so the
                    // extra 3 pt goes on as line spacing. Same conversion everywhere on this screen.
                    .lineSpacing(3)
                    .foregroundStyle(c.t3)
                    .padding(.top, 9)
            } else {
                ForEach(automations) { a in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(a.cuts ? c.heating : c.t3)
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(c.t1)
                            Text(a.detail)
                                .font(.system(size: 12, weight: .medium))
                                .lineSpacing(3)
                                .foregroundStyle(c.t3)
                                .padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 10)
                }
            }

            Text("Change these in Bambuddy → Settings → Smart Plugs.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(c.t3)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .powerCard(c)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: Sockets + tariff

    @ViewBuilder
    private var socketList: some View {
        Text("ALL SOCKETS")
            .font(.mono(10))
            .kerning(1)
            .foregroundStyle(c.t3)
            .padding(.horizontal, 20)
            .padding(.top, 22)

        ForEach(sockets) { socket in
            PlugRow(model: model, socket: socket, isPrinter: socket.id == plug.value?.id)
        }
    }

    private var tariffFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(c.t3)
            Text(
                price.map { "Tariff \(money($0))/kWh · set in Bambuddy → Settings → Energy" }
                    ?? "Electricity price not set. Add it in Bambuddy → Settings → Energy."
            )
            .font(.system(size: 12, weight: .medium))
            .lineSpacing(3)
            .foregroundStyle(c.t3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .powerCard(c, radius: 14)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: Actions

    /// The decision lives in `PowerStore.heroIntent`; this only chooses which surface asks.
    private func toggleHero() {
        switch power.heroIntent {
        case .ignore: break
        case .apply(let next): apply(next)
        case .confirmOff: confirmOff = true
        }
    }

    private func apply(_ next: Bool) {
        Task {
            do { try await hero.set(next) } catch { model.toast = .failure(PowerStore.failureMessage(error)) }
        }
    }
}

// MARK: - One socket

/// One peripheral socket on the strip.
///
/// The poller arrives WITH the plug (`PlugSocket`) rather than being `@State` here: the store owns
/// the loop, on its slower cadence, so this row cannot be rendered without the numbers that belong
/// to it and the Mac socket list drives the same one.
struct PlugRow: View {
    let model: AppModel
    let socket: PlugSocket
    var isPrinter: Bool = false

    @Environment(\.palette) private var c
    @State private var confirmOff = false

    private var plug: SmartPlug { socket.plug }
    private var poller: PlugPoller { socket.poller }
    private var name: String { Power.plugLabel(plug) }
    private var armed: [PlugAutomation] { Power.plugAutomations(plug) }

    private var statusLine: String {
        guard poller.reachable else { return "Unreachable" }
        guard poller.on else { return "Off" }
        guard let w = poller.watts else { return "On" }
        return "On · \(Int(w.rounded())) W"
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .lineLimit(1)
                    if isPrinter {
                        Text("PRINTER")
                            .font(.mono(8.5))
                            .kerning(0.5)
                            .foregroundStyle(c.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.accentDim))
                    }
                }

                HStack(spacing: 7) {
                    if poller.reachable {
                        PulseDot(color: poller.on ? c.running : c.idle, size: 6, period: 2.4)
                    } else {
                        Circle().fill(c.idle).frame(width: 6, height: 6)
                    }
                    Text(statusLine)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(c.t3)
                }
                .padding(.top, 5)

                if !armed.isEmpty {
                    Text(armed.map(\.label).joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(c.heating)
                        .lineLimit(1)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PillToggle(
                // The binding never writes through: `poller.on` stays the source of truth so the
                // knob cannot slide before the confirmation is answered.
                value: Binding(get: { poller.on }, set: { request($0) }),
                disabled: !poller.reachable,
                onColor: c.accent,
                offColor: c.s3,
                knob: .white
            )
        }
        .padding(16)
        .powerCard(c)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .alert(offConfirmTitle, isPresented: $confirmOff) {
            Button("Cancel", role: .cancel) {}
            Button("Switch off", role: .destructive) { apply(false) }
        } message: {
            Text("This cuts power at the smart plug.")
        }
    }

    /// A `String` (not a literal) so the alert resolves to the plain-text overload rather than
    /// treating the interpolated sentence as a localization key.
    private var offConfirmTitle: String { "Switch off \(name)?" }

    /// Cutting power to a peripheral is disruptive too — an AMS mid-print, a running dryer — so this
    /// asks the same question the hero control does. `PowerStore.socketIntent` is where that rule
    /// lives; here it only picks the surface.
    private func request(_ next: Bool) {
        switch PowerStore.socketIntent(next) {
        case .ignore: break
        case .apply(let v): apply(v)
        case .confirmOff: confirmOff = true
        }
    }

    private func apply(_ next: Bool) {
        Task {
            do { try await poller.set(next) } catch { model.toast = .failure(PowerStore.failureMessage(error)) }
        }
    }
}

// MARK: - Screen chrome

// Kept file-private: each ported screen carries its own copy of the scaffolding until a shared
// chrome component exists, so two screens can never fight over one name.

/// The tab's scroll container and its big inline title.
private struct PowerPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.palette) private var c

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .kerning(-0.8)
                    .foregroundStyle(c.t1)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The tab bar is a layout sibling here, not a floating overlay, so the scroll content
            // needs breathing room at the end rather than the RN build's 120 pt of clearance.
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(c.bg)
    }
}

/// A real "nothing here" state — an icon well, a headline and one sentence that says what to do.
private struct PowerEmpty: View {
    let icon: String
    let title: String
    let message: String
    @Environment(\.palette) private var c

    var body: some View {
        VStack(spacing: 15) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(c.s2)
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(c.t3)
                }
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .kerning(-0.3)
                    .foregroundStyle(c.t1)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .lineSpacing(4)
                    .foregroundStyle(c.t3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 250)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 48)
    }
}

/// A pulsing halo behind a live control.
///
/// A real sibling shape rather than an iOS shadow: a shadow cast by a transparent wrapper does not
/// render at all, which is how the glow went missing the first time.
private struct PowerBreathe<Content: View>: View {
    let active: Bool
    let color: Color
    var grow: CGFloat = 0.22
    var maxOpacity: Double = 0.45
    var cornerRadius: CGFloat = 999
    @ViewBuilder var content: () -> Content

    @State private var up = false

    var body: some View {
        // The halo is a BACKGROUND, not a ZStack sibling: a bare shape has no intrinsic size, so as
        // a sibling it stretched to the card's full width and `scaleEffect` then pushed it past both
        // screen edges. As a background it inherits the button's size and grows from there, which is
        // what a glow around a control means.
        content()
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(color)
                    .opacity(active && up ? maxOpacity : 0)
                    .scaleEffect(active && up ? 1 + grow : 1)
                    .blur(radius: 12)
                    .animation(
                        active ? Motion.inOutQuad(1.2).repeatForever(autoreverses: true) : Motion.inOutQuad(0.3),
                        value: up
                    )
                    .animation(Motion.inOutQuad(0.3), value: active)
                    .allowsHitTesting(false)
            }
            .onChange(of: active, initial: true) { _, isActive in
                up = isActive
            }
    }
}

/// A small cluster of particles drifting outward on a loop — the "current is flowing" tell next to
/// the live wattage. Purely decorative, so it never takes a touch.
private struct PowerSpark: View {
    let color: Color
    var count: Int = 6
    var size: CGFloat = 4
    var spread: CGFloat = 20

    @State private var fired = false

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let angle = Double(i) / Double(count) * 2 * .pi
                let dx = CGFloat(cos(angle)) * spread
                // Biased upward: heat rises, and the dot sits on a baseline of text.
                let dy = CGFloat(sin(angle)) * spread - 8
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .offset(x: fired ? dx : 0, y: fired ? dy : 0)
                    .scaleEffect(fired ? 0.2 : 1)
                    .opacity(fired ? 0 : 1)
                    .animation(
                        // ease-out-cubic, staggered so the cluster emits continuously.
                        .timingCurve(0.215, 0.61, 0.355, 1, duration: 1.3)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) / Double(count) * 1.2),
                        value: fired
                    )
            }
        }
        .allowsHitTesting(false)
        .onAppear { fired = true }
    }
}

private extension View {
    /// The screen's one card treatment: `s1` fill with a hairline inside the corner radius.
    func powerCard(_ c: Palette, radius: CGFloat = 18, border: Color? = nil, width: CGFloat = 1) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(c.s1))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border ?? c.line, lineWidth: width)
            )
    }
}
#endif
