#if os(macOS)
import Foundation
import SwiftUI

// MARK: - Severity

/// How loudly a triage item shows: `now` (red) or `soon` (amber).
///
/// Derived from `HardwareTriage.Item.weight`, which is ALREADY the app's severity ordering ("higher
/// sorts first"), rather than by re-testing `isDue` / humidity here. A second predicate answering
/// "how bad is this?" is the shape the recurring bug takes — it would eventually disagree with the
/// order the same list is sorted in, and the picker dot would contradict the card above it.
///
/// Shared with `MacHardwareInspector`, which paints the same dots against the same items.
enum MacHardwareSeverity: Hashable {
    case now, soon

    /// `HardwareTriage` weights overdue service 100 and a damp spool 50. The split is "stops a print
    /// today" versus "worth knowing about".
    ///
    /// It is written once **for the two Hardware surfaces**, and that is the honest scope of the
    /// claim: `MacPrinterInspector` paints its own headline dot for the same `HardwareTriage.items`
    /// output with a hard `c.heating`, so an overdue service item is red here and amber there.
    /// Fixing that means changing a file this pass does not own — **reported**, not worked around by
    /// adding a third rule here.
    private static let urgentWeight = 100

    static func of(_ item: HardwareTriage.Item) -> MacHardwareSeverity {
        item.weight >= urgentWeight ? .now : .soon
    }

    /// The worst thing flagged anywhere, or nil when nothing is.
    static func worst(_ items: [HardwareTriage.Item]) -> MacHardwareSeverity? {
        guard let top = items.map(\.weight).max() else { return nil }
        return top >= urgentWeight ? .now : .soon
    }

    /// The worst thing flagged against one segment, or nil when that segment is clean.
    static func worst(_ items: [HardwareTriage.Item], in segment: HardwareSegment) -> MacHardwareSeverity? {
        worst(items.filter { $0.segment == segment })
    }

    func color(_ c: Palette) -> Color {
        switch self {
        case .now: c.error
        case .soon: c.heating
        }
    }
}

// MARK: - Triage inputs

/// The one triage call **every Mac surface** makes.
///
/// Three cards ask "what needs doing": the Hardware section's picker dots, the Hardware inspector's
/// card, and the Printer inspector's triage block. They are the same signal said loudly and quietly,
/// so they must be the same list.
///
/// Each used to build its own `HardwareTriage.items(...)` — three arguments kept identical by hand
/// across three files — and one had already drifted. `nozzlesKnown` was `MacNozzleRack.reported(...)`
/// here and `!(status?.nozzles ?? []).isEmpty` in `MacPrinterInspector`, which misses the H2's nozzle
/// RACK entirely: on that machine one card could call the nozzles unknown while another, one click
/// away, said the opposite.
///
/// It was harmless only because `HardwareTriage.items` currently discards the argument
/// (`_ = nozzlesKnown`) — which is worse than a visible bug, not better: the drift was invisible and
/// would have surfaced the moment that parameter started being used.
enum MacHardwareTriage {
    @MainActor
    static func items(_ model: AppModel, dash: DashVM) -> [HardwareTriage.Item] {
        HardwareTriage.items(
            maintenance: model.hardware.maintenanceItems,
            humidities: dash.amsUnits.map { (label: $0.label, rh: $0.humidity) },
            nozzlesKnown: MacNozzleRack.reported(model.status?.status)
        )
    }
}

// MARK: - Section

/// The **Hardware** section (§4, prototype lines 334-414): Filament / Nozzles / Service.
///
/// Every fetch, the three-way load state and the segment selection live in `HardwareStore`; this
/// file is layout. The triage card that pins above the picker on iOS is **not** here — §4 moves it
/// to the inspector on Mac, where it is the inspector's whole job. What survives in the content
/// column is the picker's per-segment dot, which is the same signal said quietly.
@MainActor
struct MacHardwareSection: View {
    let model: AppModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    @State private var lanAlert = false
    @State private var confirmStop: DryerVM?
    @State private var confirmDone: MaintenanceItem?
    /// The start RUNS in flight, and the units with a stop in flight — two collections keyed by unit,
    /// not one slot.
    ///
    /// A single `busyDryer: Int?` answered "is SOMETHING busy, and which was it last", which is a
    /// different question from "is this unit's start in flight". Starting unit 0 and then unit 1
    /// cleared the first unit's spinner; stopping one cycle disabled the Start on another. Three
    /// AMS units are the owner's normal configuration, so this is the everyday case.
    ///
    /// A **run** is the whole start sequence as ONE task: the request, then the nine-second check
    /// that the printer really entered drying (`dryRun`). One task rather than two because "the user
    /// pressed Start on this unit and we do not yet know the outcome" is one question, and it is true
    /// from the moment of the click. Splitting it — a `starting` flag set on click, a verification
    /// handle created only once `dryingStart` had RETURNED — left a hole exactly the width of the
    /// request: a Stop pressed during it cancelled nothing, and nine seconds later the app reported
    /// that the cycle the user had just cancelled never began.
    @State private var dryRuns: [Int: Task<Void, Never>] = [:]
    @State private var stopping: Set<Int> = []
    /// The printer the store has already been reloaded for — see the `.task` below.
    @State private var reloadedFor: Int?

    private var hw: HardwareStore { model.hardware }
    private var status: PrinterStatus? { model.status?.status }
    private var locked: LockedActions { LockedActions(mode: model.lanMode, explaining: $lanAlert) }

    private func nozzleRows(_ dash: DashVM) -> [MacNozzleRow] { MacNozzleRack.rows(status, dash: dash) }

    /// "Has this unit's Start been pressed and not yet resolved?"
    ///
    /// The spinner, the disabled Start and the menu item all ask exactly this, and the answer IS "a
    /// run is in flight" — so there is no second flag that can drift out of step with the task.
    private func startingDrying(_ amsId: Int) -> Bool { dryRuns[amsId] != nil }

    var body: some View {
        // `model.vm` is a COMPUTED property: every read re-runs the whole dashboard presenter,
        // `AmsTopology` included. Reading it once here and passing the value down turned ~20
        // presentations per body evaluation (two per slot card on a 9-tray H2C, plus the header and
        // the triage) into one.
        let dash = model.vm
        return VStack(alignment: .leading, spacing: 0) {
            header(dash)
            Rectangle().fill(c.line).frame(height: 1)
            // A new identity per segment, so each pane enters with the app's own rise transition.
            //
            // It does NOT preserve per-pane scroll offset — changing the identity discards the
            // outgoing pane and SwiftUI keeps no scroll state for a discarded one, so Filament →
            // Nozzles → Filament returns to the top. That is accepted: each pane is short, and the
            // alternative (one shared 2 500 pt scroll) is the thing the segments exist to end.
            FadeRise(dy: 8, duration: 0.3) { pane(dash) }
                .id(hw.segment)
                // The two CONFIRMATIONS hang off the pane rather than the root, so no one view
                // carries more than a pair of alert modifiers. Stacking several on a single view is
                // where SwiftUI starts dropping the second presentation.
                .alert(
                    "Stop drying?",
                    isPresented: Binding(get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } }),
                    presenting: confirmStop
                ) { d in
                    Button("Cancel", role: .cancel) {}
                    Button("Stop", role: .destructive) { stopDrying(d) }
                } message: { _ in
                    Text("Ends the current drying cycle.")
                }
                .alert(
                    confirmDone.map { "Mark “\($0.maintenanceTypeName)” as done?" } ?? "",
                    isPresented: Binding(get: { confirmDone != nil }, set: { if !$0 { confirmDone = nil } }),
                    presenting: confirmDone
                ) { item in
                    Button("Cancel", role: .cancel) {}
                    Button("Mark done") { markDone(item) }
                } message: { item in
                    Text(markDoneMessage(item))
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(c.bg)
        // `MacSectionContent` starts and stops the store for whichever section is on screen, so the
        // FIRST run here must not fetch: it would be a second identical pair of requests.
        //
        // What the router cannot see is the printer changing while Hardware stays on screen — its
        // `.task(id: section)` does not re-run, while `attach` has just cleared the previous
        // machine's spools and put maintenance back to `.loading`. Without a refetch on that edge
        // the pane would sit on a spinner forever. Hence: attach always, refetch on a CHANGE only.
        .task(id: model.printerId) {
            hw.attach(client: model.client, printerId: model.printerId)
            let previous = reloadedFor
            reloadedFor = model.printerId
            guard let previous, previous != model.printerId else { return }
            // The PRINTER changed, so any start still being checked on belongs to the machine we just
            // left. AMS ids are not unique across machines — 0, 1 and 128 name a unit on every one of
            // them — so both the spinner and the nine-second verdict would land on the wrong cards.
            cancelDryRuns()
            await hw.reload()
        }
        // Deliberately NO `.onDisappear { cancel }`. Leaving Hardware must not discard a start we are
        // still checking on: that cancel threw away the printer's refusal ("mqtt message verify
        // failed") for anyone who pressed Start and hit ⌘2 within nine seconds — the exact message
        // the check exists to catch. The verdict now goes to `model.toast`, which `MacRoot` renders
        // above every section, so it survives the section being torn down.
        .lockedActionAlert($lanAlert)
    }

