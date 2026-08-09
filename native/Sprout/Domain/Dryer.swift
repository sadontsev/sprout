import Foundation

// Pure view-model for AMS filament drying (AMS 2 Pro / AMS HT). Mirrors Bambuddy's semantics:
//
// - "actively drying" = `dryTime > 0` (minutes remaining). `dryStatus` is NOT reliable — observed 0
//   mid-cycle on the live AMS 2 Pro.
// - Recommended temp/time come from each tray's RFID/preset (`dryingTemp`/`dryingTime`); trays
//   without data (0) fall back to a same-type sibling tray, then to `Dryer.defaults`.
// - The AMS 2 Pro's heater tops out at 65 °C; only the AMS HT reaches 85 °C. Bambuddy validates the
//   wider 45-85 range for BOTH, so the clamp has to happen here or the app will happily ask a
//   65 °C unit for 85 °C.

/// Human messages for the AMS's `drySfReason` codes (mirrors Bambuddy's `printers.py`).
enum DryBlockers {
    /// Reason codes 0-8, as published in `AmsUnitRaw.drySfReason`.
    static let messages: [Int: String] = [
        0: "Printer is busy",
        1: "Not enough power — too many AMS units drying, or the external PSU is required",
        2: "AMS is busy",
        3: "Filament is at the AMS outlet — retract it first",
        4: "A drying cycle is already starting",
        5: "Not supported in 2D mode",
        6: "Already drying",
        7: "AMS firmware is updating",
        8: "Plug in the external AMS power adapter to start drying",
    ]
}

/// A drying temperature (°C) and duration (hours) for one filament type.
struct DryRecommendation: Hashable, Sendable {
    var temp: Int
    var hours: Int
}

/// One dryable filament choice, deduped by type across the unit's trays.
struct DryOption: Identifiable, Hashable, Sendable {
    /// Filament type exactly as the tray reports it, e.g. "PETG" or "PLA-S".
    var type: String
    /// `#RRGGBB` of a tray holding it, or nil when the printer does not know the colour.
    var color: String?
    /// Recommended °C, already clamped to the unit's hardware ceiling.
    var temp: Int
    /// Recommended duration in hours, clamped to 1...24.
    var hours: Int
    /// True when the tray's own RFID/preset provided the numbers, rather than the fallback table.
    var fromPreset: Bool

    /// Types are deduped within a unit, so the type IS the identity.
    var id: String { type }
}

/// Where a running cycle is in its temperature curve.
enum DryStage: String, Hashable, Sendable {
    /// Still climbing to target.
    case heating
    /// At temperature.
    case holding
}

/// Everything one AMS unit's drying card needs.
struct DryerVM: Identifiable, Hashable, Sendable {
    /// RAW unit id (0...3 regular, 128+ HT). Matches `AmsUnitVM.id`, which the card joins on to get
    /// the unit's label, and it is what the drying endpoints expect — never an array index.
    var amsId: Int
    var isHt: Bool
    /// Hardware ceiling: 65 (AMS 2 Pro) or 85 (AMS HT).
    var maxTemp: Int
    /// `dryTime > 0`.
    var active: Bool
    var remainingMin: Int
    /// `remainingMin` formatted, e.g. "5h 44m"; "—" when idle.
    var remainingText: String
    var humidityPct: Int?
    /// Current air temperature inside the AMS, unrounded.
    var tempC: Double?
    /// Target °C — Bambuddy's cache when it started the cycle, else the recommendation for
    /// `filament`, else nil (cycle started from Handy/the printer with an unknown target).
    var targetTemp: Double?
    /// What the active cycle is drying ("" if unknown).
    var filament: String
    /// nil when the target is unknown or nothing is running.
    var stage: DryStage?
    /// Human reasons the AMS currently refuses to start. Code 6 ("already drying") is omitted — the
    /// active card already conveys it.
    var blockers: [String]
    var options: [DryOption]

    var id: Int { amsId }
}

enum Dryer {
    /// Bambuddy rejects anything below this, on either unit.
    static let minTemp = 45
    /// Longest cycle the AMS accepts.
    static let maxHours = 24

    /// Fallback drying recommendations by filament type, for trays whose RFID/preset carries none.
    ///
    /// Starting points only — the UI lets the user adjust, and temps are clamped to the unit's
    /// hardware max afterwards, so the 80 °C entries are unreachable on an AMS 2 Pro.
    static let defaults: [String: DryRecommendation] = [
        "PLA": DryRecommendation(temp: 55, hours: 8),
        "PETG": DryRecommendation(temp: 65, hours: 8),
        "TPU": DryRecommendation(temp: 60, hours: 8),
        "ABS": DryRecommendation(temp: 75, hours: 8),
        "ASA": DryRecommendation(temp: 75, hours: 8),
        "PC": DryRecommendation(temp: 80, hours: 10),
        "PA": DryRecommendation(temp: 80, hours: 12),
        "PVA": DryRecommendation(temp: 70, hours: 10),
        "PET": DryRecommendation(temp: 70, hours: 10),
    ]

    /// Used for filament types the table does not know at all.
    static let generic = DryRecommendation(temp: 55, hours: 8)

