import Foundation
import Observation

/// What a mutating queue action produced, ready to be shown as a one-button message — `nil` from an
/// action means "it worked and there is nothing to say".
///
/// The store runs the network and reloads the queue; the CALLER decides how to present this,
/// because an iOS alert and a Mac sheet are the same fact told two ways.
struct JobActionMessage: Equatable, Sendable {
    let title: String
    let message: String
    /// Did the action WORK?
    ///
    /// It was implied by which string was built and by nothing else, so every consumer had to infer
    /// it from the copy — and the Mac toast, which decorates by outcome, had no way to. "Queued —
    /// the job is back in the queue" was rendered under a warning triangle.
    let succeeded: Bool

    static func ok(_ title: String, _ message: String) -> JobActionMessage {
        JobActionMessage(title: title, message: message, succeeded: true)
    }

    static func failed(_ title: String, _ message: String) -> JobActionMessage {
        JobActionMessage(title: title, message: message, succeeded: false)
    }
}

/// The Jobs section's data layer: the live queue, the print-history archive, and the two mutating
/// actions those lists offer.
///
/// Both halves poll on their own cadence (queue 5 s, history 15 s) but the fetches live here rather
/// than inside a view, so pull-to-refresh can await a real completion instead of the RN build's
/// remount-and-guess-600 ms trick — and so the iOS tab and the Mac Jobs section drive ONE copy of
/// this instead of two that drift. The sections on either platform are pure functions of what is
/// loaded here.
@Observable
@MainActor
final class JobsStore {

    // MARK: What is loaded

    // nil means "never loaded" — the spinner state. A FAILED fetch is not an empty list, so a
    // failure falls back to whatever was on screen (or []) and raises the retry flag instead.
    private(set) var queue: [QueueItem]?
    private(set) var queueFailed = false
    private(set) var entries: [PrintLogEntry]?
    private(set) var historyFailed = false
    private(set) var stats: ArchiveStats?
    /// Whether the archive summary has been ASKED for since this session began, and whether the last
    /// ask failed.
    ///
    /// Three states hide behind a nil `stats` and a card that renders them as one will lie in two of
    /// them: not asked yet, asked and refused, asked and the server has nothing. `loadHistory`
    /// fetches the list and the summary in sequence, so between the two responses `stats` is nil on
    /// every cold load — and a card keyed on nil alone announced "Lifetime totals unavailable · it
    /// didn't answer" about a request that had not answered YET.
    private(set) var statsAsked = false
    private(set) var statsFailed = false
    /// Currency comes from server settings, read once — it only changes when the user edits it on
    /// the server.
    private(set) var currency: String?
    /// Whether this session's server settings have been requested yet. See `loadQueue`.
    private var settingsAsked = false

    /// The symbol every money figure in this section is rendered with.
    var currencySymbol: String { Money.symbol(currency) }

    // MARK: Cadences

    /// The queue is the half that changes under you — a job you just sent should appear without a
    /// manual refresh.
    nonisolated static let queueCadence: Duration = .seconds(5)
    /// The archive only gains a row when a print ENDS, so it is polled three times more slowly.
    nonisolated static let historyCadence: Duration = .seconds(15)

    // MARK: Wiring

    private var client: BambuddyClient?
    private var queueTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?

    // MARK: - Session

    /// Point the store at a session's client: on connect, on a re-Save, and with `nil` on sign-out.
    ///
    /// Swapping the client CLEARS what is loaded. A queue and an archive belong to the server they
    /// came from, and `nil` here means "never loaded for THIS connection" — which is exactly what
    /// the spinner claims. Re-attaching the same client is a no-op, so a repeated call can never
    /// blank a screen that is already showing that server's jobs.
    ///
    /// Running polls are deliberately left alone: each pass reads `client` fresh, so a swap is
    /// picked up on the next tick without restarting anything.
    func attach(client: BambuddyClient?) {
        guard client !== self.client else { return }
        self.client = client
        queue = nil
        queueFailed = false
        entries = nil
        historyFailed = false
        stats = nil
        statsAsked = false
        statsFailed = false
        currency = nil
        settingsAsked = false
    }

    // MARK: - Polling

    /// Poll for as long as the CALLER's task lives. iOS drives this from `.task`, so leaving the tab
    /// cancels it and genuinely stops the traffic.
    func pollQueue() async {
        await poll(every: Self.queueCadence, loadQueue)
    }

    /// As `pollQueue`, on the archive's slower cadence.
    func pollHistory() async {
        await poll(every: Self.historyCadence, loadHistory)
    }

    /// Run `work` now and then on an interval until the caller's task is cancelled.
    private func poll(every interval: Duration, _ work: () async -> Void) async {
        while !Task.isCancelled {
            await work()
            try? await Task.sleep(for: interval)
        }
    }

    /// Start polling that the store OWNS, for a host with no view lifetime to lend — the Mac window
    /// keeps a section mounted whether or not it is the visible one, so `stop()` is what ends the
    /// traffic there. Idempotent: a second call does not double the poll.
    func start() {
        guard queueTask == nil else { return }
        queueTask = poller(every: Self.queueCadence) { await $0.loadQueue() }
        historyTask = poller(every: Self.historyCadence) { await $0.loadHistory() }
        settingsTask = Task { [weak self] in await self?.loadSettings() }
    }

    func stop() {
        queueTask?.cancel()
        queueTask = nil
        historyTask?.cancel()
        historyTask = nil
        settingsTask?.cancel()
        settingsTask = nil
    }