    // MARK: Chrome

    /// The picker, and one line saying what hardware is attached. No screen title: on Mac the
    /// section name lives in the toolbar (§3), and repeating it here would say "Hardware" twice
    /// within 40 pt.
    private func header(_ dash: DashVM) -> some View {
        HStack(spacing: 12) {
            segmentPicker(MacHardwareTriage.items(model, dash: dash))
            Text(fleetLine(dash))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(c.t3)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, m.gutter)
        .padding(.vertical, 12)
    }

    /// Hand-rolled rather than `Picker(.segmented)`, because the per-segment warning dot has to be
    /// *coloured* — red for an overdue service item, amber for a damp spool — and a segmented
    /// `Picker` renders its labels in the system's own tint. iOS spells the same signal as a "•"
    /// inside the label for exactly that reason; a Mac window has the room to do it properly.
    private func segmentPicker(_ items: [HardwareTriage.Item]) -> some View {
        // The trough. Named because the thumb's radius is derived from it below.
        let trackInset: CGFloat = 2
        return HStack(spacing: 2) {
            ForEach(HardwareSegment.allCases) { seg in
                let on = hw.segment == seg
                let severity = MacHardwareSeverity.worst(items, in: seg)
                Button {
                    hw.segment = seg
                } label: {
                    HStack(spacing: 6) {
                        Text(seg.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? c.t1 : c.t3)
                        // Always drawn, `clear` when clean: a dot that appears and disappears would
                        // shift the segment widths every time a reading crosses the threshold.
                        Circle()
                            .fill(severity?.color(c) ?? .clear)
                            .frame(width: 5, height: 5)
                    }
                    .padding(.horizontal, 15)
                    .frame(height: m.minControlHeight)
                    // CONCENTRIC with the track: the thumb sits `trackInset` inside it, so its
                    // corner is the track's minus that inset. Equal radii would leave a sliver of
                    // track visible at the thumb's corners while the straight edges touched.
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.concentric(inside: m.controlRadius,
                                                                         inset: trackInset),
                                         style: .continuous)
                            .fill(on ? c.s4 : .clear)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
                .accessibilityLabel(severity == nil ? seg.label : "\(seg.label), needs attention")
                .help(severity == nil ? seg.label : "\(seg.label) — something here needs you")
            }
        }
        .padding(trackInset)
        .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).stroke(c.line))
    }

    /// "AMS 2 Pro · 3 units · 7 of 9 slots loaded".
    ///
    /// The prototype ends this line with a firmware version. Bambuddy's status payload carries no
    /// AMS firmware field, so it is omitted rather than invented — a made-up version string is worse
    /// than none, because it is the thing you would quote in a bug report.
    private func fleetLine(_ dash: DashVM) -> String {
        guard !dash.amsUnits.isEmpty else { return "No filament hub reporting" }
        let units = dash.amsUnits.count
        let loaded = dash.ams.filter { !$0.empty }.count
        let label = PrinterProfile.forPrinter(model.printer).amsLabel
        return "\(label) · \(units) unit\(units == 1 ? "" : "s") · \(loaded) of \(dash.ams.count) slots loaded"
    }

    @ViewBuilder
    private func pane(_ dash: DashVM) -> some View {
        switch hw.segment {
        case .filament: filamentPane(dash)
        case .nozzles: nozzlesPane(dash)
        case .service: servicePane
        }
    }

    // MARK: - Filament

    private func filamentPane(_ dash: DashVM) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: m.cardGap) {
                if status == nil {
                    ProgressView().tint(c.accent).frame(maxWidth: .infinity).padding(.top, 40)
                } else if dash.ams.isEmpty {
                    ContentUnavailableView(
                        "No filament hub",
                        systemImage: "shippingbox",
                        description: Text("This printer isn’t reporting an AMS. If one is attached, "
                                          + "check it’s powered and connected to the printer.")
                    )
                    .padding(.top, 40)
                } else {
                    slotGrid(dash)
                    dryingCards(dash.amsUnits)
                }
            }
        }
        // `safeAreaPadding`, not `padding` on the content: it insets what you read while leaving the
        // scroll indicator against the window edge, which is where a Mac scroller belongs.
        .safeAreaPadding(.horizontal, m.gutter)
        .safeAreaPadding(.vertical, m.gutter)
    }

    /// The prototype draws exactly four cards in one row, because it mocks a four-tray AMS Lite. The
    /// owner's H2C reports **nine** trays across three units, so the grid is adaptive: four across at
    /// the design width, wrapping rather than squeezing nine unreadable cards onto one line.
    private func slotGrid(_ dash: DashVM) -> some View {
        // Hoisted out of the `ForEach`: reading `model.vm.amsUnits` inside the closure re-presented
        // the whole dashboard twice per card.
        let units = dash.amsUnits
        let multiUnit = units.count > 1
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 208), spacing: m.cardGap)],
            spacing: m.cardGap
        ) {
            ForEach(dash.ams) { slot in
                MacSlotCard(
                    model: model,
                    slot: slot,
                    spool: hw.spool(for: slot, status: status),
                    // The HT is a single-spool unit whose id IS its tray id; Bambuddy documents
                    // ams/load for tray ids 0-15 only, so it cannot be loaded from here.
                    isHt: units.first { $0.id == slot.unitId }?.kind == .ht,
                    multiUnit: multiUnit,
                    remainPct: remainPct(for: slot),
                    locked: locked
                )
            }
        }
    }

    /// The tray's own remaining percentage, or nil when the printer does not know it.
    ///
    /// Read from the raw tray rather than parsed back out of `AmsSlotVM.pct` (a display string), and
    /// nil rather than 0 for the -1 the printer reports for a spool with no RFID — a bar sitting at
    /// empty is a claim, and "we don't know" is not that claim.
    private func remainPct(for slot: AmsSlotVM) -> Double? {
        let raw = status?.ams?
            .first { $0.id == slot.unitId }?
            .tray?.first { $0.id == slot.localId }?
            .remain?.double
        guard let raw, raw.isFinite, raw >= 0 else { return nil }
        return min(raw, 100)
    }

    // MARK: Drying

    /// Running cycles first (they have a countdown and a Stop), then the units that are actually
    /// damp, then the damp units that cannot do anything about it, then one quiet row each for the
    /// units that are dry and for the units that have not said.
    ///
    /// iOS learnt the shape of this the expensive way: three units meant three identical "Dry damp
    /// spools right in the AMS" cards pushing the actual filament off the screen. The Mac keeps the
    /// capability without the noise — a unit that is dry gets a line, not a card.
    @ViewBuilder
    private func dryingCards(_ units: [AmsUnitVM]) -> some View {
        let all = Dryer.present(status)
        let active = all.filter(\.active)
        let idle = all.filter { !$0.active }
        let damp = idle.filter { MacDryingCopy.dampness(humidityPct: $0.humidityPct) == .damp }
        let dry = idle.filter { MacDryingCopy.dampness(humidityPct: $0.humidityPct) == .dry }
        let unread = idle.filter { MacDryingCopy.dampness(humidityPct: $0.humidityPct) == .unknown }
        let stranded = MacDryingCopy.dampWithoutDryer(units, dryers: all)

        ForEach(active) { d in activeDryerCard(d, units) }
        ForEach(damp) { d in dampDryerCard(d, units) }
        if !stranded.isEmpty { noDryerCard(stranded: stranded, dryers: all, units: units) }
        if !dry.isEmpty { idleDryerRow(dry, units: units, reading: .known) }
        if !unread.isEmpty { idleDryerRow(unread, units: units, reading: .unknown) }
    }

    private func unitLabel(_ amsId: Int, in units: [AmsUnitVM]) -> String {
        units.first { $0.id == amsId }?.label ?? "AMS"
    }

    private func activeDryerCard(_ d: DryerVM, _ units: [AmsUnitVM]) -> some View {
        HStack(spacing: 14) {
            PulseDot(color: c.heating, size: 9)
            VStack(alignment: .leading, spacing: 5) {
                // A String, not a literal with interpolation: `d.filament` is the printer's own text
                // and a literal `Text` is a `LocalizedStringKey`, which SwiftUI parses as Markdown.
                Text(activeDryerTitle(d, units))
                    .font(.system(size: m.cardTitle, weight: .semibold))
                    .foregroundStyle(c.t1)
                Text(activeDryerDetail(d))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(c.t2)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            Text(d.remainingText)
                .font(.mono(17, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(c.t1)
            Text("left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(c.t3)
            Button(action: locked.press(.dryStop) { confirmStop = d }) {
                Text("Stop")
            }
            .buttonStyle(MacSecondaryButtonStyle())
            // Only this unit's own stop disables it — a start on another unit is not this button's
            // business, which is what one shared `busyDryer` slot made it.
            .disabled(stopping.contains(d.amsId))
            .locked(.dryStop, by: locked)
            .help(locked.blocked(.dryStop) ? Lan.blockedHint : "Ends the current drying cycle")
        }
        .padding(m.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.heatingDim))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.heating))
    }

    private func activeDryerTitle(_ d: DryerVM, _ units: [AmsUnitVM]) -> String {
        "Drying \(d.filament.isEmpty ? "filament" : d.filament) · \(unitLabel(d.amsId, in: units))"
    }

    private func activeDryerDetail(_ d: DryerVM) -> String {
        var parts: [String] = []
        if let stage = d.stage, let target = d.targetTemp {
            parts.append(stage == .heating
                         ? "heating to \(SafeInt.rounded(target)) °C"
                         : "holding \(SafeInt.rounded(target)) °C")
        }
        if let rh = d.humidityPct { parts.append("\(rh) % RH") }
        if let t = d.tempC, t.isFinite { parts.append(String(format: "%.1f °C inside", t)) }
        return parts.isEmpty ? "Cycle running" : parts.joined(separator: "  ·  ")
    }

    /// The prototype's amber humidity card. Every number in it comes from
    /// `HardwareTriage.dryingReason`, and the button below sends exactly the cycle that sentence
    /// promises — see `MacQuickDry`.
    private func dampDryerCard(_ d: DryerVM, _ units: [AmsUnitVM]) -> some View {
        let rh = Double(d.humidityPct ?? 0)
        let busy = startingDrying(d.amsId)
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.heatingDim)
                Circle().stroke(c.heating, lineWidth: 2).frame(width: 11, height: 11)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                Text("\(unitLabel(d.amsId, in: units)) is damp")
                    .font(.system(size: m.cardTitle, weight: .semibold))
                    .foregroundStyle(c.t1)
                Text(HardwareTriage.dryingReason(rh: rh, maxDryTemp: d.maxTemp))
                    .font(.system(size: 11.5))
                    .foregroundStyle(c.t2)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                // Asserted only when the printer says so. "Printing continues while the AMS dries"
                // is true of an AMS 2 Pro and false of hardware that has to stop — the prototype
                // states it unconditionally, which would be a promise the machine might break.
                if status?.supportsDryingWhilePrinting == true {
                    Text("Printing continues while the AMS dries.")
                        .font(.system(size: 11))
                        .foregroundStyle(c.t3)
                }
                // The AMS's own refusals, said out loud. A Start button that looks live while the
                // unit is reporting "plug in the external power adapter" is the exact failure §The
                // recurring bug describes — so the reason is on screen, next to the dimmed control.
                ForEach(d.blockers, id: \.self) { blocker in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                        Text(blocker).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(c.heating)
                }
            }
            Spacer(minLength: 12)

            Button(action: locked.press(.dryStart) { startDrying(d) }) {
                Text(busy ? "Starting…" : "Start drying")
            }
            .buttonStyle(MacPrimaryButtonStyle())
            // `.disabled` for the AMS's own refusals — those are spelled out in the card above, so a
            // dead button is explained. LAN lock is NOT disabled: it stays clickable because the
            // click is what raises the explanation (`LockedActions.press`).
            .disabled(busy || !d.blockers.isEmpty)
            .locked(.dryStart, by: locked)
            .help(dryHelp(d))
        }
        .padding(m.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.heating.opacity(0.45)))
    }

    private func dryHelp(_ d: DryerVM) -> String {
        if locked.blocked(.dryStart) { return Lan.blockedHint }
        if let first = d.blockers.first { return first }
        return "Runs a \(MacQuickDry.hours) h cycle at \(MacQuickDry.temp(ceiling: d.maxTemp)) °C"
    }

    /// Damp, with nothing on this machine that can dry it. No button, because there is no request to
    /// send — and no silence either, because the picker dot and the inspector both point here.
    ///
    /// `dryers` and `units` are passed in rather than recomputed: WHY there is no cycle to offer, and
    /// WHERE the spool could go instead, are two facts about the rest of the machine, and the card
    /// used to answer both by assumption. See `MacDryingCopy.noDryerReason`.
    private func noDryerCard(stranded: [AmsUnitVM], dryers: [DryerVM], units: [AmsUnitVM]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "humidity")
                .font(.system(size: 14))
                .foregroundStyle(c.heating)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(stranded.count == 1
                     ? "\(stranded[0].label) is damp"
                     : "\(stranded.count) units are damp")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(c.t1)
                Text(noDryerReason(stranded: stranded, dryers: dryers, units: units))
                    .font(.system(size: 11))
                    .foregroundStyle(c.t2)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, m.cardPadding)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.heating.opacity(0.45)))
    }

    /// The same threshold the drying copy quotes, and then the part that differs: there is no cycle
    /// to offer. Naming the reading matters — this is the only place the flagged number appears once
    /// the unit has no dryer card to carry it.
    ///
    /// The sentence itself is in `MacDryingCopy` so its two decisions can be tested: *why* there is
    /// no dryer (the printer reports no drying support at all, versus this unit having no heater),
    /// and *where else* the spool could go. This function's job is only to gather the facts those
    /// decisions need — the unit kinds, the printer's own `supportsDrying`, and the labels of the
    /// units that CAN dry.
    private func noDryerReason(stranded: [AmsUnitVM], dryers: [DryerVM], units: [AmsUnitVM]) -> String {
        MacDryingCopy.noDryerReason(
            stranded.map {
                MacDryingCopy.DampUnit(label: $0.label, rh: $0.humidity ?? 0, isHt: $0.kind == .ht)
            },
            cause: MacDryingCopy.noDryerCause(supportsDrying: status?.supportsDrying),
            dryElsewhere: dryers.map { unitLabel($0.amsId, in: units) }
        )
    }

    /// Whether an idle unit's humidity reading is something we have or something we lack.
    private enum IdleReading { case known, unknown }

    /// One line for every dryable unit that is not damp. Drying a dry spool is a legitimate thing to
    /// want, and the Mac has no other entry point for it — hiding the capability entirely because
    /// nothing is wrong would remove it.
    ///
    /// Split by `IdleReading` so the row never says "is dry" about a unit that reported nothing.
    private func idleDryerRow(_ ready: [DryerVM], units: [AmsUnitVM], reading: IdleReading) -> some View {
        HStack(spacing: 12) {
            Image(systemName: reading == .known ? "wind" : "questionmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(c.t2)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(idleTitle(ready, units: units, reading: reading))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(c.t1)
                Text(reading == .known
                     ? "Nothing here needs a cycle. You can still run one."
                     : "No humidity reading, so there’s nothing to judge it on. You can still run a cycle.")
                    .font(.system(size: 11))
                    .foregroundStyle(c.t3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if ready.count == 1 {
                Button(action: locked.press(.dryStart) { startDrying(ready[0]) }) {
                    // "Anyway" is only honest about a unit we KNOW is dry.
                    Text(reading == .known ? "Dry anyway" : "Dry it")
                }
                .buttonStyle(MacSecondaryButtonStyle())
                .disabled(startingDrying(ready[0].amsId) || !ready[0].blockers.isEmpty)
                .locked(.dryStart, by: locked)
                .help(dryHelp(ready[0]))
            } else {
                Menu("Dry a unit…") {
                    ForEach(ready) { d in
                        Button("\(unitLabel(d.amsId, in: units)) — \(MacQuickDry.hours) h at \(MacQuickDry.temp(ceiling: d.maxTemp)) °C") {
                            locked.press(.dryStart) { startDrying(d) }()
                        }
                        .disabled(startingDrying(d.amsId) || !d.blockers.isEmpty)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                // The menu is a drying control like any other, so it dims and explains itself with
                // the rest of them. Without this it was the only one in the section that looked
                // fully live with LAN Developer Mode off.
                .locked(.dryStart, by: locked)
                .help(locked.blocked(.dryStart)
                      ? Lan.blockedHint
                      : "Runs a \(MacQuickDry.hours) h cycle on the unit you pick")
            }
        }
        .padding(.horizontal, m.cardPadding)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.line))
    }

    private func idleTitle(_ ready: [DryerVM], units: [AmsUnitVM], reading: IdleReading) -> String {
        switch (reading, ready.count) {
        case (.known, 1):   return "\(unitLabel(ready[0].amsId, in: units)) is dry"
        case (.known, _):   return "\(ready.count) units are dry"
        case (.unknown, 1): return "\(unitLabel(ready[0].amsId, in: units)) hasn’t reported humidity"
        case (.unknown, _): return "\(ready.count) units haven’t reported humidity"
        }
    }

    // MARK: - Nozzles

    /// A hand-built table rather than a `Table`.
    ///
    /// `Table` is the right Mac idiom for Jobs history — many rows, sortable, selectable. A nozzle
    /// rack is two to six rows that nothing sorts and nothing selects, and the LAST FILAMENT cell is
    /// a colour chip. `Table` would bring its own row backgrounds and header chrome, neither of
    /// which takes the app's palette, for a list that fits on one screen with room to spare. Fixed
    /// column widths give the alignment, which is the part of "a table" this actually needs.
    private func nozzlesPane(_ dash: DashVM) -> some View {
        ScrollView {
            let rows = nozzleRows(dash)
            // Three states, because "the printer hasn't told us yet" is not "there is nothing to
            // swap". Without the first branch the pane asserted an absence it had not established,
            // every time, for as long as the connection took — and then described a nozzle changer
            // the machine may not even have.
            if status == nil {
                ProgressView().tint(c.accent).frame(maxWidth: .infinity).padding(.top, 40)
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No nozzle details",
                    systemImage: "circle.hexagongrid",
                    description: Text("This printer hasn’t reported what’s fitted — neither a nozzle "
                                      + "rack nor a diameter. Machines with a changer list every "
                                      + "docked nozzle here.")
                )
                .padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    nozzleGrid(rows)
                    // Only when there IS a changer: on a fixed head "the rest are docked" describes
                    // hardware the machine does not have.
                    if rows.contains(where: \.swappable) {
                        Text("Engaged is in the head now; the rest are docked. Colour chips show each "
                             + "nozzle's last filament — not what is loaded right now.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(c.t3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(c.bg)
                    }
                }
                .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
                .clipShape(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.line))
            }
        }
        .safeAreaPadding(.horizontal, m.gutter)
        .safeAreaPadding(.vertical, m.gutter)
    }

    /// Column widths, not `Grid`.
    ///
    /// `Grid` looks like the obvious fit and is a trap here: a modifier applied to a `GridRow` is
    /// applied to every CELL, so the row background and the row padding would be drawn five times
    /// with gaps between them. Explicit widths give the same alignment and let a row be one view.
    private enum NozzleColumn {
        static let diameter: CGFloat = 92
        static let material: CGFloat = 132
        static let state: CGFloat = 96
        static let minToolhead: CGFloat = 108
        static let minFilament: CGFloat = 130
    }

    private func nozzleGrid(_ rows: [MacNozzleRow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                columnHead("TOOLHEAD")
                    .frame(minWidth: NozzleColumn.minToolhead, maxWidth: .infinity, alignment: .leading)
                columnHead("DIAMETER").frame(width: NozzleColumn.diameter, alignment: .leading)
                columnHead("MATERIAL").frame(width: NozzleColumn.material, alignment: .leading)
                columnHead("LAST FILAMENT")
                    .frame(minWidth: NozzleColumn.minFilament, maxWidth: .infinity, alignment: .leading)
                columnHead("STATE").frame(width: NozzleColumn.state, alignment: .trailing)
            }
            .padding(.horizontal, 15)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(c.s2)

            Rectangle().fill(c.line).frame(height: 1)

            ForEach(Array(rows.enumerated()), id: \.element.id) { pair in
                if pair.offset > 0 { Rectangle().fill(c.line).frame(height: 1) }
                nozzleRow(pair.element)
            }
        }
    }

    private func columnHead(_ text: String) -> some View {
        Text(text)
            .font(.mono(m.monoLabel, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(c.t3)
    }

    private func nozzleRow(_ r: MacNozzleRow) -> some View {
        let state = nozzleState(r)
        return HStack(spacing: 12) {
            HStack(spacing: 7) {
                Text(r.toolhead)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(c.t1)
                // Flow rate is a first-class spec on the H2 series: a high-flow and a standard
                // nozzle of the same diameter print very differently, so it is not folded into
                // MATERIAL. Gated on the decoded FACT, never on the display string — comparing
                // against "High flow" meant rewording the label silently deleted the chip.
                if r.highFlow {
                    chip("HIGH FLOW", ink: c.heating, fill: c.heatingDim)
                }
            }
            .frame(minWidth: NozzleColumn.minToolhead, maxWidth: .infinity, alignment: .leading)

            Text(r.diameter.isEmpty ? "—" : r.diameter)
                .font(.mono(11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(c.t2)
                .frame(width: NozzleColumn.diameter, alignment: .leading)

            Text(r.material.isEmpty ? "—" : r.material)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(c.t2)
                .frame(width: NozzleColumn.material, alignment: .leading)

            HStack(spacing: 7) {
                Swatch(value: r.filamentHex, size: 14, radius: Metrics.swatchRadius(14), empty: r.filamentHex == nil)
                Text(r.filamentType ?? (r.filamentHex == nil ? "None recorded" : "Unnamed"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(c.t2)
                    .lineLimit(1)
            }
            .frame(minWidth: NozzleColumn.minFilament, maxWidth: .infinity, alignment: .leading)

            Text(state.label)
                .font(.mono(10, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(state.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: m.chipRadius, style: .continuous).fill(state.fill))
                .frame(width: NozzleColumn.state, alignment: .trailing)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .frame(minHeight: m.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(r.serial.isEmpty ? "This nozzle has no RFID chip" : "Serial …\(r.serial)")
    }

    /// ENGAGED/DOCKED only mean something on a toolhead with a changer. On a fixed head the honest
    /// pair is ACTIVE/FITTED — calling a soldered-in nozzle "docked" would describe a rack that does
    /// not exist.
    private func nozzleState(_ r: MacNozzleRow) -> (label: String, ink: Color, fill: Color) {
        if r.swappable {
            return r.engaged ? ("ENGAGED", c.accent, c.accentDim) : ("DOCKED", c.idle, c.idleDim)
        }
        return r.activeToolhead ? ("ACTIVE", c.accent, c.accentDim) : ("FITTED", c.idle, c.idleDim)
    }

    private func chip(_ text: String, ink: Color, fill: Color) -> some View {
        Text(text)
            .font(.mono(8, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: m.chipRadius, style: .continuous).fill(fill))
    }

    // MARK: - Service

    private var servicePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                switch hw.maint {
                case .loading:
                    ProgressView().tint(c.accent).frame(maxWidth: .infinity).padding(.top, 40)
                case .failed:
                    maintFailedCard
                case .loaded:
                    serviceList
                }
            }
            // After "Mark done" the list re-sorts (the done item sinks below the due ones) — the
            // spring makes the row visibly glide to its new slot instead of teleporting.
            .animation(.spring(response: 0.47, dampingFraction: 0.67), value: hw.serviceItems.map(\.id))
        }
        .safeAreaPadding(.horizontal, m.gutter)
        .safeAreaPadding(.vertical, m.gutter)
    }

    /// The root fix landed, so the workaround is gone.
    ///
    /// This used to carry a third sentence and an "eye.slash" note listing what it was NOT showing,
    /// because `serviceItems` filtered `enabled ?? false` while `HardwareTriage` counted
    /// `enabled != false` — so an item Bambuddy returned with no `enabled` field produced a red dot,
    /// a "1 thing needs you" row, and an empty pane. Saying that out loud was the honest thing to do
    /// while the predicates disagreed; making them agree is better than describing the disagreement.
    /// Both now read "tracked unless explicitly switched off", so `listed` is the whole set and an
    /// empty `listed` genuinely means there are no reminders.
    @ViewBuilder
    private var serviceList: some View {
        let listed = hw.serviceItems
        let untracked = hw.maintenanceItems.filter { $0.enabled == false }

        if listed.isEmpty && untracked.isEmpty {
            ContentUnavailableView(
                "No reminders set up",
                systemImage: "wrench.and.screwdriver",
                description: Text("Add service intervals in Bambuddy (Settings → "
                                  + "Maintenance) and they’ll track here as you print.")
            )
            .padding(.top, 40)
        } else {
            ForEach(listed) { item in serviceRow(item) }
            if !untracked.isEmpty {
                noteRow("eye.slash", untrackedReason(untracked, listed: listed.count))
            }
            // "Mark done" needs admin rights on Bambuddy — but `hasAdminLogin` answers "are admin
            // credentials configured in this app", which is a NEARBY question to "will Bambuddy
            // refuse this". A scoped-admin API key succeeds with no admin login at all (that is the
            // owner's own setup), so this must NOT disable the button: it states the requirement and
            // lets the request answer the rest. `adminSend` already rewrites the 403 into the same
            // instruction, so the two agree.
            if model.client?.hasAdminLogin != true {
                noteRow("key", "Marking an item done is an admin action on Bambuddy. If your API "
                             + "key isn’t admin-scoped, add the admin username and password in "
                             + "Settings → Edit.")
            }
        }
    }

    /// A quiet footnote under the list: something the pane cannot do, or cannot show.
    private func noteRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(c.t3)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, m.cardPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.line))
    }

    /// Why the pane is not listing reminders the printer does have — and, for the ones whose
    /// on/off state Bambuddy never reported, that the inspector's count includes them anyway.
    private func untrackedReason(_ untracked: [MaintenanceItem], listed: Int) -> String {
        let off = untracked.filter { $0.enabled == false }.count
        let unstated = untracked.count - off
        var parts: [String] = []
        if off > 0 { parts.append("\(off) switched off in Bambuddy") }
        if unstated > 0 {
            parts.append("\(unstated) Bambuddy didn’t report an on/off state for, which the summary "
                         + "in the inspector still counts")
        }
        let lead = listed > 0
            ? "\(untracked.count) more \(untracked.count == 1 ? "reminder isn’t" : "reminders aren’t") listed here"
            : "This printer has \(untracked.count) \(untracked.count == 1 ? "reminder" : "reminders"), and none are listed here"
        return lead + ": " + parts.joined(separator: "; ") + "."
    }

    /// "Couldn't load maintenance" and "this printer has no reminders set up" are different
    /// sentences, and `MaintLoad` keeps them apart so the section can say both.
    private var maintFailedCard: some View {
        HStack(spacing: 12) {
            Text("Couldn’t load maintenance.")
                .font(.system(size: m.body, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") { Task { await hw.reloadMaintenance() } }
                .buttonStyle(MacSecondaryButtonStyle())
        }
        .padding(m.cardPadding)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.line))
    }

    private func serviceRow(_ item: MaintenanceItem) -> some View {
        let urgency = serviceUrgency(item)
        let busy = hw.maintBusy == item.id
        return HStack(spacing: 14) {
            Circle().fill(urgency.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.maintenanceTypeName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(c.t1)
                Text(serviceDetail(item))
                    .font(.system(size: 11))
                    .foregroundStyle(urgency.urgent ? urgency.color : c.t3)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            Text(intervalText(item))
                .font(.mono(11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(c.t3)
            // Not LAN-gated: marking an item done is Bambuddy-side bookkeeping in its own database
            // and the printer is never asked. It IS admin-gated, which the client handles by routing
            // through the JWT transport — see `adminNote`.
            Button { confirmDone = item } label: {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Mark done")
                }
            }
            .buttonStyle(MacSecondaryButtonStyle())
            .disabled(busy)
            .help(model.client?.hasAdminLogin == true
                  ? "Resets this reminder’s counter in Bambuddy"
                  : "Resets this reminder’s counter in Bambuddy. Needs admin rights on the server.")
        }
        .padding(.horizontal, m.cardPadding)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(
            RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
                .stroke(urgency.urgent ? urgency.color : c.line, lineWidth: urgency.urgent ? 1.5 : 1)
        )
        .contextMenu {
            // Also gated on `busy`: without it the menu is a second door to the same request while
            // the first is still in flight, and `markDone` has no reentrancy guard of its own.
            Button("Mark done") { confirmDone = item }.disabled(busy)
        }
    }

    /// The item's scheduling interval in hours, or nil when it has none Bambuddy can count from.
    ///
    /// One predicate, read by both the row and the confirmation, because they were disagreeing: the
    /// row rendered "no interval" (guarding `> 0`) while the alert one tap later said "Next reminder
    /// in 0 h of printing" (`SafeInt.rounded(nil)` is 0) — the exact reading the row's guard exists
    /// to avoid.
    private func intervalHours(_ item: MaintenanceItem) -> Double? {
        guard let raw = item.intervalHours?.double, raw.isFinite, raw > 0 else { return nil }
        return raw
    }

    /// "every 50 h" — or nothing at all. An item with no interval renders "every 0 h" otherwise,
    /// which reads as a reminder that fires continuously rather than as a missing field.
    private func intervalText(_ item: MaintenanceItem) -> String {
        guard let hours = intervalHours(item) else { return "no interval" }
        return "every \(SafeInt.rounded(hours)) h"
    }

    private func markDoneMessage(_ item: MaintenanceItem) -> String {
        guard let hours = intervalHours(item) else {
            return "This resets its counter. It has no interval set, so nothing schedules the next one."
        }
        return "This resets its counter. Next reminder in \(SafeInt.rounded(hours)) h of printing."
    }

    private func serviceUrgency(_ item: MaintenanceItem) -> (color: Color, urgent: Bool) {
        if item.isDue ?? false { return (c.error, true) }
        if item.isWarning ?? false { return (c.heating, true) }
        return (c.idle, false)
    }

    /// The prototype's second line: "Overdue by 14 h of printing" / "Due in 6 h of printing".
    ///
    /// `hoursUntilDue < 0` is the overdue test rather than `isDue`, for the same reason
    /// `HardwareTriage` uses it: `isDue` goes true the moment the interval elapses, while a NEGATIVE
    /// remaining figure is the one that can be stated as "overdue by N hours".
    private func serviceDetail(_ item: MaintenanceItem) -> String {
        guard let raw = item.hoursUntilDue?.double, raw.isFinite else {
            return item.isDue ?? false ? "Due now" : "No due date reported"
        }
        if raw < 0 { return "Overdue by \(SafeInt.rounded(-raw)) h of printing" }
        if item.isDue ?? false { return "Due now" }
        if raw >= 1 { return "Due in \(SafeInt.rounded(raw)) h of printing" }
        return "Due in \(max(0, SafeInt.rounded(raw * 60))) min of printing"
    }

    // MARK: - Commands

    private func startDrying(_ d: DryerVM) {
        guard let client = model.client else { return }
        let printerId = model.printerId
        let amsId = d.amsId
        let temp = MacQuickDry.temp(ceiling: d.maxTemp)
        let hours = MacQuickDry.hours
        // A second press on the same unit supersedes the first. That keeps ONE invariant true, and
        // `dryRun` leans on it: a run loses its slot in `dryRuns` only by being cancelled, so a run
        // that has NOT been cancelled may safely clear the slot when it finishes. (The old code
        // cleared unconditionally after its sleep, which threw away the newer run's handle — after
        // which a Stop had nothing left to cancel.)
        dryRuns[amsId]?.cancel()
        dryRuns[amsId] = Task {
            await dryRun(client: client, printerId: printerId, amsId: amsId, temp: temp, hours: hours)
        }
    }

    private func stopDrying(_ d: DryerVM) {
        guard let client = model.client else { return }
        let printerId = model.printerId
        let amsId = d.amsId
        // A stop supersedes a start we have not finished checking on — **including one whose request
        // is still in flight**. That is the whole reason the run is stored before the request goes
        // out: cancelling only what had already come back left the nine-second verdict running, and
        // it then reported that the cycle the user had just cancelled never began.
        dryRuns[amsId]?.cancel()
        dryRuns[amsId] = nil
        stopping.insert(amsId)
        Task {
            do { try await client.dryingStop(printerId, amsId: amsId) } catch {
                model.toast = .failure("Stop drying failed — \(macHwDetail(error))")
            }
            stopping.remove(amsId)
        }
    }

    /// Drop every start we are still checking on, spinner included.
    private func cancelDryRuns() {
        for run in dryRuns.values { run.cancel() }
        dryRuns.removeAll()
    }

    /// One press of Start, from the request through to the verdict.
    ///
    /// Bambuddy answers 200 as soon as the MQTT command is SENT — the printer can still refuse it
    /// (observed live: `result:'failed', reason:'mqtt message verify failed'` with LAN Developer Mode
    /// off) and nothing would ever surface it. So after `dryVerifyDelay` seconds this asks the printer
    /// whether a cycle exists.
    ///
    /// If the cycle DID start, the unit moves to the active list and the card is replaced, which is
    /// exactly right: there is then nothing to warn about.
    ///
    /// What that establishes is "the AMS has still not reported a cycle", NOT "the printer rejected
    /// the command" — a slow AMS reports the same way a refused one does. `MacDryingCopy` says the
    /// first and offers the second as a cause only where it is still possible.
    ///
    /// **The verdict goes to `model.toast`, not to an alert on this view.** An alert bound to this
    /// view's `@State` dies with the view, so pressing Start and hitting ⌘2 within nine seconds threw
    /// the printer's refusal away silently — the one message this whole check exists to produce.
    /// `MacRoot` renders the toast above every section, so it survives leaving Hardware. The cost is
    /// real (a five-second banner for two sentences nobody asked for, rather than a dismissible
    /// alert) and it is the right trade: a message the user might miss beats one they cannot receive.
    private func dryRun(client: BambuddyClient, printerId: Int, amsId: Int, temp: Int, hours: Int) async {
        do {
            // `filament: nil` on purpose. This button dries the UNIT at the generic cycle the reason
            // line quotes; naming one of several loaded spools would make Bambuddy record a claim the
            // user never made.
            try await client.dryingStart(printerId, amsId: amsId, temp: temp, hours: hours,
                                         filament: nil, rotate: true)
        } catch {
            // Cancelled ⇒ a Stop (or a second Start) superseded this press and now owns the slot. The
            // "failure" is that cancellation, and reporting it would be reporting the user's own
            // click back to them.
            guard !Task.isCancelled else { return }
            dryRuns[amsId] = nil
            model.toast = .failure("Start drying failed — \(macHwDetail(error))")
            return
        }
        // The run stays in `dryRuns` across the wait on purpose: HTTP 200 means "the command was
        // published", not "the cycle began", so the button keeps saying "Starting…" instead of
        // becoming re-pressable during exactly the seconds we are waiting to find out.
        try? await Task.sleep(for: .seconds(Self.dryVerifyDelay))
        guard !Task.isCancelled else { return }
        // Status fetch failed — can't verify; stay quiet rather than cry wolf. The spinner still has
        // to clear, so the slot is released either way.
        let unit = (try? await client.getStatus(printerId))?.ams?.first { $0.id == amsId }
        guard !Task.isCancelled else { return }
        dryRuns[amsId] = nil
        guard let unit else { return }
        // dryTime (minutes remaining) > 0 is THE active signal; dryStatus is unreliable.
        guard !((unit.dryTime?.double ?? 0) > 0) else { return }
        model.toast = .failure(MacDryingCopy.notStarted(afterSeconds: Self.dryVerifyDelay, lanMode: model.lanMode))
    }

    /// How long to wait before asking whether the cycle actually began. Quoted verbatim in the
    /// message, so the number the user reads and the number we waited cannot drift apart.
    private static let dryVerifyDelay = 9

    /// The fetch, the busy flag and the re-sort all live in `HardwareStore`; only the message is the
    /// screen's, and it goes where every other command failure on Mac goes.
    private func markDone(_ item: MaintenanceItem) {
        Task {
            if let message = await hw.markDone(item) {
                model.toast = .failure("Mark done failed — \(message)")
            }
        }
    }
}

// MARK: - Slot card

/// One AMS tray: what is in it, how much is left, and load/unload.
@MainActor
private struct MacSlotCard: View {
    let model: AppModel
    let slot: AmsSlotVM
    let spool: Spool?
    let isHt: Bool
    let multiUnit: Bool
    /// nil when the printer does not report a level for this tray (a spool with no RFID reports -1).
    let remainPct: Double?
    let locked: LockedActions

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Swatch(value: swatch, size: 30, radius: Metrics.swatchRadius(30), empty: slot.empty)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(slot.active ? c.accent : c.t3)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(slotName)
                    .font(.mono(m.monoLabel, weight: .medium))
                    .foregroundStyle(c.t3)
                    .fixedSize()
            }

            levelBar.padding(.top, 12)

            action.padding(.top, 10)
        }
        .padding(m.cardPadding)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(
            RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
                .stroke(slot.active ? c.accent : c.line, lineWidth: slot.active ? 1.5 : 1)
        )
    }

    // MARK: Composition

    private var swatch: String? {
        spool.flatMap { FilamentColor.norm($0.rgba) } ?? slot.color
    }

    /// Composed by `FilamentIdentity` rather than here: a vendor's own colour name always wins over
    /// one computed from hex. Recomputing it is how a brown spool got labelled "Orange".
    private var title: String {
        if slot.empty, spool == nil { return "Empty slot" }
        return FilamentIdentity.resolve(
            colorHex: swatch,
            spoolColorName: spool?.colorName,
            // The spool's material is the better answer when inventory knows the tray; `slot.label`
            // is the tray's own word for it.
            material: spool?.material ?? slot.label,
            product: spool?.slicerFilamentName
        ).line
    }

    private var subtitle: String {
        guard !slot.empty else { return "no spool detected" }
        var parts: [String] = []
        if slot.active { parts.append("printing now") }
        // Which nozzle THIS spool feeds. With a Filament Track Switch fitted the unit no longer has
        // a fixed extruder, so the per-slot answer is the only true one.
        let side = AmsTopology.extruderSide(slot.extruder)
        if !side.isEmpty { parts.append("→ \(side)") }
        if let remainPct {
            parts.append("\(SafeInt.rounded(remainPct)) %")
        } else if let spool, let label = spool.labelWeight?.double, label > 0 {
            parts.append("\(SafeInt.rounded(spool.gramsRemaining)) g left")
        } else {
            // Never "0 %": the printer reports -1 for a spool it cannot read, and painting that as
            // empty is a claim about filament that may well be full.
            parts.append("level unknown")
        }
        return parts.joined(separator: " · ")
    }

    /// The level, or an honest gap where it would be.
    ///
    /// A `HeatBar` at `remainPct ?? 0` draws exactly the bar the subtitle above it refuses to write:
    /// a track sitting at empty is a claim about a spool that may well be full. With no reading
    /// there is no fill at all — a dashed rule instead, which reads as "no data" rather than "none
    /// left".
    @ViewBuilder
    private var levelBar: some View {
        if let remainPct {
            HeatBar(
                pct: remainPct,
                heating: false,
                color: slot.active ? c.accent : (slot.empty ? c.s3 : c.idle),
                track: c.s3,
                height: 5
            )
        } else {
            Capsule()
                .strokeBorder(c.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 5)
                .accessibilityLabel("Level unknown")
        }
    }

    /// The LOCATION always leads: "Slot 1" is ambiguous once a second unit is fitted.
    private var slotName: String {
        multiUnit ? "\(slot.unitLabel) · \(slot.localId + 1)" : "Slot \(slot.localId + 1)"
    }

    // MARK: Action

    @ViewBuilder
    private var action: some View {
        if !slot.empty {
            Button(action: locked.press(.amsUnload) {
                model.perform("Unload") { client, id in
                    try await client.amsUnload(id)
                }
            }) {
                Text(unloadLabel).frame(maxWidth: .infinity)
            }
            .buttonStyle(MacSecondaryButtonStyle())
            .locked(.amsUnload, by: locked)
            .help(locked.blocked(.amsUnload) ? Lan.blockedHint : unloadHelp)
        } else if isHt {
            // Say it rather than hide it. Bambuddy documents `ams/load` for tray ids 0-15 only, and
            // the HT's id IS its tray id (128+), so there is no request to send — a Load button here
            // would be a control that cannot work.
            Text("Loads from the unit itself — the HT isn’t addressable from here.")
                .font(.system(size: 10.5))
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: m.primaryControlHeight, alignment: .center)
        } else {
            Button(action: locked.press(.amsLoad) {
                // GLOBAL tray id, not the flat index — index 4 is the HT, whose id is 128.
                let trayId = slot.globalId
                model.perform("Load") { client, id in
                    try await client.amsLoad(id, trayId: trayId)
                }
            }) {
                Text("Load filament").frame(maxWidth: .infinity)
            }
            .buttonStyle(MacSecondaryButtonStyle())
            .locked(.amsLoad, by: locked)
            .help(locked.blocked(.amsLoad) ? Lan.blockedHint : "Feed this tray to the toolhead")
        }
    }

    /// `amsUnload` takes a printer id and **no tray id** — it retracts whatever is in the toolhead.
    /// Nine loaded trays therefore render nine buttons that all do the same one thing, and eight of
    /// them are not about the spool on their own card. "This tray is loaded" and "this tray is in
    /// the toolhead" are two questions; `slot.active` answers the second, so the card that owns the
    /// filament being retracted says "Unload" and the others say what they actually do.
    private var unloadLabel: String { slot.active ? "Unload" : "Unload toolhead" }

    private var unloadHelp: String {
        slot.active
            ? "Retract this spool from the toolhead"
            : "Retracts whatever is in the toolhead — the AMS has no per-tray unload, so this is "
              + "probably not this spool"
    }
}

