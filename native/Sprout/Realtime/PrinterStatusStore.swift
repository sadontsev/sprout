import Foundation
import Observation
import OSLog

private let statusLog = Logger(subsystem: "com.mvks5.bambu", category: "status")

/// One frame off the Bambuddy socket. The single socket carries frames for EVERY registered
/// printer, so the printer id has to come out of the frame rather than being assumed.
struct WsFrame: Sendable, Hashable {
    let printerId: Int
    let status: PrinterStatus

    /// What a raw frame turned out to be.
    ///
    /// The three-way split matters to the caller. A heartbeat is nothing to worry about; a frame we
    /// cannot READ is a lost status update, and while the socket is up the REST fallback is off — so
    /// swallowing it leaves the dashboard frozen on the last good frame with nothing to show for it.
    /// `PrinterStatus` is not uniformly lenient (`nozzle_rack[].id`, `AmsTray.id` and friends are
    /// plain `Int`s, and `connected`/`state` are required despite their defaults), so one stringified
    /// numeric from a firmware revision loses the whole payload.
    enum Outcome: Sendable, Equatable {
        case status(WsFrame)
        /// Well-formed, just not a status push (heartbeats, job events…).
        case ignored
        /// Should have carried a status and didn't. The payload is never included — only the field
        /// name — because this is logged.
        case undecodable(String)
    }

    private struct Envelope: Decodable {
        let type: String?
        let printerId: Int?
        let data: PrinterStatus?
    }

    /// Just the discriminator. Decoded on its own so a status payload the strict fields reject can
    /// still be IDENTIFIED as a lost status, and — the other way round — so a frame of some other
    /// type whose `data` happens not to look like a `PrinterStatus` is not mistaken for one.
    private struct Kind: Decodable { let type: String? }

    /// Pure: classify a raw WS frame.
    static func classify(_ raw: String) -> Outcome {
        guard let data = raw.data(using: .utf8) else { return .undecodable("frame was not valid UTF-8") }
        do {
            let env = try BambuddyClient.decoder.decode(Envelope.self, from: data)
            guard env.type == "printer_status" else { return .ignored }
            guard let id = env.printerId, let status = env.data else {
                return .undecodable("printer_status frame carried no status")
            }
            return .status(WsFrame(printerId: id, status: status))
        } catch {
            if let kind = try? BambuddyClient.decoder.decode(Kind.self, from: data),
               let type = kind.type, type != "printer_status" {
                return .ignored
            }
            return .undecodable(reason(error))
        }
    }

    /// Pure: extract (printerId, status) from a raw WS frame, else nil.
    static func parse(_ raw: String) -> WsFrame? {
        guard case .status(let frame) = classify(raw) else { return nil }
        return frame
    }

    /// Pure: a specific printer's status from a raw WS frame, else nil.
    static func status(from raw: String, printerId: Int) -> PrinterStatus? {
        guard let f = parse(raw), f.printerId == printerId else { return nil }
        return f.status
    }

    /// A short, value-free description of a decoding failure: field NAMES only, never the payload,
    /// since the caller logs this. "missing field 'state'" is the difference between a mystery and a
    /// diagnosis when the dashboard goes quiet.
    private static func reason(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return "status frame could not be decoded" }
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch e {
        case .keyNotFound(let key, let ctx):
            let p = path(ctx)
            return "missing field '\(p.isEmpty ? key.stringValue : p + "." + key.stringValue)'"
        case .typeMismatch(_, let ctx):
            let p = path(ctx)
            return p.isEmpty ? "frame was not the expected shape" : "wrong type for field '\(p)'"
        case .valueNotFound(_, let ctx):
            let p = path(ctx)
            return p.isEmpty ? "frame carried no value" : "null in non-optional field '\(p)'"
        case .dataCorrupted(let ctx):
            let p = path(ctx)
            return p.isEmpty ? "frame was not valid JSON" : "malformed value in field '\(p)'"
        @unknown default:
            return "status frame could not be decoded"
        }
    }
}

/// Live printer status via WebSocket, with a REST-poll fallback for the selected printer while the
/// socket is down (and periodic reconnect attempts).
///
/// Exposes the selected printer's status plus the latest known status of every printer seen on the
/// socket — the fleet switcher and the Live Activity's "follow the printing machine" logic read the
/// map.
///
/// The socket is per-CLIENT, not per-printer: switching printers must not drop it.
@MainActor
@Observable
final class PrinterStatusStore {
    private(set) var statuses: [Int: PrinterStatus] = [:]
    private(set) var connected = false

    /// Why the last frame was thrown away, and how many this connection has lost. Surfaced rather
    /// than swallowed: a frozen dashboard is otherwise indistinguishable from a quiet printer. Both
    /// reset when a new connection is established.
    private(set) var lastFrameError: String?
    private(set) var droppedFrames = 0

