#if os(macOS)
import SwiftUI

/// The **Printer** inspector (§4, prototype `1a` lines 508–551): camera tile → triage card → the
/// current job's facts → recent prints.
///
/// **The camera leaves the content column.** That is the single biggest change from iOS, and it is
/// the inspector's rule made concrete: content is the thing, and the inspector is what is LIVE about
/// it. Nothing here navigates except the triage card's one deliberate hand-off to Hardware, which is
/// the card's entire purpose.
///
/// …with one qualification, learnt from the running app: §1 auto-hides this whole column below
/// 1180 pt, so "the camera lives here" also meant "a window narrowed by a few points has no camera".
/// The tile is therefore `MacPrinterCameraTile`, a view the Printer **section** can render too, and
/// `MacCameraPlacement` says which of the two owns it. This file no longer decides anything about
/// the camera beyond asking for the tile.
///
/// Everything is derived from `DashVM` and the app's stores. Nothing here fetches: the archive cards
/// read `model.jobs`, whose poll `MacSectionContent` owns for the whole Printer section, and Snapshot
/// saves the frame the tile has already decoded rather than asking the server for another.
struct MacPrinterInspector: View {
    let model: AppModel

    /// Spelled out because `selection` below is a `private` stored property with a default, which
    /// makes the synthesised memberwise initialiser private too — `MacInspectorContent` builds this
    /// view with only `model`.
    init(model: AppModel) {
        self.model = model
    }

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// Where the triage card's hand-off writes. See `MacSectionSelection` — a bare `@FocusedValue`
    /// reads nil the instant the camera window this inspector just opened becomes key.
    private var selection = MacSectionSelection()

    private var vm: DashVM { model.vm }
    private var status: PrinterStatus? { model.status?.status }
    private var caption: CGFloat { MacPrinterType.caption(m) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: m.cardGap) {
                header
                // The same tile the section falls back to when this column is hidden — one view, so
                // the two surfaces cannot drift apart in behaviour or in copy. It asks
                // `MacCameraPlacement` whether it may stream; being rendered is not the permission.
                MacPrinterCameraTile(model: model, surface: .inspector)
                triageCard
                jobCard
                recentCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .background(c.bg)
        .onChange(of: selection.ownsFocus, initial: true) { _, _ in selection.latch() }
    }

    private var header: some View {
        HStack {
            MacPrinterMonoLabel("PRINTER")
            Spacer(minLength: 0)
            Text(verbatim: "⌥⌘I")
                .font(.mono(m.monoLabel + 1, weight: .medium))
                .foregroundStyle(c.t3)
        }
        .padding(.bottom, 2)
    }

    // MARK: - Triage

    /// What the printer is complaining about right now.
    private var alerts: [AlertVM] {
        Alerts.present(
            status,
            caps: AlertCaps(connected: vm.kind != .offline, canControl: true, model: model.printer?.model)
        )
    }

    /// What the machine's hardware wants doing. `HardwareStore` already holds the maintenance load,
    /// and `maintenanceItems` is `[]` while it is loading or after a failure — the card counts
    /// problems it can prove, so an unknown state reads as "nothing to say", never "nothing wrong".
    /// Through `MacHardwareTriage`, the one the Hardware section uses — NOT a second call to
    /// `HardwareTriage.items` with its own arguments.
    ///
    /// This built its own, answering `nozzlesKnown` with `!(status?.nozzles ?? []).isEmpty`. That
    /// misses the H2's nozzle RACK, where the machine reports its nozzles somewhere else entirely —
    /// so this card could say the nozzles were unknown about a printer that had just reported them,
    /// while the Hardware section one click away said the opposite. Two callers, two answers, one
    /// question.
    private var triage: [HardwareTriage.Item] {
        MacHardwareTriage.items(model, dash: vm)
    }