// MARK: - Nozzle rack

/// One row of the Nozzles table.
struct MacNozzleRow: Identifiable, Hashable, Sendable {
    var id: String
    /// "Left" | "Right" | "Nozzle".
    var toolhead: String
    var diameter: String
    /// The nozzle's METAL — "Hardened", "Stainless". Never a bare unknown code.
    var material: String
    /// The decoded FACT, not a label: the H2 code's middle letter is "H". False when the code
    /// carries no flow information at all (the A1's long-form names), which is also when no chip
    /// should be drawn — so callers ask this rather than comparing display copy.
    var highFlow: Bool
    /// Per-nozzle filament MEMORY (the last filament run through it), not what is loaded now.
    var filamentHex: String?
    var filamentType: String?
    /// Last 4 of the RFID serial; "" for chipless nozzles.
    var serial: String
    /// This nozzle's toolhead has a changer, so ENGAGED/DOCKED is a meaningful distinction.
    var swappable: Bool
    var engaged: Bool
    /// This toolhead is the extruder currently doing the work.
    var activeToolhead: Bool
}

/// Nozzles as a flat table, following Bambu Studio's own parser (`DevNozzleSystemParser::ParseV2_0`):
///  - rack `id` < 16  ⇒ the nozzle CURRENTLY INSTALLED on extruder `id` (0 = RIGHT/main, 1 = LEFT);
///  - rack `id` >= 16 ⇒ a nozzle DOCKED in the changer ("vortex"), which belongs to the MAIN
///    (right, ext 0) extruder — Studio attaches rack nozzles only there.
///  - An engaged nozzle's home dock simply DISAPPEARS from the list.
///  - `filamentColor` is per-nozzle filament memory, so several docked nozzles legitimately carry
///    one; `wear`/`stat` mark neither engagement nor emptiness. Chipless nozzles report serial "N/A"
///    but are REAL — the H2C's left fixed 0.4 is exactly that, so "N/A" must not be filtered out.
///
/// **This duplicates `NozzlePresenter` in `Views/AmsView.swift`**, which is `private` and compiled
/// for iOS only. The fix is hoisting that presenter into `Domain/`, which is outside this pass's
/// files — reported rather than done. Until then, changes to nozzle-code decoding have to land in
/// both places. Two of them are already deliberate divergences worth back-porting: `fromRack`'s
/// nothing-engaged case below, and `isHighFlow` (iOS drives its chip off the display string).
enum MacNozzleRack {
    /// "Has the printer said anything at all about its nozzles?"
    ///
    /// Read from the raw payload rather than by running `rows`. Those are NEARBY questions — "did
    /// the printer report nozzles" versus "did the presenter produce rows from them" — and the only
    /// caller (`HardwareTriage.items`, via `MacHardwareTriage`) discards the answer entirely today
    /// (`_ = nozzlesKnown`), so parsing the whole rack to produce it was pure cost: once per render
    /// in the section and three times per render in the inspector.
    ///
    /// `MacPrinterInspector` passes `!(status?.nozzles ?? []).isEmpty` for the same parameter, which
    /// misses the H2's rack entirely — harmless only while the argument is unused. **Reported.**
    static func reported(_ status: PrinterStatus?) -> Bool {
        !(status?.nozzleRack ?? []).isEmpty || !(status?.nozzles ?? []).isEmpty
    }

