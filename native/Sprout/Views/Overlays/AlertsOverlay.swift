import SwiftUI

/// The full alert list, opened from the dashboard's single summary row.
///
/// Deliberately NOT on the dashboard: with three HMS notices plus a plate prompt, inline cards pushed
/// the actual print state off the screen. The dashboard keeps one summary row; everything explanatory
/// — and every action — lives here.
///
/// The alerts themselves come from `Alerts.present`, which only ever offers an action the printer can
/// currently take, so an empty action row is a deliberate answer and not a missing feature.
struct AlertsOverlay: View {
    let model: AppModel

    @Environment(\.palette) private var c
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Bambu's own HMS / print-error prose. Starts empty and fills in asynchronously — alerts render
    /// their code with generic copy in the meantime, never a spinner and never a blocked list.
    @State private var catalog: HmsCatalog = .empty
    @State private var confirming: PendingConfirm?
    @State private var lanAlert = false
    /// The alert whose "What is this?" is currently walking its candidate wiki pages. Up to four HEAD
    /// requests can pass before a page resolves, which is long enough that a silent tap reads as dead.
    @State private var probing: String?

    private var status: PrinterStatus? { model.status?.status }

    private var alerts: [AlertVM] {
        Alerts.present(
            status,
            // Bambuddy's scoped key covers print control, so the only thing that can take the actions
            // away is an unreachable printer.
            caps: AlertCaps(connected: status?.connected == true, canControl: true, model: model.printer?.model),
            describe: AlertDescribe(catalog: catalog)
        )
    }

    private var locked: LockedActions { LockedActions(mode: model.lanMode, explaining: $lanAlert) }

    /// Re-runs the wiki scrape only when the set of codes on screen changes, or when the catalogue
    /// actually grew. Both halves matter: without the code list a new alert is never described, and
    /// without the catalogue counts a failed scrape would retry forever.
    private var learnKey: String {
        let codes = alerts.compactMap(\.code).joined(separator: ",")
        return "\(codes)|\(catalog.hms.count)|\(catalog.learned.count)"
    }

