#if os(macOS)
import SwiftUI

/// Everything demanding attention, with the actions that are possible right now.
///
/// §4 sends alerts to the Printer inspector's triage card, and that is where they are SEEN — but a
/// card in a 320 pt column cannot carry an alert's actions, so the Mac build showed alert text
/// read-only and `AlertVM.actions` were unreachable. That is a capability the iOS app has and this
/// one silently did not: Resume, Stop, Clear notices, Confirm the plate, and — the one with no
/// substitute anywhere — **Look it up**, which opens Bambu's own page for an HMS code.
///
/// A sheet rather than a window: it is about the printer you are looking at, it is transient, and
/// §Fleet keeps this app to one printer at a time.
struct MacAlertsSheet: View {
    let model: AppModel
    @Binding var isPresented: Bool

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m
    @Environment(\.openURL) private var openURL

    @State private var catalog: HmsCatalog = .empty
    @State private var probing: String?
    @State private var pending: MacPendingAlertConfirm?
    @State private var explainingLock = false

    private var locked: LockedActions {
        LockedActions(mode: model.lanMode, explaining: $explainingLock)
    }

    /// Re-runs the wiki scrape only when the set of codes on screen changes, or when the catalogue
    /// actually grew. Both halves matter: without the code list a new alert is never described, and
    /// without the catalogue counts a failed scrape would retry forever.
    private var learnKey: String {
        let codes = alerts.compactMap(\.code).joined(separator: ",")
        return "\(codes)|\(catalog.hms.count)|\(catalog.learned.count)"
    }