    static func rows(_ status: PrinterStatus?, dash: DashVM) -> [MacNozzleRow] {
        guard let status else { return [] }
        let rack = status.nozzleRack ?? []
        if !rack.isEmpty { return fromRack(rack, activeExtruder: status.activeExtruder?.int) }
        return fromSpec(status, dash: dash)
    }

    private static func fromRack(_ rack: [NozzleRackSlot], activeExtruder: Int?) -> [MacNozzleRow] {
        let installed = rack.filter { $0.id < 16 }      // on-extruder: the id IS the extruder id
        let docked = rack.filter { $0.id >= 16 }

        var exts: [Int] = []
        for r in installed where !exts.contains(r.id) { exts.append(r.id) }
        exts.sort(by: >)                                // descending ⇒ LEFT (1) displayed first
        let dual = exts.count > 1

        var out: [MacNozzleRow] = []
        for ext in exts {
            let label = dual ? (ext == 0 ? "Right" : "Left") : "Nozzle"
            let swappable = ext == 0 && !docked.isEmpty
            let active = activeExtruder == ext
            for r in installed where r.id == ext {
                out.append(row(r, toolhead: label, swappable: swappable, engaged: true, active: active))
            }
            if ext == 0 {
                for r in docked {
                    out.append(row(r, toolhead: label, swappable: true, engaged: false, active: active))
                }
            }
        }
        // A rack with nothing engaged reports docked slots and no id < 16 at all. Attaching them to
        // no toolhead would render "Nothing to swap" on a machine that just listed four nozzles —
        // the iOS presenter drops them, which is a bug worth back-porting rather than copying.
        if !docked.isEmpty, !exts.contains(0) {
            for r in docked {
                out.append(row(r, toolhead: dual ? "Right" : "Nozzle", swappable: true,
                               engaged: false, active: activeExtruder == 0))
            }
        }
        return out
    }

