import Foundation

// When is the plate cool enough to take the print off?
//
// The one number any vendor actually publishes is Bambu's own, for the Textured PEI plate: "we
// always recommend waiting until it reaches 35℃ or lower", stated for the HEATBED — which is
// exactly the sensor we read (`Temperatures.bed`). Everything else in circulation is either a bed
// SETPOINT (55-80°C, a different quantity entirely) or an unsourced extrapolation.
//
// Two traps this module exists to avoid:
//
// 1. A threshold at or below room temperature can NEVER be reached — a passively cooling plate
//    approaches ambient asymptotically and cannot cross it. Picking a "safely cool" 25°C would mean
//    the notification silently never fires. This office sits around 28°C, so even 35°C is only a few
//    degrees of headroom. Hence `.stalled`: when the plate has levelled off, or the measured room is
//    already at the target, we say so instead of waiting forever for a number that will never
//    arrive.
// 2. Glass transition is a poor predictor of release (PLA releases ~25°C below Tg, PETG can stay
//    welded to smooth PEI 45°C below it, and TPU has no Tg above room temperature at all). So there
//    is no per-material threshold table here on purpose. Material only ever changes the WORDING.

/// Where a plate is in its cooldown.
enum CooldownPhase: String, Sendable, Hashable {
    case none, cooling, ready, stalled
}

/// How hot the readout should look. A semantic token, resolved to a colour by the view — the
/// view-model never stores a `Color`.
enum CooldownTone: String, Sendable, Hashable {
    case hot, warm, ready
}

/// One bed-temperature reading.
struct BedSample: Sendable, Hashable {
    /// When the reading was taken.
    var t: Date
    /// Bed temperature, °C.
    var c: Double
}

/// A Newton-cooling model of the plate: where it is heading, and how fast.
struct CoolingFit: Sendable, Hashable {
    /// Room temperature the plate is decaying toward. MEASURED (`Cooling.estimateAmbient`), never
    /// fitted from the curve itself.
    var ambientC: Double
    /// Newton cooling constant, per minute.
    var kPerMin: Double
}

/// Everything the cooldown card, notification and Live Activity need to say.
struct CooldownVM: Sendable, Hashable {
    var phase: CooldownPhase
    var bedC: Double
    var thresholdC: Double
    /// Minutes until the threshold. nil when unknown or unreachable.
    var etaMin: Double?
    var ambientC: Double?
    var label: String
    var detail: String
    /// 0..1, from the bed's peak down to the threshold. Drives a progress bar.
    var progress: Double
    var tone: CooldownTone
    /// Material-specific warning, when the material is known.
    var caution: String?
}

/// Everything `Cooling.present` reads. A struct rather than a long argument list because most calls
/// supply only two or three of these.
struct CooldownInput: Sendable {
    /// True while the printer is actually printing — cooling is meaningless then.
    var printing: Bool
    var bedC: Double?
    var nozzleC: Double?
    /// nil takes `Cooling.defaultThresholdC`; anything supplied is clamped.
    var thresholdC: Double?
    var samples: [BedSample] = []
    /// Room temperature, MEASURED (see `Cooling.estimateAmbient`). Without it there is no ETA — but
    /// every other part of the readout still works, because they rely on observation, not
    /// prediction.
    var ambientC: Double?
    /// Active filament, for wording only.
    var material: String?
    var now: Date = Date()
}

/// The plate-cooldown model: measure the room, fit the current decay rate, and only speak when the
/// answer is honest.
enum Cooling {

    // MARK: - Constants

    /// Bambu's published figure for the textured PEI plate.
    static let defaultThresholdC = 35.0
    /// Below this the threshold starts colliding with room temperature and may never be reached.
    static let minThresholdC = 30.0
    /// Burn ceiling. EN ISO 13732-1 puts the 1-minute contact threshold for bare metal at ~51°C; you
    /// grip the steel plate for several seconds to flex it, so cap well under that.
    static let maxThresholdC = 45.0
    /// Above this the hotend is worth a warning — it never blocks "ready", since the plate is what
    /// you touch and it cools far slower than the nozzle.
    static let nozzleCautionC = 50.0
    /// Plateau detector: less than `plateauDeltaC` of fall across this many minutes means it has
    /// stopped cooling.
    static let plateauWindowMin = 10.0
    static let plateauDeltaC = 1.0
    /// Trailing window used to measure the CURRENT decay rate.
    static let rateWindowMin = 20.0
    /// Only offer a time estimate once the bed is within this much of the threshold.
    ///
    /// Measured against a real 89-minute cooldown: with a known ambient the estimate lands within ~6
    /// minutes of truth from 45°C down, but runs 27-45% optimistic while the plate is above 50°C.
    /// Real plate cooling is not a single exponential — plate, chamber and room have different time
    /// constants — so an early extrapolation always runs fast. Rather than show a number we know is
    /// wrong by half, we show none until the horizon is short enough to be honest.
    static let etaMaxLeadC = 10.0

