import SwiftUI

// The Jobs tab reads top-to-bottom as the printer's job timeline: what is printing NOW, what is UP
// NEXT (with queue actions), then the HISTORY archive (lifetime stats + reprint). Merging the queue
// and the archive into one screen is what freed a tab slot.
//
// The scaffolding types below (`JobsPage`, `LoadFailedCard`, `EmptyState`, `ExtrudeBar`) are
// file-private on purpose: every tab needs its own copy of this chrome and there is no shared
// Components file for it yet. Promote them the moment a second screen would import them unchanged.

/// The Jobs tab: live queue on top, print-history archive below.
///
/// Both halves poll on their own cadence (queue 5 s, history 15 s) but the fetches live here rather
/// than inside the sections, so pull-to-refresh can await a real completion instead of the RN
/// build's remount-and-guess-600 ms trick. The sections are pure functions of what is loaded.
struct JobsView: View {
    let model: AppModel

    @Environment(\.palette) private var c

    // nil means "never loaded" — the spinner state. A FAILED fetch is not an empty list, so a
    // failure falls back to whatever was on screen (or []) and raises the retry banner instead.
    @State private var queue: [QueueItem]?
    @State private var queueFailed = false
    @State private var entries: [PrintLogEntry]?
    @State private var historyFailed = false
    @State private var stats: ArchiveStats?
    /// Currency comes from server settings, read once — it only changes when the user edits it on
    /// the server.
    @State private var currency: String?

    @State private var confirm: Confirm?
    @State private var notice: Notice?
    @State private var lanAlert = false

    private var locked: LockedActions { LockedActions(mode: model.lanMode, explaining: $lanAlert) }
    private var sym: String { Money.symbol(currency) }

    var body: some View {
        page
            .lockedActionAlert($lanAlert)
    }

    private var page: some View {
        JobsPage(title: "Jobs", onRefresh: refreshAll) {
            QueueSection(
                items: queue,
                failed: queueFailed,
                vm: model.vm,
                printerId: model.printerId,
                printers: model.printers,
                onRetry: { Task { await loadQueue() } },
                onBrowse: { model.tab = .library },
                onRemove: askRemove
            )
            HistorySection(
                entries: entries,
                stats: stats,
                failed: historyFailed,
                sym: sym,
                client: model.client,
                camToken: model.cameraToken,
                onRetry: { Task { await loadHistory() } },
                onReprint: askReprint
            )
        }
        .task { await poll(every: .seconds(5), loadQueue) }
        .task { await poll(every: .seconds(15), loadHistory) }
        .task { await loadSettings() }
        .alert(
            confirm?.title ?? "",
            isPresented: presented($confirm),
            presenting: confirm
        ) { ask in
            Button(ask.cancel, role: .cancel) {}
            Button(ask.action, role: ask.destructive ? .destructive : nil, action: ask.run)
        } message: { ask in
            Text(ask.message)
        }
        .alert(
            notice?.title ?? "",
            isPresented: presented($notice),
            presenting: notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { note in
            Text(note.message)
        }
    }

    // MARK: - Loading

    /// Run `work` now and then on an interval until the view goes away. `.task` cancellation is what
    /// stops the poll, so leaving the tab genuinely stops the traffic.
    private func poll(every interval: Duration, _ work: @escaping () async -> Void) async {
        while !Task.isCancelled {
            await work()
            try? await Task.sleep(for: interval)
        }
    }

    private func loadQueue() async {
        guard let client = model.client else { return }
        do {
            queue = try await client.listQueue()
            queueFailed = false
        } catch {
            queue = queue ?? []
            queueFailed = true
        }
    }

    private func loadHistory() async {
        guard let client = model.client else { return }
        do {
            entries = try await client.getPrintLog(limit: 50).items
            historyFailed = false
        } catch {
            entries = entries ?? []
            historyFailed = true
        }
        // Stats are decoration on top of the list: losing them silently drops the banner rather than
        // claiming the whole archive failed to load.
        stats = try? await client.getArchiveStats()
    }

    private func loadSettings() async {
        guard let client = model.client else { return }
        currency = (try? await client.getSettings())?.currency
    }

    private func refreshAll() async {
        await loadQueue()
        await loadHistory()
    }

    // MARK: - Actions

    private func askRemove(_ j: QueueItem) {
        confirm = Confirm(
            title: "Remove from queue?",
            message: "“\(Self.queueName(j))” won't print.",
            action: "Remove",
            cancel: "Keep",
            destructive: true
        ) {
            remove(j)
        }
    }

    /// Cancelling a queue item is Bambuddy-side bookkeeping — the printer is never asked — so it is
    /// deliberately NOT LAN-gated.
    private func remove(_ j: QueueItem) {
        guard let client = model.client else { return }
        Task {
            do {
                try await client.queueAction(j.id, action: "cancel")
                await loadQueue()
            } catch {
                notice = Notice(title: "Couldn't remove", message: Self.failureText(error))
            }
        }
    }

    private func askReprint(_ e: PrintLogEntry) {
        guard e.archiveId != nil else { return }
        // A history row is a list item, not a button. Dimming the whole archive to 40 % would read
        // as broken data, so this one gate explains itself on tap instead of going grey.
        locked.press(.printAgain) {
            confirm = Confirm(
                title: "Print again?",
                message: "“\(Self.historyName(e))” goes back into the queue.",
                action: "Print again",
                cancel: "Cancel",
                destructive: false
            ) {
                reprint(e)
            }
        }()
    }

    private func reprint(_ e: PrintLogEntry) {
        guard let client = model.client, let archiveId = e.archiveId else { return }
        let printerId = model.printerId
        Task {
            do {
                try await client.reprint(archiveId: archiveId, printerId: printerId)
                notice = Notice(title: "Queued", message: "The job is back in the queue.")
                // Show the new job immediately rather than up to 5 s later.
                await loadQueue()
            } catch {
                notice = Notice(title: "Couldn't reprint", message: Self.failureText(error))
            }
        }
    }

    // MARK: - Naming

    static func queueName(_ j: QueueItem) -> String {
        j.libraryFileName ?? j.archiveName ?? "Job \(j.id)"
    }

    static func historyName(_ e: PrintLogEntry) -> String {
        e.printName ?? "Print \(e.id)"
    }

    /// Bambuddy's own `detail` string when it sent one — a 409's "AMS is busy" is far more useful
    /// than a transport description.
    static func failureText(_ error: Error) -> String {
        (error as? BambuddyError)?.detail ?? error.localizedDescription
    }
}

// MARK: - Alert payloads

/// A confirmation to run. One alert serves both the queue-removal and the reprint prompts, because
/// SwiftUI presents a single alert per view and two stacked ones fight over the slot.
private struct Confirm: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: String
    let cancel: String
    let destructive: Bool
    let run: () -> Void
}

