import Foundation

/// The slicer presets a slice needs, flattened once from `GET /slicer/presets`.
///
/// This is `WizardPresets` — an iOS-only private struct — made shared, because macOS needs the same
/// four lists to slice the same way. It is a WRAPPER around `PresetSelect.selectProcess`, not a
/// replacement for it: `ProcessPresets.hasSupportProfile` is a plain `Bool` and 21 tests depend on
/// that, while the UI needs the **tri-state** below. Widening the existing type to suit one caller
/// would have been the tempting move and the wrong one.
struct SlicePresets: Hashable, Sendable {

    /// The machine preset, resolved for the mounted nozzle. See `PresetSelect.pickPrinterPreset`.
    var printer: Preset?
    /// Quality profiles for this machine, in the server's order.
    var qualities: [Preset] = []
    /// Quality name → its "+ Supports" twin, where one is provisioned.
    var supportByBase: [String: Preset] = [:]

    /// Are support profiles provisioned at all?
    ///
    /// **Tri-state, and the third state is the point.** `false` means the server answered and there
    /// are none — show the provisioning notice. `nil` means the request FAILED, and showing that same
    /// notice would blame the user's preset library for what is really a network error. The plain
    /// `Bool` on `ProcessPresets` cannot express the difference, which is why this type exists.
    var hasSupportProfile: Bool?

    /// Filaments matched to this machine and nozzle — what a per-tray preset is resolved from.
    var catalog: [Preset] = []
    /// Every stock filament row, unfiltered. `FilamentMatch.loaded` wants this one, not `catalog`:
    /// it does its own matching and needs the whole set to do it.
    var allFilaments: [Preset] = []

    /// Flatten a presets response for one machine.
    ///
    /// `token` and `nozzle` are REQUIRED, with no defaults, on purpose. `FilamentMatch`'s equivalents
    /// default to `"@BBL A1"` / `.mm04`, and on an H2C those silently match against the wrong machine
    /// and return plausible-looking wrong presets — with a green test suite. A parameter you must
    /// supply cannot be forgotten.
    static func build(
        from p: PresetsResponse,
        printerPresetBase: String,
        token: String,
        nozzle: NozzleSize
    ) -> SlicePresets {
        let stock = p.standard?.printer ?? []
        let process = PresetSelect.selectProcess(p, token: token, nozzle: nozzle)
        let allFilaments = p.standard?.filament ?? []
        return SlicePresets(
            printer: PresetSelect.pickPrinterPreset(stock, base: printerPresetBase, nozzle: nozzle),
            qualities: process.qualities,
            supportByBase: process.supportByBase,
            hasSupportProfile: process.hasSupportProfile,
            catalog: FilamentMatch.catalog(in: allFilaments, token: token, nozzle: nozzle),
            allFilaments: allFilaments
        )
    }

    /// Is there enough here to slice with?
    ///
    /// A machine preset is the one thing with no sensible fallback — without it the server has no idea
    /// what it is slicing for. Quality can default and supports are optional.
    var canSlice: Bool { printer != nil }
}