    /// The iOS dashboard's maintenance chip AND its alert chip, merged into the one card §4 puts
    /// here — but NOT merged into one count. "2 alerts" and "2 things need you" are answers to
    /// different questions, and adding them would produce a number nothing on screen can explain.
    @ViewBuilder
    private var triageCard: some View {
        let alertList = alerts
        let items = triage
        let headline = HardwareTriage.headline(items)

        if !alertList.isEmpty || headline != nil {
            let tone = MacPrinterCopy.triageTone(alertList)
            // `Palette`'s own dim tokens, not `tint.opacity(0.10)`. The `*Dim` colours are tuned per
            // scheme — light mode does not use dark mode's alphas — so a computed opacity is a
            // different colour from the one every other tinted card on the platform draws, including
            // the section's own `lanBanner` six inches to the left.
            MacPrinterCard(padding: 13, fill: tone.dim(c), stroke: tone.solid(c)) {
                VStack(alignment: .leading, spacing: 9) {
                    // Up to three, then a count. A 320 pt column that lists nine HMS notices is a
                    // wall nobody reads.
                    ForEach(alertList.prefix(3)) { alertRow($0) }
                    if alertList.count > 3 {
                        Text(verbatim: "+ \(alertList.count - 3) more")
                            .font(.system(size: caption, weight: .medium))
                            .foregroundStyle(c.t3)
                    }

                    // The way into `MacAlertsSheet`, which had NO raiser at all: `model.showAlerts`
                    // was never assigned true anywhere in the app, so a 280-line sheet written
                    // precisely because "the Mac build showed alert text read-only and
                    // AlertVM.actions were unreachable" could not be opened.
                    //
                    // A 320 pt column cannot carry an alert's actions, which is why they live in the
                    // sheet — and one of them, "Look it up", is the ONLY route to Bambu's page for a
                    // fault code anywhere in the Mac app.
                    if !alertList.isEmpty {
                        MacSectionLink(title: "What can I do?", canNavigate: true) {
                            model.showAlerts = true
                        }
                    }

                    if let headline {
                        if !alertList.isEmpty { Divider().overlay(c.line) }
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Circle().fill(c.heating).frame(width: 7, height: 7)
                                Text(headline)
                                    .font(.system(size: m.cardTitle, weight: .semibold))
                                    .foregroundStyle(c.t1)
                            }
                            Text(verbatim: HardwareTriage.detail(items))
                                .font(.system(size: caption))
                                .foregroundStyle(c.t2)
                                .fixedSize(horizontal: false, vertical: true)
                            MacSectionLink(
                                title: "Open Hardware",
                                canNavigate: selection.canNavigate
                            ) {
                                // Land on the segment that raised the loudest item, exactly as the
                                // iOS chip does — the same `HardwareTriage.Segment` the store's
                                // selection uses, so there is no mapping to disagree with.
                                if let first = items.first { model.hardware.segment = first.segment }
                                selection.go(to: .ams)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Display only. The actions an `AlertVM` carries (resume, stop, plate cleared) are all offered by
    /// the hero card six inches to the left — including "Plate cleared", which is now shown whenever
    /// the plate needs confirming rather than only on a `.complete` machine, so this card can no
    /// longer state that the queue is blocked with nothing on screen able to unblock it. `.lookup`
    /// needs a browser hand-off that belongs to a dedicated alerts surface, which macOS does not have
    /// yet; a button here that did nothing would be worse than the sentence it replaced.
    private func alertRow(_ alert: AlertVM) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Per-ALERT level, not the card's tint: the card is coloured by the worst one, and a
            // warning sitting under an error must not borrow the error's red.
            Circle()
                .fill(MacPrinterCopy.alertTone(alert.level).solid(c))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(alert.title)
                        .font(.system(size: m.cardTitle, weight: .semibold))
                        .foregroundStyle(c.t1)
                    if let code = alert.code {
                        Text(code)
                            .font(.mono(m.monoLabel, weight: .medium))
                            .foregroundStyle(c.t3)
                            .textSelection(.enabled)   // the code is what you paste into a search
                    }
                }
                Text(alert.detail)
                    .font(.system(size: caption))
                    .foregroundStyle(c.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - This job

    /// One label/value line. `mono` marks the ticking and measured values, which take tabular figures
    /// so the column stops jittering once a second.
    private struct Fact: Identifiable {
        let label: String
        let value: String
        var mono = false
        var id: String { label }
    }

    /// This printer's archive rows, and whether the server named a printer on any of them.
    private var archive: (rows: [PrintLogEntry], unattributed: Bool) {
        MacPrinterCopy.printerArchive(model.jobs.entries, printerId: model.printerId)
    }

    /// The archive row behind what is on screen.
    ///
    /// While a print runs, `currentArchiveId` names it exactly — and an exact id needs no attribution
    /// filter, because it came from THIS printer's own status. Otherwise fall back to the newest row
    /// this printer ran, which is what "LAST JOB" means.
    private var jobEntry: PrintLogEntry? {
        if let hit = namedJobEntry { return hit }
        return archive.rows.first
    }

    /// The row `currentArchiveId` names outright, if it is loaded. Separate because a NAMED row needs
    /// no attribution — it came from this printer's own status — while a picked one does.
    private var namedJobEntry: PrintLogEntry? {
        guard let archiveId = vm.reprintArchiveId else { return nil }
        return (model.jobs.entries ?? []).first { $0.archiveId == archiveId }
    }

    /// True when the row on the job card was PICKED rather than named, out of an archive that records
    /// no printer at all — so "LAST JOB" is the server's last job, not provably this machine's.
    private var jobEntryUnattributed: Bool {
        archive.unattributed && namedJobEntry == nil && jobEntry != nil
    }

    private var jobCard: some View {
        let live = vm.kind == .live
        let facts = live ? liveFacts : finishedFacts
        // Four states, not two. `JobsStore.loadHistory` answers a failed fetch with `entries = []`
        // plus `historyFailed`, so "the archive didn't load" and "an archive with nothing in it" are
        // the SAME value — and rendering the failure as "Nothing has been printed on this machine
        // yet" turned a transport error into a confident claim about the machine's whole history.
        let empty = MacPrinterCopy.archiveEmpty(
            entries: model.jobs.entries,
            failed: model.jobs.historyFailed,
            matched: jobEntry != nil
        )
        return MacPrinterCard(padding: 13) {
            VStack(alignment: .leading, spacing: 11) {
                MacPrinterMonoLabel(live ? "THIS JOB" : "LAST JOB")
                if facts.isEmpty, let empty {
                    Text(empty)
                        .font(.system(size: caption))
                        .foregroundStyle(c.t3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(facts) { factRow($0) }
                    }
                    if jobEntryUnattributed {
                        unattributedNote("The archive doesn’t record which printer ran this.")
                    }
                }
            }
        }
    }

    /// Said, not silently assumed. `MacPrinterCopy.printerArchive` falls back to the whole archive
    /// when the server names no printer on any row, because hiding every print would be its own lie —
    /// but those rows are then not KNOWN to be this machine's, and neither card may imply they are.
    private func unattributedNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: caption))
            .foregroundStyle(c.t3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func factRow(_ fact: Fact) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(fact.label)
                .font(.system(size: caption, weight: .medium))
                .foregroundStyle(c.t3)
            Spacer(minLength: 8)
            Text(fact.value)
                .font(fact.mono ? .mono(caption, weight: .medium)
                                : .system(size: caption, weight: .medium))
                .foregroundStyle(c.t1)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// What is knowable about a RUNNING print, and nothing else.
    ///
    /// The prototype lists "Filament used" and "Energy so far"; neither exists mid-print. The status
    /// payload carries no gram count, and `PlugPoller.kwh` is the plug's total for TODAY, not this
    /// job's — labelling it "Energy so far" would be a number that is wrong by however much else ran
    /// today.
    ///
    /// **"Power now" is not here either, and that is the fix rather than an omission.** `if let watts`
    /// answers "has the plug ever reported", not "is it reporting now" — two questions, and only the
    /// second one entitles a row to the word *now*. `MacSectionContent` runs `PowerStore` only while
    /// the Power section is on screen, and `PowerStore.stop()` cancels the pollers without clearing
    /// `hero.watts`, so one visit to Power left this printing that frozen reading, labelled "now",
    /// for the rest of the session. Nothing on the Printer section is entitled to a live wattage
    /// until `PowerStore` can say whether a reading is current; the Power section, one click away,
    /// polls it properly.
    private var liveFacts: [Fact] {
        var out: [Fact] = []
        if let started = startedAt {
            out.append(Fact(label: "Started", value: Dash.fmtClock(started), mono: true))
            let minutes = Date().timeIntervalSince(started) / 60
            if minutes > 0 {
                out.append(Fact(label: "Elapsed", value: Dash.fmtDuration(minutes), mono: true))
            }
        }
        if vm.totalLayers != "0" {
            out.append(Fact(label: "Layer", value: "\(vm.layer) / \(vm.totalLayers)", mono: true))
        }
        out.append(Fact(label: "Time left", value: vm.etaText, mono: true))
        out.append(Fact(label: "Done", value: vm.doneText, mono: true))
        out.append(Fact(label: "Speed", value: vm.speedLabel))
        if let active = vm.ams.first(where: { $0.active }) {
            out.append(Fact(label: "Filament", value: "\(active.label) · \(active.unitLabel)"))
        }
        return out
    }

    /// A finished job's facts come from the archive row, where the totals genuinely exist.
    private var finishedFacts: [Fact] {
        guard let entry = jobEntry else { return [] }
        var out: [Fact] = []
        out.append(Fact(label: "Job", value: JobsStore.historyName(entry)))
        out.append(Fact(label: "Result", value: entry.status.capitalized))
        if let finished = entry.completedAt ?? entry.startedAt {
            out.append(Fact(label: "Finished", value: PrintTime.relative(finished), mono: true))
        }
        if let seconds = entry.durationSeconds?.double, seconds > 0 {
            out.append(Fact(label: "Duration", value: Dash.fmtDuration(seconds / 60), mono: true))
        }
        if let grams = entry.filamentUsedGrams?.double, grams > 0 {
            out.append(Fact(label: "Filament used", value: "\(Int(grams.rounded())) g", mono: true))
        }
        if let kwh = entry.energyKwh?.double, kwh > 0 {
            out.append(Fact(label: "Energy", value: String(format: "%.2f kWh", kwh), mono: true))
        }
        if let cost = entry.cost?.double, cost > 0 {
            out.append(Fact(label: "Cost", value: Money.format(model.jobs.currencySymbol, cost), mono: true))
        }
        return out
    }

    /// When the running print began, from its archive row. Bambuddy writes naive LOCAL timestamps, and
    /// `PrintTime.parse` is the one place that knows it.
    private var startedAt: Date? {
        guard vm.kind == .live,
              let archiveId = vm.reprintArchiveId,
              let entry = (model.jobs.entries ?? []).first(where: { $0.archiveId == archiveId }),
              let iso = entry.startedAt else { return nil }
        return PrintTime.parse(iso)
    }

    // MARK: - Recent

    /// The prototype's `RECENT` is an event feed — bed levelling, filament engaged. The printer
    /// publishes no such stream and Bambuddy stores none, so this shows the thing that IS recorded:
    /// the last few prints on this machine. Inventing an event log would be the more faithful mock
    /// and the less honest screen.
    private var recentCard: some View {
        let found = archive
        let rows = Array(found.rows.prefix(4))
        let empty = MacPrinterCopy.archiveEmpty(
            entries: model.jobs.entries,
            failed: model.jobs.historyFailed,
            matched: !rows.isEmpty
        )
        return MacPrinterCard(padding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                MacPrinterMonoLabel("RECENT PRINTS")
                if let empty {
                    Text(empty)
                        .font(.system(size: caption))
                        .foregroundStyle(c.t3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(MacPrinterCopy.resultTone(entry.status).solid(c))
                                    .frame(width: 6, height: 6)
                                Text(JobsStore.historyName(entry))
                                    .font(.system(size: caption, weight: .medium))
                                    .foregroundStyle(c.t2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(PrintTime.relative(entry.completedAt ?? entry.startedAt))
                                    .font(.mono(m.monoLabel + 1, weight: .medium))
                                    .foregroundStyle(c.t3)
                                    .monospacedDigit()
                            }
                        }
                    }
                    if found.unattributed {
                        unattributedNote("The archive doesn’t record which printer ran these.")
                    }
                }
            }
        }
    }

}
#endif
