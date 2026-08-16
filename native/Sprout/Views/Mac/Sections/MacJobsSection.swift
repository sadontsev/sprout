#if os(macOS)
import SwiftUI

// MARK: - Where the selection lives

/// The Jobs selection key, and why it is a named constant rather than a string in two files.
///
/// `MacJobsSection` and `MacJobsInspector` are SIBLINGS — both are constructed by
/// `MacSectionContent`, which this pass does not own — so there is no parent to hold the selection
/// in `@State` and no binding to thread down. Scene storage is the one channel between them: same
/// scene, same key, both directions, and it survives a relaunch so the window reopens on the run you
/// were reading.
///
/// **The key is a persisted format**, exactly like `TabKey`'s raw values, `mac.section` and
/// `MacFilesSelection` — renaming it silently resets the user's selection instead of failing. Two
/// literal copies of it, one per file, made that a rename away from silently unlinking the two
/// columns; one constant cannot drift.
enum MacJobsSelection {
    /// The selected archived run, as the print-log entry's `id`.
    static let run = "mac.jobs.selected"
}

// MARK: - Section

/// The Jobs section (§4, prototype `1a` · Jobs).
///
/// Top-to-bottom the same story the iOS tab tells — what is printing NOW, what is UP NEXT, then the
/// archive — but the archive is a real `Table`: sortable columns, one selected row, and the
/// selection drives the inspector rather than pushing anything. That is the single most Mac-shaped
/// thing in the port, and it is why the history half is not a `ForEach` of cards.
///
/// Every fetch lives in `JobsStore`. This file is layout, selection and presentation plumbing only,
/// and deliberately holds no `@State` that a store already owns. The only modal it raises is a
/// confirmation for an irreversible action; every command OUTCOME goes to `model.toast`, which
/// `MacRoot` renders — the rule `MacHardwareSection` states and Printer, Power and Files follow.
///
/// **The three blocks are three views on purpose.** `model.vm` is recomputed from the live status
/// store, so any body that reads it re-evaluates on every status frame. While all three blocks were
/// one `body`, that dragged the History projection with it — 50 `PrintLogEntry`s through
/// `PrintTime.parse`, `Date.formatted`, `Money.format` and a URL build, three times per pass,
/// several times a second. Split, each block re-renders on its own data: the strip on status frames,
/// UP NEXT on the 5 s queue poll, HISTORY on the 15 s archive poll. `MacPrinterSection` records the
/// same hazard for its thumbnail.
struct MacJobsSection: View {
    let model: AppModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: m.sectionGap) {
            MacJobsTopStrip(model: model)
            MacJobsUpNext(model: model)
            MacJobsHistory(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(m.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(c.bg)
        // NO `.task { store.start() }` here, and no `.onAppear` either: `MacSectionContent` starts
        // and stops `JobsStore` with one `.task(id: section)` for whichever section is on screen.
        //
        // What used to stand here was a comment asserting that this section deliberately started
        // nothing because "the window keeps every section mounted" and "`AppModel` starts the
        // store's own loops on connect". Both were false — `MacSectionContent`'s body is a
        // ViewBuilder switch, so exactly one section exists at a time, and `AppModel` has no
        // `startStores()` by design — and between them NOTHING on macOS ever started this store.
        // UP NEXT, HISTORY and LIFETIME PRINTS each sat on their placeholder forever.
    }
}

// MARK: - Now printing + lifetime

/// Two cards side by side. `fixedSize(vertical:)` makes the row as tall as the taller card's ideal
/// height and no taller; each card's own `maxHeight: .infinity` then fills that, so the two
/// backgrounds line up instead of one floating short.
private struct MacJobsTopStrip: View {
    let model: AppModel

    @Environment(\.metrics) private var m

    var body: some View {
        HStack(alignment: .top, spacing: m.cardGap) {
            MacJobsNowPrinting(model: model)
            MacJobsLifetime(store: model.jobs)
                // The prototype's 190 pt, rounded up so a five-figure lifetime count still fits
                // beside its success percentage. Not a Metrics token: this is one card's width, not
                // a density decision.
                .frame(width: 200)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The live card. The ONLY view in this section that reads `model.vm`, so a status frame invalidates
/// this and nothing else.
private struct MacJobsNowPrinting: View {
    let model: AppModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// NEVER re-derived from `status.state` — `DashVM` is the single classifier, and a strip that
    /// disagreed with the toolbar pill six inches above it would be exactly that bug.
    private var vm: DashVM { model.vm }

    var body: some View {
        HStack(spacing: 14) {
            // A neutral well with the brand mark, NOT a thumbnail. The prototype draws an image here
            // and live status has no thumbnail URL to draw: `QueueItem.libraryFileThumbnail` /
            // `archiveThumbnail` are raw paths with no documented base and no stated token, and
            // nothing in the app builds a URL from them. Guessing one would render a broken tile on
            // every print — an affordance resting on a capability nobody checked.
            //
            // `controlRadius`, not `cardRadius`: the scale's middle step covers fixed-size media
            // wells in the 28–64 pt band as well as clickable controls, and this and the 32 pt
            // queue-row well below both sit in it.
            RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous)
                .fill(c.thumb)
                .frame(width: 52, height: 52)
                .overlay {
                    Image("TabNozzle")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20)
                        .foregroundStyle(c.t3)
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if vm.kind == .live {
                        PulseDot(color: c.running, size: 6, period: 2)
                    } else {
                        Circle().fill(stateColor).frame(width: 6, height: 6)
                    }
                    Text(verbatim: vm.kind == .live ? "NOW PRINTING" : vm.stateLabel.uppercased())
                        .font(.mono(m.monoLabel, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(stateColor)
                }
                Text(verbatim: headline)
                    .font(.system(size: m.cardTitle, weight: .semibold))
                    .foregroundStyle(c.t1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 7)
                if vm.kind == .live {
                    progressBar
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if vm.kind == .live {
                VStack(alignment: .trailing, spacing: 5) {
                    Text(verbatim: vm.etaText)
                        .font(.mono(m.screenTitle, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(c.t1)
                    Text("left")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(c.t3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(m.cardPadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        // The live card is the one thing on this screen that outlines itself in its state colour;
        // idle and offline keep the ordinary hairline so the green means something.
        .overlay(
            RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
                .strokeBorder(vm.kind == .live ? c.running.opacity(0.3) : c.line, lineWidth: 1)
        )
    }

    private var stateColor: Color { vm.stateColor.resolve(c) }

    /// The subtask name while printing; otherwise a line that says what this machine is doing, so
    /// the strip is never an empty box with a dot in it.
    private var headline: String {
        if vm.kind == .live { return vm.heroSub.isEmpty ? "Current print" : vm.heroSub }
        switch vm.kind {
        case .idle: return "Nothing printing — queued jobs start automatically."
        case .complete: return "Print finished. Clear the plate to release the queue."
        case .offline: return "Printer offline — the queue below is Bambuddy's, not the machine's."
        case .error: return "The printer reported an error."
        default: return "Connecting…"
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            Capsule()
                .fill(c.s3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(c.running)
                        .frame(width: geo.size.width * min(max(Double(vm.progressInt) / 100, 0), 1))
                }
        }
        .frame(height: 5)
        .animation(Motion.standard(0.7), value: vm.progressInt)
        .accessibilityHidden(true)
    }
}

/// The lifetime figures. Reads the archive stats and nothing else.
private struct MacJobsLifetime: View {
    let store: JobsStore

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LIFETIME PRINTS")
                .font(.mono(m.monoLabel, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(c.t3)

            switch MacJobsLifetimeBody.of(
                stats: store.stats,
                statsAsked: store.statsAsked,
                statsFailed: store.statsFailed,
                entries: store.entries,
                historyFailed: store.historyFailed
            ) {
            case .figures(let stats):
                figures(stats)
            case .loading:
                note("Loading…")
            case .empty:
                // Not a wall of zeroes: a fresh install has no archive, and "0 prints · 0.0 h"
                // reads as a broken fetch rather than an empty one.
                note("No prints archived yet")
            case .unavailable(let why):
                // The headline is the same either way — no number can be shown — but the reason is
                // not, and one sentence for both cases asserted the wrong one half the time.
                note("Lifetime totals unavailable")
                    .help(why.help)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(m.cardPadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line))
    }

    private func figures(_ stats: ArchiveStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                RollingNumber(
                    value: stats.totalPrints ?? 0,
                    font: .mono(m.heroMetric, weight: .bold),
                    color: c.t1
                )
                Text(verbatim: MacJobStats.successText(stats))
                    .font(.system(size: 12, weight: .semibold))
                    // Ticks as prints finish, so the percentage must not reflow the line beside it.
                    .monospacedDigit()
                    .foregroundStyle(c.running)
            }
            .padding(.top, 10)

            Text(verbatim: MacJobStats.totalsText(stats))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(c.t3)
                .padding(.top, 9)

            if stats.energyDataWarmingUp == true {
                // Says why a cost column can read "—" on a machine that plainly used power.
                Text("Energy data warming up")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(c.t3)
                    .padding(.top, 5)
                    .help("Costs appear after the next full job the smart plug meters end to end.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(c.t3)
            .padding(.top, 10)
    }
}

// MARK: - Up next

private struct MacJobsUpNext: View {
    let model: AppModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    @State private var confirmRemove: QueueItem?

    private var store: JobsStore { model.jobs }

    var body: some View {
        // ONE lane split and ONE state decision per body pass, passed down — the same discipline
        // the History block below keeps for its row projection. Read as computed properties these
        // re-filtered the whole queue four times: the header count, the banner's padding, the
        // content switch and the "queued elsewhere" line.
        //
        // The lane split lives in `JobsStore` because the iOS tab applies exactly the same rule,
        // and "which jobs are mine" is the kind of predicate that goes quietly wrong when it is
        // written twice.
        let upcoming = JobsStore.upNext(store.queue, printerId: model.printerId)
        let elsewhere = JobsStore.queuedElsewhere(store.queue, printerId: model.printerId)
        let state = MacJobsQueueBody.of(
            queue: store.queue,
            failed: store.queueFailed,
            printerId: model.printerId
        )
        return VStack(alignment: .leading, spacing: 0) {
            header(state, count: upcoming.count)
            if store.queueFailed {
                // A failed fetch is NOT an empty queue — the store keeps the last rows and raises
                // this flag, so the banner sits ABOVE whatever is still on screen rather than
                // replacing it with "nothing queued".
                MacJobsRetryCard(text: "Couldn’t reach the server for the queue.") {
                    Task { await store.loadQueue() }
                }
                // Nothing follows the banner when the queue was never answered, so no gap either.
                .padding(.bottom, state == .unknown ? 0 : 8)
            }
            content(state, upcoming: upcoming)
            if !elsewhere.isEmpty {
                let names = JobsStore.otherPrinterNames(elsewhere, printers: model.printers)
                Text(verbatim: "\(elsewhere.count) more \(elsewhere.count == 1 ? "job" : "jobs") queued for \(names.joined(separator: ", ")).")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(c.t3)
                    .padding(.top, 8)
            }
        }
        // The ONE presentation this view raises: a confirmation for an irreversible action, which
        // is what a modal is for. The removal's OUTCOME goes to `model.toast` (see `remove`) —
        // there used to be a second `.alert` for it on this same view, and SwiftUI gives a view one
        // presentation slot, so the two fought over it.
        .alert(
            "Remove from queue?",
            isPresented: macJobsPresented($confirmRemove),
            presenting: confirmRemove
        ) { job in
            Button("Keep", role: .cancel) {}
            Button("Remove", role: .destructive) { remove(job) }
        } message: { job in
            Text(verbatim: "“\(JobsStore.queueName(job))” won't print.")
        }
    }

    private func header(_ state: MacJobsQueueBody, count: Int) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: state.headerLabel(count: count))
                .font(.mono(m.monoLabel, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(c.t3)
            // The prototype says "drag to reorder" here. THERE IS NO REORDER ENDPOINT: the client
            // exposes `POST /queue/`, `POST /queue/{id}/{action}` and nothing that moves a row, and
            // `JobsStore` has no reorder method. A drag that reverted on the next 5 s poll is
            // precisely this codebase's recurring bug — an affordance gated on a capability nobody
            // checked — so the caption states the truth instead.
            //
            // Shown only when there is a list for it to be true OF, exactly as HISTORY's "newest
            // 50" scope note is: a sentence about the ordering of the rows, printed above a block
            // that is deliberately blank, describes a list that is not on screen.
            if state == .rows {
                Text("server order · this app can't reorder the queue")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(c.t3)
                    .help("Bambuddy's queue API has no verified reorder route, so no drag is offered rather than one that silently snaps back.")
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 9)
    }

    @ViewBuilder
    private func content(_ state: MacJobsQueueBody, upcoming: [QueueItem]) -> some View {
        switch state {
        case .loading:
            MacJobsLoadingRow()
        case .rows:
            queueList(upcoming)
        case .unknown:
            // Deliberately nothing. The retry banner above has already said the only true thing
            // there is to say; a placeholder underneath it would be the app inventing an answer it
            // never received.
            EmptyView()
        case .emptyEverywhere:
            placeholder("Nothing queued. Files you send to print line up here.")
        case .elsewhereOnly:
            // The line below names the machines, so this only has to say whose lane is clear.
            placeholder("Nothing queued for \(model.printer?.name ?? "this printer").")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(c.t3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line))
    }

    /// Fixed row height so the block's height is arithmetic rather than a guess, and so the cap below
    /// lands on a half row — a visible slice of the next card is the only honest scroll cue in a list
    /// that is otherwise flush with its neighbours.
    ///
    /// **Not `Metrics.rowHeight`.** That token is 28 on macOS and is documented as "a row in a list
    /// or table" — a row of TEXT, which is what the History `Table` below uses. This row carries a
    /// 32 pt thumbnail well, so 28 would clip it outright: "how tall is a text row?" and "how tall is
    /// a row with a thumbnail in it?" are two questions with two answers. The second one deserves its
    /// own `Metrics` token; adding one edits a file this pass does not own, so the height is derived
    /// from the well it has to contain rather than left as an unexplained 46.
    private static let thumbSize: CGFloat = 32
    private static let rowPadding: CGFloat = 7
    private static let queueRowHeight: CGFloat = thumbSize + rowPadding * 2
    private static let queueRowGap: CGFloat = 8

    private func queueListHeight(_ count: Int) -> CGFloat {
        let n = CGFloat(count)
        let content = n * Self.queueRowHeight + max(n - 1, 0) * Self.queueRowGap
        let cap = Self.queueRowHeight * 3.5 + Self.queueRowGap * 3
        return min(content, cap)
    }

    private func queueList(_ upcoming: [QueueItem]) -> some View {
        ScrollView {
            VStack(spacing: Self.queueRowGap) {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, job in
                    queueRow(job, ordinal: index + 1)
                }
            }
        }
        .scrollIndicators(.automatic)
        // Every queued job stays reachable (each row carries the only Remove it has), which is why
        // this scrolls rather than truncating to "+3 more".
        .frame(height: queueListHeight(upcoming.count))
    }

    private func queueRow(_ job: QueueItem, ordinal: Int) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(ordinal)")
                .font(.mono(11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(c.t3)
                .frame(width: 14, alignment: .leading)

            RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous)
                .fill(c.thumb)
                .frame(width: Self.thumbSize, height: Self.thumbSize)

            Text(JobsStore.queueName(job))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(c.t1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: MacJobQueue.subtitle(job))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(c.t3)
                .lineLimit(1)

            // Removing a queue item is Bambuddy-side bookkeeping — the printer is never asked — so
            // it is deliberately NOT LAN-gated, and stays live when every print command is refused.
            Button("Remove") { confirmRemove = job }
                .buttonStyle(MacJobsChipButtonStyle())
                .accessibilityLabel("Remove \(JobsStore.queueName(job)) from the queue")
        }
        .padding(.horizontal, 14)
        .frame(height: Self.queueRowHeight)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line))
        .contextMenu {
            Button("Remove from Queue", role: .destructive) { confirmRemove = job }
        }
    }

    private func remove(_ job: QueueItem) {
        Task {
            // A successful removal says nothing: the row simply leaves the list. A failure goes to
            // `model.toast`, which `MacRoot` renders — the rule `MacHardwareSection` states and
            // Printer, Power and Files follow. It used to raise its own modal, so a queue removal
            // that Bambuddy refused stopped the window until it was dismissed, while the identical
            // refusal of Pause or Stop six inches away slid in and out on its own.
            if let outcome = await store.remove(job) { model.toast = MacJobsToast.toast(outcome) }
        }
    }
}

// MARK: - History

private struct MacJobsHistory: View {
    let model: AppModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// The inspector declares the identical key — see `MacJobsSelection`.
    @SceneStorage(MacJobsSelection.run) private var selectedId: Int?

    /// Newest first — the order the server already returns, so the first paint does not visibly
    /// re-sort. Clicking a column header replaces this and the rows re-sort locally.
    @State private var sortOrder: [KeyPathComparator<MacJobRow>] = [
        KeyPathComparator(\MacJobRow.started, order: .reverse)
    ]

    private var store: JobsStore { model.jobs }

    var body: some View {
        // ONE projection per body pass, passed down. Read as a computed property it was rebuilt
        // three times — for the count, the emptiness test and the table — mapping every archived
        // entry each time.
        let rows = MacJobRow.rows(
            store.entries ?? [],
            symbol: store.currencySymbol,
            client: model.client,
            cameraToken: model.cameraToken
        )
        return VStack(alignment: .leading, spacing: 0) {
            header(rows)
            if store.historyFailed {
                MacJobsRetryCard(text: "Couldn’t reach the server for the archive.") {
                    Task { await store.loadHistory() }
                }
                .padding(.bottom, rows.isEmpty ? 0 : 8)
            }
            content(rows)
        }
    }

    private func header(_ rows: [MacJobRow]) -> some View {
        HStack(spacing: 10) {
            Text("HISTORY")
                .font(.mono(m.monoLabel, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(c.t3)
            Spacer(minLength: 8)
            // Only once there is a pool to describe. "newest 0" above an empty card is a scope note
            // for a list that is not there.
            if !rows.isEmpty {
                Text(verbatim: scope(rows.count))
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(c.t3)
                    // Same honesty rule the MakerWorld sort learnt: a client-side sort must say what
                    // pool it sorted. The archive endpoint is asked for the newest 50.
                    .help("The newest 50 archived runs are loaded; sorting a column reorders those.")
            }
        }
        .padding(.bottom, 9)
    }

    private func scope(_ count: Int) -> String {
        guard let total = store.stats?.totalCost?.double, total > 0 else { return "newest \(count)" }
        return "newest \(count) · lifetime \(Money.format(store.currencySymbol, total))"
    }

    @ViewBuilder
    private func content(_ rows: [MacJobRow]) -> some View {
        switch MacJobsHistoryBody.of(entries: store.entries, failed: store.historyFailed) {
        case .loading:
            MacJobsLoadingRow()
        case .rows:
            table(rows)
        case .unknown:
            // The retry banner above is the whole story: a cold failure leaves an EMPTY array
            // behind, and "No prints yet" would be the app asserting an archive it never read.
            EmptyView()
        case .empty:
            Text("No prints yet. Once a print finishes it's archived here with its stats, filament and cost.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
                .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line))
        }
    }

    /// A real `Table`: sortable headers, one selected row, keyboard navigation for free.
    ///
    /// Selection writes `selectedId` and NOTHING else — the content column does not scroll, reload
    /// or navigate when a row is picked (§4). The inspector is the only thing that changes.
    private func table(_ rows: [MacJobRow]) -> some View {
        Table(rows.sorted(using: sortOrder), selection: $selectedId, sortOrder: $sortOrder) {
            TableColumn("FILE", value: \MacJobRow.name) { row in
                HStack(spacing: 8) {
                    if let swatch = row.swatch {
                        Swatch(value: swatch, size: 11, radius: Metrics.swatchRadius(11))
                    }
                    Text(row.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 150, ideal: 260)

            // Relative ("3h ago") because that is what the eye wants when scanning, and identical to
            // the iOS list. Sorting uses the parsed `Date`, so the friendly text never drives order —
            // the inspector shows the absolute timestamp for the one run being read.
            TableColumn("STARTED", value: \MacJobRow.started) { row in
                Text(verbatim: row.startedText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(c.t2)
            }
            .width(min: 70, ideal: 95)

            TableColumn("DURATION", value: \MacJobRow.duration) { row in
                Text(verbatim: row.durationText)
                    .font(.mono(11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(c.t2)
            }
            .width(min: 65, ideal: 85)

            TableColumn("FILAMENT", value: \MacJobRow.filament) { row in
                Text(verbatim: row.filament)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(c.t2)
                    .lineLimit(1)
            }
            .width(min: 75, ideal: 110)

            TableColumn("COST", value: \MacJobRow.cost) { row in
                Text(verbatim: row.costText)
                    .font(.mono(11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(row.cost > 0 ? c.accent : c.t3)
            }
            .width(min: 55, ideal: 75)

            TableColumn("RESULT", value: \MacJobRow.outcomeLabel) { row in
                Text(verbatim: row.outcome.label.uppercased())
                    .font(.mono(10, weight: .bold))
                    .foregroundStyle(row.outcome.color(c))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: m.chipRadius, style: .continuous).fill(row.outcome.dim(c)))
            }
            .width(min: 70, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(c.s1)
        .clipShape(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
                .strokeBorder(c.line)
        )
        // Deliberately no "Print again" in a row context menu: reprint is the inspector's primary
        // button, and it is gated on facts (an archive id, LAN mode) that would then have to be
        // decided in two files. One gate, one place — that is how the gate stops drifting.
    }
}

// MARK: - What each block is actually showing

/// What the UP NEXT block shows under its heading.
///
/// Five different FACTS that one `upcoming.isEmpty` check used to conflate, and two of them were
/// being told as lies:
///
///  - **`.unknown` was rendered as `.emptyEverywhere`.** `JobsStore.loadQueue` falls back to
///    `queue = queue ?? []` on failure, so the FIRST failed fetch leaves a non-nil empty array
///    behind. "Is the array empty?" and "did we ever get an answer?" are two questions; reading the
///    first as the second printed "Nothing queued. Files you send to print line up here." directly
///    underneath the retry banner. iOS guards its own empty card with `&& !failed`.
///  - **`.elsewhereOnly` was rendered as `.emptyEverywhere`.** `upNext` is THIS PRINTER'S LANE, so a
///    queue whose every job is pinned to another machine made the section claim "Nothing queued" one
///    line above "2 more jobs queued for Studio." The empty card's question is "is there nothing
///    waiting to print anywhere?", which is `upcoming` *and* `elsewhere`.
///
/// A pure function so the distinction is unit-tested rather than eyeballed in a window.
enum MacJobsQueueBody: Equatable {
    /// Never loaded — the spinner state.
    case loading
    /// This printer has jobs waiting. Stale rows count: they are the last thing the server said.
    case rows
    /// A fetch failed and left nothing behind. We do NOT know what is queued, and must not say.
    case unknown
    /// The whole pending queue is empty, on every printer.
    case emptyEverywhere
    /// Jobs are pending, all of them pinned to other machines.
    case elsewhereOnly

    static func of(queue: [QueueItem]?, failed: Bool, printerId: Int) -> MacJobsQueueBody {
        // Rows first: a failure keeps the last ones on screen with the banner above them.
        if !JobsStore.upNext(queue, printerId: printerId).isEmpty { return .rows }
        if queue == nil && !failed { return .loading }
        if failed { return .unknown }
        return JobsStore.queuedElsewhere(queue, printerId: printerId).isEmpty
            ? .emptyEverywhere
            : .elsewhereOnly
    }

    /// The heading above the lane — with a count, or without one.
    ///
    /// Two questions, and the header was answering the wrong one:
    ///
    ///  - **"how many jobs are in this printer's lane?"** always has an `Int` answer, because
    ///    `JobsStore.upNext` returns an empty array for a queue that never loaded exactly as
    ///    readily as for one that is genuinely empty.
    ///  - **"how many jobs is this block SHOWING?"** is what a number beside a heading claims, and
    ///    in `.loading` and `.unknown` it has no answer at all.
    ///
    /// Rendering the first as the second put `UP NEXT · 0` above a retry banner and a deliberately
    /// blank body — the heading asserting the empty lane that `content` had just refused to assert,
    /// one line apart, on the same fetch failure. The two empty states drop the count too: the
    /// placeholder card underneath says "Nothing queued…" in words, and `· 0` on top of it is the
    /// same fact told twice (iOS omits the whole header there for the same reason).
    func headerLabel(count: Int) -> String {
        switch self {
        case .rows: "UP NEXT · \(count)"
        case .loading, .unknown, .emptyEverywhere, .elsewhereOnly: "UP NEXT"
        }
    }
}

/// What the HISTORY block shows under its heading — the same three-way distinction, for the same
/// reason: `JobsStore.loadHistory` does `entries = entries ?? []`, so a cold archive failure used to
/// render "No prints yet…" underneath its own retry banner.
enum MacJobsHistoryBody: Equatable {
    case loading, rows, unknown, empty

    static func of(entries: [PrintLogEntry]?, failed: Bool) -> MacJobsHistoryBody {
        if entries?.isEmpty == false { return .rows }
        if entries == nil && !failed { return .loading }
        if failed { return .unknown }
        return .empty
    }
}

/// What the LIFETIME PRINTS card shows.
///
/// `stats` is its OWN request (`getArchiveStats`), so three separate facts hide behind a nil one,
/// and every pair of them that gets conflated produces a card asserting something it has not
/// established:
///
///  - **"has the summary been ASKED yet?"** — `JobsStore.statsAsked`. `loadHistory` assigns
///    `entries` and only THEN awaits the summary, so on every cold load there is a window whose
///    observed state is `(stats: nil, entries: [...], historyFailed: false)`. Keyed on `stats == nil`
///    this card fell through to "Lifetime totals unavailable · it didn't answer" about a request
///    that had not answered *yet*. `statsAsked` is the only thing that tells in-flight from refused,
///    because a nil `stats` is the same value in both.
///  - **"did the ask FAIL?"** — `JobsStore.statsFailed`. Note that a failed refresh no longer clears
///    the previous figures, so a card reading "213 · 94 % success" keeps them instead of flipping to
///    a placeholder and back on every transient failure.
///  - **"is the archive empty?"** — only the summary's own `totalPrints == 0` says that, and it is
///    only repeated here when it will not contradict the table beside it (see below).
enum MacJobsLifetimeBody: Equatable {
    case loading
    case figures(ArchiveStats)
    /// No lifetime total can be stated — and *why*, because the two reasons need different words.
    case unavailable(NoTotal)
    case empty

    /// Why the card has no number to show. The headline is identical for both; the explanation is
    /// the part that was lying, by telling every case that the request "didn't answer".
    enum NoTotal: Equatable {
        /// The summary request itself did not come back.
        case requestFailed
        /// It came back, and nothing in it establishes a total this card can stand behind — no
        /// count at all, or a zero contradicted by the runs listed below.
        case answeredWithoutOne

        var help: String {
            switch self {
            case .requestFailed:
                "The archive's summary is a separate request and it didn't answer. The runs listed below are unaffected — ⌘R retries."
            case .answeredWithoutOne:
                "The archive's summary answered without a lifetime total in it. The runs listed below are unaffected — ⌘R retries."
            }
        }
    }

    static func of(
        stats: ArchiveStats?,
        statsAsked: Bool,
        statsFailed: Bool,
        entries: [PrintLogEntry]?,
        historyFailed: Bool
    ) -> MacJobsLifetimeBody {
        // Figures whenever we have them, including a set kept through a failed refresh.
        if let stats, (stats.totalPrints ?? 0) > 0 { return .figures(stats) }
        // "Has it been asked?", NOT "did it come back?" — see the note above.
        if !statsAsked { return .loading }
        if statsFailed { return .unavailable(.requestFailed) }
        // "Is the table beside this card listing runs?", NOT "did the archive list request
        // succeed?". The corroboration this needs is only that the card will not read "No prints
        // archived yet" above visible archived prints — and after a cold archive failure the block
        // below renders NOTHING (`MacJobsHistoryBody.unknown`), so there is nothing to contradict.
        // Asking `historyFailed` directly answered the nearby question and suppressed a true
        // "empty" whenever the unrelated list request happened to fail.
        let runsListed = MacJobsHistoryBody.of(entries: entries, failed: historyFailed) == .rows
        if let total = stats?.totalPrints, total == 0, !runsListed { return .empty }
        return .unavailable(.answeredWithoutOne)
    }
}

// MARK: - Row projection

/// One archived run, as BOTH Mac columns render it.
///
/// Shared with `MacJobsInspector` on purpose: the same print appears in the table and in the
/// inspector at the same moment, and two independent projections of one `PrintLogEntry` are two
/// chances to disagree about what happened. Every `Table` sort key is a plain non-optional
/// `Comparable` because `TableColumn(_:value:content:)` requires one.
///
/// **The rendered strings are computed, the raw facts are stored.** A projection is built for every
/// archived entry on every refresh, but the table draws only the visible cells and the inspector
/// only the selected row — so `startedAbsolute`, `filamentDetail`, `energyText` and the rest are
/// derived where they are read rather than formatted fifty times for one reader.
struct MacJobRow: Identifiable, Hashable {
    /// The print-log entry id — also the value persisted as the scene's selection.
    let id: Int
    let name: String
    /// The parsed start, or nil when the archive recorded none.
    let startedDate: Date?
    let startedText: String
    /// Seconds. 0 means "not recorded" — `durationText` shows "—", so the sentinel only ever decides
    /// where the unknowns sit when sorting.
    let duration: Double
    /// The filament type as the archive recorded it, "" when it recorded none.
    let filamentType: String
    let filamentGrams: Double?
    let cost: Double
    let energyKwh: Double?
    let outcome: MacJobOutcome
    /// First colour of a possibly comma-joined multi-material string — the spool the eye recognises
    /// the model by.
    let swatch: String?
    let thumb: URL?
    /// nil when Bambuddy never archived the run. The ONLY thing that decides whether it can be
    /// re-queued; see `MacJobsInspector`.
    let archiveId: Int?
    let printerName: String?
    /// The symbol every money figure in this row renders with. Carried per row so the two columns
    /// cannot format one run's cost in two currencies.
    let symbol: String

    // MARK: Sort keys

    /// `.distantPast` when the archive recorded no start time, so undated runs collect at one end
    /// under either direction instead of interleaving; the cell still reads "".
    var started: Date { startedDate ?? .distantPast }
    /// The RESULT column sorts on the rendered label, so the order matches what is on screen.
    var outcomeLabel: String { outcome.label }
    /// The column shows the type alone: the table is for scanning ("was that the PETG one?"), and a
    /// two-fact cell wraps at every useful column width.
    var filament: String { filamentType.isEmpty ? "—" : filamentType }

    // MARK: Rendered

    var durationText: String { duration > 0 ? Dash.fmtDuration(duration / 60) : "—" }
    var costText: String { cost > 0 ? Money.format(symbol, cost) : "—" }

    /// The inspector's timestamp. The table says "3h ago" because that is what scanning wants; the
    /// one run you are reading gets the real date and time, which is what a note or a bug report
    /// wants. Empty when the archive recorded none.
    var startedAbsolute: String {
        startedDate?.formatted(.dateTime.day().month(.abbreviated).hour().minute()) ?? ""
    }

    /// Grams AND type, for the inspector — "112 g PLA Basic".
    ///
    /// Both halves are optional and often only one of them lands, so the line is assembled rather
    /// than templated — "112 g" and "PLA Basic" are each worth showing alone.
    var filamentDetail: String {
        var detail: [String] = []
        if let grams = filamentGrams, grams > 0 { detail.append("\(Int(grams.rounded())) g") }
        if !filamentType.isEmpty { detail.append(filamentType) }
        return detail.isEmpty ? "—" : detail.joined(separator: " ")
    }

    /// An em dash, never "0.00 kWh": the server reports nothing until a plug has metered a whole
    /// job, and a zero would read as "this printer used no power".
    var energyText: String {
        guard let kwh = energyKwh, kwh > 0 else { return "—" }
        return "\(String(format: "%.2f", kwh)) kWh"
    }

    init(_ e: PrintLogEntry, symbol: String, client: BambuddyClient?, cameraToken: String?) {
        id = e.id
        name = JobsStore.historyName(e)
        startedDate = e.startedAt.flatMap(PrintTime.parse)
        startedText = PrintTime.relative(e.startedAt)
        duration = e.durationSeconds?.double ?? 0
        filamentType = e.filamentType?.trimmingCharacters(in: .whitespaces) ?? ""
        filamentGrams = e.filamentUsedGrams?.double
        // The archive fills `cost` OR `energyCost` depending on how far its metering got; the iOS
        // list reads them in this order and so does this.
        cost = e.cost?.double ?? e.energyCost?.double ?? 0
        energyKwh = e.energyKwh?.double
        outcome = MacJobOutcome(status: e.status)
        swatch = FilamentColor.norm(
            e.filamentColor?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        )
        thumb = client?.printLogThumbUrl(e.id, token: cameraToken, thumbnailPath: e.thumbnailPath)
        archiveId = e.archiveId
        printerName = e.printerName
        self.symbol = symbol
    }

    static func rows(
        _ entries: [PrintLogEntry],
        symbol: String,
        client: BambuddyClient?,
        cameraToken: String?
    ) -> [MacJobRow] {
        entries.map { MacJobRow($0, symbol: symbol, client: client, cameraToken: cameraToken) }
    }
}

/// How a run ended. Labels match the iOS archive exactly — one vocabulary for one fact across both
/// platforms — and an unrecognised status keeps the server's own word rather than being flattened
/// into "Failed".
///
/// **This is a second statement of `HistoryRow.meta` in `Views/JobsView.swift`, not a shared one.**
/// The two view trees are supposed to duplicate LAYOUT and nothing else
/// (18-mac-port-architecture.md, "What this costs, honestly"), and a status→label→colour mapping is
/// not layout. Unifying it means moving this into `Domain/` and deleting the iOS copy — an edit to
/// a file outside this pass. Until then: change one, change both.
enum MacJobOutcome: Hashable {
    case done, failed, cancelled, other(String)

    init(status: String) {
        switch status {
        case "completed": self = .done
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default:
            self = status.isEmpty ? .other("Unknown") : .other(status.prefix(1).uppercased() + status.dropFirst())
        }
    }

    var label: String {
        switch self {
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Canceled"
        case .other(let s): s
        }
    }

    func color(_ p: Palette) -> Color {
        switch self {
        case .done: p.running
        case .failed: p.error
        case .cancelled, .other: p.idle
        }
    }

    func dim(_ p: Palette) -> Color {
        switch self {
        case .done: p.runningDim
        case .failed: p.errorDim
        case .cancelled, .other: p.idleDim
        }
    }
}

/// The lifetime-card figures. Separate from the view so the rounding is readable.
///
/// Same caveat as `MacJobOutcome`: the kg/g threshold and the success percentage are also stated in
/// `StatsBanner` (`Views/JobsView.swift`). A unit threshold is a domain rule, not layout — it
/// belongs in `Domain/` with both trees reading it.
enum MacJobStats {
    static func successText(_ s: ArchiveStats) -> String {
        let total = s.totalPrints ?? 0
        guard total > 0 else { return "" }
        let pct = Int((Double(s.successfulPrints ?? 0) / Double(total) * 100).rounded())
        return "\(pct) % success"
    }

    static func totalsText(_ s: ArchiveStats) -> String {
        let hours = s.totalPrintTimeHours?.double ?? 0
        let grams = s.totalFilamentGrams?.double ?? 0
        // Kilograms once there is a kilogram to show — "1240 g" is harder to read than "1.24 kg".
        let filament = grams >= 1000
            ? "\(String(format: "%.2f", grams / 1000)) kg"
            : "\(Int(grams.rounded())) g"
        return "\(String(format: "%.1f", hours)) h · \(filament) filament"
    }
}

/// Queue-row text. Also a copy — of `QueueSection.subtitle` in `Views/JobsView.swift`, doc comment
/// included — and also belongs in `Domain/` rather than twice in the view layer.
enum MacJobQueue {
    /// A slice-less job has no time estimate, so it shows its raw status instead. Zero seconds means
    /// "unknown", not "instant".
    static func subtitle(_ job: QueueItem) -> String {
        guard let seconds = job.printTimeSeconds?.double, seconds > 0 else { return job.status }
        return Dash.fmtDuration(seconds / 60)
    }
}

// MARK: - Command outcomes

/// A `JobActionMessage` as the ONE line `model.toast` shows.
///
/// The store returns a title AND a message because it was written for an alert, which has a slot for
/// each. The Mac tree reports every command outcome through the toast instead (`MacToast`, and the
/// rule as `MacHardwareSection` states it), and a toast is one line — so the halves are joined the
/// way every other Mac command failure already reads: `AppModel.perform` writes
/// "Pause failed — AMS is busy". Neither half is dropped. The title is the only thing that names
/// WHICH action spoke, and the message is the only thing carrying Bambuddy's own words for why —
/// a 409's "AMS is busy" beats any transport description this app could substitute.
enum MacJobsToast {
    /// The whole message, with the outcome it belongs to.
    ///
    /// `JobActionMessage.succeeded` is the fact — not a guess from the copy. "Queued — the job is
    /// back in the queue" was going through the failure banner and wearing a warning triangle.
    static func toast(_ m: JobActionMessage) -> Toast {
        m.succeeded ? .success(text(m)) : .failure(text(m))
    }

    static func text(_ outcome: JobActionMessage) -> String {
        let title = outcome.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = outcome.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return message }
        if message.isEmpty { return title }
        return "\(title) — \(message)"
    }
}

// MARK: - Shared chrome

/// A fetch failed — deliberately distinct from an empty list, which would tell the user their queue
/// or archive is gone. The store keeps the last rows underneath, so this is a banner, not a state.
///
/// Its chrome is deliberately IDENTICAL to `MacFilesSection.retryBanner` — same radius, same
/// padding, same button style — because the two sections sit one keystroke apart and were showing
/// two different-looking banners for the same event. There are four copies of this component in the
/// Mac tree now (Files, Jobs, Hardware, the menu bar); one shared `MacRetryBanner` is the real fix
/// and it needs a file this pass does not own. Until it exists, matching is what keeps them in step.
struct MacJobsRetryCard: View {
    let text: String
    let onRetry: () -> Void

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13))
                .foregroundStyle(c.t3)
            Text(verbatim: text)
                .font(.system(size: m.body, weight: .medium))
                .foregroundStyle(c.t2)
            Spacer(minLength: 8)
            Button("Retry", action: onRetry)
                .buttonStyle(MacSecondaryButtonStyle())
        }
        .padding(m.cardPadding)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line))
    }
}

/// "Never loaded" — distinct from both "empty" and "failed".
struct MacJobsLoadingRow: View {
    @Environment(\.palette) private var c

    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text("Loading…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(c.t3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
    }
}

/// The small in-row chip button (Remove). Not `MacSecondaryButtonStyle`: that is the 34 pt
/// PRIMARY-adjacent shape, and at 34 pt inside a 46 pt row it reads as the row's main action.
/// `minControlHeight` is §8's floor and this sits exactly on it.
struct MacJobsChipButtonStyle: ButtonStyle {
    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(c.t2)
            .padding(.horizontal, 10)
            .frame(height: m.minControlHeight)
            .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.s3))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(.rect)
            .animation(Motion.standard(0.12), value: configuration.isPressed)
    }
}

/// Drives an `isPresented:` alert from an optional payload, clearing it on dismiss. Used by the ONE
/// presentation Jobs still raises — the Remove confirmation, which needs the job it is asking about.
/// (The reprint confirmation is a plain `Bool`, and command outcomes are toasts now, not alerts.)
/// The iOS tab keeps its own copy because the two view trees duplicate layout plumbing and nothing
/// else.
/// `@MainActor` so the two closures inherit main-actor isolation: `Binding(get:set:)` takes
/// `@Sendable` closures, and a `Binding` is not `Sendable`, so a nonisolated helper captures it into
/// a concurrency warning under `SWIFT_STRICT_CONCURRENCY: complete`.
@MainActor
func macJobsPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(
        get: { value.wrappedValue != nil },
        set: { shown in if !shown { value.wrappedValue = nil } }
    )
}
#endif
