import Foundation

/// Building the `ams_mapping` array a print command carries.
///
/// The field is **indexed by the 3MF's filament slot and valued by the global tray id**. Index 0 is
/// filament slot 1. Getting index and value the wrong way round debits the wrong spool and cannot
/// address anything past the first AMS unit at all; getting the *length* wrong leaves filaments
/// unmapped for the firmware to guess at.
///
/// Global tray id = `ams_id * 4 + slot_id`, AMS-HT units use their unit id directly (≥ 128), `254`
/// and `255` are the two external spools, and **`-1` means unmapped**.
///
/// This lives here, pure and tested, because it is the last thing that happens before a physical
/// machine starts moving, and because the wizard's own comment already warns about the index/value
/// swap — a warning is not a test.
enum AmsMapping {

    /// More filament slots than any real plate uses. `usedSlots` comes off the wire, and the array is
    /// sized from its maximum — a payload claiming slot 9999 would otherwise allocate 9999 elements
    /// and send them to a printer. Anything above this is refused by name rather than truncated.
    static let maxSlots = 16

    /// Slots this build cannot address at all — see `maxSlots`. Never silently dropped.
    static func unmappable(usedSlots: [Int]) -> [Int] {
        usedSlots.filter { $0 > maxSlots }.sorted()
    }

    /// `ams_mapping` for a print whose plate needs `usedSlots`, given the tray chosen for each.
    ///
    /// - Parameters:
    ///   - usedSlots: the 1-based filament slots the plate actually consumes, from
    ///     `GET /library/files/{id}/filament-requirements?plate_id=`.
    ///   - trays: slot → global tray id. A slot with no entry is sent as `-1` rather than defaulted;
    ///     silently substituting a tray is how a print comes out in the wrong colour.
    ///
    /// The array is as long as the HIGHEST used slot, not as long as `usedSlots`: a plate that uses
    /// only slot 3 still needs `[-1, -1, tray]`, because index 2 is what addresses slot 3.
    static func build(usedSlots: [Int], trays: [Int: Int]) -> [Int] {
        let valid = usedSlots.filter { (1...maxSlots).contains($0) }
        guard let highest = valid.max() else { return [] }
        var mapping = [Int](repeating: -1, count: highest)
        for slot in valid {
            mapping[slot - 1] = trays[slot] ?? -1
        }
        return mapping
    }

    /// The slots the plate needs that have no tray chosen — the exact set the UI must name before it
    /// lets a print start. Returned in slot order so the message reads predictably.
    static func unmapped(usedSlots: [Int], trays: [Int: Int]) -> [Int] {
        usedSlots.filter { $0 >= 1 && trays[$0] == nil }.sorted()
    }

    /// Slots whose chosen tray is no longer usable — gone from the machine, or now empty.
    ///
    /// Deliberately a **separate question** from `unmapped`. "The user picked a tray" and "that tray
    /// still holds filament" are different, and the AMS is live between choosing on step 6 and
    /// pressing Start: a spool can be pulled in between.
    static func stale(trays: [Int: Int], loaded: [AmsTrayRef]) -> [Int] {
        let usable = Set(loaded.filter { !($0.trayType ?? "").isEmpty }.map(\.globalId))
        return trays.filter { !usable.contains($0.value) }.keys.sorted()
    }

    /// Whether every slot this plate needs has a tray. The exact precondition for starting a print —
    /// not "how many filaments", and not "is a tray selected".
    ///
    /// **Returns `false` for an empty `usedSlots`.** An empty requirement list means "not known", not
    /// "nothing required"; callers that could not fetch requirements must pass the `[1]` fallback
    /// rather than `[]`, or a print with unknown needs would look satisfied.
    static func isComplete(usedSlots: [Int], trays: [Int: Int]) -> Bool {
        let valid = usedSlots.filter { $0 >= 1 }
        return !valid.isEmpty
            && unmapped(usedSlots: valid, trays: trays).isEmpty
            && unmappable(usedSlots: valid).isEmpty
    }
}
