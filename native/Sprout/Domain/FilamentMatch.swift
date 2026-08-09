import Foundation

// Filament matching for the print wizard: which slicer preset should drive each plate filament, and
// what is actually loaded in the AMS right now.
//
// Pure functions over values — no printer I/O, no view state. The naming rules below were verified
// against the live 189-preset H2C set and encode two shipped bugs (nozzle-variant leakage and
// cross-unit spool inheritance), so they are worth reading before changing anything.

/// The parts of an inventory slot assignment that filament matching reads.
///
/// Deliberately narrower than `SlotAssignment`: `amsId` is optional here because records written
/// before assignments carried a unit id still exist, and they must keep matching their tray.
struct AssignmentLike: Hashable, Sendable {
    /// The spool fields that matter to matching — its slicer preset name, and its colour.
    struct SpoolLike: Hashable, Sendable {
        var colorName: String?
        var rgba: String?
        var slicerFilamentName: String?

        init(colorName: String? = nil, rgba: String? = nil, slicerFilamentName: String? = nil) {
            self.colorName = colorName
            self.rgba = rgba
            self.slicerFilamentName = slicerFilamentName
        }
    }

    /// Tray index INSIDE its unit — not a global tray id.
    var trayId: Int
    /// nil on legacy records written before assignments carried a unit id.
    var amsId: Int?
    var spool: SpoolLike?

    init(trayId: Int, amsId: Int? = nil, spool: SpoolLike? = nil) {
        self.trayId = trayId
        self.amsId = amsId
        self.spool = spool
    }

    /// Narrow a full inventory assignment down to what matching needs.
    init(_ assignment: SlotAssignment) {
        self.init(
            trayId: assignment.trayId,
            amsId: assignment.amsId,
            spool: SpoolLike(
                colorName: assignment.spool.colorName,
                rgba: assignment.spool.rgba,
                slicerFilamentName: assignment.spool.slicerFilamentName
            )
        )
    }
}

/// A filament actually loaded in an AMS tray, mapped to a slicer preset and its real colour.
struct LoadedFilament: Hashable, Sendable, Identifiable {
    /// GLOBAL tray id — what `trayNow`, ams/load and ams_mapping VALUES all speak. NOT a local
    /// index: with three units fitted, local ids collide three ways.
    var slot: Int
    var unitLabel: String
    /// Position inside its unit, for display ("Slot 3").
    var localId: Int
    /// The tray's own material string, e.g. "PETG-CF".
    var material: String
    var colorHex: String?
    var colorName: String?
    var preset: Preset?
    var isSupport: Bool

    var id: Int { slot }
}

enum FilamentMatch {
    /// Material type -> canonical base preset name, used when a tray has no inventory spool to name
    /// a preset for it. Keyed uppercase, so a lookup uppercases first and callers may pass any case.
    private static let materialBase: [String: String] = [
        "PLA": "Bambu PLA Basic",
        "PLA-S": "Bambu Support For PLA",
        "PETG": "Bambu PETG HF",
        "PETG-CF": "Bambu PETG-CF",
        "ABS": "Bambu ABS",
        "ABS-GF": "Bambu ABS-GF",
        "ASA": "Bambu ASA",
        "TPU": "Bambu TPU 95A HF",
        "PC": "Bambu PC",
        "PA-CF": "Bambu PA-CF",
        "PVA": "Bambu Support For PLA",
    ]

    /// The curated "other filament" catalog offered by the wizard, in the order it is shown.
    static let catalogMaterials = [
        "Bambu PLA Basic", "Bambu PLA Matte", "Bambu PETG HF", "Bambu PETG-CF",
        "Bambu ABS", "Bambu ASA", "Bambu TPU 95A HF", "Bambu Support For PLA",
    ]

    /// This printer's filament presets for ONE nozzle size: the bare `<base> @BBL <model>` form plus
    /// that size's ` <n> nozzle` variant. Other models ("M" / " mini") and other sizes are dropped.
    ///
    /// Bambu's naming is ASYMMETRIC and both halves matter (verified against the live 189-preset H2C
    /// set): every material has a bare form, but size variants exist only where Bambu tuned one —
    /// `Bambu PLA Basic @BBL H2C` ships 0.2/0.6/0.8 and NO 0.4, while `Bambu PETG-CF @BBL H2C` ships
    /// bare AND 0.4. So the rule is uniform for every size: prefer the exact `<size> nozzle` variant,
    /// else fall back to the bare form. Hard-coding 0.4 — as this once did — silently stripped every
    /// 0.2/0.6/0.8 variant from the pool, so picking 0.6 in the wizard sliced with 0.4-tuned flow and
    /// volumetric speed.
    private static func modelFilaments(_ presets: [Preset], token: String, nozzle: NozzleSize) -> [Preset] {
        let sized = " \(nozzle.rawValue) nozzle"
        return presets.filter { candidate in
            guard let at = candidate.name.range(of: token) else { return false }
            let after = candidate.name[at.upperBound...]
            return after.isEmpty || after == sized
        }
    }

