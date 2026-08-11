import Foundation
import Network
import Observation

/// Whether the bytes the app is about to spend cost the user anything.
///
/// `NWPathMonitor` answers this directly — `isExpensive` for cellular and personal hotspots,
/// `isConstrained` for Low Data Mode — so nothing here infers it from the interface type, which would
/// be a stand-in for the question rather than the question. The only consumer today is the dashboard
/// camera tile (`CameraRate`), which streams continuously and is the one surface that can quietly
/// burn an allowance.
@MainActor
@Observable
final class NetworkPathCost {

    private(set) var isExpensive = true
    private(set) var isConstrained = false

    /// False until the first path update lands, and the reason callers should hold off rather than
    /// guess. The camera tile puts its rate in the stream URL, so a guess that turns out wrong changes
    /// that URL a moment later — and changing it restarts the connection, which is a visible hiccup on
    /// every launch traded for a few milliseconds. `NWPathMonitor` reports the current path almost
    /// immediately after `start`, so waiting costs approximately nothing.
    ///
    /// The initial `isExpensive = true` above is the safe reading for anything that ignores this flag:
    /// briefly treating home wifi as metered costs a low-resolution thumbnail, while the opposite
    /// mistake spends a cellular allowance before the monitor can correct it.
    private(set) var resolved = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "bambu.network.path")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Read the flags off the path HERE and send only the two Bools across the hop. The handler
            // runs on `queue`, and carrying the whole NWPath over the main-actor boundary to read two
            // booleans off it is work for nothing.
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isExpensive = expensive
                self.isConstrained = constrained
                self.resolved = true
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        // `cancel()` is not actor-isolated and the monitor is only ever handed to `start`, so this is
        // safe from a deinit that may run anywhere.
        monitor.cancel()
    }
}
