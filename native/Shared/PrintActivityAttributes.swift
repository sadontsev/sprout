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

        /// `nil` when there is no ETA. Finiteness is checked because this number arrives as JSON off
        /// the wire: an infinity would otherwise build a nonsense `Date` that compares as a perfectly
        /// good future one.
        var etaDate: Date? {
            guard etaEpochMs > 0, etaEpochMs.isFinite else { return nil }
            return Date(timeIntervalSince1970: etaEpochMs / 1000)
        }

        /// What the card's countdown slot should render *right now*.
        ///
        /// `now` is injected so the decision is testable without waiting on a clock; render sites
        /// call it with the default.
        func countdown(now: Date = Date()) -> LiveActivityCountdown {
            guard let eta = etaDate else { return .hidden }
            // `>` and not `>=`: a zero-length range is a legal `ClosedRange` but renders a timer with
            // nothing left to tick, which is exactly the `.overdue` case.
            guard eta > now else { return .overdue }
            return .ticking(now...eta)
        }
    }

    /// Identifies the card. `printerId` alone was not enough: a drying cycle and a print run
    /// concurrently on the same machine, and with three drying-capable units fitted so do multiple
    /// dry cycles — so the AMS unit is part of the identity too.
    var printerId: Int
    /// nil for a print card; the AMS unit id for a drying card.
    var amsId: Int?
}

/// What a card's countdown slot can show — the only sanctioned way to build a range for
/// `Text(timerInterval:)`.
///
/// `Text(timerInterval:)` takes a `ClosedRange<Date>`, and `...` calls
/// `precondition(lowerBound <= upperBound)`, so `Date()...etaDate` **traps the whole widget
/// process** the instant the stored ETA is in the past. That is routine rather than exotic: a
/// content state is sticky. In local mode the app is the only updater and stops the moment it is
/// suspended, so WidgetKit re-renders the last pushed state on every lock-screen wake and every
/// Dynamic Island expansion thereafter; prints also routinely overrun their own estimate while the
/// app is backgrounded. Clamping the ETA when it is *computed* cannot help — nothing keeps it in the
/// future until it is *rendered*. So no render site forms a range itself; they all switch on this.
enum LiveActivityCountdown: Equatable, Sendable {
    /// No ETA at all. The slot renders nothing, as it always has.
    case hidden
    /// A well-formed future range, safe to hand to `Text(timerInterval:countsDown:)`.
    case ticking(ClosedRange<Date>)
    /// The ETA is known but has passed: static text. Counting *up* from the ETA instead is not an
    /// option — `Text(timerInterval:)` clamps at the range it was given, so an `eta...now` range
    /// would freeze at the instant of the render that built it.
    case overdue

    /// Overdue text for the roomy slots (lock-screen card, expanded Dynamic Island). "Finishing" is
    /// honest for both readings of a passed ETA — a print running over, or a state that went stale
    /// while the app was suspended.
    static let overdueLabel = "Finishing"
    /// Overdue text for the ~44pt compact Dynamic Island slot, where `overdueLabel` would truncate.
    /// Reads as the countdown it replaces, run out.
    static let overdueLabelCompact = "0:00"
}