    /// The exact-size preset for `base`, else its bare form, else nil.
    ///
    /// NO prefix fallback: the pool admits more than one suffix, so a `hasPrefix` match could hand
    /// back a different size than the one asked for.
    private static func byBase(_ base: String, pool: [Preset], token: String, nozzle: NozzleSize) -> Preset? {
        pool.first { $0.name == "\(base) \(token) \(nozzle.rawValue) nozzle" }
            ?? pool.first { $0.name == "\(base) \(token)" }
    }

    /// Best filament preset for a slicer name (preferred) or a raw material type, for `nozzle`.
    ///
    /// `token` is the `@BBL <model>` suffix BambuStudio stamps on every preset for a machine.
    static func preset(
        in presets: [Preset],
        slicerName: String?,
        material: String?,
        token: String = "@BBL A1",
        nozzle: NozzleSize = .mm04
    ) -> Preset? {
        let pool = modelFilaments(presets, token: token, nozzle: nozzle)
        // An empty name is "no name", not a base to look up — the inventory spool field is free text
        // and comes back blank for unrecognized spools.
        if let slicerName, !slicerName.isEmpty,
           let match = byBase(slicerName, pool: pool, token: token, nozzle: nozzle) {
            return match
        }
        if let material, !material.isEmpty, let base = materialBase[material.uppercased()] {
            return byBase(base, pool: pool, token: token, nozzle: nozzle)
        }
        return nil
    }

    /// True for filaments the wizard keeps out of the pickable list — they are printed as support,
    /// not as a model.
    private static func isSupport(_ material: String) -> Bool {
        let lower = material.lowercased()
        return lower.contains("support") || lower == "pla-s" || lower == "pva"
    }

    /// Build the loaded-filament options from AMS trays, enriched by inventory assignments + presets.
    ///
    /// Takes tray REFS (unit-aware) rather than one unit's tray array: this used to be handed
    /// `status.ams[0].tray`, so every unit after the first was invisible to the print wizard.
    static func loaded(
        trays: [AmsTrayRef],
        assignments: [AssignmentLike],
        presets: [Preset],
        token: String = "@BBL A1",
        nozzle: NozzleSize = .mm04
    ) -> [LoadedFilament] {
        var out: [LoadedFilament] = []
        for tray in trays {
            guard let material = tray.trayType, !material.isEmpty else { continue }  // empty slot
            // Match on BOTH ids. Matching the tray id alone made AMS 2 slot 0 inherit AMS 1 slot 0's
            // spool — wrong brand and colour, and a wrong slicer preset driving the slice. The unit
            // id is optional on the assignment, so a legacy record with no unit still matches its
            // tray as before.
            let assignment = assignments.first { $0.trayId == tray.localId && $0.amsId == tray.unitId }
                ?? assignments.first { $0.trayId == tray.localId && $0.amsId == nil }
            let spool = assignment?.spool
            out.append(LoadedFilament(
                slot: tray.globalId,
                unitLabel: tray.unitLabel,
                localId: tray.localId,
                material: material,
                // The tray's own colour wins; the inventory spool is the fallback for a tray whose
                // colour the printer does not know.
                colorHex: FilamentColor.norm(tray.trayColor) ?? FilamentColor.norm(spool?.rgba),
                colorName: spool?.colorName,
                preset: preset(
                    in: presets,
                    slicerName: spool?.slicerFilamentName,
                    material: material,
                    token: token,
                    nozzle: nozzle
                ),
                isSupport: isSupport(material)
            ))
        }
        return out
    }

    /// The curated "other filament" catalog, resolved against `presets` for `nozzle` and kept in
    /// `catalogMaterials` order. Materials this machine has no preset for are skipped.
    ///
    /// Single source of truth: the print-wizard sheet used to rebuild this list with its own
    /// 0.4-only filter, which is how the nozzle-size bug above came to exist in two places at once.
    static func catalog(in presets: [Preset], token: String, nozzle: NozzleSize = .mm04) -> [Preset] {
        let pool = modelFilaments(presets, token: token, nozzle: nozzle)
        return catalogMaterials.compactMap { byBase($0, pool: pool, token: token, nozzle: nozzle) }
    }
}