    /// No rack (A1 etc.): one non-swappable toolhead per mounted nozzle, spec from `status.nozzles`.
    ///
    /// `dash.nozzles` is TEMPERATURE-ordered (index 0 = `nozzle` = LEFT) while the `nozzles` spec
    /// array is EXTRUDER-ordered (index 0 = extruder 0 = RIGHT) — hence the `1 - i` cross-map,
    /// without which the diameters swap sides on a dual.
    private static func fromSpec(_ status: PrinterStatus, dash: DashVM) -> [MacNozzleRow] {
        let info = status.nozzles ?? []
        let dual = dash.nozzles.count > 1
        return dash.nozzles.enumerated().compactMap { pair -> MacNozzleRow? in
            let i = pair.offset
            let spec = dual ? info[safe: 1 - i] : info[safe: i]
            let diameter = dia(Double(spec?.nozzleDiameter ?? ""))
            let material = typeLabel(spec?.nozzleType)
            guard !diameter.isEmpty || !material.isEmpty else { return nil }
            return MacNozzleRow(
                id: "m\(i)",
                toolhead: dual ? (i == 0 ? "Left" : "Right") : "Nozzle",
                diameter: diameter,
                material: material,
                highFlow: isHighFlow(spec?.nozzleType),
                filamentHex: nil,
                filamentType: nil,
                serial: "",
                swappable: false,
                engaged: pair.element.active,
                activeToolhead: pair.element.active
            )
        }
    }

