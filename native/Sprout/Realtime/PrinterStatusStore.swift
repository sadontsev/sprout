import Foundation
import Observation

/// One frame off the Bambuddy socket. The single socket carries frames for EVERY registered
/// printer, so the printer id has to come out of the frame rather than being assumed.
struct WsFrame: Sendable, Hashable {
    let printerId: Int
    let status: PrinterStatus

    /// Pure: extract (printerId, status) from a raw WS frame, else nil.
    static func parse(_ raw: String) -> WsFrame? {
        guard let data = raw.data(using: .utf8) else { return nil }
        struct Envelope: Decodable {
            let type: String?
            let printerId: Int?
            let data: PrinterStatus?
        }
        guard let env = try? BambuddyClient.decoder.decode(Envelope.self, from: data),
              env.type == "printer_status",
              let id = env.printerId,
              let status = env.data
        else { return nil }
        return WsFrame(printerId: id, status: status)
    }

    /// Pure: a specific printer's status from a raw WS frame, else nil.
    static func status(from raw: String, printerId: Int) -> PrinterStatus? {
        guard let f = parse(raw), f.printerId == printerId else { return nil }
        return f.status
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

    var printerId: Int {
        didSet { if printerId != oldValue { restartPolling() } }
    }

    var status: PrinterStatus? { statuses[printerId] }

    private let client: BambuddyClient
    private var socketTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private static let pollInterval: Duration = .seconds(3)
    private static let reconnectDelay: Duration = .seconds(12)

    init(client: BambuddyClient, printerId: Int) {
        self.client = client
        self.printerId = printerId
    }

    func start() {
        guard socketTask == nil else { return }
        socketTask = Task { [weak self] in
            // Re-acquire `self` each pass rather than awaiting one long-lived call on it, so a
            // dead store is collected instead of being pinned by the loop.
            while !Task.isCancelled {
                guard let self else { return }
                await self.runSocketOnce()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.reconnectDelay)
            }
        }
        restartPolling()
    }

    func stop() {
        socketTask?.cancel()
        socketTask = nil
        pollTask?.cancel()
        pollTask = nil
    }

    // No deinit: `Task` state is main-actor isolated and can't be touched from a nonisolated deinit.
    // The store is owned by the app shell for the process lifetime, and `stop()` is the explicit
    // teardown — both tasks capture `self` weakly, so they unwind on their own if it ever does die.

    // MARK: - Socket

    /// One connect-and-pump cycle. Returns when the socket closes or errors; the caller waits out
    /// the reconnect delay and calls again.
    private func runSocketOnce() async {
        do {
            let token = try await client.mintWsToken()
            guard let url = URL(string: "\(client.wsBaseUrl)/api/v1/ws?token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? token)") else {
                throw SproutError("bad websocket URL")
            }
            let socket = URLSession.shared.webSocketTask(with: url)
            socket.resume()
            connected = true
            restartPolling()   // stops the REST fallback

            defer {
                socket.cancel(with: .goingAway, reason: nil)
                connected = false
                restartPolling()   // resumes the REST fallback
            }

            while !Task.isCancelled {
                let message = try await socket.receive()
                let raw: String? = switch message {
                case .string(let s): s
                case .data(let d): String(data: d, encoding: .utf8)
                @unknown default: nil
                }
                if let raw, let frame = WsFrame.parse(raw) {
                    statuses[frame.printerId] = frame.status
                }
            }
        } catch {
            connected = false
            restartPolling()
        }
    }

    // MARK: - REST fallback

    /// Poll the SELECTED printer while the socket is down, plus one immediate fetch so the first
    /// paint doesn't wait for a socket frame.
    private func restartPolling() {
        pollTask?.cancel()
        guard !connected else { pollTask = nil; return }
        let id = printerId
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let s = try? await self.client.getStatus(id) {
                    self.statuses[id] = s
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }
}