/// A one-button message (a failure, or the reprint's "Queued" acknowledgement).
private struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Drives an `isPresented:` alert from an optional payload, clearing it on dismiss.
private func presented<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(
        get: { value.wrappedValue != nil },
        set: { shown in if !shown { value.wrappedValue = nil } }
    )
}

// MARK: - Queue

/// The "what's coming" half: the live print, then this printer's lane of the queue.
private struct QueueSection: View {
    let items: [QueueItem]?
    let failed: Bool
    let vm: DashVM
    let printerId: Int
    let printers: [Printer]
    let onRetry: () -> Void
    let onBrowse: () -> Void
    let onRemove: (QueueItem) -> Void

    @Environment(\.palette) private var c

    private var pending: [QueueItem] {
        (items ?? []).filter { $0.status == "pending" || $0.status == "queued" }
    }

    /// The queue is backend-global; this tab shows the selected printer's lane, with untargeted jobs
    /// included because they can land here.
    private var upcoming: [QueueItem] {
        pending.filter { $0.printerId == nil || $0.printerId == printerId }
    }

    private var elsewhere: [QueueItem] {
        pending.filter { !($0.printerId == nil || $0.printerId == printerId) }
    }

    /// Distinct printer names, in queue order.
    private var otherNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for j in elsewhere {
            let name = j.printerName ?? printers.first { $0.id == j.printerId }?.name ?? "another printer"
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// NEVER re-derived from `status.state` — the view-model is the single classifier.
    private var printing: Bool { vm.kind == .live }

    var body: some View {
        Group {
            if items == nil && !failed {
                ProgressView()
                    .tint(c.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
            if failed {
                LoadFailedCard(onRetry: onRetry)
            }
            if items?.isEmpty == true && !printing && !failed {
                emptyCard
            }
            if printing {
                nowPrinting
            }
            if !upcoming.isEmpty {
                upNext
            }
            if !elsewhere.isEmpty {
                Text("\(elsewhere.count) more \(elsewhere.count == 1 ? "job" : "jobs") queued for \(otherNames.joined(separator: ", ")).")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c.t3)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
            }
        }
    }

    /// Compact inline empty state rather than a full-screen one — history renders directly below and
    /// a 72 pt icon well here would push it off the screen.
    private var emptyCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.system(size: 16))
                .foregroundStyle(c.t3)
            Text("Nothing queued. Files you send to print line up here.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Tap(action: onBrowse) {
                Text("Browse")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(c.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s3))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.line))
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var nowPrinting: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NOW PRINTING")
                .font(.mono(11))
                .tracking(1)
                .foregroundStyle(c.t3)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 11)

            VStack(alignment: .leading, spacing: 0) {
                Text(vm.heroSub.isEmpty ? "Current print" : vm.heroSub)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.t1)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    PulseDot(color: c.running, size: 6, period: 2)
                    Text("\(vm.progressInt)% · \(vm.etaText) left")
                        .font(.mono(11))
                        .foregroundStyle(c.running)
                }
                .padding(.top, 5)
                ExtrudeBar(pct: vm.progressInt, color: c.running, track: c.s3, height: 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(c.s1))
            // 1.5 pt, not 1 — the live card is the one thing on this screen that outlines itself.
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(c.running, lineWidth: 1.5))
            .padding(.horizontal, 20)
        }
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("UP NEXT")
                    .font(.mono(11))
                    .tracking(1)
                    .foregroundStyle(c.t3)
                Spacer(minLength: 8)
                Text("\(upcoming.count) jobs")
                    .font(.mono(11))
                    .foregroundStyle(c.t3)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 11)

            VStack(spacing: 10) {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, job in
                    row(job, ordinal: index + 1)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func row(_ j: QueueItem, ordinal: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(ordinal)")
                .font(.mono(13))
                .foregroundStyle(c.t3)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text(JobsView.queueName(j))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(c.t1)
                    .lineLimit(1)
                Text(subtitle(j))
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(c.t3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Tap { onRemove(j) } content: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(c.t3)
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Remove \(JobsView.queueName(j)) from the queue")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(c.line))
    }

    /// A slice-less job has no time estimate, so it shows its raw status instead. Zero seconds means
    /// "unknown", not "instant".
    private func subtitle(_ j: QueueItem) -> String {
        guard let seconds = j.printTimeSeconds?.double, seconds > 0 else { return j.status }
        return Dash.fmtDuration(seconds / 60)
    }
}

// MARK: - History

/// The "what happened" half: lifetime stats, then the archive, newest first.
private struct HistorySection: View {
    let entries: [PrintLogEntry]?
    let stats: ArchiveStats?
    let failed: Bool
    let sym: String
    let client: BambuddyClient?
    let camToken: String?
    let onRetry: () -> Void
    let onReprint: (PrintLogEntry) -> Void

    @Environment(\.palette) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HISTORY")
                .font(.mono(11))
                .tracking(1)
                .foregroundStyle(c.t3)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 2)

            if entries == nil && !failed {
                ProgressView()
                    .tint(c.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
            if failed {
                LoadFailedCard(onRetry: onRetry)
            }
            if let stats, entries != nil, (stats.totalPrints ?? 0) > 0 {
                StatsBanner(stats: stats, sym: sym)
            }
            if entries?.isEmpty == true && !failed {
                EmptyState(
                    icon: "clock",
                    title: "No prints yet",
                    body: "Once you finish a print it's archived here with its stats, filament, and cost."
                )
            }
            if let entries, !entries.isEmpty {
                Text("RECENT PRINTS · TAP TO REPRINT")
                    .font(.mono(11))
                    .tracking(1)
                    .foregroundStyle(c.t3)
                    .padding(.horizontal, 20)
                    .padding(.top, 26)
                    .padding(.bottom, 12)

                VStack(spacing: 10) {
                    ForEach(entries) { entry in
                        HistoryRow(
                            entry: entry,
                            thumb: client?.printLogThumbUrl(entry.id, token: camToken, thumbnailPath: entry.thumbnailPath),
                            sym: sym,
                            onReprint: onReprint
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

/// One archived print: thumbnail, name, outcome chip, and the facts worth scanning for.
private struct HistoryRow: View {
    let entry: PrintLogEntry
    let thumb: URL?
    let sym: String
    let onReprint: (PrintLogEntry) -> Void

    @Environment(\.palette) private var c

    /// Rows with no archive behind them cannot be re-queued. They stay visually identical and simply
    /// do nothing — a greyed-out row in a list reads as corrupt data.
    private var canReprint: Bool { entry.archiveId != nil }

    private var meta: (label: String, color: Color, dim: Color) {
        switch entry.status {
        case "completed": return ("Done", c.running, c.runningDim)
        case "failed": return ("Failed", c.error, c.errorDim)
        case "cancelled": return ("Canceled", c.idle, c.idleDim)
        default:
            let s = entry.status
            let label = s.isEmpty ? "Unknown" : s.prefix(1).uppercased() + s.dropFirst()
            return (label, c.idle, c.idleDim)
        }
    }

    /// Duration, filament and energy — each shown only when the archive actually recorded it. Many
    /// of these stay null until the server has seen a full job.
    private var facts: [String] {
        var out: [String] = []
        if let seconds = entry.durationSeconds?.double { out.append(Dash.fmtDuration(seconds / 60)) }
        if let grams = entry.filamentUsedGrams?.double { out.append("\(Int(grams.rounded()))g") }
        if let kwh = entry.energyKwh?.double { out.append("\(String(format: "%.2f", kwh)) kWh") }
        return out
    }

    private var cost: Double? { entry.cost?.double ?? entry.energyCost?.double }

    var body: some View {
        Tap(disabled: !canReprint) {
            onReprint(entry)
        } content: {
            HStack(alignment: .top, spacing: 13) {
                thumbnail
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(JobsView.historyName(entry))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(c.t1)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(meta.label.uppercased())
                            .font(.mono(9.5, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(meta.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(meta.dim))
                    }
                    detailLine
                        .padding(.top, 6)
                    if let printer = entry.printerName, !printer.isEmpty {
                        Text(printer)
                            .font(.mono(10, weight: .medium))
                            .foregroundStyle(c.t3)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(c.line))
            .contentShape(.rect)
        }
    }

    private var detailLine: some View {
        HStack(spacing: 8) {
            // A multi-material print joins its colours with commas; the first one is the spool the
            // eye recognises the model by.
            if let swatch = FilamentColor.norm(entry.filamentColor?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }) {
                Swatch(value: swatch, size: 11, radius: 3)
            }
            Text(PrintTime.relative(entry.startedAt))
                .font(.mono(11, weight: .medium))
                .foregroundStyle(c.t3)
            if !facts.isEmpty {
                Text("· \(facts.joined(separator: " · "))")
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(c.t3)
            }
            if let cost, cost > 0 {
                Text("· \(Money.format(sym, cost))")
                    .font(.mono(11))
                    .foregroundStyle(c.accent)
            }
        }
        .lineLimit(1)
    }

    private var thumbnail: some View {
        // Print-log thumbnails are gated by the camera STREAM token in `?token=`, not the API key —
        // the header auth 401s here. The URL is already signed, so a plain AsyncImage is enough.
        ZStack {
            c.thumb
            if let thumb {
                AsyncImage(url: thumb) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        fallbackGlyph
                    default:
                        Color.clear
                    }
                }
            } else {
                fallbackGlyph
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.line))
    }

    private var fallbackGlyph: some View {
        Image(systemName: "shippingbox")
            .font(.system(size: 22))
            .foregroundStyle(c.t3)
    }
}

// MARK: - Lifetime stats

/// The archive's headline numbers. Only rendered once the server reports at least one print, so it
/// never shows a wall of zeroes to a new install.
private struct StatsBanner: View {
    let stats: ArchiveStats
    let sym: String

    @Environment(\.palette) private var c

    private var total: Int { stats.totalPrints ?? 0 }
    private var successful: Int { stats.successfulPrints ?? 0 }
    private var failed: Int { stats.failedPrints ?? 0 }
    private var successPct: Int { total > 0 ? Int((Double(successful) / Double(total) * 100).rounded()) : 0 }
    private var grams: Double { stats.totalFilamentGrams?.double ?? 0 }
    private var totalCost: Double { stats.totalCost?.double ?? 0 }
    private var totalKwh: Double { stats.totalEnergyKwh?.double ?? 0 }

    /// Kilograms once there is a kilogram to show — "1240g" is harder to read than "1.24kg".
    private var filamentValue: String {
        grams >= 1000 ? String(format: "%.2f", grams / 1000) : String(Int(grams.rounded()))
    }
    private var filamentUnit: String { grams >= 1000 ? "kg" : "g" }

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 12, alignment: .leading)]

    var body: some View {
        FadeRise {
            VStack(alignment: .leading, spacing: 0) {
                headline
                blocks
                    .padding(.top, 12)
                if stats.energyDataWarmingUp == true {
                    Text("Energy data is warming up — costs appear after the next full job.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(c.t3)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
        }
    }

    private var headline: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text("LIFETIME PRINTS")
                    .font(.mono(10))
                    .tracking(1.2)
                    .foregroundStyle(c.t3)
                RollingNumber(
                    value: total,
                    font: .system(size: 46, weight: .bold),
                    color: c.t1,
                    digitHeight: 50
                )
                .tracking(-2)
                .padding(.top, 7)
                HStack(spacing: 7) {
                    PulseDot(color: c.running, size: 7, period: 2.4)
                    Text("\(successful) done")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(c.t2)
                    if failed > 0 {
                        Circle()
                            .fill(c.error)
                            .frame(width: 7, height: 7)
                            .padding(.leading, 6)
                        Text("\(failed) failed")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(c.t2)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 12)
            successRing
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(c.line))
        .shadow1()
    }

    private var successRing: some View {
        ProgressRing(
            progress: Double(successPct) / 100,
            size: 76,
            lineWidth: 7,
            color: c.accent,
            track: c.s3,
            glow: false
        ) {
            VStack(spacing: 0) {
                RollingNumber(
                    value: successPct,
                    font: .system(size: 20, weight: .bold),
                    color: c.t1,
                    digitHeight: 22
                )
                .tracking(-0.5)
                Text("SUCCESS")
                    .font(.mono(8))
                    .tracking(0.5)
                    .foregroundStyle(c.t3)
                    .padding(.top, -2)
            }
        }
    }

    private var blocks: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            StatBlock(label: "PRINT HOURS", value: String(format: "%.1f", stats.totalPrintTimeHours?.double ?? 0), unit: "h")
            StatBlock(label: "FILAMENT", value: filamentValue, unit: filamentUnit)
            if totalCost > 0 {
                StatBlock(label: "EST. COST", value: Money.format(sym, totalCost), unit: nil, accent: true)
            }
            // An em dash rather than "0.00 kWh": the server reports nothing until a plug has been
            // metered through a whole job, and a zero would read as "this printer uses no power".
            StatBlock(
                label: "ENERGY",
                value: totalKwh > 0 ? String(format: "%.2f", totalKwh) : "—",
                unit: totalKwh > 0 ? "kWh" : nil
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(c.line))
    }
}

/// One labelled figure in the stats grid.
private struct StatBlock: View {
    let label: String
    let value: String
    var unit: String?
    var accent: Bool = false

    @Environment(\.palette) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.mono(9.5))
                .tracking(1)
                .foregroundStyle(c.t3)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                // `RollingNumber` only rolls integers; these values carry decimals and currency
                // symbols, so the digits animate through SwiftUI's own numeric transition instead.
                Text(value)
                    .font(.system(size: 25, weight: .bold))
                    .tracking(-1)
                    .foregroundStyle(accent ? c.accent : c.t1)
                    .contentTransition(.numericText())
                    .animation(Motion.roll(0.6), value: value)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(c.t3)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared chrome

/// Scrolling page with the big title and pull-to-refresh.
private struct JobsPage<Content: View>: View {
    let title: String
    let onRefresh: () async -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.palette) private var c

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(c.t1)
                    .padding(.horizontal, 20)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            // Clears the floating tab bar and leaves the last row reachable with a thumb.
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .refreshable { await onRefresh() }
        .background(c.bg)
    }
}

/// A fetch failed — deliberately distinct from an empty list, which would tell the user their queue
/// or archive is gone.
private struct LoadFailedCard: View {
    let onRetry: () -> Void

    @Environment(\.palette) private var c

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18))
                .foregroundStyle(c.t3)
            Text("Couldn't reach the server.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(c.t2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Tap(action: onRetry) {
                Text("Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(c.t1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s3))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(c.line))
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }
}

/// A genuinely empty list, with a line explaining what would fill it.
private struct EmptyState: View {
    let icon: String
    let title: String
    let body: String

    @Environment(\.palette) private var c

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(c.t3)
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(c.s2))
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(c.t1)
                Text(body)
                    .font(.system(size: 13, weight: .medium))
                    .lineSpacing(19 - 13)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(c.t3)
                    .frame(maxWidth: 250)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 48)
    }
}

