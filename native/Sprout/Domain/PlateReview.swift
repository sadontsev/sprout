import Foundation

// Pure review of one build plate, for the print wizard's Review step.
//
// Two endpoints describe the same sliced file and neither is complete on its own: `/plates` knows
// per-plate time/material/objects and the embedded printer + process presets, while the file's
// slicer metadata knows layers, layer height, nozzle temperature and bed type. This merges them,
// each filling the other's gaps, so the view reads one flat value type and never re-derives
// anything.

/// One filament a plate consumes, ready to render.
struct ReviewFilament: Hashable, Sendable, Identifiable {
    /// 1-based slicer slot. 0 means the payload omitted it — the backend always sends one, so this
    /// is a "don't know" marker rather than a real slot.
    var slot: Int
    /// "PLA" | "PETG-CF" | … , or "—" when unknown.
    var type: String
    /// RAW slicer colour (`#RRGGBB`). Run it through `FilamentColor.norm` at the render site — the
    /// value can be a MakerWorld string that is not a colour at all.
    var color: String?
    var grams: Double?
    var meters: Double?

    var id: Int { slot }
}

/// Normalized, render-ready review of one plate of a sliced model.
struct PlateReviewVM: Hashable, Sendable {
    /// The plate actually being described — not necessarily the one that was asked for.
    var plateIndex: Int
    var plateCount: Int
    var isMultiPlate: Bool
    var timeSeconds: Double?
    var grams: Double?
    var layers: Int?
    var layerHeight: Double?
    /// layers × layerHeight, rounded to 2 dp, when both are known.
    var heightMm: Double?
    var nozzleTemp: Int?
    var bedType: String?
    var objectCount: Int?
    var printer: String?
    var process: String?
    var filaments: [ReviewFilament]
}

enum PlateReview {
    /// Build the review view-model for a sliced model.
    ///
    /// `plateIndex` is 1-based and falls back to the FIRST plate when the requested index isn't
    /// present — a file can be re-sliced to fewer plates while the wizard still holds the old
    /// selection. Both inputs may be nil (the two requests are fired in parallel and either can
    /// still be in flight); the result is a safe, all-nil VM rather than an optional.
    static func build(plates: PlatesResponse?, meta: FileMetadata?, plateIndex: Int = 1) -> PlateReviewVM {
        let plate = pickPlate(plates, plateIndex: plateIndex)

        // Height is computed from the RAW doubles, not from the rounded `layers` below, so a
        // fractional layer count can't shift the model's height.
        let layersRaw = finite(meta?.totalLayers)
        let layerHeight = finite(meta?.layerHeight)
        var heightMm: Double?
        if let layersRaw, let layerHeight {
            heightMm = (layersRaw * layerHeight * 100).rounded() / 100
        }

        return PlateReviewVM(
            plateIndex: plate?.index ?? plateIndex,
            plateCount: plates?.plates.count ?? 0,
            isMultiPlate: plates?.isMultiPlate == true,
            timeSeconds: finite(plate?.printTimeSeconds) ?? finite(meta?.printTimeSeconds),
            grams: finite(plate?.filamentUsedGrams) ?? finite(meta?.filamentUsedG),
            layers: whole(layersRaw),
            layerHeight: layerHeight,
            heightMm: heightMm,
            nozzleTemp: whole(finite(meta?.nozzleTemperature)),
            bedType: meta?.bedType,
            objectCount: plate?.objectCount,
            printer: plates?.embeddedPrinter ?? meta?.slicedForModel,
            process: plates?.embeddedProcess,
            filaments: filaments(plate: plate, meta: meta)
        )
    }

    /// "12 min" / "1 h 2 min" from seconds. "—" for nothing, zero, negative or unusable input.
    ///
    /// Deliberately NOT `Dash.fmtDuration`, which renders the same duration as "1h 02m" for the
    /// dense dashboard readouts. This spaced form is the wizard's stat-tile style.
    static func fmtSeconds(_ s: Double?) -> String {
        guard let s, s.isFinite, s > 0 else { return "—" }
        guard let m = whole((s / 60).rounded()) else { return "—" }
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(m % 60) min"
    }

    // MARK: - Internals

    private static func pickPlate(_ plates: PlatesResponse?, plateIndex: Int) -> PlateInfo? {
        guard let list = plates?.plates, !list.isEmpty else { return nil }
        return list.first { $0.index == plateIndex } ?? list[0]
    }

    /// Filaments for the plate: prefer the plate's own list, else derive from the file metadata's
    /// slots. An EMPTY plate list counts as absent — an unsliced or partially parsed plate reports
    /// `filaments: []`, and the metadata slots are still the better answer.
    private static func filaments(plate: PlateInfo?, meta: FileMetadata?) -> [ReviewFilament] {
        if let fromPlate = plate?.filaments, !fromPlate.isEmpty {
            return fromPlate.map { f in
                ReviewFilament(
                    slot: f.slotId ?? 0,
                    type: f.type ?? "—",
                    color: f.color,
                    grams: finite(f.usedGrams),
                    meters: finite(f.usedMeters)
                )
            }
        }
        if let slots = meta?.filamentSlots, !slots.isEmpty {
            return slots.map { s in
                ReviewFilament(
                    slot: s.slotId ?? 0,
                    type: s.type ?? "—",
                    color: s.color,
                    // Metadata slots carry mass only; length is a per-plate figure.
                    grams: finite(s.usedG),
                    meters: nil
                )
            }
        }
        return []
    }

    /// The number, or nil when it is missing or not finite. A stringified `"NaN"`/`"Infinity"`
    /// survives `LooseNumber` decoding, and infinity would render as a plausible-looking stat.
    private static func finite(_ n: LooseNumber?) -> Double? {
        guard let d = n?.double, d.isFinite else { return nil }
        return d
    }

    /// Nearest `Int`, or nil when the value can't be one. The range check is load-bearing:
    /// `Int(_: Double)` TRAPS on anything outside Int's range, so a garbage payload would crash the
    /// app instead of showing a dash.
    private static func whole(_ d: Double?) -> Int? {
        guard let d, d.isFinite else { return nil }
        let r = d.rounded()
        guard r >= Double(Int.min), r < Double(Int.max) else { return nil }
        return Int(r)
    }
}
