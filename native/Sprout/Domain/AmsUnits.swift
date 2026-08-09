import Foundation

// Pure AMS topology: 1..N units of mixed kinds -> the view-models every AMS surface consumes.
//
// Before this module the RN app read `status.ams[0]` in four places (plus la-push), so a second unit
// was invisible. That is not future-proofing: the owner's H2C reports THREE units — two AMS 2 Pro
// (ids 0 and 1, module_type "n3f", 4 trays each) and an AMS HT (id 128, "n3s", 1 tray, isAmsHt) —
// verified live on 2026-08-01, together with a Filament Track Switch (`filaSwitch.installed`).
//
// The H2 series drives up to 4 regular units (ids 0-3) plus 8 HT units (128-135); this module makes
// no assumption about how many of either are present.

enum AmsKind: String, Sendable, Hashable {
    case ams, ht
}

/// How AMS units are bound to extruders right now.
///
/// - `switch`: a Filament Track Switch is installed: any unit can feed either nozzle, so no unit HAS
///   a fixed extruder and any per-unit binding shown to the user would be a lie.
/// - `fixed`: classic wiring — each unit feeds the extruder named in `amsExtruderMap`.
///
/// This distinction is not cosmetic. Bambuddy builds `amsExtruderMap` from each unit's `info` bits
/// and skips units reporting 0xE ("no fixed extruder"), which is exactly what an FTS-routed unit
/// reports — permanently. The map is also merge-only and never pruned, so on this machine it still
/// reads {"0":0,"128":1} from before the switch was fitted while the unit added afterwards (id 1)
/// can never gain an entry. Reading it as current routing therefore shows two units a stale binding
/// and the third nothing at all. Bambuddy's own UI and queue scheduler drop the per-extruder filter
/// whenever the switch is installed; this does the same.
enum AmsRouting: String, Sendable, Hashable {
    case fixed, `switch`
}

struct AmsUnitVM: Identifiable, Hashable, Sendable {
    /// RAW unit id (0..3 regular, 128+ HT) — this is what drying/load endpoints expect, NOT an index.
    let id: Int
    var label: String           // "AMS 1" | "AMS 2" | "AMS HT"
    var kind: AmsKind
    var capacity: Int           // trays this unit reports (4 for an AMS 2 Pro, 1 for an HT)
    var loaded: Int             // trays with filament
    /// Drying ceiling: the AMS 2 Pro tops out at 65 °C, the HT reaches 85 °C.
    var maxDryTemp: Int
    var humidity: Double?
    var tempC: Double?
    /// Which extruder this unit feeds: 0 = RIGHT, 1 = LEFT. nil when the printer doesn't say — which
    /// includes every unit once a Filament Track Switch is fitted, because routing is then dynamic.
    var extruder: Int?
    /// Short serial tail — the only way to tell two identical AMS 2 Pro units apart.
    var serialTail: String
    var dryingMinLeft: Int      // 0 when idle
}

struct AmsSlotVM: Identifiable, Hashable, Sendable {
    var label: String
    var color: String?
    var pct: String
    var active: Bool
    var empty: Bool
    // --- topology ---
    var unitId: Int
    var unitLabel: String
    var localId: Int            // tray index INSIDE its unit (what SlotAssignment stores)
    var globalId: Int           // what the printer speaks
    /// Which extruder THIS tray is feeding right now (0 = Right, 1 = Left), or nil.
    ///
    /// With a Filament Track Switch fitted this is the only honest routing answer available: units no
    /// longer belong to a nozzle, but a LOADED tray is on a track, and the track has an outlet. Only
    /// the trays currently threaded through the switch have one.
    var extruder: Int?

    var id: Int { globalId }
}

