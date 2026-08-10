import Foundation

// The one place the app decides what to CALL a filament.
//
// Three surfaces describe the same spool — the Hardware tab, the print wizard's Material step and its
// Map-filament step — and each used to name it its own way, which is how the wizard shipped two wrong
// answers for a slot the Hardware tab got right: a "Bambu PLA Wood" spool read as bare "PLA", and its
// brown was renamed "Orange" by the HSL namer while the swatch beside those words stayed brown.
// Neither was a data problem — the inventory record carried the right answer the whole time.
//
// Pure values in, display strings out: no view state, no printer I/O.

/// What to call one filament, with every source that can name it already reconciled.
struct FilamentIdentity: Hashable, Sendable {
    /// Normalised `#RRGGBB`, or nil when nothing knows the colour.
    var colorHex: String?
    /// "Clay Brown" — the spool's own name when it has one, else the computed fallback, else nil.
    var colorName: String?
    /// The bare material type the printer reports: "PLA", "PETG-CF".
    var material: String?
    /// The specific filament: "Bambu PLA Wood". nil unless it says more than `material` alone does.
    var product: String?

    /// Resolve the two precedences this app has exactly one right answer for.
    ///
    /// 1. A vendor's own colour name beats anything computed. `FilamentColor.name` buckets by hue and
    ///    chroma, and it classifies this printer's "Clay Brown" spool as *orange* — a word the brown
    ///    swatch next to it flatly contradicts. Its own doc comment says so: the computed name is a
    ///    FALLBACK, for a tray with no inventory record behind it, where a swatch alone cannot say
    ///    "white".
    /// 2. The specific filament beats the bare material. "PLA" is what the AMS reports for every PLA
    ///    ever made; "Bambu PLA Wood" is what is actually on the spool, and it prints differently.
    ///
    /// Empty and whitespace-only strings are "unknown", not values — every one of these fields is
    /// free text on the inventory record and comes back blank for an unrecognised spool.
    static func resolve(
        colorHex: String?,
        spoolColorName: String?,
        material: String?,
        product: String?
    ) -> FilamentIdentity {
        // `norm` is idempotent, so callers may pass either a raw RGBA tray value or an already
        // normalised one.
        let hex = FilamentColor.norm(colorHex)
        let material = clean(material)
        let product = clean(product)
        return FilamentIdentity(
            colorHex: hex,
            colorName: clean(spoolColorName) ?? FilamentColor.name(hex),
            material: material,
            // A "product" that only repeats the material ("PLA" for a PLA tray) names nothing new.
            product: product.flatMap { same($0, material) ? nil : $0 }
        )
    }

    /// Colour then material — "Clay Brown PLA". The Hardware tab's headline, and the form for any row
    /// with a second line to carry `product`. Empty when nothing at all is known.
    var title: String { Self.join([colorName, material], " ") }

    /// The whole identity on ONE line, for rows that have no second one:
    /// "Clay Brown · Bambu PLA Wood", or "Red PLA · Polymaker PolyLite" when the product name does not
    /// already say the material.
    var line: String {
        guard let product else { return title }
        // Dropping the material once the product name already contains it as a word is the same
        // de-duplication the Hardware tab does for brand vs preset ("Bambu Lab · Bambu PETG Basic"):
        // "Clay Brown PLA · Bambu PLA Wood" spends a whole row's width saying PLA twice. Word-wise,
        // not substring-wise — "PETG" appears inside "PETG-CF", but a PETG-CF spool is a different
        // filament and must keep saying which one it is.
        let repeated = material.map { m in
            product.split(separator: " ").contains { $0.caseInsensitiveCompare(m) == .orderedSame }
        } ?? false
        return Self.join([repeated ? colorName : title, product], " · ")
    }

    // MARK: - Internals

    private static func clean(_ s: String?) -> String? {
        let trimmed = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func same(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    private static func join(_ parts: [String?], _ separator: String) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: separator)
    }
}

// MARK: - Review rows