    var body: some View {
        ZStack {
            c.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                list
            }
        }
        .task { catalog = await HmsCatalogStore.shared.load() }
        .task(id: learnKey) { await learnUnknownCodes() }
        .lockedActionAlert($lanAlert)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Attention")
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(c.t1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Tap {
                dismiss()
            } content: {
                // SF Symbols render heavier than Feather at the same point size, so 17 pt here is the
                // visual match for the design's 20 pt Feather `x`.
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(c.t2)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(c.s2))
                    .contentShape(.circle)
            }
            .accessibilityLabel("Close")
        }
        .padding(.top, 12)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if status?.connected == false {
                    offlineNote
                }

                if status == nil {
                    // No status has landed yet — the alert set is genuinely unknown, so claiming
                    // "nothing needs attention" would be a lie for the first second of every launch.
                    ForEach(0..<2, id: \.self) { _ in
                        Shimmer(base: c.s2, cornerRadius: 18)
                            .frame(height: 96)
                    }
                } else if alerts.isEmpty {
                    emptyState
                } else {
                    ForEach(alerts) { alert in
                        FadeRise {
                            AlertCard(
                                alert: alert,
                                locked: locked,
                                probing: probing == alert.id,
                                onAction: { act in request(alert, act) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .alert(
            confirming.map { "\($0.action.label)?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { pending in
            Button("Cancel", role: .cancel) {}
            Button(pending.action.label, role: .destructive) { perform(pending.alert, pending.action) }
        } message: { pending in
            Text("\(pending.alert.title) — this can’t be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(c.running)
            Text("Nothing needs attention")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(c.t2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// Why the cards below have no buttons. `Alerts.present` strips every control action when the
    /// printer is unreachable, and a row of explanations with nothing to press is otherwise baffling.
    private var offlineNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(c.t3)
            Text("The printer is offline. Actions come back the moment it reconnects.")
                .font(.system(size: 12.5, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(c.t2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(c.line, lineWidth: 1))
    }

    // MARK: - Actions

    /// A tap that has already passed the LAN gate: confirm first if it can't be undone.
    private func request(_ alert: AlertVM, _ act: AlertActionVM) {
        guard act.destructive else {
            perform(alert, act)
            return
        }
        confirming = PendingConfirm(alert: alert, action: act)
    }

    private func perform(_ alert: AlertVM, _ act: AlertActionVM) {
        switch act.id {
        case .resume:
            model.perform("Resume") { client, id in try await client.resume(id) }
        case .stop:
            model.perform("Stop") { client, id in try await client.stop(id) }
        case .clearHms:
            model.perform("Clear notices") { client, id in try await client.clearHms(id) }
        case .plateCleared:
            // Bambuddy-side bookkeeping only — no MQTT, so it works with Developer Mode off. Success
            // is silent on purpose: the server clears `awaiting_plate_clear` and the next status frame
            // takes this very card off the screen, which is a better confirmation than a dialog.
            model.perform("Confirm the plate") { client, id in try await client.clearPlate(id) }
        case .lookup:
            lookUp(alert, act)
        }
    }

    /// Opens Bambu's page for a code — the first candidate that actually resolves.
    ///
    /// The wiki is per model FAMILY and each family has its own code namespace, so the right page
    /// can't be known from the code alone. `Alerts.hmsURLs` orders the candidates with this machine's
    /// family first and the searchable index last; the index always resolves. Without the probe a tap
    /// landed on a 404 — the reported "fatal is not found".
    private func lookUp(_ alert: AlertVM, _ act: AlertActionVM) {
        guard let urls = act.urls, !urls.isEmpty else { return }
        probing = alert.id
        Task {
            let target = await firstResolvingURL(urls)
            probing = nil
            if let target { openURL(target) }
        }
    }

    /// Reads the wiki page for every code the catalogue still can't describe, once, and remembers it.
    ///
    /// Every H2-family code is missing from Bambu's public feed — including the one that turned out to
    /// say "Nozzle camera lens is dirty…", precisely the sentence worth surfacing.
    private func learnUnknownCodes() async {
        let targets = Alerts.unknownCodes(in: alerts, catalog: catalog)
        guard !targets.isEmpty else { return }
        catalog = await HmsCatalogStore.shared.learn(targets)
    }
}

// MARK: - Confirmation

/// A destructive action waiting on the user's yes. Carries the alert too, because the dialog quotes
/// its title ("Print paused — this can't be undone").
private struct PendingConfirm: Identifiable {
    let alert: AlertVM
    let action: AlertActionVM

    var id: String { "\(alert.id)-\(action.id.rawValue)" }
}

// MARK: - Probe

/// The first of `urls` that answers 2xx to a HEAD, or the last entry as the guaranteed fallback.
///
/// A thrown request (offline, DNS blocked, captive portal) stops the walk immediately rather than
/// burning one timeout per family — the index page is the right answer in that state anyway.
private func firstResolvingURL(_ urls: [String]) async -> URL? {
    for candidate in urls.dropLast() {
        guard let url = URL(string: candidate) else { continue }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) { return url }
        } catch {
            break
        }
    }
    return urls.last.flatMap { URL(string: $0) }
}

// MARK: - Card

/// One alert: severity glyph, title, Bambu's own description, the code, and the actions that are
/// possible right now.
private struct AlertCard: View {
    let alert: AlertVM
    let locked: LockedActions
    let probing: Bool
    let onAction: (AlertActionVM) -> Void

    @Environment(\.palette) private var c

    private var tone: Color {
        switch alert.level {
        case .error: c.error
        case .warning: c.heating
        case .info: c.accent
        }
    }

    private var dim: Color {
        switch alert.level {
        case .error: c.errorDim
        case .warning: c.heatingDim
        case .info: c.accentDim
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: alert.level == .info ? "info.circle" : "exclamationmark.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(tone)

                VStack(alignment: .leading, spacing: 0) {
                    Text(alert.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(c.t1)

                    Text(alert.detail)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineSpacing(3)
                        .foregroundStyle(c.t2)
                        .padding(.top, 4)

                    if let code = alert.code {
                        Text("HMS \(code)")
                            .font(.mono(11, weight: .semibold))
                            .foregroundStyle(c.t3)
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !alert.actions.isEmpty {
                ActionFlow(spacing: 8) {
                    ForEach(alert.actions) { act in
                        AlertActionButton(
                            action: act,
                            tone: tone,
                            locked: locked,
                            busy: probing && act.id == .lookup,
                            run: { onAction(act) }
                        )
                    }
                }
                .padding(.top, 14)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(dim))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(tone, lineWidth: 1))
        .shadow1()
    }
}

// MARK: - Action button

/// One action pill.
///
/// Styling precedence is `destructive` → `lookup` → default, which is why a default-filled action on
/// a warning card is amber-filled with `accentInk` text. That reads oddly next to the amber border and
/// is intentional: the filled pill is the card's primary action whatever the card's tone.
private struct AlertActionButton: View {
    let action: AlertActionVM
    let tone: Color
    let locked: LockedActions
    let busy: Bool
    let run: () -> Void

    @Environment(\.palette) private var c

    /// The LAN-gate identity of this action, or nil for the ones the printer is never asked about
    /// (`clearHms` is Bambuddy bookkeeping; `lookup` is a web page).
    private var gate: ActionId? {
        switch action.id {
        case .resume: .resume
        case .stop: .stop
        case .plateCleared: .plateCleared
        case .clearHms, .lookup: nil
        }
    }

    private var isLocked: Bool { gate.map(locked.blocked) ?? false }

    private var fillColor: Color {
        if action.destructive { return c.s3 }
        return action.id == .lookup ? c.s2 : tone
    }

    private var inkColor: Color {
        if action.destructive { return c.error }
        return action.id == .lookup ? c.t1 : c.accentInk
    }

    var body: some View {
        Tap {
            // The gate runs before the confirmation: a locked control must explain itself, not open a
            // dialog for a command the firmware will refuse.
            guard let gate else {
                run()
                return
            }
            locked.press(gate, run)()
        } content: {
            HStack(spacing: 6) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .bold))
                }
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(inkColor)
                }
                Text(action.label)
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(inkColor)
            .padding(.horizontal, 15)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fillColor))
            .overlay {
                if action.id == .lookup {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(c.line2, lineWidth: 1)
                }
            }
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .opacity(gate.flatMap { locked.style($0) } ?? 1)
        .accessibilityLabel(isLocked ? "\(action.label), locked" : action.label)
    }
}

// MARK: - Wrapping row

/// Left-aligned row that wraps onto further lines, with the same gap between and across lines.
///
/// The action row is `flexWrap` in the design and genuinely needs it: "What is this?" beside
/// "Dismiss all (12)" overflows a narrow phone, and an `HStack` would squeeze both labels to ellipses
/// instead of moving one down.
private struct ActionFlow: Layout {
    var spacing: CGFloat = 8

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? (rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extended = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, extended > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = extended
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