    var printerId: Int {
        didSet {
            guard printerId != oldValue else { return }
            restartPolling()
            // A printer we have never seen on the socket has no status at all until it next pushes
            // one, so the switch would paint an empty dashboard for the gap.
            seedStatus()
        }
    }

    var status: PrinterStatus? { statuses[printerId] }

    private let client: BambuddyClient
    private var socket: URLSessionWebSocketTask?
    private var socketTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var seedTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    /// When a status last ARRIVED, from any source. The watchdog's only input.
    private var lastStatusAt = ContinuousClock.now

    /// Set by `start()`, cleared by `stop()`. Everything that (re)arms a task consults it, because
    /// the socket unwinding calls back into `restartPolling()` on its way out — after `stop()` has
    /// already returned, in the exact case where the store is being dropped.
    private var running = false

    /// This connection has already lost a frame, so the socket is no longer a COMPLETE source of
    /// status and the REST poll runs alongside it. Latched for the life of the connection rather
    /// than cleared on the next good frame: flapping the poll on and off per frame would cost more
    /// than simply paying for it once.
    private var socketDegraded = false

    private static let pollInterval: Duration = .seconds(3)
    private static let reconnectDelay: Duration = .seconds(12)

    /// How long status may be silent before the socket is treated as dead.
    ///
    /// Generous on purpose. While a print is running frames arrive far more often than this, so a
    /// 90-second silence is not a quiet printer — it is a connection that has stopped delivering. An
    /// idle printer may genuinely have nothing to say, and tripping the watchdog then costs only the
    /// REST poll, which is the correct behaviour anyway: if we cannot tell "idle and quiet" from
    /// "socket is dead", we must assume the second and go and ask.
    private static let staleAfter: Duration = .seconds(90)
    private static let watchdogInterval: Duration = .seconds(15)

    init(client: BambuddyClient, printerId: Int) {
        self.client = client
        self.printerId = printerId
    }