    /// A store-owned poll loop. `self` arrives as a parameter and is re-acquired on EVERY pass,
    /// never held across a sleep: binding it once outside the loop turns the weak capture into a
    /// strong one for the loop's whole life — and since the loop only exits on cancellation, and the
    /// task is owned by the very object it pins, nothing could ever release it. `CooldownStore`
    /// learnt this the expensive way, leaking a poller that kept calling a stale client forever.
    private func poller(
        every interval: Duration,
        _ work: @escaping @Sendable (JobsStore) async -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await work(self)
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: - Loading

    func loadQueue() async {
        guard let client else { return }
        // Self-healing, rather than relying on a view to ask again. `attach` clears `currency` on a
        // session change, but the iOS view's `.task { loadSettings() }` is un-keyed and does not
        // re-run when the client is swapped underneath it — so after Settings -> Save with Jobs on
        // screen, every cost in the archive would have rendered with the default "$" for the rest
        // of the session. Costs are money; a wrong symbol is a wrong number.
        if !settingsAsked { await loadSettings() }
        do {
            queue = try await client.listQueue()
            queueFailed = false
        } catch {
            queue = queue ?? []
            queueFailed = true
        }
    }

    func loadHistory() async {
        guard let client else { return }
        do {
            entries = try await client.getPrintLog(limit: 50).items
            historyFailed = false
        } catch {
            entries = entries ?? []
            historyFailed = true
        }
        // Stats are decoration on top of the list: losing them silently drops the banner rather
        // than claiming the whole archive failed to load. But "dropped" has to be distinguishable
        // from "not fetched yet" — see `statsAsked`.
        do {
            stats = try await client.getArchiveStats()
            statsFailed = false
        } catch {
            statsFailed = true
        }
        statsAsked = true
    }

    func loadSettings() async {
        guard let client else { return }
        currency = (try? await client.getSettings())?.currency
        // Set even when the read failed or the server has no currency configured. It records
        // "we have asked", not "we got an answer" — otherwise a server with no currency set would
        // be re-asked on every 5 s poll forever.
        settingsAsked = true
    }

    /// What pull-to-refresh and ⌘R call. Settings are not refetched: the currency changes only when
    /// the user edits it on the server, and it is already read once per session.
    func refreshAll() async {
        await loadQueue()
        await loadHistory()
    }

    // MARK: - Actions

    /// Drop a queued job.
    ///
    /// Cancelling a queue item is Bambuddy-side bookkeeping — the printer is never asked — so it is
    /// deliberately NOT LAN-gated. Says nothing when it works: the row simply leaves the list.
    func remove(_ job: QueueItem) async -> JobActionMessage? {
        guard let client else { return nil }
        do {
            try await client.queueAction(job.id, action: "cancel")
            await loadQueue()
            return nil
        } catch {
            return .failed("Couldn't remove", Self.failureText(error))
        }
    }

    /// Put a finished print back in the queue.
    ///
    /// `printerId` is a parameter rather than store state because the selection lives on `AppModel`
    /// and changes without the session being rebuilt — a copy here would be the stale one.
    func reprint(_ entry: PrintLogEntry, printerId: Int) async -> JobActionMessage? {
        guard let client, let archiveId = entry.archiveId else { return nil }
        do {
            try await client.reprint(archiveId: archiveId, printerId: printerId)
            // Show the new job immediately rather than up to 5 s later. Kicked off rather than
            // awaited, so the acknowledgement still lands the instant the POST returns — awaiting a
            // queue GET first would hold the alert behind a whole extra round-trip. `remove` awaits
            // its reload because it has nothing to say and the caller's await IS the completion.
            Task { await self.loadQueue() }
            return .ok("Queued", "The job is back in the queue.")
        } catch {
            return .failed("Couldn't reprint", Self.failureText(error))
        }
    }

    // MARK: - Queue lanes

    /// Jobs that have not started yet. Both spellings the backend uses for "waiting".
    nonisolated static func pending(_ items: [QueueItem]?) -> [QueueItem] {
        (items ?? []).filter { $0.status == "pending" || $0.status == "queued" }
    }

    /// The queue is backend-global; a Jobs section shows the selected printer's lane, with
    /// untargeted jobs included because they can land here.
    nonisolated static func upNext(_ items: [QueueItem]?, printerId: Int) -> [QueueItem] {
        pending(items).filter { $0.printerId == nil || $0.printerId == printerId }
    }

    /// The rest of the pending queue: jobs pinned to some other machine.
    nonisolated static func queuedElsewhere(_ items: [QueueItem]?, printerId: Int) -> [QueueItem] {
        pending(items).filter { !($0.printerId == nil || $0.printerId == printerId) }
    }

    /// Distinct printer names, in queue order.
    nonisolated static func otherPrinterNames(_ jobs: [QueueItem], printers: [Printer]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for j in jobs {
            let name = j.printerName ?? printers.first { $0.id == j.printerId }?.name ?? "another printer"
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    // MARK: - Naming

    nonisolated static func queueName(_ j: QueueItem) -> String {
        j.libraryFileName ?? j.archiveName ?? "Job \(j.id)"
    }

    nonisolated static func historyName(_ e: PrintLogEntry) -> String {
        e.printName ?? "Print \(e.id)"
    }

    /// Bambuddy's own `detail` string when it sent one — a 409's "AMS is busy" is far more useful
    /// than a transport description.
    nonisolated static func failureText(_ error: Error) -> String {
        (error as? BambuddyError)?.detail ?? error.localizedDescription
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
