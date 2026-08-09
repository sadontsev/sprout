import ActivityKit
import Foundation

/// Fixed palette for Live Activity content — deliberately NOT the app's theme tokens.
///
/// A card lives on the lock screen, which has no relationship to the in-app theme, and la-push
/// (which owns cards in server mode) has no idea what theme the phone is on: it always sends these
/// values. Reading the themed colour meant a light-mode app produced #23B24A while an identical card
/// pushed from the server produced #30D158 — the same print rendering in two different greens
/// depending on which side created it. **These MUST equal la-push's COLORS.**
enum LAColors {
    static let running = "#30D158"
    static let heating = "#FF9F0A"
    static let paused = "#0A84FF"
    static let error = "#FF453A"
    static let idle = "#8E9398"
    /// Drying amber — matches la-push's `dry_state`.
    static let drying = "#FFB86C"
}

/// Shared between the app (which starts/updates activities) and the widget extension (which renders
/// them). Lives in `Shared/` so both targets compile one definition — a mismatch silently produces a
/// blank card.
///
/// **The property names are a wire format.** la-push pushes this content state as JSON over APNs, so
/// every name here has to match what the server sends, field for field. Renaming one breaks remote
/// updates without breaking the build.
struct PrintActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// Which machine this card is for — one activity per printer.
        var printerName: String = ""
        /// Subtask/file name.
        var name: String = ""
        var stateLabel: String = ""
        /// 0...100.
        var progress: Int = 0
        var layer: Int = 0
        var totalLayers: Int = 0
        /// Absolute finish time, ms since epoch; 0 if unknown. Rendered as a native ticking timer, so
        /// the countdown costs no pushes.
        var etaEpochMs: Double = 0
        var finished: Bool = false
        /// SF Symbol name.
        var symbol: String = "printer.fill"
        /// `file://` URI of the brand nozzle glyph in the App Group ("" falls back to `symbol`).
        var iconUri: String = ""
        /// Hex accent — one of `LAColors`.
        var tint: String = LAColors.running

        // Nozzles are physical: `nozzle` is the left/only head, `nozzle2` the right (H2-series).
        var nozzle: Int = 0
        var nozzleTarget: Int = 0
        var nozzle2: Int = 0
        var nozzle2Target: Int = 0
        /// True on dual-nozzle machines — show both, one labelled active.
        var hasNozzle2: Bool = false
        /// 0 = left/only, 1 = right — which head is currently driven.
        var activeNozzle: Int = 0
        var bed: Int = 0
        var bedTarget: Int = 0

        /// `file://` URI of the plate thumbnail in the App Group ("" falls back to the glyph).
        var modelUri: String = ""
        var queueCount: Int = 0
        var nextName: String = ""

        // ---- AMS drying card (a second activity per unit; the widget branches on `dry`) ----
        /// True when this card shows a DRYING cycle rather than a print.
        var dry: Bool?
        var amsTemp: Int?
        var amsTarget: Int?
        var humidity: Int?

        var etaDate: Date? {
            etaEpochMs > 0 ? Date(timeIntervalSince1970: etaEpochMs / 1000) : nil
        }
    }

    /// Identifies the card. `printerId` alone was not enough: a drying cycle and a print run
    /// concurrently on the same machine, and with three drying-capable units fitted so do multiple
    /// dry cycles — so the AMS unit is part of the identity too.
    var printerId: Int
    /// nil for a print card; the AMS unit id for a drying card.
    var amsId: Int?
}
