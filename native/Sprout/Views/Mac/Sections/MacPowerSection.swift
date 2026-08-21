#if os(macOS)
import SwiftUI

/// §4 Power (prototype `1a`, Power screen).
///
/// Four blocks, top to bottom: the printer socket as a hero control, TODAY / THIS PRINT beside it,
/// every socket on the strip as a `Table`, and the read-only automation card.
///
/// Every fetch, poll loop and money figure lives in `PowerStore` (Domain/), which `PowerView` on iOS
/// drives too — this file is layout and confirmation plumbing only. Nothing here re-derives a number
/// the store already owns.
///
/// **Deliberately not LAN-gated.** `LockedActions` guards controls the *printer* will refuse; a
/// smart plug is a different device on a different integration, and it is the real kill switch
/// precisely when the printer has stopped taking commands. Gating it on LAN mode would be this
/// codebase's recurring bug pointed at the one control that must never be disabled by a proxy.
///
/// The page does **not** scroll. Its four blocks are fixed except the socket table, which takes the
/// remaining height and scrolls internally when the strip is long — a `Table` inside a `ScrollView`
/// has no height to size itself against and either collapses or nests two scrollers.
struct MacPowerSection: View {
    let model: AppModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// Which switch is waiting on a confirmation, or nil for none. One dialog serves the hero and
    /// every table row: a `Table` cell is not a good place to hang a sheet, and the question is the
    /// same question either way.
    @State private var pendingCut: CutTarget?

    /// What a pending confirmation is about. The printer's own plug appears BOTH as the hero and as
    /// a row (`Power.otherPlugs` keeps it), so "which plug" is not enough to say which control was
    /// touched. Both cases resolve to the same poller for that plug — see `poller(for:)` — but they
    /// stay distinct because a row can be any socket and the hero is only ever one.
    private enum CutTarget: Equatable {
        case printerSocket
        case socket(Int)
    }

    // Thin reads of the store, so the layout below says what it means.
    private var power: PowerStore { model.power }
    private var plug: PlugSlot { power.plug }
    private var hero: PlugPoller { power.hero }
    private var sockets: [PlugSocket] { power.sockets }
    private var status: PrinterStatus? { model.status?.status }

