#if os(iOS)
// ActivityAttributes does not exist on macOS, and neither does the surface it describes:
// §6 keeps Live Activities and SproutWidget on iOS, with the menu bar extra (1b) as the Mac
// equivalent. LAColors travels with it because it exists only to match what Trellis pushes
// into a card — there is no card on macOS to match.
import ActivityKit
import Foundation

/// Shared between the app (which starts/updates activities) and the widget extension (which renders
/// them). Lives in `Shared/` so both targets compile one definition — a mismatch silently produces a
/// blank card.
///
/// **The property names are a wire format.** Trellis pushes this content state as JSON over APNs, so
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
        /// `square.stack.3d.up.fill` — layers stacking upward, which is what an FDM machine does.
        /// NOT `printer.fill`, a sheet-fed office printer that reads as the wrong appliance; the app
        /// already sends the right value, but a Trellis push that omits `symbol` fell back to it.
        var symbol: String = "square.stack.3d.up.fill"
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

        /// Chamber temperature — **enclosed machines only**, and `nil` is the capability signal.
        ///
        /// `nil` means "this printer has no chamber", which is NOT the same question as "the chamber
        /// reads 0°". An open-frame machine (A1, P1P) reports no `chamber` key at all, so a
        /// non-optional `Int = 0` here would put a confident `C 0°` on its card — the exact shape of
        /// bug this codebase keeps re-learning. Presence is mirrored on both producers: the app reads
        /// `Temperatures.chamber != nil` (same predicate as `DashVM.hasChamber`, so the card and the
        /// dashboard cannot disagree), and Trellis omits the key entirely rather than sending 0.
        ///
        /// `chamberTarget` is only ever set alongside `chamber`, so a target can never appear for a
        /// machine that has no chamber to heat. The H2C does drive this — an ABS/ASA run heats the
        /// chamber — so the readout is `C 31° → 50°` while chasing and `C 31°` once settled.
        var chamber: Int?
        var chamberTarget: Int?

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

        /// One row per unit, when this card AGGREGATES several drying cycles.
        ///
        /// Empty or nil on a single-unit card, which keeps using the flat `amsTemp`/`amsTarget`/
        /// `humidity` fields above — so an old client, or a Trellis that has not been redeployed yet,
        /// renders exactly what it did before rather than a blank card. That matters because the two
        /// halves ship separately in practice however hard we try.
        ///
        /// **A new field is invisible to the card until it is in `meaningfulChange`.** Every push is
        /// gated on that comparison, so a row whose temperature moved while nothing else did would
        /// never reach the widget.
        var dryUnits: [DryUnitState]?



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


    /// One unit's line on an aggregate drying card.
    ///
    /// Names are wire format, same as `ContentState`'s — Trellis builds these server-side.
    struct DryUnitState: Codable, Hashable, Sendable, Identifiable {
        var amsId: Int
        /// `AMS 1`, `AMS HT` — the printer's own label, not derived, because the HT is not "AMS 3".
        var label: String = ""
        var filament: String = ""
        var temp: Int = 0
        var target: Int = 0
        var humidity: Int = 0
        /// Minutes remaining. The rows sort by this, soonest first.
        var minutesLeft: Int = 0

        var id: Int { amsId }
    }

    /// Identifies the card. `printerId` alone was not enough: a drying cycle and a print run
    /// concurrently on the same machine, and with three drying-capable units fitted so do multiple
    /// dry cycles — so the AMS unit is part of the identity too.
    var printerId: Int
    /// nil for a print card; the AMS unit id for a drying card; `aggregateAmsId` for one card
    /// standing in for several units.
    var amsId: Int?

    /// The sentinel identity for an aggregate drying card, and Trellis's `dry:<printerId>:all`.
    ///
    /// Negative because unit ids are indices and can never be: a real id colliding with the sentinel
    /// would make the aggregate replace a unit's own card.
    static let aggregateAmsId = -1
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
    /// How a live ETA should read.
    ///
    /// A duration answers "how long until I can stop waiting", which is the wrong question for a
    /// print: nobody stands over a ten-hour job. A wall-clock finish answers "when do I come back",
    /// which is what the small slots are glanced at for, and it matches what the app's own dashboard
    /// already says ("done ~ 9:22 PM"). The roomy slots keep the ticking duration, where watching it
    /// move is the point.
    enum Style: Equatable, Sendable {
        /// A ticking duration, e.g. "1:21:04".
        case remaining
        /// The wall-clock time the print is expected to end, e.g. "21:47".
        case finishClock
    }

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
#endif
