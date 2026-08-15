import Foundation

// Extracted from CameraPiPRenderer so it survives on macOS, where PiP does not exist but the
// reconnect cadence still governs the camera window (1c) and the inspector tile. Pure arithmetic
// with its own tests — nothing here was ever about PiP.

/// The reconnect cadence, as pure arithmetic so the ceiling is covered by a test rather than by a
/// comment. It is not a tuning knob: a tight retry loop once piled up six subscribers on the
/// on-demand camera and starved it for every other client on the network, so the calm cadence after
/// a run of frameless attempts is the thing that stops a client-side fault taking the camera down
/// for everything else.
enum CameraReconnectPolicy {
    /// Attempts up to and including this one use the fast exponential cadence.
    static let fastAttempts = 5
    static let firstDelay: TimeInterval = 0.4
    static let growth = 1.6
    static let fastCeiling: TimeInterval = 5.0
    static let calmDelay: TimeInterval = 20.0

    /// `attempt` is 1-based: 1 is the first reconnect after a failure.
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let n = max(1, attempt)
        // Fast at first, because the camera self-terminates ~7 s after its last viewer and a slow
        // retry guarantees paying the cold warm-up again.
        guard n <= fastAttempts else { return calmDelay }
        return min(firstDelay * pow(growth, Double(n - 1)), fastCeiling)
    }
}