/// Progress bar with the brand nozzle riding the leading edge and a glow behind the fill.
///
/// The nozzle is offset by a TRANSFORM off the measured track width rather than by a layout change,
/// so a progress update never re-lays-out the row it sits in.
private struct ExtrudeBar: View {
    let pct: Int
    var color: Color
    var track: Color
    var height: CGFloat = 8

    /// Headroom above the bar for the glyph, which overhangs the track.
    private static let nozzleLane: CGFloat = 30
    private static let nozzleWidth: CGFloat = 24

    private var fraction: Double { min(max(Double(pct) / 100, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(track)
                    .frame(width: width, height: height)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color)
                            .frame(width: width * fraction)
                            .shadow(color: color.opacity(0.85), radius: 6)
                    }
                    .offset(y: Self.nozzleLane)

                NozzleGlyph(tip: color)
                    .offset(x: width * fraction - Self.nozzleWidth / 2)
            }
            .animation(Motion.standard(0.7), value: pct)
        }
        .frame(height: height + Self.nozzleLane)
        .accessibilityHidden(true)
    }
}

/// The two-tone nozzle mark used by `ExtrudeBar` — the app's monochrome `NozzleIcon` with the melt
/// zone tinted to the bar's own colour.
private struct NozzleGlyph: View {
    let tip: Color