    /// A fit needs at least this many points spanning at least this many minutes. Fewer, or bunched
    /// into a few seconds, and the slope is noise dressed up as physics.
    private static let rateMinSamples = 5
    private static let rateMinSpanMin = 5.0
    /// A handful of readings cannot establish a room temperature; the ambient estimate wants hours.
    private static let ambientMinSamples = 60
    /// No room is hotter than this, so a "floor" above it is a stuck sensor, not a room.
    private static let ambientMaxPlausibleC = 45.0
    /// 10 hours. Past this the model has clearly lost the plot, and promising a 40-hour wait is
    /// worse than promising nothing.
    private static let etaCapMin = 600.0

    // MARK: - Small helpers

    /// Drop NaN and infinity. Every reading that reaches this module has already been through
    /// `LooseNumber`, so a bad value arrives as a non-finite `Double` rather than as text.
    private static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }

    /// Round for display. `Int(_:)` traps on anything outside `Int`'s range, and a garbage sensor
    /// reading is not worth a crash.
    private static func rounded(_ v: Double) -> Int {
        guard v.isFinite else { return 0 }
        if v >= 9.0e18 { return Int.max }
        if v <= -9.0e18 { return Int.min }
        return Int(v.rounded())
    }

    /// A threshold in the detail string, written the way a person would: "35", not "35.0".
    private static func fmtC(_ c: Double) -> String {
        guard c.isFinite else { return "—" }
        return c == c.rounded() ? String(rounded(c)) : String(c)
    }

    /// Rounded to 5-minute steps above 10 minutes: measured against a real cooldown the estimate is
    /// good to about ±6 min, so "about 35 min" is honest where "34 min" would be false precision.
    private static func fmtMin(_ m: Double) -> String {
        var r = rounded(m)
        if r >= 10 { r = Int((Double(r) / 5).rounded()) * 5 }
        if r <= 1 { return "under a minute" }
        if r < 60 { return "about \(r) min" }
        let h = r / 60
        let rem = r % 60
        return rem != 0 ? "about \(h) h \(rem) min" : "about \(h) h"
    }

    // MARK: - Threshold

    /// Keep a user-supplied threshold inside the defensible band. Anything outside is either
    /// unreachable (too low) or hot enough to hurt (too high).
    static func clampThreshold(_ c: Double?) -> Double {
        guard let c, c.isFinite else { return defaultThresholdC }
        return min(maxThresholdC, max(minThresholdC, c))
    }

    /// Same, for a threshold that comes back from storage as text. Unparseable text takes the
    /// default rather than the floor — an empty settings value means "unset", not "as cold as
    /// possible".
    static func clampThreshold(_ c: String) -> Double {
        clampThreshold(Double(c.trimmingCharacters(in: .whitespaces)))
    }

    // MARK: - Samples

    /// Clean, sorted, de-duplicated samples. The history endpoint can return points out of order
    /// after a backfill, and one non-finite reading would poison every fit downstream.
    static func normalizeSamples(_ raw: [BedSample]) -> [BedSample] {
        let clean = raw.filter { $0.c.isFinite && $0.t.timeIntervalSince1970.isFinite }
        // Sorted with the original index as a tiebreaker. `sorted(by:)` is NOT a stable sort, and
        // the de-dup below keeps the FIRST of any equal-timestamped run — without the tiebreaker,
        // which of two readings sharing a timestamp survives would vary between runs.
        let sorted = clean.enumerated()
            .sorted { $0.element.t == $1.element.t ? $0.offset < $1.offset : $0.element.t < $1.element.t }
            .map(\.element)
        var out: [BedSample] = []
        out.reserveCapacity(sorted.count)
        for s in sorted where out.last?.t != s.t { out.append(s) }
        return out
    }

    /// Turn a sensor-history response into samples. Only the first series is read — the bed request
    /// asks for one sensor.
    static func parseBedHistory(_ h: SensorHistory?) -> [BedSample] {
        let points = h?.series?.first?.data ?? []
        var out: [BedSample] = []
        out.reserveCapacity(points.count)
        for p in points {
            guard let raw = p.recordedAt, !raw.isEmpty,
                  let t = parseTimestamp(raw),
                  let c = p.value?.double
            else { continue }
            out.append(BedSample(t: t, c: c))
        }
        return normalizeSamples(out)
    }

    /// Read a Bambuddy timestamp.
    ///
    /// Bambuddy timestamps are NAIVE and expressed in UTC ("2026-08-01T11:57:57", no zone marker).
    /// Every convenient parser — `DateFormatter` with the device's default zone, and the browser
    /// `Date` this app grew out of — reads a bare datetime like that as LOCAL time, which silently
    /// shifts the entire curve by the UTC offset. That corrupts every rate, ETA and plateau check
    /// while looking perfectly plausible. So the fields are assembled against a fixed UTC calendar,
    /// and a zone is applied only when the string actually carries one.
    ///
    /// Accepts `YYYY-MM-DD` + `T` or a space + `HH:MM[:SS[.fff]]`, optionally suffixed with `Z`,
    /// `±HH:MM` or `±HHMM`. Returns nil for anything else rather than guessing.
    static func parseTimestamp(_ raw: String) -> Date? {
        var body = Substring(raw.trimmingCharacters(in: .whitespaces))
        guard !body.isEmpty else { return nil }

        var offsetSeconds = 0
        if let last = body.last, last == "Z" || last == "z" {
            body = body.dropLast()
        } else if let zone = trailingZoneOffset(body) {
            offsetSeconds = zone.seconds
            body = body.dropLast(zone.length)
        }

        guard let naive = naiveUTC(body) else { return nil }
        return naive.addingTimeInterval(-Double(offsetSeconds))
    }

    /// A fixed calendar, so a timestamp never depends on the device's zone, locale or region.
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// Match a trailing `+HH:MM` or `-HHMM`. A bare `+02` is deliberately NOT recognised: half-form
    /// offsets are not something Bambuddy emits, and treating one as naive is safer than inventing
    /// an offset from an ambiguous suffix.
    private static func trailingZoneOffset(_ s: Substring) -> (seconds: Int, length: Int)? {
        for length in [6, 5] {
            guard s.count > length else { continue }
            let tail = Array(s.suffix(length))
            guard tail[0] == "+" || tail[0] == "-" else { continue }
            if length == 6 && tail[3] != ":" { continue }
            if length == 5 && tail.contains(":") { continue }
            let zoneDigits: [Character] = tail.dropFirst().filter { $0 != ":" }
            guard zoneDigits.count == 4, zoneDigits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let hh = Int(String(zoneDigits[0...1])), let mm = Int(String(zoneDigits[2...3]))
            else { continue }
            let magnitude = hh * 3600 + mm * 60
            return (tail[0] == "-" ? -magnitude : magnitude, length)
        }
        return nil
    }

    /// Parse the zone-free part of a timestamp as UTC.
    private static func naiveUTC(_ body: Substring) -> Date? {
        guard let sep = body.firstIndex(where: { $0 == "T" || $0 == "t" || $0 == " " }) else { return nil }
        let datePart = body[body.startIndex..<sep]
        let timePart = body[body.index(after: sep)...]

        let d = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard d.count == 3, d[0].count == 4, d[1].count == 2, d[2].count == 2,
              let year = digits(d[0]), let month = digits(d[1]), let day = digits(d[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        let t = timePart.split(separator: ":", omittingEmptySubsequences: false)
        guard t.count == 2 || t.count == 3, t[0].count == 2, t[1].count == 2,
              let hour = digits(t[0]), let minute = digits(t[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }

        var second = 0
        var fraction = 0.0
        if t.count == 3 {
            var secField = t[2]
            if let dot = secField.firstIndex(where: { $0 == "." || $0 == "," }) {
                let frac = secField[secField.index(after: dot)...]
                guard !frac.isEmpty, frac.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let f = Double("0." + frac)
                else { return nil }
                fraction = f
                secField = secField[secField.startIndex..<dot]
            }
            guard secField.count == 2, let s = digits(secField), (0...59).contains(s) else { return nil }
            second = s
        }

        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        guard let base = utcCalendar.date(from: comps) else { return nil }
        return base.addingTimeInterval(fraction)
    }

    /// `Int(_:)` on a run of ASCII digits only — `Int("٣")` and `Int("+3")` must not slip through a
    /// field that is supposed to be fixed-width digits.
    private static func digits(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }

    // MARK: - Model

    /// Room temperature, MEASURED rather than inferred: between prints the plate always settles to
    /// ambient, so the low percentile of idle bed readings over a long window is the room.
    ///
    /// This replaces solving for ambient from the cooling curve itself, which sounds elegant and
    /// does not work. Fitted against the real measured cooldown it returned 39.9°C for a 28.5°C room
    /// while the plate was still at 56°C — which would have declared the plate "as cool as it will
    /// get" less than ten minutes after the print ended. The curve simply does not identify its own
    /// asymptote early on; the idle floor does, directly.
    ///
    /// Takes the 5th percentile rather than the minimum so one cold night or one bad reading cannot
    /// drag the estimate down.
    static func estimateAmbient(_ temps: [Double?], pct: Double = 0.05) -> Double? {
        let s = temps.compactMap { $0 }.filter { $0.isFinite && $0 > 0 }.sorted()
        guard s.count >= ambientMinSamples else { return nil }
        let idx = min(s.count - 1, Int((Double(s.count) * pct).rounded(.down)))
        let v = s[idx]
        return v >= 0 && v <= ambientMaxPlausibleC ? v : nil
    }

    /// The plate's CURRENT decay rate, given a known ambient. One free parameter instead of two, so
    /// it is well conditioned even against whole-degree readings: regress ln(T − ambient) on time.
    ///
    /// Deliberately uses only a trailing window — k is not constant across a real cooldown (it fell
    /// from 0.038 to 0.021 over 89 measured minutes), and what matters for a short extrapolation is
    /// how fast the plate is losing heat NOW.
    static func fitDecayRate(_ samples: [BedSample], ambientC: Double, now: Date) -> Double? {
        let window = samples.filter { now.timeIntervalSince($0.t) <= rateWindowMin * 60 }
        guard window.count >= rateMinSamples, let first = window.first, let last = window.last else { return nil }
        let spanMin = last.t.timeIntervalSince(first.t) / 60
        guard spanMin >= rateMinSpanMin else { return nil }

        let t0 = first.t
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for s in window {
            // Readings at or below ambient carry no rate information and break the logarithm. The
            // half-degree floor is the printer's own reporting granularity.
            guard s.c - ambientC > 0.5 else { return nil }
            let x = s.t.timeIntervalSince(t0) / 60
            let y = log(s.c - ambientC)
            sx += x
            sy += y
            sxx += x * x
            sxy += x * y
        }
        let n = Double(window.count)
        let denom = n * sxx - sx * sx
        guard abs(denom) >= 1e-9 else { return nil }
        let k = -((n * sxy - sx * sy) / denom)
        return k.isFinite && k > 0 ? k : nil
    }

    /// Minutes until the bed reaches `thresholdC`. nil whenever we cannot say honestly.
    static func etaToThreshold(_ fit: CoolingFit?, bedC: Double, thresholdC: Double) -> Double? {
        if bedC <= thresholdC { return 0 }
        guard let fit else { return nil }
        // A plate approaches ambient asymptotically and cannot cross it: if the room is warmer than
        // the threshold, no amount of waiting gets there.
        if fit.ambientC >= thresholdC { return nil }
        // Too far out to extrapolate honestly — see `etaMaxLeadC`.
        if bedC > thresholdC + etaMaxLeadC { return nil }
        let mins = log((bedC - fit.ambientC) / (thresholdC - fit.ambientC)) / fit.kPerMin
        guard mins.isFinite, mins >= 0 else { return nil }
        return min(etaCapMin, mins)
    }

    /// Has the plate stopped falling? Looks only at the trailing window.
    static func hasPlateaued(_ samples: [BedSample], now: Date) -> Bool {
        let window = samples.filter { now.timeIntervalSince($0.t) <= plateauWindowMin * 60 }
        guard window.count >= 3, let first = window.first, let last = window.last else { return false }
        // The window must actually span the period — three samples in ten seconds prove nothing.
        guard last.t.timeIntervalSince(first.t) / 60 >= plateauWindowMin * 0.8 else { return false }
        let temps = window.map(\.c)
        guard let hi = temps.max(), let lo = temps.min() else { return false }
        return hi - lo < plateauDeltaC
    }

    /// Material-specific caution. Never changes the threshold — only what we say about it.
    /// Matches on a substring so "PLA-CF", "PETG HF" and "Bambu ABS" all land correctly.
    static func materialCaution(_ material: String?) -> String? {
        let m = (material ?? "").uppercased()
        if m.isEmpty { return nil }
        if m.contains("TPU") {
            return "TPU never pops off on its own — lift a corner and let isopropyl wick underneath."
        }
        if m.contains("ABS") || m.contains("ASA") || m.contains("PC") || m.hasPrefix("PA") || m.contains("NYLON") {
            return "Keep the door shut until the chamber cools too, or the part can warp as it contracts."
        }
        if m.contains("PETG") {
            return "PETG can bond hard to smooth PEI — on a smooth plate, ease it off rather than forcing it."
        }
        return nil
    }

    // MARK: - View model

    /// The single source of truth for "is the plate cool enough yet". Pure: same inputs, same
    /// answer.
    static func present(_ input: CooldownInput) -> CooldownVM {
        let thresholdC = clampThreshold(input.thresholdC)
        let bed = finite(input.bedC)
        let samples = normalizeSamples(input.samples)
        let caution = materialCaution(input.material)

        // A bed reading of 0 means "no data" far more often than "the plate is frozen" —
        // temperatures is nullable and missing fields round to 0 upstream.
        guard !input.printing, let bedC = bed, bedC > 0 else {
            return CooldownVM(
                phase: .none,
                bedC: bed ?? 0,
                thresholdC: thresholdC,
                etaMin: nil,
                ambientC: nil,
                label: "",
                detail: "",
                progress: 0,
                tone: .hot,
                caution: nil
            )
        }

        let ambientC = finite(input.ambientC)
        var fit: CoolingFit?
        if let ambientC, let kPerMin = fitDecayRate(samples, ambientC: ambientC, now: input.now) {
            fit = CoolingFit(ambientC: ambientC, kPerMin: kPerMin)
        }
        let etaMin = etaToThreshold(fit, bedC: bedC, thresholdC: thresholdC)

        let peak = max(bedC, samples.map(\.c).max() ?? bedC)
        let progress: Double = peak > thresholdC
            ? min(1, max(0, (peak - bedC) / (peak - thresholdC)))
            : 1

        var nozzleNote = ""
        if let n = finite(input.nozzleC), n > nozzleCautionC {
            nozzleNote = " The nozzle is still at \(rounded(n))°C."
        }

        if bedC <= thresholdC {
            return CooldownVM(
                phase: .ready,
                bedC: bedC,
                thresholdC: thresholdC,
                etaMin: 0,
                ambientC: ambientC,
                label: "Plate is cool",
                // Deliberately "safe to flex", not "it has popped off" — plenty of prints stay stuck
                // at room temperature, and over-promising invites someone to force it and tear the
                // PEI coating.
                detail: "Bed at \(rounded(bedC))°C — safe to flex the plate and lift the print off.\(nozzleNote)",
                progress: 1,
                tone: .ready,
                caution: caution
            )
        }

        // Stalled: it stopped falling, or the MEASURED room is already at/above the target so it
        // never can. Both are observations — nothing here is extrapolated.
        let stalled = hasPlateaued(samples, now: input.now) || (ambientC.map { $0 >= thresholdC } ?? false)
        if stalled {
            let room = ambientC.map { " The room is around \(rounded($0))°C." } ?? ""
            return CooldownVM(
                phase: .stalled,
                bedC: bedC,
                thresholdC: thresholdC,
                etaMin: nil,
                ambientC: ambientC,
                label: "As cool as it will get",
                detail: "Bed has settled at \(rounded(bedC))°C and is no longer dropping.\(room) "
                    + "Go ahead and flex the plate.\(nozzleNote)",
                progress: progress,
                tone: .warm,
                caution: caution
            )
        }

        let detail: String
        if let etaMin {
            detail = "Bed at \(rounded(bedC))°C — \(fmtMin(etaMin)) until it is easy to remove."
        } else {
            detail = "Bed at \(rounded(bedC))°C, heading for \(fmtC(thresholdC))°C."
        }
        return CooldownVM(
            phase: .cooling,
            bedC: bedC,
            thresholdC: thresholdC,
            etaMin: etaMin,
            ambientC: ambientC,
            label: "Plate cooling",
            detail: detail,
            progress: progress,
            tone: bedC > thresholdC + 15 ? .hot : .warm,
            caution: caution
        )
    }
}
