import Foundation
import ActivityKit

/// Shared between the app (which starts/updates the activity) and the widget extension (which
/// renders it). Lives in `Shared/` so both targets compile the same definition — a mismatch here
/// silently produces a blank Live Activity.
struct PrintActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var stateLabel: String
        var progress: Double        // 0...1
        var etaText: String
        var doneText: String
        var layer: String
        var totalLayers: String
        var nozzleNow: Int
        var nozzleTarget: Int
        var bedNow: Int
        var bedTarget: Int
        var isPaused: Bool
        var kind: String            // DashKind raw value
    }

    var printerName: String
    var jobName: String
}
