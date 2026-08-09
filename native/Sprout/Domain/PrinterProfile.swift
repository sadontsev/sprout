import Foundation

// Pure, model-keyed printer knowledge. Everything the UI and the print wizard need in order to
// behave correctly per machine lives here rather than scattered as "A1" literals, so adding a
// printer is a table entry.

/// A build plate the machine accepts.
struct BedType: Hashable, Sendable, Identifiable {
    /// Canonical `bed_type` value the slicer expects — this string goes on the wire.
    let id: String
    /// Short name for the picker.
    let label: String
}

/// Build-plate footprint in millimetres (X width × Y depth).
struct PlateSize: Hashable, Sendable {
    let w: Double
    let d: Double
}

/// Per-model printer capabilities: preset naming, filament hub, plates, bed size, camera copy.
struct PrinterProfile: Hashable, Sendable {
    /// Preset-name token: BambuStudio suffixes profiles with "@BBL <token>".
    let presetToken: String
    /// The stock printer-preset base name in `/slicer/presets`, e.g. "Bambu Lab A1".
    let printerPresetBase: String
    /// Marketing name of the filament hub.
    let amsLabel: String
    let dualNozzle: Bool
    /// Build plates this machine accepts (first = default).
    let bedTypes: [BedType]
    /// Physical build-plate footprint in mm — drives the layer viewer's plate.
    let plate: PlateSize
    /// Camera behaviour copy. The A1's camera is on-demand and slow; H2-series streams additionally
    /// need LAN Mode Liveview switched on at the printer's own screen.
    let cameraHint: String
}

extension PrinterProfile {

    // MARK: - Build plates

    static let texturedPei = BedType(id: "Textured PEI Plate", label: "Textured PEI")
    static let smoothPei = BedType(id: "Smooth PEI Plate", label: "Smooth PEI")
    static let coolPlate = BedType(id: "Cool Plate", label: "Cool Plate")
    static let engineeringPlate = BedType(id: "Engineering Plate", label: "Engineering")
    static let highTempPlate = BedType(id: "High Temp Plate", label: "High Temp")

    /// The plates the A1 ships with, and the best-effort set for a machine we do not recognise.
    static let defaultBedTypes = [texturedPei, smoothPei, coolPlate, engineeringPlate]

    /// Footprint shared by the A1 and the unknown-model fallback.
    static let defaultPlate = PlateSize(w: 256, d: 256)

    // MARK: - Known machines

    /// Profiles keyed by UPPERCASED model string.
    static let known: [String: PrinterProfile] = [
        "A1": PrinterProfile(
            presetToken: "@BBL A1",
            printerPresetBase: "Bambu Lab A1",
            amsLabel: "AMS Lite",
            dualNozzle: false,
            bedTypes: PrinterProfile.defaultBedTypes,
            plate: PrinterProfile.defaultPlate,
            cameraHint: "The A1’s camera is on-demand and can be slow — give it a moment and tap Retry."
        ),
        "H2C": PrinterProfile(
            presetToken: "@BBL H2C",
            printerPresetBase: "Bambu Lab H2C",
            amsLabel: "AMS 2 Pro",
            dualNozzle: true,
            bedTypes: [
                PrinterProfile.texturedPei,
                PrinterProfile.smoothPei,
                PrinterProfile.highTempPlate,
                PrinterProfile.engineeringPlate,
            ],
            // 350 × 320 mm: the H2C's bed is deeper than it is wide — not square like the A1's.
            plate: PlateSize(w: 350, d: 320),
            cameraHint: "If this persists, enable LAN Mode Liveview in the printer’s settings screen (Settings → General)."
        ),
    ]

    // MARK: - Lookup

    /// Profile for a Bambuddy printer record. Unknown models get a best-effort generic profile
    /// (preset token derived from the model string) instead of silently behaving like an A1.
    ///
    /// A nil record means the printer list has not loaded yet, which falls back to the A1.
    static func forPrinter(_ printer: Printer?) -> PrinterProfile {
        let model = (printer?.model ?? "A1").trimmingCharacters(in: .whitespacesAndNewlines)
        // `uppercased()` is deliberately the locale-INDEPENDENT form: a Turkish device would
        // otherwise map "i" to "İ" and miss the table for any model spelled in lower case.
        if let match = known[model.uppercased()] { return match }
        return PrinterProfile(
            presetToken: "@BBL \(model)",
            printerPresetBase: "Bambu Lab \(model)",
            amsLabel: "AMS",
            dualNozzle: (printer?.nozzleCount ?? 1) > 1,
            bedTypes: defaultBedTypes,
            plate: defaultPlate,
            cameraHint: "Give the camera a moment and tap Retry. Make sure the printer is powered on."
        )
    }

    // MARK: - Wrong-machine guard

    /// Does a sliced file's embedded printer name match this machine? Nil/empty = unknown = allowed.
    ///
    /// The match is on the exact model: "Bambu Lab A1 mini" must NOT pass for the A1, because that
    /// is a different machine with a different bed.
    func matchesSlicedFor(_ embeddedPrinter: String?) -> Bool {
        let emb = (embeddedPrinter ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if emb.isEmpty { return true }
        let model = PrinterProfile.removingFirst("Bambu Lab ", from: printerPresetBase).uppercased()
        let embModel = PrinterProfile.removingFirst("BAMBU LAB ", from: emb)
        // Exact, or exact followed by a nozzle suffix ("A1 0.4 NOZZLE") — but never a longer model
        // name, which is what plain prefix matching would wrongly accept.
        return embModel == model || embModel.hasPrefix("\(model) 0.")
    }

    /// Drops only the FIRST occurrence of `needle`. `replacingOccurrences(of:with:)` drops every
    /// one, which would collapse a name that repeats the prefix ("Bambu Lab Bambu Lab A1") into a
    /// bare model and let a mislabelled file through the guard.
    private static func removingFirst(_ needle: String, from haystack: String) -> String {
        guard let range = haystack.range(of: needle) else { return haystack }
        return haystack.replacingCharacters(in: range, with: "")
    }
}
