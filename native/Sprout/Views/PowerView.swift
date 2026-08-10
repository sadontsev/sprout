import SwiftUI

// MARK: - Live plug state

/// Live state for one smart plug: a poll loop plus optimistic toggles.
///
/// Shared by the printer's hero control (5 s — the thing you are watching) and each peripheral row
/// (8 s — background devices), so the settle/revert behaviour cannot drift between them.
@MainActor
@Observable
final class PlugPoller {
    private(set) var on = false
    private(set) var reachable = true
    private(set) var watts: Double?
    private(set) var kwh: Double?

    private let period: Duration
    private var client: BambuddyClient?
    private var plugId: Int?

    /// Poll results are DISCARDED until this instant. Bambuddy drives the plug through Home
    /// Assistant, which takes a few seconds to report the new state; without the window the poll
    /// that lands in between is stale and visibly bounces the switch back under the user's finger.
    private var settledUntil: Date = .distantPast
    private static let settleWindow: TimeInterval = 8

    init(period: Duration) {
        self.period = period
    }

    /// Poll until cancelled. Owned by `.task(id:)`, so binding a different plug restarts it and
    /// leaving the screen ends it.
    func run(client: BambuddyClient?, plugId: Int?) async {
        self.client = client
        self.plugId = plugId
        guard let client, let plugId else { return }
        while !Task.isCancelled {
            await poll(client, plugId)
            try? await Task.sleep(for: period)
        }
    }

    /// One poll out of band. Pull-to-refresh re-resolves the plug list, and the live numbers should
    /// refresh with it rather than waiting out the remaining interval.
    func refreshNow() async {
        guard let client, let plugId else { return }
        await poll(client, plugId)
    }

    /// Optimistic write: the switch flips now and holds through the settle window; a rejection
    /// reverts it and reopens polling immediately so the truth comes back without a delay.
    func set(_ next: Bool) async throws {
        guard let client, let plugId else { return }
        on = next
        settledUntil = Date().addingTimeInterval(Self.settleWindow)
        do {
            try await client.plugControl(plugId, on: next)
        } catch {
            settledUntil = .distantPast
            on = !next
            throw error
        }
    }

    private func poll(_ client: BambuddyClient, _ plugId: Int) async {
        do {
            let s = try await client.plugStatus(plugId)
            guard Date() >= settledUntil else { return }
            on = s.state?.uppercased() == "ON"
            reachable = s.reachable ?? false
            watts = finiteNumber(s.energy?.power)
            kwh = finiteNumber(s.energy?.today)
        } catch {
            // A failed status read is exactly what "unreachable" means here — the plug integration
            // is the thing that answers this endpoint.
            reachable = false
        }
    }
}

/// `LooseNumber` turns the literal string `"nan"` these energy fields sometimes carry into a real
/// `Double.nan`, which would render as "nan W". Anything non-finite is absent.
private func finiteNumber(_ n: LooseNumber?) -> Double? {
    guard let v = n?.double, v.isFinite else { return nil }
    return v
}

// MARK: - Screen

/// The printer's own plug is a three-way answer, and the empty state hangs on telling the cases
/// apart: still-loading must never render "No smart plug linked".
private enum PlugSlot: Equatable {
    case loading
    /// No plug bound to this printer. `getPlug` swallows its transport error, so a server that is
    /// simply unreachable also lands here.
    case unlinked
    case linked(SmartPlug)

    var value: SmartPlug? {
        if case .linked(let p) = self { return p }
        return nil
    }
}

/// The Power tab: the printer's smart plug as a hero on/off control with live draw and today's
/// energy, this print's projected cost while one is running, the automations Bambuddy runs on the
/// plug, and every other socket on the strip as a row.
///
/// The automations card is deliberately read-only: writes to `/smart-plugs/{id}` are admin-only and
/// 403 with a scoped API key, so the honest thing the app can do is report them accurately.
struct PowerView: View {
    let model: AppModel
    @Environment(\.palette) private var c

    @State private var plug: PlugSlot = .loading
    @State private var allPlugs: [SmartPlug] = []
    @State private var settings: AppSettings?
    @State private var hero = PlugPoller(period: .seconds(5))
    @State private var confirmOff = false

    private var status: PrinterStatus? { model.status?.status }

    /// Every socket, the printer's own included — passing nil keeps it. All of these are sockets on
    /// one physical strip, and hiding the printer's made the strip look like it was missing one even
    /// though that socket drives the big control above the list.
    private var sockets: [SmartPlug] { Power.otherPlugs(allPlugs, printerPlugId: nil) }
    private var automations: [PlugAutomation] { Power.plugAutomations(plug.value) }

    private var price: Double? { finiteNumber(settings?.energyCostPerKwh) }
    private var symbol: String { currencySymbol(settings?.currency) }
    private var todayCost: Double? {
        guard let price, let kwh = hero.kwh else { return nil }
        return kwh * price
    }

    private var running: Bool { (status?.state ?? "").uppercased() == "RUNNING" }
    private var remainMin: Double? { finiteNumber(status?.remainingTime) }