    private static func row(_ r: NozzleRackSlot, toolhead: String, swappable: Bool,
                            engaged: Bool, active: Bool) -> MacNozzleRow {
        let color = r.filamentColor ?? ""
        let known = !color.isEmpty && color != "00000000"
        let serial = r.serialNumber ?? ""
        let chipless = serial.isEmpty || serial == "N/A"
        let type = r.filamentType ?? ""
        return MacNozzleRow(
            id: "\(toolhead)-\(r.id)",
            toolhead: toolhead,
            diameter: dia(r.nozzleDiameter?.double),
            material: typeLabel(r.nozzleType),
            highFlow: isHighFlow(r.nozzleType),
            filamentHex: known ? FilamentColor.norm(color) : nil,
            filamentType: type.isEmpty ? nil : type,
            serial: chipless ? "" : String(serial.suffix(4)),
            swappable: swappable,
            engaged: engaged,
            activeToolhead: active
        )
    }

    /// H2-series nozzle codes are structured, not opaque: "H" + flow letter + a two-digit MATERIAL id
    /// (HS01 and HH01 are both 0.4 mm / 350 °C and differ only in the middle letter, which pins that
    /// letter as flow). Decoding the halves independently means a nozzle Bambu ships tomorrow still
    /// reports its flow correctly instead of falling back to a raw code.
    private static let material: [String: String] = [
        "00": "Stainless", "01": "Hardened", "05": "Tungsten Carbide",
    ]