/// A tray plus the unit context needed to address it. The raw `trayType`/`trayColor` are kept
/// (rather than the presented `AmsSlotVM` strings) because preset matching and colour fallback need
/// the unformatted values.
struct AmsTrayRef: Hashable, Sendable {
    var unitId: Int
    var unitLabel: String
    var localId: Int
    /// What the printer speaks: `trayNow`, ams/load's tray_id, and ams_mapping VALUES.
    var globalId: Int
    var trayType: String?
    var trayColor: String?
}

enum AmsTopology {
    /// A tray's id in the space the PRINTER speaks: `trayNow`, ams/load's tray_id, ams_mapping values.
    ///
    /// Regular AMS units pack 4 trays each (unit 0 -> 0..3, unit 1 -> 4..7); an AMS HT is a
    /// single-spool unit whose id (128..135) IS its tray id. Confirmed against the live inventory
    /// endpoint, which keys the same three trays as {"0","2","128"}.
    ///
    /// This is the one piece of id math in the app; every "is this tray active / load this tray"
    /// question must go through it. Comparing a LOCAL tray index against `trayNow` is right only by
    /// coincidence for unit 0, and lights the HT's tray whenever AMS-0 slot 0 prints.
    static func globalTrayId(unitId: Int, localId: Int) -> Int {
        unitId >= 128 ? unitId : unitId * 4 + localId
    }

    /// 0 = RIGHT/main, 1 = LEFT on the H2 series — the same convention as `activeExtruder` and the
    /// nozzle rack. Centralised because getting it backwards is easy and silent: the AMS tab shipped
    /// it inverted once already.
    static func extruderSide(_ e: Int?) -> String {
        switch e {
        case 0: return "Right"
        case 1: return "Left"
        default: return ""
        }
    }

    /// Which extruder a given global tray id is feeding, via the Filament Track Switch.
    ///
    /// `filaSwitch.inSlots[track]` is the GLOBAL tray id loaded on that track (-1 = empty) and
    /// `outExtruders[track]` is the nozzle that track terminates at — so the answer is a lookup by
    /// index. This mirrors Bambuddy's own web UI exactly. Returns nil with no switch, or for a tray
    /// that is not currently on a track.
    static func switchExtruderForTray(_ status: PrinterStatus?, globalId: Int) -> Int? {
        guard let fs = status?.filaSwitch, fs.installed == true else { return nil }
        guard let track = fs.inSlots?.firstIndex(of: globalId) else { return nil }
        guard let out = fs.outExtruders?[safe: track] else { return nil }
        // 0xE (14) is the documented "no outlet" marker.
        return out != 0xE ? out : nil
    }

    /// Human label. Regular units are numbered from their own stable id (not array position, which
    /// the printer may reorder); HT units are named by kind, numbered only if there are several.
    private static func labelFor(unitId: Int, kind: AmsKind, htIndex: Int, htTotal: Int) -> String {
        if kind == .ht { return htTotal > 1 ? "AMS HT \(htIndex + 1)" : "AMS HT" }
        return "AMS \(unitId + 1)"
    }

    struct Result: Sendable {
        var units: [AmsUnitVM] = []
        var slots: [AmsSlotVM] = []
        var routing: AmsRouting = .fixed
    }