    /// This print's energy cost so far and at completion, extrapolated from the live draw.
    private var projection: (soFar: Double?, projected: Double?) {
        guard running,
              let price,
              let watts = hero.watts,
              let remain = remainMin,
              let pct = finiteNumber(status?.progress), pct > 0, pct < 100
        else { return (nil, nil) }
        // total = elapsed + remain and pct = elapsed / total, so elapsed = remain · pct / (100 − pct).
        let elapsed = (remain * pct) / (100 - pct)
        let kwhPerMin = watts / 1000 / 60
        return (elapsed * kwhPerMin * price, (elapsed + remain) * kwhPerMin * price)
    }

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
        .task(id: model.printerId) { await reload() }
        .task(id: plug.value?.id) {
            await hero.run(client: model.client, plugId: plug.value?.id)
        }
        .refreshable { await reload() }
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
                    if (hero.watts ?? 0) > 5 {
                        Circle()
                            .fill(c.accent)
                            .frame(width: 5, height: 5)
                            .overlay { PowerSpark(color: c.accent, count: 6, size: 3, spread: 14) }
                    }
                }
                bigValue(hero.watts.map { RollingNumber(
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
                bigValue(hero.kwh.map { kwh in
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
        return "\(fmtMoney(symbol, todayCost)) today"
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
            Text(amount.map { fmtMoney(symbol, $0) } ?? "—")
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
        let draw = hero.watts.map { String(Int($0.rounded())) } ?? "—"
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

        ForEach(sockets) { p in
            PlugRow(model: model, plug: p, isPrinter: p.id == plug.value?.id)
        }
    }

    private var tariffFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(c.t3)
            Text(
                price.map { "Tariff \(fmtMoney(symbol, $0))/kWh · set in Bambuddy → Settings → Energy" }
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

    private func toggleHero() {
        guard plug.value != nil else { return }
        if hero.on {
            // Switching OFF cuts power to the printer — confirm, so an accidental tap can't kill a
            // print. Turning on is harmless and applies immediately.
            confirmOff = true
        } else {
            apply(true)
        }
    }

    private func apply(_ next: Bool) {
        Task {
            do { try await hero.set(next) } catch { model.toast = plugFailureMessage(error) }
        }
    }

    private func reload() async {
        guard let client = model.client else { return }
        async let fetchedPlug = client.getPlug(model.printerId)
        async let fetchedAll = client.listPlugs()
        async let fetchedSettings = settingsOrNil(client)
        let (p, all, s) = await (fetchedPlug, fetchedAll, fetchedSettings)
        plug = p.map(PlugSlot.linked) ?? .unlinked
        allPlugs = all
        settings = s
        // Refreshing the plug list without refreshing the numbers it describes would leave stale
        // watts on screen for the rest of the poll interval.
        await hero.refreshNow()
    }
}

// MARK: - One socket

/// One peripheral socket on the strip. Polls slower than the printer's own plug — these are
/// background devices, not the thing you are watching.
struct PlugRow: View {
    let model: AppModel
    let plug: SmartPlug
    var isPrinter: Bool = false

    @Environment(\.palette) private var c
    @State private var poller = PlugPoller(period: .seconds(8))
    @State private var confirmOff = false

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
        .task(id: plug.id) { await poller.run(client: model.client, plugId: plug.id) }
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

    private func request(_ next: Bool) {
        // Cutting power to a peripheral is disruptive too — an AMS mid-print, a running dryer.
        if next { apply(true) } else { confirmOff = true }
    }

    private func apply(_ next: Bool) {
        Task {
            do { try await poller.set(next) } catch { model.toast = plugFailureMessage(error) }
        }
    }
}

// MARK: - Formatting

/// The settings read is the only one of the three fetches that throws, and a failure here just
/// means "price unknown", so it is flattened before the concurrent load.
private func settingsOrNil(_ client: BambuddyClient) async -> AppSettings? {
    try? await client.getSettings()
}

/// Surfaces Bambuddy's own `detail` (e.g. "Plug is disabled") instead of transport noise.
private func plugFailureMessage(_ error: Error) -> String {
    if let e = error as? BambuddyError { return "Plug command failed — \(e.detail)" }
    return "Plug command failed — \(error.localizedDescription)"
}

private func currencySymbol(_ code: String?) -> String {
    switch (code ?? "").uppercased() {
    case "GBP": return "£"
    case "USD", "AUD", "CAD", "NZD": return "$"
    case "EUR": return "€"
    case "JPY", "CNY": return "¥"
    default:
        // An unknown ISO code is still information; showing "SEK 12.34" beats guessing a glyph.
        let raw = code ?? ""
        return raw.isEmpty ? "$" : "\(raw) "
    }
}

/// Always two decimals, so a column of costs lines up under tabular figures.
private func fmtMoney(_ symbol: String, _ amount: Double) -> String {
    "\(symbol)\(String(format: "%.2f", amount))"
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
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(color)
                .opacity(active && up ? maxOpacity : 0)
                .scaleEffect(active && up ? 1 + grow : 1)
                .animation(
                    active ? Motion.inOutQuad(1.2).repeatForever(autoreverses: true) : Motion.inOutQuad(0.3),
                    value: up
                )
                .animation(Motion.inOutQuad(0.3), value: active)
                .allowsHitTesting(false)
            content()
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