    private var alerts: [AlertVM] {
        Alerts.present(
            model.status?.status,
            // Bambuddy's scoped key covers print control, so the only thing that can take the
            // actions away is an unreachable printer.
            caps: AlertCaps(
                connected: model.status?.status?.connected == true,
                canControl: true,
                model: model.printer?.model
            ),
            describe: AlertDescribe(catalog: catalog)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if alerts.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: m.cardGap) {
                        ForEach(alerts) { alert in
                            MacAlertCard(
                                alert: alert,
                                locked: locked,
                                probing: probing == alert.id,
                                onAction: { act in start(alert, act) }
                            )
                        }
                    }
                    .padding(m.gutter)
                }
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 520)
        .background(c.bg)
        .lockedActionAlert($explainingLock)
        .task { catalog = await HmsCatalogStore.shared.load() }
        .task(id: learnKey) { await learnUnknownCodes() }
        .confirmationDialog(
            pending?.action.label ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { p in
            Button(p.action.label, role: .destructive) { perform(p.alert, p.action) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text(p.alert.title)
        }
    }

    private var header: some View {
        HStack {
            Text("Needs attention")
                .scaledFont(15, weight: .bold)
                .foregroundStyle(c.t1)
            if !alerts.isEmpty {
                Text("\(alerts.count)")
                    .font(.mono(m.monoLabel, weight: .bold))
                    .foregroundStyle(c.t3)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, m.gutter)
        .padding(.vertical, 14)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .scaledFont(26)
                .foregroundStyle(c.running)
            Text("Nothing needs you right now.")
                .font(.system(size: m.body))
                .foregroundStyle(c.t2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { isPresented = false }
                .buttonStyle(MacPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, m.gutter)
        .padding(.vertical, 12)
        .background(c.s1)
    }

    /// Destructive actions ask first; everything else runs immediately — the same split iOS makes.
    private func start(_ alert: AlertVM, _ act: AlertActionVM) {
        if act.destructive {
            pending = MacPendingAlertConfirm(alert: alert, action: act)
        } else {
            perform(alert, act)
        }
    }

    private func perform(_ alert: AlertVM, _ act: AlertActionVM) {
        switch act.id {
        case .resume:       model.perform("Resume") { try await $0.resume($1) }
        case .stop:         model.perform("Stop") { try await $0.stop($1) }
        case .clearHms:     model.perform("Clear notices") { try await $0.clearHms($1) }
        case .plateCleared: model.perform("Confirm the plate") { try await $0.clearPlate($1) }
        case .lookup:       lookUp(alert, act)
        }
    }

    /// Opens Bambu's page for a code — the first candidate that actually resolves.
    ///
    /// The wiki is per model FAMILY and each family has its own code namespace, so the right page
    /// cannot be known from the code alone. `Alerts.hmsURLs` orders the candidates with this
    /// machine's family first and the searchable index last; the index always resolves. Without the
    /// probe a click landed on a 404 — the reported "fatal is not found".
    private func lookUp(_ alert: AlertVM, _ act: AlertActionVM) {
        guard let urls = act.urls, !urls.isEmpty else { return }
        probing = alert.id
        Task {
            let target = await firstResolvingURL(urls)
            probing = nil
            if let target { openURL(target) }
        }
    }

    /// Reads the wiki page for every code the catalogue still cannot describe, once, and remembers
    /// it. Every H2-family code is missing from Bambu's public feed — including the one that turned
    /// out to say "Nozzle camera lens is dirty…", precisely the sentence worth surfacing.
    private func learnUnknownCodes() async {
        let targets = Alerts.unknownCodes(in: alerts, catalog: catalog)
        guard !targets.isEmpty else { return }
        catalog = await HmsCatalogStore.shared.learn(targets)
    }
}

/// A destructive action waiting on the user's yes. Carries the alert too, because the dialog quotes
/// its title.
private struct MacPendingAlertConfirm: Identifiable {
    let alert: AlertVM
    let action: AlertActionVM

    var id: String { "\(alert.id)-\(action.id.rawValue)" }
}

/// One alert: severity, title, Bambu's own description, the code, and the actions possible now.
private struct MacAlertCard: View {
    let alert: AlertVM
    let locked: LockedActions
    let probing: Bool
    let onAction: (AlertActionVM) -> Void

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    private var tint: Color {
        switch alert.level {
        case .error: c.error
        case .warning: c.heating
        case .info: c.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(alert.title)
                    .font(.system(size: m.cardTitle, weight: .semibold))
                    .foregroundStyle(c.t1)
                Spacer(minLength: 8)
                if let code = alert.code {
                    Text(code)
                        .font(.mono(m.monoLabel, weight: .medium))
                        .foregroundStyle(c.t3)
                        .textSelection(.enabled)     // a code people paste into a search box
                }
            }

            Text(alert.detail)
                .font(.system(size: m.body - 1))
                .foregroundStyle(c.t2)
                .fixedSize(horizontal: false, vertical: true)

            if !alert.actions.isEmpty {
                HStack(spacing: 7) {
                    ForEach(alert.actions) { act in
                        actionButton(act)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(m.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(tint.opacity(0.35)))
    }

    @ViewBuilder
    private func actionButton(_ act: AlertActionVM) -> some View {
        let gate = Self.gate(for: act.id)
        let blocked = gate.map(locked.blocked) ?? false

        Button {
            // The gate runs BEFORE the action: a locked control must explain itself, not act.
            guard let gate else { onAction(act); return }
            locked.press(gate) { onAction(act) }()
        } label: {
            HStack(spacing: 6) {
                if blocked { Image(systemName: "lock.fill").scaledFont(9, weight: .bold) }
                if probing, act.id == .lookup { ProgressView().controlSize(.small) }
                Text(act.label)
            }
        }
        .buttonStyle(MacSecondaryButtonStyle(role: act.destructive ? .destructive : .normal))
        .opacity(blocked ? Lan.lockedOpacity : 1)
        .disabled(probing && act.id == .lookup)
    }

    /// The LAN-gate identity of an alert action, or **nil for the ones the printer is never asked
    /// about**: `clearHms` is Bambuddy's own bookkeeping, and `lookup` opens a web page.
    ///
    /// Nil rather than some nearby action id. Gating "Look it up" on whether the printer is
    /// reachable would be one predicate answering "can we talk to the machine" on behalf of a
    /// button that never talks to it — and it would lock exactly when a fault code most needs
    /// explaining. Mirrors `AlertCard.gate` on iOS; the two must agree.
    private static func gate(for id: AlertActionId) -> ActionId? {
        switch id {
        case .resume: .resume
        case .stop: .stop
        case .plateCleared: .plateCleared
        case .clearHms, .lookup: nil
        }
    }
}
#endif