    /// The artwork's coordinate space, so the shape numbers below match the source drawing exactly.
    private static let viewBox = CGRect(x: 48, y: 30, width: 96, height: 128)

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width / Self.viewBox.width, size.height / Self.viewBox.height)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -Self.viewBox.minX, y: -Self.viewBox.minY)

            let shell = GraphicsContext.Shading.color(Color(hex: 0xC2C7CC))
            ctx.fill(Path(roundedRect: CGRect(x: 60, y: 36, width: 72, height: 50), cornerRadius: 12), with: shell)
            ctx.fill(
                Path(roundedRect: CGRect(x: 60, y: 80, width: 72, height: 9), cornerRadius: 4.5),
                with: .color(Color(hex: 0x878D94))
            )

            var cone = Path()
            cone.move(to: CGPoint(x: 74, y: 92))
            cone.addLine(to: CGPoint(x: 118, y: 92))
            cone.addLine(to: CGPoint(x: 106, y: 128))
            cone.addLine(to: CGPoint(x: 96, y: 150))
            cone.addLine(to: CGPoint(x: 86, y: 128))
            cone.closeSubpath()
            ctx.fill(cone, with: shell)

            ctx.fill(Path(ellipseIn: CGRect(x: 85, y: 106, width: 22, height: 22)), with: .color(tip))
        }
        .frame(width: 24, height: 32)
    }
}