    /// Long-form codes some machines (A1) report instead of the H2 short codes.
    private static let longForm: [String: String] = [
        "hardened_steel": "Hardened",
        "stainless_steel": "Stainless",
        "tungsten_carbide": "Tungsten Carbide",
        "hardened_tungsten": "Hardened Tungsten",
    ]

    private static func h2Code(_ t: String?) -> (flow: Character, material: String)? {
        guard let t, t.count == 4, t.hasPrefix("H") else { return nil }
        let chars = Array(t)
        guard chars[1] == "S" || chars[1] == "H" else { return nil }
        guard chars[2].isNumber, chars[3].isNumber else { return nil }
        return (chars[1], String(chars[2...3]))
    }

    /// The MATERIAL only — flow is reported separately so the two facts can be shown in their own
    /// columns. Never returns a bare unknown token: a raw `HS02` next to rows reading "Hardened"
    /// reads like a material name, so an undecodable code becomes "Type HS02".
    static func typeLabel(_ t: String?) -> String {
        guard let t, !t.isEmpty else { return "" }
        if let code = h2Code(t) {
            return material[code.material] ?? "Type \(t)"   // known shape, unknown material
        }
        if let known = longForm[t] { return known }
        if t.contains("_") {
            return t.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
        return "Type \(t)"
    }

    /// Is this a high-flow nozzle? False when the code carries no flow information at all (the A1's
    /// long-form names), which is the same answer the UI wants: no chip.
    ///
    /// The predicate the chip needs, rather than `flowLabel(t) == "High flow"`. Those are two
    /// questions — "what does this nozzle do" and "what word did we choose for it" — and the chip
    /// was asking the second, so rewording the label would have silently deleted the chip from every
    /// high-flow row.
    static func isHighFlow(_ t: String?) -> Bool {
        h2Code(t)?.flow == "H"
    }

    /// "0.4 mm". `%g` keeps the printer's own precision without inventing decimals (1 stays "1").
    static func dia(_ d: Double?) -> String {
        guard let d, d.isFinite else { return "" }
        return String(format: "%g mm", d)
    }
}

// MARK: - Scaffolding

/// The one cycle the Mac's Start button runs.
///
/// `HardwareTriage.dryingReason` formats the sentence "A 6 h cycle at min(55, ceiling) °C fixes it",
/// and this button has to send exactly that — a control that starts a different cycle from the
/// sentence directly above it is the recurring bug in miniature. The pair belongs in
/// `HardwareTriage`, next to the copy that quotes it; it lives here because `Domain/` is not this
/// pass's to edit. **Reported.**
private enum MacQuickDry {
    static let hours = 6
    static func temp(ceiling: Int) -> Int { min(55, ceiling) }
}

// MARK: - Drying copy

/// The sentences the drying UI says, and the decisions behind them — out of the view so the
/// decisions can be tested without a window.
///
/// Each one of these used to be composed inline from a predicate that answered a NEARBY question:
///
/// - **"Why is there no dryer here?"** was never asked at all. The stranded-unit card advised moving
///   the spool "to a unit that can heat (AMS 2 Pro or HT)" without consulting the unit's `kind` or
///   the printer's own `supportsDrying` — so an AMS HT on a printer that reports no drying support
///   was told to move its spool into an AMS HT, and a machine whose ONLY units are heaterless was
///   told to move it somewhere that does not exist.
/// - **"Did the printer refuse the command?"** is not what a status read nine seconds later
///   establishes. What it establishes is "the AMS has still not reported a cycle".
/// - **"Is this unit dry?"** is not "did this unit report a humidity reading?" — hence three answers
///   from `dampness`, not a Bool.
enum MacDryingCopy {

    // MARK: Dampness

    /// What a unit's humidity reading says — including "it hasn't said".
    enum Dampness: Hashable, Sendable { case damp, dry, unknown }