    /// The recommendation for a filament type: exact match, then the base type before the first
    /// hyphen ("PETG-CF" -> PETG), then generic.
    static func defaultFor(_ type: String) -> DryRecommendation {
        if let exact = defaults[type] { return exact }
        // Everything up to the first hyphen — including the empty string for a leading hyphen, which
        // then falls through to `generic` rather than matching some later segment.
        let base = String(type.prefix { $0 != "-" })
        return defaults[base] ?? generic
    }

    /// Pure: one `DryerVM` per drying-capable AMS unit on a drying-capable machine.
    static func present(_ status: PrinterStatus?) -> [DryerVM] {
        guard let status, status.supportsDrying == true, let units = status.ams, !units.isEmpty else { return [] }

        return units.filter(canDry).map { unit -> DryerVM in
            let isHt = unit.isAmsHt == true
            // The heater's hardware ceiling, not a preference: the AMS 2 Pro physically stops at 65.
            let maxTemp = isHt ? 85 : 65
            let remainingMin = max(0, safeRound(num(unit.dryTime) ?? 0))
            let active = remainingMin > 0
            let humidity = num(unit.humidity)
            let tempC = num(unit.temp)

            let options = dryOptions(unit, maxTemp: maxTemp)
            let filament = unit.dryFilament ?? ""

            var targetTemp = num(unit.dryTargetTemp)
            // "Unknown target" arrives as null over REST but as 0 over the WebSocket (different
            // Bambuddy serializers — verified live). A real drying target is 45-85 °C, so anything
            // <= 0 is unknown; without this the active card renders "holding 0°".
            if let t = targetTemp, t <= 0 { targetTemp = nil }
            if active, targetTemp == nil, !filament.isEmpty {
                // Cycle started outside Bambuddy — the best estimate available is the recommendation
                // for whatever it says it is drying.
                targetTemp = options.first { $0.type == filament }.map { Double($0.temp) }
            }

            var stage: DryStage?
            if active, let target = targetTemp, let now = tempC {
                stage = now < target - 3 ? .heating : .holding
            }

            let blockers = (unit.drySfReason ?? []).compactMap { code -> String? in
                guard let n = code.int, n != 6 else { return nil }
                return DryBlockers.messages[n]
            }

            return DryerVM(
                amsId: unit.id,
                isHt: isHt,
                maxTemp: maxTemp,
                active: active,
                remainingMin: remainingMin,
                remainingText: Dash.fmtDuration(Double(remainingMin)),
                humidityPct: humidity.map(safeRound),
                tempC: tempC,
                targetTemp: targetTemp,
                filament: filament,
                stage: stage,
                blockers: blockers,
                options: options
            )
        }
    }

    // MARK: - Internals

    /// `supportsDrying` is PRINTER-level — a heaterless first-gen AMS on the same hub must not get a
    /// drying card. Fail open per unit: real dryers always publish `dryTime` (verified live on the
    /// AMS 2 Pro), and `isAmsHt` / `moduleType` "n3f" identify the drying models explicitly.
    private static func canDry(_ u: AmsUnitRaw) -> Bool {
        u.isAmsHt == true
            || u.moduleType == "n3f"
            || u.dryTime != nil
            || u.dryTargetTemp != nil
            || u.dryFilament != nil
    }

    /// Dryable options for one unit: dedupe trays by type, keeping the FIRST tray of each type but
    /// letting a tray with real preset data displace a 0/0 sibling. Order follows the tray order.
    private static func dryOptions(_ unit: AmsUnitRaw, maxTemp: Int) -> [DryOption] {
        var options: [DryOption] = []
        var indexByType: [String: Int] = [:]

        for tray in unit.tray ?? [] {
            guard let type = tray.trayType, !type.isEmpty else { continue }
            let presetTemp = num(tray.dryingTemp) ?? 0
            let presetHours = num(tray.dryingTime) ?? 0
            let fromPreset = presetTemp > 0
            let fallback = defaultFor(type)
            let option = DryOption(
                type: type,
                color: FilamentColor.norm(tray.trayColor),
                temp: clampTemp(fromPreset ? presetTemp : Double(fallback.temp), max: maxTemp),
                hours: clampHours(fromPreset && presetHours > 0 ? presetHours : Double(fallback.hours)),
                fromPreset: fromPreset
            )
            if let i = indexByType[type] {
                if option.fromPreset && !options[i].fromPreset { options[i] = option }
            } else {
                indexByType[type] = options.count
                options.append(option)
            }
        }
        return options
    }

    /// A finite reading, or nil. `LooseNumber` hands back whatever the payload contained, and a NaN
    /// or infinity would TRAP on conversion to `Int` — so every numeric read here goes through this.
    private static func num(_ n: LooseNumber?) -> Double? {
        guard let v = n?.double, v.isFinite else { return nil }
        return v
    }

    /// Rounds to `Int` without trapping: `Int(Double)` is a runtime error for non-finite values and
    /// for anything outside `Int`'s range.
    private static func safeRound(_ v: Double) -> Int {
        guard v.isFinite else { return 0 }
        if v >= Double(Int.max) { return .max }
        if v <= Double(Int.min) { return .min }
        return Int(v.rounded())
    }

    private static func clampTemp(_ t: Double, max maxTemp: Int) -> Int {
        min(max(safeRound(t), minTemp), maxTemp)
    }

    private static func clampHours(_ h: Double) -> Int {
        min(max(safeRound(h), 1), maxHours)
    }
}