    var body: some View {
        content
            .padding(m.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(c.bg)
            // Keyed on the SESSION, not on the printer — two questions that look like one:
            //
            //   "is a different PRINTER on screen?"            → `model.printerId`
            //   "is a different (SERVER, printer) loaded?"     → this
            //
            // Settings → Save rebuilds the client with the *same* printer id (`teardownSession`
            // never clears `printerId`, and `connect` re-assigns the same value), while
            // `PowerStore.attach` sets `plug = .loading` and drops the sockets. A task keyed on the
            // printer therefore never re-fired, and on macOS — where the Settings scene does not
            // unmount the window — the section sat on "Checking" with a dead hero switch and an
            // empty table until ⌘R or a section switch.
            //
            // The poll LOOPS are not started here: `MacSectionContent` owns store lifetimes for
            // every section, so exactly one place decides what polls. This is the one-shot fetch of
            // what has no poll at all — which plug is the printer's, the whole strip, the tariff.
            .task(id: MacPowerSessionKey(model)) { await power.reload() }
            .confirmationDialog(
                cutTitle,
                isPresented: Binding(get: { pendingCut != nil }, set: { if !$0 { pendingCut = nil } }),
                titleVisibility: .visible
            ) {
                Button("Switch off", role: .destructive) { confirmCut() }
                Button("Cancel", role: .cancel) { pendingCut = nil }
            } message: {
                Text(cutMessage)
            }
    }

    @ViewBuilder
    private var content: some View {
        // `.loading` must never render the empty state — a section still asking the server is not a
        // section that got an answer, and that is the whole reason `PlugSlot` is a three-way answer
        // rather than an optional.
        if plug == .unlinked && sockets.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: m.sectionGap) {
                topRow
                // No `else { Spacer() }`. A Spacer here absorbed the whole remaining height whenever
                // the strip held nothing but the printer's own socket, and glued AUTOMATIC SWITCHING
                // to the window's bottom edge with a void above it. The blocks stack from the top
                // (the outer frame is `.topLeading`) and the page ends where its content does; the
                // table is the only greedy child, and it is only present when it has rows to show.
                if showsSocketTable { socketTable }
                if plug.value != nil { automationCard }
            }
        }
    }

    /// The table earns its space when it says something the hero does not.
    ///
    /// iOS asks `sockets.count > 1`, which is the NEARBY question: with one socket that is not the
    /// printer's — a strip where nothing is bound to this machine — that count hides the only plug
    /// on screen. The question is "is there a socket the hero does not already control", so that is
    /// what this asks.
    private var showsSocketTable: Bool {
        sockets.contains { $0.id != plug.value?.id }
    }

    // MARK: - Hero row

    private var topRow: some View {
        HStack(alignment: .top, spacing: m.cardGap) {
            if plug == .unlinked { noPrinterPlugCard } else { heroCard }
            VStack(spacing: m.cardGap) {
                todayCard
                thisPrintCard
            }
            // The prototype's fixed right column. Not a Metrics token — Metrics names density, not
            // column widths — so it is the prototype's number, kept as one.
            .frame(width: 300)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                monoLabel("PRINTER SOCKET")
                Spacer(minLength: 8)
                if hero.on && hero.reachable {
                    PulseDot(color: c.accent, size: 6, period: 2.4)
                }
                Text(heroStateWord)
                    .font(.system(size: m.cardTitle, weight: .semibold))
                    .foregroundStyle(heroStateColor)
                Toggle("", isOn: heroSwitch)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(c.accent)
                    .controlSize(.small)
                    // The exact capability, not a proxy for it: `PlugPoller` starts life claiming
                    // `reachable` and `off`, so before the first poll lands a switch gated only on
                    // reachability is live with nothing bound behind it — a click would fall through
                    // `heroIntent`'s `.ignore` and do nothing at all.
                    .disabled(!hero.reachable || plug.value == nil)
                    // A dimmed switch with no reason is the failure mode CLAUDE.md warns about. The
                    // sentence below says it too; this is for the hover — and it names the SAME
                    // reason the disable does, rather than only one of the two.
                    .help(heroSwitchHelp)
                    .accessibilityLabel("Printer socket power")
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // `liveWatts`, not `watts`: a retained reading from a plug Bambuddy can no longer
                // reach is not a draw, and the em dash below is what "no current reading" looks like.
                if let watts = hero.liveWatts {
                    RollingNumber(
                        value: Int(watts.rounded()),
                        font: .system(size: m.heroMetric, weight: .bold),
                        color: c.t1
                    )
                } else {
                    Text(verbatim: "—")
                        .font(.system(size: m.heroMetric, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(c.t1)
                }
                Text(wattsCaption)
                    .font(.system(size: m.cardTitle, weight: .semibold))
                    .foregroundStyle(c.t3)
            }
            .padding(.top, 16)

            Text(heroSentence)
                .font(.system(size: m.body))
                .lineSpacing(3)
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(m.cardPadding)
        .powerSectionCard(c, radius: m.cardRadius, border: heroBorder)
    }

    /// The hero's slot when this printer has no plug bound but the strip has other sockets. The
    /// space keeps its meaning instead of the layout silently losing a column.
    private var noPrinterPlugCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            monoLabel("PRINTER SOCKET")
            Text("No plug is linked to this printer.")
                .font(.system(size: m.cardTitle, weight: .semibold))
                .foregroundStyle(c.t1)
                .padding(.top, 12)
            Text("Bind one in Bambuddy → Settings → Smart Plugs. The sockets below are on the same strip and still switch.")
                .font(.system(size: m.body))
                .lineSpacing(3)
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(m.cardPadding)
        .powerSectionCard(c, radius: m.cardRadius)
    }

    /// Every reason the switch above can be dimmed, in the same order `disabled` decides it.
    private var heroSwitchHelp: String {
        if plug == .loading { return "Still checking which plug is this printer's" }
        guard plug.value != nil else { return "No plug is linked to this printer" }
        return hero.reachable ? "Switch the printer's smart plug" : "Bambuddy can't reach this plug"
    }

    private var heroBorder: Color {
        hero.on && hero.reachable ? c.accent.opacity(0.3) : c.line
    }

    private var heroStateWord: String {
        if plug == .loading { return "Checking" }
        if !hero.reachable { return "Unreachable" }
        return hero.on ? "On" : "Off"
    }

    private var heroStateColor: Color {
        if plug == .loading { return c.t3 }
        if !hero.reachable { return c.heating }
        return hero.on ? c.accent : c.t3
    }

    /// Never "0 W" for a missing reading — the plug reports nothing and zero is a measurement.
    ///
    /// Reachability is asked FIRST. `hero.watts != nil` is the nearby question ("do we have a
    /// number") where this needs "is the number current": a failed poll only clears `reachable`, so
    /// asking about the number captioned the last-known figure "W drawing now" while the state word
    /// two lines above said "Unreachable" — and made the unreachable branch below dead code the
    /// moment any poll had ever succeeded.
    private var wattsCaption: String {
        guard hero.reachable else { return "W · plug unreachable" }
        return hero.liveWatts != nil ? "W drawing now" : "W · not reported yet"
    }

    /// What switching off would actually do, said specifically when it would destroy work.
    ///
    /// The predicate is `DashVM.kind == .live`, NOT `PowerStore.isRunning`. They are the nearby
    /// questions this codebase keeps confusing: `isRunning` asks "is the machine drawing power right
    /// now", which is what the cost projection needs; this asks "is there work in progress that
    /// cutting power would destroy", and a PAUSED print is squarely inside that.
    private var heroSentence: String {
        guard hero.reachable else {
            return "Bambuddy can't reach this plug, so it can't be switched from here. Check it in Bambuddy → Settings → Smart Plugs."
        }
        let vm = model.vm
        guard vm.kind == .live else {
            return "This cuts power at the smart plug. If a print is running, it will stop."
        }
        return vm.isPaused
            ? "A print is paused, not finished. Switching off cuts power at the plug and ends it — it cannot be resumed."
            : "A print is running. Switching off cuts power at the plug and stops it — it cannot be resumed."
    }

    // MARK: - Stat cards

    private var todayCard: some View {
        statCard(label: "TODAY") {
            // `liveKwh`: the same "is the number current" rule as the hero. A frozen total priced at
            // the tariff is a money figure the meter never reported.
            statFigure(hero.liveKwh.map { String(format: "%.2f", $0) }, caption: todayCaption)
        }
    }

    /// Four different absences, each named for what is actually missing.
    ///
    /// "not recorded yet" is a promise that a number is coming, and it was being made for a printer
    /// with no plug bound to it and for a plug the server cannot reach — neither of which is waiting
    /// for data. The hero slot beside this already says so; this card used to contradict it.
    private var todayCaption: String {
        if plug == .loading { return "kWh · checking for a plug" }
        if plug == .unlinked { return "kWh · nothing is measuring" }
        guard hero.reachable else { return "kWh · plug unreachable" }
        guard hero.liveKwh != nil else { return "kWh · not recorded yet" }
        // A tariff the server was never given is not a price of zero, and the app never invents one.
        // Same words as THIS PRINT below: one condition, one sentence, in cards that touch.
        guard let cost = power.todayCost else { return "kWh · price not set in Bambuddy" }
        return "kWh · \(power.money(cost))"
    }

    /// This print's cost so far, and at completion.
    ///
    /// The prototype shows kWh here as well as money; `PowerStore.projection` returns money only, and
    /// re-deriving the kWh half in the view would be a second copy of the elapsed-time maths that
    /// already lives in the store. Money is what the store gives, so money is what this shows.
    private var thisPrintCard: some View {
        // `PowerStore.projection` reads `hero.watts` straight, so the "is the reading current"
        // question is asked here: extrapolating a cost from a retained wattage would put a confident
        // money figure on a plug that stopped answering minutes ago.
        let projection: (soFar: Double?, projected: Double?) =
            hero.reachable ? power.projection(status) : (nil, nil)
        return statCard(label: "THIS PRINT", live: PowerStore.isRunning(status)) {
            statFigure(projection.soFar.map { power.money($0) }, caption: thisPrintCaption(projection.projected))
        }
    }

    /// Names the capability that is actually absent, in the order the user would ask.
    ///
    /// The old fall-through said "not recorded yet" for an unlinked plug — testing for a projection
    /// *value* when the question is "is anything measuring this printer at all". Nothing is going to
    /// record it, so "yet" was a promise the app could not keep. Same shape as the recurring bug in
    /// CLAUDE.md: a predicate answering the nearby question.
    private func thisPrintCaption(_ projected: Double?) -> String {
        // `PowerStore.isRunning` here on purpose — this is the "is it drawing power" question, which
        // is the one the projection can answer. A paused print says so rather than showing a dash.
        guard PowerStore.isRunning(status) else {
            guard model.vm.kind == .live else { return "no print running" }
            return model.vm.isPaused ? "paused — nothing to project" : "starting — nothing to project yet"
        }
        if plug == .loading { return "checking for a plug" }
        if plug == .unlinked { return "no plug is measuring this printer" }
        guard hero.reachable else { return "plug unreachable — nothing to project from" }
        guard power.price != nil else { return "price not set in Bambuddy" }
        guard let projected else {
            // The two remaining inputs, told apart: the plug's reading and the printer's estimate.
            return hero.liveWatts == nil
                ? "plug hasn't reported a draw yet"
                : "not enough from the printer to project yet"
        }
        return "so far · \(power.money(projected)) projected"
    }

    private func statCard<Body: View>(
        label: String,
        live: Bool = false,
        @ViewBuilder content: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if live { PulseDot(color: c.running, size: 5, period: 2) }
                monoLabel(label)
            }
            content()
                .padding(.top, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(m.cardPadding)
        .powerSectionCard(c, radius: m.cardRadius)
    }

    /// A secondary big number with its unit on the same baseline, or an em dash when there is none.
    ///
    /// The prototype pairs a 40 pt hero with 24 pt stat figures. Metrics names 27 (`heroMetric`) and
    /// 19 (`screenTitle`); that pair carries the same "one step down" relationship, and both are
    /// tokens rather than eyeballed sizes.
    private func statFigure(_ value: String?, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value ?? "—")
                .font(.system(size: m.screenTitle, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(c.t1)
            Text(caption)
                .font(.system(size: m.body, weight: .semibold))
                // The caption carries live money ("kWh · £0.47", "so far · £0.29 projected") and
                // re-renders every 5 s. Without tabular figures the whole line jitters as the digits
                // change width. `PowerView` sets this on the iOS counterpart for the same reason.
                .monospacedDigit()
                .foregroundStyle(c.t3)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - All sockets

    /// A real `Table` (§4), not a stack of rows.
    ///
    /// Deliberately WITHOUT a selection binding. The inspector shows what is live — the printer's
    /// draw and the tariff — and nothing in it is about a selected row, so a selection highlight
    /// would be an affordance with nothing behind it.
    ///
    /// Headers are title-case rather than the prototype's mono-uppercase band: they are real
    /// `Table` headers here, and the Files and Jobs tables in this same window set that convention.
    private var socketTable: some View {
        Table(sockets) {
            TableColumn("All Sockets") { socket in
                nameCell(socket)
            }
            .width(min: 190, ideal: 280)

            TableColumn("Drawing") { socket in
                let p = poller(for: socket)
                numberCell(drawing(p), missing: p.liveWatts == nil)
            }
            .width(min: 96, ideal: 120)

            TableColumn("Today") { socket in
                let p = poller(for: socket)
                numberCell(today(p), missing: p.liveKwh == nil)
            }
            .width(min: 96, ideal: 130)

            TableColumn("Power") { socket in
                let p = poller(for: socket)
                Toggle("", isOn: socketSwitch(socket))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(c.accent)
                    .controlSize(.mini)
                    .disabled(!p.reachable)
                    .help(p.reachable
                          ? "Switch \(Power.plugLabel(socket.plug))"
                          : "Bambuddy can't reach this plug")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("\(Power.plugLabel(socket.plug)) power")
            }
            .width(min: 72, ideal: 84, max: 110)
        }
        .tableStyle(.inset)
        // The table's own scroll background is the system's; the card fill underneath is the app's.
        .scrollContentBackground(.hidden)
        .powerSectionCard(c, radius: m.cardRadius)
        .frame(maxHeight: .infinity)
    }

    /// The poller a row must READ AND WRITE — which is not always the one `PlugSocket` carries.
    ///
    /// The printer's own socket is on the strip *and* is the hero, so it is on screen twice with a
    /// switch in each place (`PowerStore.syncPollers` passes `printerPlugId: nil` on purpose — a
    /// strip that hides a socket looks like it is missing one). What it must not have is two
    /// independently-settled copies of its state: `set()` flips one poller optimistically and opens
    /// an 8 s settle window on that one only, so switching off from the hero left the PRINTER row
    /// reporting "On" with live watts until its own poll caught up. On iOS a scroll separated the
    /// two; here they sit about 100 pt apart and visibly disagree.
    ///
    /// One physical socket, one poller. The row's own poller keeps running in the store and is
    /// simply not read for this row (see the report — the fix belongs in `syncPollers`).
    private func poller(for socket: PlugSocket) -> PlugPoller {
        socket.id == plug.value?.id ? hero : socket.poller
    }

    private func nameCell(_ socket: PlugSocket) -> some View {
        let armed = Power.plugAutomations(socket.plug)
        return HStack(spacing: 9) {
            // A static dot, not a `PulseDot`: one breathing dot marks the live control in the hero;
            // a column of them reads as an alarm.
            Circle()
                .fill(socketDot(poller(for: socket)))
                .frame(width: 7, height: 7)
            Text(Power.plugLabel(socket.plug))
                .font(.system(size: m.cardTitle, weight: .semibold))
                .foregroundStyle(c.t1)
                .lineLimit(1)
            if socket.id == plug.value?.id {
                Text("PRINTER")
                    .font(.mono(m.monoLabel, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(c.accent)
            }
            if !armed.isEmpty {
                // Says the socket switches itself, and in the dangerous colour only when a rule
                // actually cuts power.
                Text(armed.map(\.label).joined(separator: " · "))
                    .font(.mono(m.monoLabel, weight: .medium))
                    .foregroundStyle(armed.contains { $0.cuts } ? c.heating : c.t3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: m.rowHeight)
    }

    private func numberCell(_ text: String, missing: Bool) -> some View {
        Text(text)
            .font(.system(size: m.body))
            .monospacedDigit()
            .foregroundStyle(missing ? c.t3 : c.t2)
            .lineLimit(1)
    }

    /// Unreachable is `heating` (amber), the same colour the hero's state word uses. It was `idle`
    /// (#8E9398), which against off (`t3`, #6B7177) is a near-identical grey — so the column drew
    /// two different states the same and one state two different ways depending on where you looked.
    private func socketDot(_ poller: PlugPoller) -> Color {
        guard poller.reachable else { return c.heating }
        return poller.on ? c.running : c.t3
    }

    private func drawing(_ poller: PlugPoller) -> String {
        guard poller.reachable else { return "unreachable" }
        guard let watts = poller.liveWatts else { return "not reported" }
        return "\(Int(watts.rounded())) W"
    }

    /// The same reachability guard `drawing` has, and for the same reason.
    ///
    /// Without it the two columns of one row answered "is this number current" differently:
    /// "unreachable" beside a frozen kWh, rendered in the live colour because `missing:` was keyed
    /// on `kwh == nil` and the retained value defeated it. The row states unreachability once, in
    /// the Drawing column and the dot; repeating the word in every column is noise, so what this
    /// says is simply that it has no current total.
    private func today(_ poller: PlugPoller) -> String {
        guard let kwh = poller.liveKwh else { return poller.reachable ? "not recorded" : "—" }
        return String(format: "%.2f kWh", kwh)
    }

    // MARK: - Automations

    /// Read-only on purpose: writes to `/smart-plugs/{id}` are admin-only and 403 with a scoped API
    /// key, so the honest thing the app can do is report them accurately and name the place they
    /// change. A switch here would be a control that lies.
    private var automationCard: some View {
        let automations = power.automations
        let cuts = automations.contains { $0.cuts }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: cuts ? "clock" : "shield")
                    .font(.system(size: m.cardTitle))
                    .foregroundStyle(cuts ? c.heating : c.t3)
                monoLabel("AUTOMATIC SWITCHING")
            }

            if automations.isEmpty {
                Text("Nothing switches this plug automatically — power stays as you leave it.")
                    .font(.system(size: m.body))
                    .lineSpacing(3)
                    .foregroundStyle(c.t2)
                    .padding(.top, 9)
            } else {
                ForEach(automations) { a in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(a.cuts ? c.heating : c.t3)
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.label)
                                .font(.system(size: m.cardTitle, weight: .semibold))
                                .foregroundStyle(c.t1)
                            Text(a.detail)
                                .font(.system(size: m.body))
                                .lineSpacing(3)
                                .foregroundStyle(c.t3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 9)
                }
            }

            Text("Change these in Bambuddy → Settings → Smart Plugs.")
                .font(.system(size: m.body))
                .foregroundStyle(c.t3)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(m.cardPadding)
        .powerSectionCard(c, radius: m.cardRadius)
    }

    // MARK: - Empty state

    /// Nothing came back — and the app genuinely **cannot tell why**.
    ///
    /// `PlugSlot.unlinked` is what `getPlug` returning nil produces, and that call swallows its
    /// transport error (see `PlugSlot`'s own doc), so "no plug is bound to this printer" and
    /// "Bambuddy did not answer" arrive as the identical empty answer. The old copy picked one of
    /// them — a definite claim about server configuration, plus instructions to go and change it —
    /// for a server that may be perfectly configured and simply unreachable.
    ///
    /// So this says the part that is true either way, names both readings, and offers the one action
    /// that actually distinguishes them.
    private var emptyState: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
                .fill(c.s2)
                .frame(width: 60, height: 60)
                .overlay {
                    Image(systemName: "power")
                        .scaledFont(26)
                        .foregroundStyle(c.t3)
                }
            Text("No plugs came back")
                .font(.system(size: m.screenTitle, weight: .bold))
                .foregroundStyle(c.t1)
            Text("Either no plug is linked to this printer, or Bambuddy didn't answer — the plug lookup gives the same empty result for both, so the app can't tell them apart. Link one in Bambuddy → Settings → Smart Plugs, or try the server again.")
                .font(.system(size: m.body))
                .lineSpacing(4)
                .foregroundStyle(c.t3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            // No `.keyboardShortcut("r")` — ⌘R is already bound once, in `MacCommands`, and it
            // reaches `power.reload()` through `MacSectionRefresh`. A second binding for the same
            // key would be two menu items claiming it.
            Button("Try again") { Task { await power.reload() } }
                .buttonStyle(MacSecondaryButtonStyle())
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chrome

    private func monoLabel(_ text: String) -> some View {
        Text(text)
            .font(.mono(m.monoLabel, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(c.t3)
    }

    // MARK: - Switching

    /// The knob never slides before the answer does: the binding reads `poller.on` and writes
    /// nothing, so a cancelled confirmation leaves the switch exactly where it was.
    private var heroSwitch: Binding<Bool> {
        Binding(get: { hero.on }, set: { toggleHero($0) })
    }

    private func socketSwitch(_ socket: PlugSocket) -> Binding<Bool> {
        let p = poller(for: socket)
        return Binding(get: { p.on }, set: { requestSocket(socket, $0) })
    }

    /// Two questions the setter has to keep apart:
    ///
    ///   "did the user just ask for a change?"  → the incoming value, against what is on screen
    ///   "which way does this plug go now?"     → `PowerStore.heroIntent`, where that rule lives
    ///
    /// The value used to be discarded and the direction re-derived, so *any* setter call — an
    /// NSSwitch dragged away and back to its origin, a re-assert of the state it is already in —
    /// opened the destructive confirmation for a gesture that changed nothing. `socketSwitch` used
    /// `$0` and was immune; the control without the guard was the dangerous one.
    private func toggleHero(_ next: Bool) {
        guard next != hero.on else { return }
        switch power.heroIntent {
        case .ignore: break
        case .apply(let value): apply(value, on: hero)
        case .confirmOff: pendingCut = .printerSocket
        }
    }

    /// Cutting power to a peripheral is disruptive too — an AMS mid-print, a running dryer — so a
    /// row asks the same question the hero does. `PowerStore.socketIntent` is where that rule lives.
    private func requestSocket(_ socket: PlugSocket, _ next: Bool) {
        let p = poller(for: socket)
        guard next != p.on else { return }
        switch PowerStore.socketIntent(next) {
        case .ignore: break
        case .apply(let value): apply(value, on: p)
        case .confirmOff: pendingCut = .socket(socket.id)
        }
    }

    private func confirmCut() {
        guard let target = pendingCut else { return }
        pendingCut = nil
        switch target {
        case .printerSocket:
            apply(false, on: hero)
        case .socket(let id):
            // Through `poller(for:)`, so confirming from the printer's own ROW writes to the same
            // poller the hero switch does — one physical socket, one optimistic state, one settle
            // window.
            guard let socket = sockets.first(where: { $0.id == id }) else { return }
            apply(false, on: poller(for: socket))
        }
    }

    private func apply(_ next: Bool, on poller: PlugPoller) {
        Task {
            do { try await poller.set(next) } catch { model.toast = .failure(PowerStore.failureMessage(error)) }
        }
    }

    // MARK: - The confirmation's words

    /// A `String`, not a literal, so the dialog takes the plain-text overload rather than treating an
    /// interpolated sentence as a localization key.
    private var cutTitle: String {
        switch pendingCut {
        case .socket(let id):
            return "Switch off \(Power.plugLabel(sockets.first { $0.id == id }?.plug))?"
        case .printerSocket, .none:
            return "Switch off \(Power.plugLabel(plug.value))?"
        }
    }

    private var cutMessage: String {
        guard targetsPrinter else {
            return "This cuts power at the smart plug. Anything plugged into it stops."
        }
        // Same reasoning as `heroSentence`: the question is "would this destroy work in progress",
        // which `DashVM` answers and `PowerStore.isRunning` does not.
        let vm = model.vm
        guard vm.kind == .live else { return "This cuts power at the smart plug." }
        return vm.isPaused
            ? "A print is paused, not finished. Cutting power at the plug ends it — it cannot be resumed."
            : "A print is running. Cutting power at the plug stops it — it cannot be resumed."
    }

    /// Whether the pending confirmation is about the machine's own socket — the one that can take a
    /// print down with it. A row for that same plug counts.
    private var targetsPrinter: Bool {
        switch pendingCut {
        case .printerSocket: return true
        case .socket(let id): return id == plug.value?.id
        case .none: return false
        }
    }
}

/// **"Which printer is on screen" is not "which loaded session is on screen".**
///
/// `PowerStore.attach` keys on the pair (client, printer) — and `.task(id:)` in this section and its
/// inspector has to ask the same question, or it misses the case the two answer differently:
/// Settings → Save rebuilds the client with the *same* printer id, so a task keyed on `printerId`
/// alone never re-fires while the store has already reset itself to `.loading`.
///
/// Shared by `MacPowerSection` and `MacPowerInspector` so the section's fetch and the inspector's
/// trace start over together. It is named for Power because Power is where it was needed; the same
/// mis-keying is the convention across the Mac sections (`MacHardwareSection` keys on `printerId`
/// too) and one shared key belongs in `Views/Mac/` — noted in the report rather than done here,
/// because those files belong to other sections.
struct MacPowerSessionKey: Equatable {
    let client: ObjectIdentifier?
    let printerId: Int

    @MainActor
    init(_ model: AppModel) {
        client = model.client.map { ObjectIdentifier($0) }
        printerId = model.printerId
    }
}


private extension View {
    /// The section's one card treatment: `s1` fill with a hairline inside the corner radius.
    func powerSectionCard(_ c: Palette, radius: CGFloat, border: Color? = nil) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(c.s1))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border ?? c.line)
            )
    }
}
#endif
