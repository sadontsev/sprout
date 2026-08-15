import Foundation

/// How a model's versions are grouped, counted and described.
///
/// Pure, because the hard part of this screen is not layout — it is **honesty about data that is
/// mostly missing**, and every one of those judgements is worth pinning in a test.
///
/// The shape of the problem, measured on model 40146:
///
///  * a model publishes up to **88** versions;
///  * **51 of those 88 carry no `detail` at all** — no time, no weight, no material, no slots,
///    including the row MakerWorld itself pre-selects;
///  * material, when present, is sometimes `Universal` rather than a real material.
///
/// So the three axes a user wants to sort and filter on are absent on ~58 % of rows. A screen that
/// quietly sorted 88 rows by time would be inventing an order for most of them.
enum VersionGrouping {

    /// Where a version sits. Order matters: this is the order the sections appear in.
    enum Group: Int, CaseIterable, Identifiable, Sendable {
        case recommended, oneColour, multiColour, needsFilament, unlabelled

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .recommended:   return "RECOMMENDED"
            case .oneColour:     return "ONE COLOUR"
            case .multiColour:   return "TWO OR MORE COLOURS"
            case .needsFilament: return "NEEDS FILAMENT YOU DON'T HAVE"
            case .unlabelled:    return "NO PUBLISHED SETTINGS"
            }
        }

        /// The unlabelled group is collapsed by default and never participates in a sort.
        var isUnlabelled: Bool { self == .unlabelled }
    }

    /// How the loaded versions may be ordered.
    ///
    /// **Rule 1 — an unlabelled version is never reordered by a sort it has no data for.** Those
    /// rows keep MakerWorld's own order in a trailing group, always, whatever is selected here.
    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case recommended, fastest, leastFilament

        var id: String { rawValue }

        var label: String {
            switch self {
            case .recommended:   return "Recommended"
            case .fastest:       return "Fastest"
            case .leastFilament: return "Least filament"
            }
        }
    }

    /// A version placed in a group, with whatever marks it earned.
    struct Placed: Identifiable, Sendable {
        var row: MWProfileRow
        var group: Group
        /// `FASTEST`, `LIGHTEST`, `PICK`, `ANY MATERIAL`. Superlatives survive grouping so the
        /// extremes stay findable inside a section rather than only in a flat sorted list.
        var marks: [String] = []
        /// Set on `.needsFilament` rows: what to load to make this printable. Rule 6 — a version you
        /// cannot print is shown, greyed, with the remedy, never hidden.
        var remedy: String?

        var id: Int { row.id }
        /// Rule 1's other half: these rows carry no numbers, so nothing may claim to order them.
        var isUnlabelled: Bool { row.detail == nil }
    }

    // MARK: Placement

    /// Split rows into their groups.
    ///
    /// `printableMaterials` is what the AMS can currently supply, upper-cased. Empty means "we don't
    /// know what's loaded" — and then **nothing** is marked unprintable, because an empty AMS
    /// reading and a genuinely missing material are different facts and only one of them justifies
    /// greying a row out.
    /// - Parameter trays: what the AMS actually holds, from `trays(in:)`. **Trays, not a set of
    ///   materials.** This took a `Set<String>` and computed `missing` by set subtraction, which is
    ///   tray-count blind: a version needing three PLA slots was called printable by a machine with
    ///   one PLA spool, under the words "N fit your filament". `assignTrays` is the tested answer to
    ///   the question those words ask, and its own doc comment describes this bug — it was fixed
    ///   there and left standing here.
    ///
    ///   Empty still means "we don't know", not "you have nothing": no row is greyed out when the
    ///   status has not arrived.
    static func place(_ rows: [MWProfileRow],
                      defaultInstanceId: Int?,
                      trays: [Tray]) -> [Placed] {
        rows.map { row in
            guard let detail = row.detail else {
                return Placed(row: row, group: .unlabelled)
            }
            let missing: [String]
            if trays.isEmpty {
                missing = []
            } else {
                let assigned = assignTrays(slots: detail.slots, trays: trays)
                // A slot that asked for a material and got no tray. Universal asks for nothing, so
                // `assignTrays` returns nil for it too — hence the filter rather than a bare zip.
                missing = zip(detail.slots, assigned).compactMap { slot, tray -> String? in
                    guard tray == nil,
                          let want = slot.type?.uppercased(),
                          !want.isEmpty, want != "UNIVERSAL"
                    else { return nil }
                    return want
                }.sorted()
            }

            if !missing.isEmpty {
                return Placed(row: row, group: .needsFilament,
                              remedy: "load \(missing.joined(separator: " + ")) to print")
            }
            if row.id == defaultInstanceId {
                return Placed(row: row, group: .recommended)
            }
            return Placed(row: row, group: detail.slotCount > 1 ? .multiColour : .oneColour)
        }
    }

    /// Apply a sort, then re-mark the superlatives.
    ///
    /// The unlabelled rows are sliced off first and appended untouched — they cannot be compared on
    /// a field they do not have, and sorting them by a default of zero would silently rank them
    /// "fastest".
    static func sorted(_ placed: [Placed], by sort: Sort) -> [Placed] {
        let (labelled, unlabelled) = (placed.filter { !$0.isUnlabelled },
                                      placed.filter(\.isUnlabelled))
        let ordered: [Placed]
        switch sort {
        case .recommended:
            ordered = labelled            // MakerWorld's order, with `recommended` already grouped first
        case .fastest:
            ordered = labelled.sorted { ($0.row.detail?.seconds ?? .infinity) < ($1.row.detail?.seconds ?? .infinity) }
        case .leastFilament:
            ordered = labelled.sorted { ($0.row.detail?.grams ?? .infinity) < ($1.row.detail?.grams ?? .infinity) }
        }
        return marked(ordered) + unlabelled
    }

    /// Attach `FASTEST` / `LIGHTEST` / `ANY MATERIAL` to the rows that earn them.
    ///
    /// Only ever computed over rows that publish the field in question, and only when there is more
    /// than one such row — "fastest of one" is not information.
    private static func marked(_ placed: [Placed]) -> [Placed] {
        let times = placed.compactMap { $0.row.detail?.seconds }
        let grams = placed.compactMap { $0.row.detail?.grams }
        let fastest = times.count > 1 ? times.min() : nil
        let lightest = grams.count > 1 ? grams.min() : nil

        return placed.map { item in
            var item = item
            var marks: [String] = []
            if item.group == .recommended { marks.append("PICK") }
            if let fastest, item.row.detail?.seconds == fastest { marks.append("FASTEST") }
            if let lightest, item.row.detail?.grams == lightest { marks.append("LIGHTEST") }
            if let slots = item.row.detail?.slots,
               !slots.isEmpty,
               slots.allSatisfy({ ($0.type ?? "").uppercased() == "UNIVERSAL" }) {
                marks.append("ANY MATERIAL")
            }
            item.marks = marks
            return item
        }
    }

    // MARK: Saying the gap out loud

    /// The line under the title.
    ///
    /// **Rule 2 — say the gap out loud.** A bare "88 versions" implies 88 sortable, comparable rows
    /// when most of them can be neither. This is the same class of claim as a sort chip implying
    /// server-side ordering, and it gets the same treatment: state the number that is actually
    /// filterable, and state how many are not.
    static func countLine(matching: Int, total: Int, unlabelled: Int) -> String {
        var parts: [String] = []
        parts.append(matching == total ? "\(total) version\(total == 1 ? "" : "s")"
                                       : "\(matching) of \(total) match")
        if unlabelled > 0 { parts.append("\(unlabelled) publish no settings") }
        return parts.joined(separator: "  ·  ")
    }

    /// What the collapsed group says about itself, so nobody has to open it to find out why it is
    /// separate.
    static let unlabelledExplanation =
        "No time, weight or material, so they can't be filtered or compared. "
        + "Listed in MakerWorld's order."

    // MARK: Filtering

    /// The filter the sheet applies.
    struct Filter: Equatable, Sendable {
        /// Upper-cased material names. Empty means no material filter.
        var materials: Set<String> = []
        /// **Rule 3 — a material filter must state what it does with unlabelled rows.** This is that
        /// statement, made a setting rather than a silent policy.
        var includeUnlabelled = true
        var onlyWithPhotosOrNotes = false
        var onlyPrintableNow = false
        var maxSeconds: Int?
        var maxGrams: Int?

        var isActive: Bool {
            !materials.isEmpty || onlyWithPhotosOrNotes || onlyPrintableNow
                || maxSeconds != nil || maxGrams != nil || !includeUnlabelled
        }

        /// How many controls are on, for the toolbar badge.
        var activeCount: Int {
            var n = 0
            if !materials.isEmpty { n += 1 }
            if onlyWithPhotosOrNotes { n += 1 }
            if onlyPrintableNow { n += 1 }
            if maxSeconds != nil { n += 1 }
            if maxGrams != nil { n += 1 }
            if !includeUnlabelled { n += 1 }
            return n
        }
    }

    static func apply(_ filter: Filter, to placed: [Placed]) -> [Placed] {
        placed.filter { item in
            guard let detail = item.row.detail else {
                // An unlabelled row cannot satisfy or fail a numeric test — it can only be kept or
                // dropped wholesale, which is exactly what `includeUnlabelled` decides.
                return filter.includeUnlabelled && !filter.onlyPrintableNow
                    && !filter.onlyWithPhotosOrNotes && filter.maxSeconds == nil
                    && filter.maxGrams == nil && filter.materials.isEmpty
            }
            if !filter.materials.isEmpty {
                let types = Set(detail.slots.compactMap { $0.type?.uppercased() })
                // **Rule 4 — `Universal` always passes a material filter.** It is not a material; it
                // is the absence of a constraint, and excluding it would hide versions that print
                // in anything.
                let passes = types.contains("UNIVERSAL") || !types.isDisjoint(with: filter.materials)
                if !passes { return false }
            }
            if filter.onlyWithPhotosOrNotes {
                guard item.row.summary != nil || !item.row.pictures.isEmpty else { return false }
            }
            if filter.onlyPrintableNow, item.group == .needsFilament { return false }
            if let cap = filter.maxSeconds, let s = detail.seconds, s > Double(cap) { return false }
            if let cap = filter.maxGrams, let g = detail.grams, g > Double(cap) { return false }
            return true
        }
    }

    // MARK: Which of your spools would serve which slot

    /// One loaded tray, flattened out of the AMS status.
    struct Tray: Equatable, Sendable {
        var unit: Int      // 0-based AMS unit
        var slot: Int      // 0-based slot within the unit
        var type: String   // upper-cased material
    }

    /// The AMS, flattened into trays. **One builder**, because three views had their own copy and
    /// two of them collapsed it to a `Set<String>` on the way — which is exactly how the tray COUNT
    /// got lost. A set answers "is this material loaded"; the question the UI asks is "can this
    /// version's slots each get a tray".
    static func trays(in status: PrinterStatus?) -> [Tray] {
        var out: [Tray] = []
        for unit in status?.ams ?? [] {
            for tray in unit.tray ?? [] {
                guard let t = tray.trayType?.uppercased(), !t.isEmpty else { continue }
                out.append(Tray(unit: unit.id, slot: tray.id, type: t))
            }
        }
        return out
    }

    /// Assign a distinct tray to each of a version's filament slots.
    ///
    /// **Distinct is the whole point.** The first version of this answered "is there a tray with
    /// this material?" and so reported the same tray for every PLA slot — a three-colour version
    /// claiming to print from one spool. That is the nearby-question bug this codebase keeps
    /// shipping: "the material is loaded" and "this slot has a tray" are different questions.
    ///
    /// Greedy and first-fit, in slot order, because that is all this page needs: it is a statement
    /// about what you have, not the mapping. `AmsMapping` owns the real mapping and the wizard is
    /// where it is chosen — a second matcher that drifted from it would be worse than none.
    ///
    /// A slot needing a material with no tray left returns `nil`, and the caller says why.
    static func assignTrays(slots: [MWSlot], trays: [Tray]) -> [Tray?] {
        var available = trays
        return slots.map { slot in
            guard let want = slot.type?.uppercased(), !want.isEmpty, want != "UNIVERSAL" else {
                return nil   // Universal asks for nothing, so nothing is claimed for it
            }
            guard let i = available.firstIndex(where: { $0.type == want }) else { return nil }
            return available.remove(at: i)
        }
    }

    /// Why a slot got no tray — "you have none" and "you have fewer than this version needs" are
    /// different problems with different fixes.
    static func shortfall(slots: [MWSlot], trays: [Tray]) -> [String: Int] {
        var needed: [String: Int] = [:]
        for slot in slots {
            guard let t = slot.type?.uppercased(), !t.isEmpty, t != "UNIVERSAL" else { continue }
            needed[t, default: 0] += 1
        }
        var short: [String: Int] = [:]
        for (material, want) in needed {
            let have = trays.filter { $0.type == material }.count
            if have < want { short[material] = want - have }
        }
        return short
    }

    /// The materials worth offering, built from the versions actually present rather than a
    /// hardcoded list — a filter for a material no version uses returns nothing and teaches nothing.
    static func materialsPresent(_ rows: [MWProfileRow]) -> [String] {
        var seen = Set<String>()
        for row in rows {
            for slot in row.detail?.slots ?? [] {
                if let t = slot.type?.uppercased(), !t.isEmpty, t != "UNIVERSAL" { seen.insert(t) }
            }
        }
        return seen.sorted()
    }
}