    /// Pure: every AMS unit and every slot across all of them.
    ///
    /// `slots` is a FLAT list in unit order — the dashboard strip and the Live Activity consume it
    /// directly, while `units` carries the grouping the Hardware tab needs.
    static func present(_ status: PrinterStatus?) -> Result {
        let raw = status?.ams ?? []
        guard !raw.isEmpty else { return Result() }

        // Routing is only 'fixed' when the map is COMPLETE — an entry for every unit present.
        //
        // filaSwitch alone is not a sufficient signal: it is absent from the WebSocket payload
        // (verified live — REST carries it, the WS feed does not), and the app runs on the
        // WebSocket. Keying solely on it meant the live app fell back to the stale map and painted
        // every unit-0 slot "-> Right".
        //
        // An INCOMPLETE map is itself the tell. Bambuddy omits any unit whose info nibble reads 0xE,
        // which means "no fixed extruder" — exactly what a switch-routed unit reports. So a map that
        // covers some units but not others cannot be describing static wiring, whichever transport
        // delivered it.
        let mapped = status?.amsExtruderMap ?? [:]
        let everyUnitMapped = raw.allSatisfy { mapped[String($0.id)] != nil }
        let routing: AmsRouting = (status?.filaSwitch?.installed == true || !everyUnitMapped) ? .switch : .fixed
        // With a switch fitted the map is stale residue, not current routing — ignore it wholesale
        // rather than showing a binding for the units that happen to still have an entry.
        let extMap = routing == .switch ? [:] : mapped

        // Count HTs with the SAME predicate used to classify them, or a unit that reports the 128+ id
        // without isAmsHt is labelled 'AMS HT' while htTotal stays 0 — two units, one identical label.
        func isHt(_ u: AmsUnitRaw) -> Bool { u.isAmsHt == true || u.id >= 128 }
        let htTotal = raw.filter(isHt).count
        let trayNow = status?.trayNow?.int

        var htSeen = 0
        var result = Result(routing: routing)

        for unit in raw {
            let id = unit.id
            // isAmsHt is authoritative; moduleType ("n3s") and the 128+ id space corroborate it.
            let kind: AmsKind = isHt(unit) ? .ht : .ams
            let label = labelFor(unitId: id, kind: kind, htIndex: htSeen, htTotal: htTotal)
            if kind == .ht { htSeen += 1 }
            let trays = unit.tray ?? []

            result.units.append(AmsUnitVM(
                id: id,
                label: label,
                kind: kind,
                capacity: trays.count,
                loaded: trays.filter { !($0.trayType ?? "").isEmpty }.count,
                maxDryTemp: kind == .ht ? 85 : 65,
                humidity: unit.humidity?.double,
                tempC: unit.temp?.double,
                extruder: extMap[String(id)],
                serialTail: {
                    let sn = unit.serialNumber ?? ""
                    return (!sn.isEmpty && sn != "N/A") ? String(sn.suffix(4)) : ""
                }(),
                dryingMinLeft: max(0, Int((unit.dryTime?.double ?? 0).rounded()))
            ))

            for tray in trays {
                let localId = tray.id
                let globalId = globalTrayId(unitId: id, localId: localId)
                let empty = (tray.trayType ?? "").isEmpty
                result.slots.append(AmsSlotVM(
                    label: empty ? "Empty" : (tray.trayType ?? ""),
                    // nil = colour unknown. The old '#3A3F45' fallback was a literal dark grey that
                    // never adapted to the light theme and, worse, claimed a colour we do not know.
                    color: empty ? nil : FilamentColor.norm(tray.trayColor),
                    pct: empty ? "—" : "\(Int((tray.remain?.double ?? 0).rounded()))%",
                    active: !empty && trayNow != nil && trayNow == globalId,
                    empty: empty,
                    unitId: id,
                    unitLabel: label,
                    localId: localId,
                    globalId: globalId,
                    extruder: routing == .switch ? switchExtruderForTray(status, globalId: globalId) : extMap[String(id)]
                ))
            }
        }
        return result
    }

    /// Every tray across every unit, flat and in unit order.
    ///
    /// Exists because callers kept reaching for `status.ams[0].tray`, which silently hides every unit
    /// after the first — with three units fitted that is 5 of 9 slots.
    static func trayRefs(_ status: PrinterStatus?) -> [AmsTrayRef] {
        let slots = present(status).slots
        var rawById: [Int: AmsUnitRaw] = [:]
        for u in status?.ams ?? [] { rawById[u.id] = u }
        return slots.map { s in
            let tray = rawById[s.unitId]?.tray?.first { $0.id == s.localId }
            return AmsTrayRef(
                unitId: s.unitId,
                unitLabel: s.unitLabel,
                localId: s.localId,
                globalId: s.globalId,
                trayType: tray?.trayType,
                trayColor: tray?.trayColor
            )
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
