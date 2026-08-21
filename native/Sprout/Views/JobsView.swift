#if os(iOS)
// iOS layout. macOS: Views/Mac/Sections/MacJobsSection.
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
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
/// Every fetch lives in `JobsStore` (Domain/), which the Mac Jobs section drives too — this view is
/// layout and alert plumbing only. The sections are pure functions of what the store has loaded.
struct JobsView: View {
    let model: AppModel

    @Environment(\.palette) private var c

    /// Read off `AppModel` rather than passed in or put in the environment: `Shell` already hands
    /// this view the model, so this is the whole of the wiring.
    private var store: JobsStore { model.jobs }

    @State private var confirm: Confirm?
    @State private var notice: Notice?
    @State private var lanAlert = false

    private var locked: LockedActions { LockedActions(mode: model.lanMode, explaining: $lanAlert) }
    private var sym: String { store.currencySymbol }

    var body: some View {
        page
            .lockedActionAlert($lanAlert)
    }

    private var page: some View {
        JobsPage(title: "Jobs", onRefresh: { await store.refreshAll() }) {
            QueueSection(
                items: store.queue,
                failed: store.queueFailed,
                vm: model.vm,
                printerId: model.printerId,
                printers: model.printers,
                onRetry: { Task { await store.loadQueue() } },
                onBrowse: { model.tab = .library },
                onRemove: askRemove
            )
            HistorySection(
                entries: store.entries,
                stats: store.stats,
                failed: store.historyFailed,
                sym: sym,
                client: model.client,
                camToken: model.cameraToken,
                onRetry: { Task { await store.loadHistory() } },
                onReprint: askReprint
            )
        }
        // The store's polls run for as long as these tasks do, and `.task` cancellation is what stops
        // them — so leaving the tab genuinely stops the traffic, exactly as when the loops lived here.
        .task { await store.pollQueue() }
        .task { await store.pollHistory() }
        .task { await store.loadSettings() }
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

    // MARK: - Actions

    private func askRemove(_ j: QueueItem) {
        confirm = Confirm(
            title: "Remove from queue?",
            message: "“\(JobsStore.queueName(j))” won't print.",
            action: "Remove",
            cancel: "Keep",
            destructive: true
        ) {
            remove(j)
        }
    }

    private func remove(_ j: QueueItem) {
        Task {
            let outcome = await store.remove(j)
            present(outcome)
        }
    }

    private func askReprint(_ e: PrintLogEntry) {
        guard e.archiveId != nil else { return }
        // A history row is a list item, not a button. Dimming the whole archive to 40 % would read
        // as broken data, so this one gate explains itself on tap instead of going grey.
        locked.press(.printAgain) {
            confirm = Confirm(
                title: "Print again?",
                message: "“\(JobsStore.historyName(e))” goes back into the queue.",
                action: "Print again",
                cancel: "Cancel",
                destructive: false
            ) {
                reprint(e)
            }
        }()
    }

    private func reprint(_ e: PrintLogEntry) {
        Task {
            let outcome = await store.reprint(e, printerId: model.printerId)
            present(outcome)
        }
    }

    /// Show what an action had to say, if anything. A successful removal says nothing — the row
    /// simply leaves the list.
    private func present(_ message: JobActionMessage?) {
        guard let message else { return }
        notice = Notice(title: message.title, message: message.message)
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

    // The lane split lives in `JobsStore` because the Mac Jobs section applies exactly the same
    // rule, and "which jobs are mine" is the kind of predicate that goes quietly wrong when it is
    // written twice.
    private var upcoming: [QueueItem] { JobsStore.upNext(items, printerId: printerId) }
    private var elsewhere: [QueueItem] { JobsStore.queuedElsewhere(items, printerId: printerId) }
    private var otherNames: [String] { JobsStore.otherPrinterNames(elsewhere, printers: printers) }

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
                Text(JobsStore.queueName(j))
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
            .accessibilityLabel("Remove \(JobsStore.queueName(j)) from the queue")
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
                    message: "Once you finish a print it's archived here with its stats, filament, and cost."
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
                        Text(JobsStore.historyName(entry))
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
                    color: c.t1
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
                    color: c.t1
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    // Live data, not a loop: this updates on every WebSocket frame — roughly once
                    // a second for the whole print — so under Reduce Motion the rolling digits are
                    // continuous motion during the one activity the app exists for. The VALUE still
                    // updates; only the roll is dropped.
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : Motion.roll(0.6), value: value)
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
            // End-of-content breathing room only — the system tab bar insets the safe area for us.
            .padding(.bottom, 32)
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
    // Not `body`: that name is the View protocol requirement.
    let message: String

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
                Text(message)
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
#endif