/// One filament row on the wizard's Review step: what the printer will actually extrude, and how much
/// of it this plate needs.
struct ReviewFilamentRow: Hashable, Sendable, Identifiable {
    /// Position in the plate's filament list, 0-based — also the index `ams_mapping` speaks.
    var index: Int
    /// Already normalised `#RRGGBB`; nil when the colour is unknown.
    var colorHex: String?
    /// "Clay Brown · Bambu PLA Wood" | "PLA" | "—"
    var name: String
    var grams: Double?
    var meters: Double?

    var id: Int { index }
}

extension FilamentIdentity {
    /// The Review step's filament rows: the plate's own list, with the MAPPED entry rewritten to
    /// describe the spool the user actually chose.
    ///
    /// Which source wins, and why:
    /// - IDENTITY (colour + material) comes from the selection. A plate's `type`/`color` are the
    ///   slicer preset that produced the G-code — a default nobody physically swapped — while the AMS
    ///   slot this print is mapped to holds the spool the nozzle will really pull from. Preferring the
    ///   plate is how a green "PLA" row came to describe a print that will run in brown Bambu PLA Wood.
    /// - QUANTITIES stay with the plate. Only the slice can know how many grams and metres it needs;
    ///   the spool knows nothing about this model.
    /// - ONLY the mapped row is rewritten. `ams_mapping` is indexed by FILAMENT and the wizard sends a
    ///   single entry, so filament 1 is the only one bound to a tray; any others are still purely the
    ///   slicer's choice and must keep saying so.
    /// Rows for a print with a chosen spool per filament slot.
    ///
    /// `selections` is keyed by the row's 0-based index, i.e. `slotId - 1`. Rows with no selection
    /// keep describing what the slicer chose — still the right rule, now applied per row instead of
    /// only to row 0.
    static func reviewRows(
        _ filaments: [ReviewFilament],
        selections: [Int: FilamentIdentity]
    ) -> [ReviewFilamentRow] {
        guard !filaments.isEmpty else {
            guard let named = selections[0], !named.line.isEmpty else { return [] }
            return [ReviewFilamentRow(index: 0, colorHex: named.colorHex, name: named.line,
                                      grams: nil, meters: nil)]
        }
        return filaments.enumerated().map { i, f in
            guard let named = selections[i], !named.line.isEmpty else {
                return ReviewFilamentRow(index: i, colorHex: FilamentColor.norm(f.color),
                                         name: f.type, grams: f.grams, meters: f.meters)
            }
            // The spool's colour, falling back to the plate's — a row must never lose a swatch it
            // could have shown.
            return ReviewFilamentRow(index: i, colorHex: named.colorHex ?? FilamentColor.norm(f.color),
                                     name: named.line, grams: f.grams, meters: f.meters)
        }
    }

    static func reviewRows(
        _ filaments: [ReviewFilament],
        selection: FilamentIdentity?,
        mappedIndex: Int = 0
    ) -> [ReviewFilamentRow] {
        // A selection that can name nothing (an empty tray, or one the inventory has never seen) is
        // not an improvement on the plate's own words.
        let named = (selection?.line.isEmpty == false) ? selection : nil

        guard !filaments.isEmpty else {
            // A plate that lists no filament at all — unsliced, or a payload neither endpoint could
            // parse — still has a chosen spool worth showing, with no quantities because nothing
            // measured any.
            guard let named else { return [] }
            return [ReviewFilamentRow(index: 0, colorHex: named.colorHex, name: named.line, grams: nil, meters: nil)]
        }

        return filaments.enumerated().map { i, f in
            guard i == mappedIndex, let named else {
                return ReviewFilamentRow(
                    index: i,
                    colorHex: FilamentColor.norm(f.color),
                    name: f.type,
                    grams: f.grams,
                    meters: f.meters
                )
            }
            return ReviewFilamentRow(
                index: i,
                // The spool's colour, falling back to the plate's when inventory has no hex — the row
                // must never lose a swatch it could have shown.
                colorHex: named.colorHex ?? FilamentColor.norm(f.color),
                name: named.line,
                grams: f.grams,
                meters: f.meters
            )
        }
    }
}