    func start() {
        guard socketTask == nil else { return }
        running = true
        socketTask = Task { [weak self] in
            // `self` is re-acquired each pass rather than held across the whole loop — but that alone
            // does not bound the store's lifetime, because `runSocketOnce` pins it for as long as the
            // socket is pumping. `stop()` closing the socket is what actually lets a pass return.
            while !Task.isCancelled {
                guard let self else { return }
                await self.runSocketOnce()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.reconnectDelay)
            }
        }
        seedStatus()
        restartPolling()
        startWatchdog()
    }

    func stop() {
        running = false
        // Cancelling the Task is NOT enough. `URLSessionWebSocketTask.receive()` is the async form of
        // a completion-handler API: it does not observe Swift task cancellation, so a receive parked
        // on an idle printer never resumes, the `defer` that closes the socket never runs, and the
        // suspended call pins both the connection and the store for the process lifetime. Closing the
        // socket here is what makes that receive throw and the task unwind.
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketTask?.cancel()
        socketTask = nil
        pollTask?.cancel()
        pollTask = nil
        seedTask?.cancel()
        seedTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        connected = false
    }

    // No deinit: `Task` state is main-actor isolated and can't be touched from a nonisolated deinit.
    // `stop()` is the explicit teardown — and the only one that closes the socket, so a store that is
    // merely dropped without it stays alive behind its own parked receive.

    // MARK: - Socket

    /// One connect-and-pump cycle. Returns when the socket closes or errors; the caller waits out
    /// the reconnect delay and calls again.
    private func runSocketOnce() async {
        defer {
            // However this ended — mint failure, close, cancellation — the REST fallback is the
            // safety net on the way out. `restartPolling()` itself refuses once `stop()` has run.
            connected = false
            restartPolling()
        }
        do {
            let token = try await client.mintWsToken()
            guard let url = URL(string: "\(client.wsBaseUrl)/api/v1/ws?token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? token)") else {
                throw SproutError("bad websocket URL")
            }
            let socket = URLSession.shared.webSocketTask(with: url)
            socket.resume()
            self.socket = socket
            defer {
                socket.cancel(with: .goingAway, reason: nil)
                // Only if it is still ours: `stop()` may have replaced or cleared it already.
                if self.socket === socket { self.socket = nil }
            }

            socketDegraded = false
            lastFrameError = nil
            droppedFrames = 0
            connected = true
            restartPolling()   // stops the REST fallback — the one-shot seed fetch is separate

            while !Task.isCancelled {
                let message = try await socket.receive()
                let raw: String? = switch message {
                case .string(let s): s
                case .data(let d): String(data: d, encoding: .utf8)
                @unknown default: nil
                }
                guard let raw else { noteDroppedFrame("frame was not valid UTF-8"); continue }
                switch WsFrame.classify(raw) {
                case .status(let frame):
                    statuses[frame.printerId] = frame.status
                    lastStatusAt = ContinuousClock.now
                case .ignored: break
                case .undecodable(let why): noteDroppedFrame(why)
                }
            }
        } catch {
            // Never log the error itself: `URLError`'s description carries `NSErrorFailingURL`, which
            // is the socket URL WITH the auth token in its query. The code alone is safe.
            let code = (error as? URLError)?.code.rawValue ?? 0
            statusLog.debug("websocket ended (urlerror \(code, privacy: .public)); REST fallback resumes")
        }
    }

    /// A frame arrived and was thrown away. Record it, say so, and stop trusting the socket as the
    /// only source of status for the rest of this connection.
    private func noteDroppedFrame(_ why: String) {
        droppedFrames += 1
        lastFrameError = why
        statusLog.error("dropped a websocket frame: \(why, privacy: .public)")
        guard !socketDegraded else { return }
        socketDegraded = true
        restartPolling()
    }

    // MARK: - REST fallback

    /// One immediate REST read so the first paint doesn't wait for a socket frame.
    ///
    /// Deliberately NOT the first iteration of the poll loop: `runSocketOnce` tears the poll down the
    /// instant the socket resumes, and `URLSession.data(for:)` is cancellation-aware — so whenever
    /// the token mint won the race (a POST against a GET, comparable latency) the very fetch that
    /// exists to seed the first paint was aborted mid-flight and never replaced.
    private func seedStatus() {
        seedTask?.cancel()
        guard running else { seedTask = nil; return }
        let id = printerId
        seedTask = Task { [weak self] in
            guard let self, let s = try? await self.client.getStatus(id) else { return }
            guard !Task.isCancelled else { return }
            // A socket frame that landed while this was in flight is fresher — don't overwrite it.
            if self.statuses[id] == nil {
                self.statuses[id] = s
                self.lastStatusAt = ContinuousClock.now
            }
        }
    }

    /// Is a connection that has said nothing since `lastStatusAt` dead?
    ///
    /// Pure and static so the rule can be tested without a socket, a clock or a server.
    /// `threshold` has no default: a `@MainActor` static cannot supply one to a `nonisolated`
    /// signature, and passing it explicitly is what lets a test choose its own without a clock.
    nonisolated static func isStale(
        lastStatusAt: ContinuousClock.Instant,
        now: ContinuousClock.Instant,
        threshold: Duration
    ) -> Bool {
        now - lastStatusAt > threshold
    }

    /// Notice a socket that has gone SILENT rather than broken, and force it to be rebuilt.
    ///
    /// This is the gap that let a Mac show a two-print-old "Complete" over a machine that was
    /// printing. The recovery paths this store already had both key on the socket FAILING: a thrown
    /// error unwinds `runSocketOnce`, which flips `connected` and lets `restartPolling` run the REST
    /// fallback. A socket that is merely dead — which is what a Mac waking from sleep, a changed
    /// network or a silently dropped TCP connection leaves behind — never throws. `receive()` stays
    /// parked (this file already documents that it does not observe cancellation), `connected` stays
    /// true, and `restartPolling`'s `guard !connected || socketDegraded` therefore REFUSES to poll.
    /// Nothing was left to notice, so the last frame stayed on screen indefinitely while the camera —
    /// a separate connection — kept working and made the app look healthy.
    ///
    /// iOS mostly escapes this because the system suspends the app and tears the socket down properly,
    /// so resuming reconnects. A Mac app stays open across sleep for hours, which is why this surfaced
    /// there.
    ///
    /// The remedy is deliberately the existing machinery rather than a new path: closing the socket is
    /// exactly what `stop()` does to unwind a parked receive, and everything downstream — `connected`
    /// going false, `restartPolling()` on the way out, the reconnect loop after `reconnectDelay` —
    /// already works and is already reasoned about.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchdogInterval)
                guard let self, !Task.isCancelled, self.running else { return }
                guard self.connected,
                      Self.isStale(lastStatusAt: self.lastStatusAt,
                                   now: ContinuousClock.now,
                                   threshold: Self.staleAfter)
                else { continue }
                statusLog.debug("status silent past the watchdog threshold; rebuilding the socket")
                // Stamped BEFORE closing, so a reconnect that takes a moment cannot trip the watchdog
                // again immediately and close the socket it is still opening.
                self.lastStatusAt = ContinuousClock.now
                self.socket?.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    /// Poll the SELECTED printer while the socket is down — or alongside a socket that has dropped a
    /// frame, since it is then not carrying every update.
    private func restartPolling() {
        pollTask?.cancel()
        pollTask = nil
        guard running else { return }
        guard !connected || socketDegraded else { return }
        let id = printerId
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let s = try? await self.client.getStatus(id) {
                    self.statuses[id] = s
                    self.lastStatusAt = ContinuousClock.now
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }
}