    /// Three answers, because a single `isDamp` Bool conflated two questions: "is this unit above the
    /// threshold?" and "did this unit report a reading at all?". `!isDamp` was answering the first
    /// for units that had never answered the second, which is how a unit with no hygrometer reading
    /// rendered "AMS 1 is dry · Nothing here needs a cycle" — the same claim-from-missing-data the
    /// slot subtitle refuses ("never 0 %"), and the same one the inspector refuses when it prints "—"
    /// for this very reading.
    ///
    /// 0 counts as unknown deliberately: an AMS that has not taken a reading publishes 0, and
    /// `MacHardwareInspector.humidityText` already treats `> 0` as the known test.
    ///
    /// The threshold is `HardwareTriage.dampRH`, the same constant the reason line quotes. A local
    /// number here would let the card say "38 % is above the 30 % you'd want" while appearing at 45.
    static func dampness(humidityPct: Int?) -> Dampness {
        guard let rh = humidityPct, rh > 0 else { return .unknown }
        return Double(rh) >= HardwareTriage.dampRH ? .damp : .dry
    }

    /// The units that are damp and have **no dryer at all**.
    ///
    /// Two predicates for what looks like one question. "Is this unit damp?" is answered from
    /// `DashVM.amsUnits`, which is every attached unit — and that is what raises the amber dot on the
    /// picker and the "AMS 1 at 38 % RH — Filament ›" row in the inspector. "Can this unit dry
    /// itself?" is answered by `Dryer.present`, which returns nothing at all unless the printer
    /// reports `supportsDrying` and the unit has a heater. Every drying card used to come from the
    /// second, so an AMS Lite at 38 % RH lit a warning that pointed at a pane which then said nothing
    /// whatsoever about it. This is the missing sentence's input, and it says the honest thing: the
    /// reading is real, and there is no control here that can fix it.
    static func dampWithoutDryer(_ units: [AmsUnitVM], dryers: [DryerVM]) -> [AmsUnitVM] {
        let dryable = Set(dryers.map(\.amsId))
        return units.filter { unit in
            guard !dryable.contains(unit.id) else { return false }
            guard let rh = unit.humidity, rh.isFinite, rh > 0 else { return false }
            return rh >= HardwareTriage.dampRH
        }
    }

    // MARK: No dryer

    /// One damp unit, reduced to what the copy needs. `isHt` is `AmsUnitVM.kind == .ht`, which is the
    /// fact the advice turned out to hinge on and the one the old sentence never read.
    struct DampUnit: Hashable, Sendable {
        var label: String
        var rh: Double
        var isHt: Bool
    }

    /// WHY a damp unit has no drying control. Two different absences that read identically on screen
    /// and have opposite remedies.
    enum NoDryerCause: Hashable, Sendable {
        /// The printer does not report drying support, so `Dryer.present` returns nothing for ANY
        /// unit — heated ones included. Moving the spool to another unit cannot help, because no unit
        /// on this machine has a cycle to offer.
        case printerReportsNoDrying
        /// The printer can dry, and this unit is not one of the units it can dry.
        case unitHasNoHeater
    }

    /// Mirrors `Dryer.present`'s own printer-level gate (`status.supportsDrying == true`), because
    /// that gate is the reason the unit is missing from its output. `supportsDrying` is `Bool?`, and
    /// `nil` is not `false` — a printer that never reports the field strands every unit it has,
    /// which is exactly the case the old copy mis-described.
    ///
    /// It belongs beside that gate in `Domain/Dryer.swift`, which is not this pass's to edit —
    /// **reported**. Until then, changing the gate means changing this too.
    static func noDryerCause(supportsDrying: Bool?) -> NoDryerCause {
        supportsDrying == true ? .unitHasNoHeater : .printerReportsNoDrying
    }

    /// The reading, the threshold, and then the part that differs from every other drying card: there
    /// is no cycle to start, and what to do instead.
    ///
    /// `dryElsewhere` is the labels of the units that CAN dry — the affordance the advice needs, not
    /// a guess about what hardware the owner might have. With none, the sentence does not offer a
    /// move it cannot deliver.
    static func noDryerReason(_ damp: [DampUnit], cause: NoDryerCause, dryElsewhere: [String]) -> String {
        guard !damp.isEmpty else { return "" }
        let readings = damp
            .map { "\($0.label) at \(SafeInt.rounded($0.rh)) % RH" }
            .joined(separator: ", ")
        let lead = "\(readings) — above the \(Int(HardwareTriage.dampRH)) % you’d want for PETG. "

        switch cause {
        case .printerReportsNoDrying:
            // Note what is NOT said: nothing about moving the spool. On this branch no unit on the
            // machine has a cycle to offer, so every "move it to…" would be a dead end — and an HT is
            // in this branch precisely because the printer is silent, not because it lacks a heater.
            let heater = damp.contains(where: \.isHt)
                ? ", even though an AMS HT has a heater built in"
                : ""
            return lead
                + "This printer isn’t reporting drying support, so there’s no cycle to start from "
                + "here\(heater). Dry the spool in a standalone filament dryer, or start a cycle on "
                + "the printer’s own screen."
        case .unitHasNoHeater:
            return lead + subject(damp) + ", so there’s no cycle to start here. " + remedy(dryElsewhere)
        }
    }

    /// What is missing, said without claiming more than the unit kind supports. An AMS HT always has
    /// a heater, so "this unit has no dryer" is a statement about the HARDWARE that would be false —
    /// what is true is that the printer is not reporting a dryer for it.
    private static func subject(_ damp: [DampUnit]) -> String {
        let plural = damp.count > 1
        if damp.allSatisfy(\.isHt) {
            return plural
                ? "The printer isn’t reporting a dryer for these units, though an AMS HT has one built in"
                : "The printer isn’t reporting a dryer for this unit, though an AMS HT has one built in"
        }
        if damp.contains(where: \.isHt) {
            // Mixed kinds, so necessarily more than one unit: neither sentence above is true of all
            // of them, and the one thing that is true of all of them is the printer's silence.
            return "The printer isn’t reporting a dryer for these units"
        }
        return plural ? "These units have no dryer" : "This unit has no dryer"
    }

    private static func remedy(_ dryElsewhere: [String]) -> String {
        guard !dryElsewhere.isEmpty else {
            return "Dry the spool in a standalone filament dryer — no other unit on this printer can "
                 + "heat either."
        }
        return "Dry the spool in a standalone filament dryer, or move it to \(list(dryElsewhere)), "
             + "which can heat."
    }

    /// "AMS 2", "AMS 2 or AMS HT", "AMS 1, AMS 2 or AMS HT".
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
    }

    // MARK: The inspector's one-line reading

    /// "Drying · 5h 44m", "Idle", "Not supported" — or "Not reported", which is the case the fourth
    /// answer exists for.
    ///
    /// Two nearby questions, both of which this line got wrong in turn. `dryingMinLeft == 0` answers
    /// "is a cycle running?", not "does this unit have a dryer?", so an AMS Lite read as "Idle" —
    /// describing a heater it does not contain. Falling back to `Dryer.present` fixed that and
    /// introduced the mirror image: `Dryer.present` is empty for EVERY unit when the printer does not
    /// report `supportsDrying`, so an AMS HT — a unit that is nothing but a dryer — read as "Not
    /// supported". "This unit has no heater" and "this printer hasn't said" are two claims, and only
    /// the second is available when the field is missing.
    static func dryerLine(_ dryer: DryerVM?, cause: NoDryerCause) -> String {
        if let dryer { return dryer.active ? "Drying · \(dryer.remainingText)" : "Idle" }
        switch cause {
        case .unitHasNoHeater: return "Not supported"
        case .printerReportsNoDrying: return "Not reported"
        }
    }

    /// The tooltip under that reading — the room the reading itself does not have.
    static func dryerNote(_ dryer: DryerVM?, cause: NoDryerCause) -> String {
        if let dryer {
            return dryer.active
                ? "A drying cycle is running on this unit."
                : "This unit has a dryer and isn’t using it. Start a cycle in the Filament pane."
        }
        switch cause {
        case .unitHasNoHeater:
            return "This printer can dry, but not this unit — it has no heater."
        case .printerReportsNoDrying:
            return "This printer isn’t reporting drying support, so no unit shows a cycle here — "
                 + "including one with a heater of its own."
        }
    }

    // MARK: Verification

    /// The one message here that is not a reply to a click: it arrives `afterSeconds` later,
    /// unrequested.
    ///
    /// It states what was OBSERVED first, then offers a cause only where that cause is still
    /// possible. `.dryStart` is in `Lan.blocked`, so `LockedActions.press` intercepts the click
    /// entirely when `lanMode == .off` — which means this can only be reached with LAN mode `.on` or
    /// `.unknown`. Telling someone whose printer has just reported Developer Mode ON to go and switch
    /// it on is advice the app already knows is wrong: the recurring bug wearing a helpful voice.
    static func notStarted(afterSeconds: Int, lanMode: LanMode) -> String {
        let observed = "Drying hasn’t started — \(afterSeconds) seconds after the command the AMS "
                     + "still reports no cycle."
        switch lanMode {
        case .on:
            return observed + " The printer may have refused it; check its screen, then try again."
        case .off, .unknown:
            return observed + " If the printer refused it, that is usually LAN Developer Mode: on "
                 + "the printer’s screen, Settings → Network → Developer Mode."
        }
    }
}

/// Bambuddy's own message ("AMS is busy" from a 409), not the transport noise around it.
private func macHwDetail(_ error: Error) -> String {
    (error as? BambuddyError)?.detail ?? error.localizedDescription
}
#endif