// MARK: - Formatting

/// Currency rendering for the history + stats figures.
enum Money {
    /// Symbol for an ISO code. An unknown code keeps its letters plus a space ("SEK 12.00") rather
    /// than silently pretending to be dollars.
    static func symbol(_ code: String?) -> String {
        switch (code ?? "").uppercased() {
        case "GBP": return "£"
        case "USD", "AUD", "CAD", "NZD": return "$"
        case "EUR": return "€"
        case "JPY", "CNY": return "¥"
        default:
            guard let code, !code.isEmpty else { return "$" }
            return "\(code) "
        }
    }

    static func format(_ symbol: String, _ amount: Double) -> String {
        "\(symbol)\(String(format: "%.2f", amount))"
    }
}

/// Timestamps from the print log.
enum PrintTime {
    /// "5m ago" / "3h ago" / "2d ago", falling back to "Jun 28" past a week.
    static func relative(_ iso: String?, now: Date = Date()) -> String {
        guard let iso, let date = parse(iso) else { return "" }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Bambuddy writes naive timestamps — "2026-06-28T15:07:35.681213" with no zone — and they are
    /// LOCAL time, not UTC. Parsing them as UTC shifted every history row by the offset, which on a
    /// summer BST clock made a print that finished an hour ago read as "just now".
    static func parse(_ iso: String) -> Date? {
        if hasZone(iso) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: iso) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: iso)
        }
        // Fractional seconds come back with 1–6 digits depending on the value, so drop them rather
        // than trying to match a fixed width.
        return naive.date(from: String(iso.prefix(19)))
    }

    private static func hasZone(_ iso: String) -> Bool {
        guard iso.count > 10 else { return false }
        let time = iso.dropFirst(10)
        return time.contains("Z") || time.contains("+") || time.contains("-")
    }

    private static let naive: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}
