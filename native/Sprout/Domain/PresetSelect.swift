import Foundation

// Pure selection of a printer's slicing quality (process) presets out of a Bambuddy
// /slicer/presets response. It lives apart from the print wizard so it can be unit-tested — this
// is exactly where a regression (0.2/0.6/0.8-nozzle variants leaking into the 0.4 mm list) slipped
// through once.

/// One slicer preset row as Bambuddy reports it.
struct Preset: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var name: String
    /// Which group the row came from, when the server bothers to say.
    var source: String?
}

/// The slice of `GET /slicer/presets` the app reads. Bambuddy groups presets by origin: the
/// BambuStudio stock set plus whatever the user has saved locally or in either cloud.
///
/// Property names are camelCase because keys are matched AFTER the shared decoder's snake_case
/// conversion — `orca_cloud` arrives as `orcaCloud`.
struct PresetsResponse: Codable, Hashable, Sendable {
    struct Group: Codable, Hashable, Sendable {
        var printer: [Preset]?
        var process: [Preset]?
        var filament: [Preset]?
    }

    var standard: Group?
    var local: Group?
    var cloud: Group?
    var orcaCloud: Group?
}

/// Stock nozzle sizes BambuStudio ships preset families for.
enum NozzleSize: String, CaseIterable, Hashable, Sendable, Identifiable {
    case mm02 = "0.2"
    case mm04 = "0.4"
    case mm06 = "0.6"
    case mm08 = "0.8"

    var id: String { rawValue }
}

/// The quality presets available for one printer + nozzle, with the support-enabled twins split out.
struct ProcessPresets: Hashable, Sendable {
    /// Base qualities only — the twins are deliberately absent so the wizard's grid stays clean.
    var qualities: [Preset] = []
    /// Base quality NAME -> its "+ Supports" twin, for the qualities that have one.
    var supportByBase: [String: Preset] = [:]
    var hasSupportProfile: Bool = false
}

/// Pure preset-picking rules: which quality profiles a machine + nozzle can actually use.
enum PresetSelect {
    /// The A1 (the 0.4-nozzle single-extruder), excluding the A1 Mini / A1M.
    static func isA1(_ name: String) -> Bool {
        name.contains("A1") && !name.contains("A1M") && !name.lowercased().contains("mini")
    }

    /// The support-enabled twin of a base quality, per the convention the provisioning script uses:
    /// "0.20mm Standard @BBL A1" -> "0.20mm Standard + Supports @BBL A1".
    static func supportTwinName(_ baseName: String, token: String = "@BBL A1") -> String {
        // Only the FIRST occurrence is rewritten — a name that repeats the model token must not
        // sprout two "+ Supports" markers and stop matching its twin.
        guard let range = baseName.range(of: " \(token)") else { return baseName + " + Supports" }
        return baseName.replacingCharacters(in: range, with: " + Supports \(token)")
    }

    /// The stock printer-preset name for a nozzle variant ("Bambu Lab H2C 0.6 nozzle").
    /// The machine preset for a mounted nozzle, with the two fallbacks that keep a slice possible.
    ///
    /// Three tiers, in order, and each exists for a measured reason:
    ///
    ///  1. the exact nozzle variant — `"H2C 0.6 nozzle"` — which is what you actually want;
    ///  2. the `0.4 nozzle` name, because it is the only variant every A1/H2 profile set is
    ///     guaranteed to ship, so it is the safe landing spot for an unusual nozzle;
    ///  3. the bare base name, for a profile set that does not split by nozzle at all.
    ///
    /// Returning nil rather than guessing is deliberate: `SlicePresets.canSlice` reads it, and a
    /// slice with no machine preset is a slice for no machine.
    ///
    /// Lifted out of `WizardView.loadPresets`, where it was three chained `first(where:)` calls in a
    /// view macOS cannot see.
    static func pickPrinterPreset(_ stock: [Preset], base: String, nozzle: NozzleSize) -> Preset? {
        stock.first { $0.name == printerPresetNameFor(base, nozzle: nozzle) }
            ?? stock.first { $0.name == "\(base) 0.4 nozzle" }
            ?? stock.first { $0.name == base }
    }

    static func printerPresetNameFor(_ base: String, nozzle: NozzleSize) -> String {
        "\(base) \(nozzle.rawValue) nozzle"
    }

    /// The selectable quality profiles for a printer + NOZZLE variant, merged across every preset
    /// group the server returns (standard plus the user's own local/cloud/orca_cloud profiles),
    /// deduped by id. `token` is the "@BBL <model>" suffix BambuStudio stamps on its presets.
    ///
    /// Naming convention (verified against the live preset list): 0.4-nozzle presets carry NO
    /// nozzle suffix; 0.2/0.6/0.8 variants are suffixed "@BBL <model> <d> nozzle". So for 0.4 every
    /// suffixed name is excluded; for the other sizes exactly that suffix is required.
    ///
    /// Support-enabled twins are kept OUT of the main quality list and paired to their base in
    /// `supportByBase` instead, so the wizard can offer a clean "Supports" toggle (the base quality
    /// stays selected and the toggle swaps in the twin at slice time). Twins are provisioned for
    /// 0.4 only.
    static func selectProcess(
        _ p: PresetsResponse?,
        token: String,
        nozzle: NozzleSize = .mm04
    ) -> ProcessPresets {
        let groups = [p?.standard?.process, p?.local?.process, p?.cloud?.process, p?.orcaCloud?.process]

        // `(?!\S)` is the whole reason this is a regex: it is what stops "@BBL A1" from matching
        // "@BBL A1M" (the A1 Mini) or "@BBL H2C" from matching a longer model token.
        let pattern = "0\\.\\d+mm .*\(NSRegularExpression.escapedPattern(for: token))(?!\\S)"
        guard let tokenRe = try? NSRegularExpression(pattern: pattern) else { return ProcessPresets() }
        let variantSuffix = "\(token) \(nozzle.rawValue) nozzle"

        var seen = Set<String>()
        var proc: [Preset] = []
        for preset in groups.compactMap({ $0 }).flatMap({ $0 }) {
            let keep = nozzle == .mm04
                ? matches(tokenRe, preset.name) && !hasVariantNozzleMarker(preset.name)
                : preset.name.hasSuffix(variantSuffix)
            guard keep, seen.insert(preset.id).inserted else { continue }
            proc.append(preset)
        }

        let qualities = proc.filter { !isSupportPreset($0.name) }
        let twins = proc.filter { isSupportPreset($0.name) }
        var supportByBase: [String: Preset] = [:]
        for base in qualities {
            let wanted = supportTwinName(base.name, token: token)
            if let twin = twins.first(where: { $0.name == wanted }) {
                supportByBase[base.name] = twin
            }
        }
        return ProcessPresets(
            qualities: qualities,
            supportByBase: supportByBase,
            hasSupportProfile: !twins.isEmpty
        )
    }

    /// Nozzle diameters physically mounted right now, read from the live status (e.g. on an H2C:
    /// left 0.6 + right-vortex 0.4). Extruder order is preserved; unknown/garbage entries dropped.
    static func mountedNozzles(_ status: PrinterStatus?) -> [NozzleSize] {
        var out: [NozzleSize] = []
        for n in status?.nozzles ?? [] {
            guard let size = NozzleSize(rawValue: n.nozzleDiameter ?? "") else { continue }
            if !out.contains(size) { out.append(size) }
        }
        return out
    }

    /// Default nozzle selection: prefer 0.4 when mounted (richest preset family, and the only one
    /// with support twins), else the first mounted size, else 0.4.
    static func defaultNozzle(_ mounted: [NozzleSize]) -> NozzleSize {
        if mounted.contains(.mm04) { return .mm04 }
        return mounted.first ?? .mm04
    }

    /// Convenience for the A1's process presets.
    static func selectA1Process(_ p: PresetsResponse?) -> ProcessPresets {
        selectProcess(p, token: "@BBL A1")
    }

    /// Default quality: prefer 0.20 mm Standard, then any 0.20 mm, else the first available.
    static func pickDefaultQuality(_ qualities: [Preset]) -> Preset? {
        qualities.first { $0.name.contains("0.20mm Standard") }
            ?? qualities.first { $0.name.contains("0.20") }
            ?? qualities.first
    }

    // MARK: - Internals

    /// A support twin by name. "support" alone already covers "+ Supports"; "tree" catches the
    /// tree-support profiles that do not spell the word out.
    private static func isSupportPreset(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("support") || lower.contains("tree")
    }

    /// The nozzle-variant marker the non-default families carry. 0.4-nozzle presets carry no
    /// nozzle suffix at all, so excluding these three is how the 0.4 list stays clean.
    private static func hasVariantNozzleMarker(_ name: String) -> Bool {
        name.contains("0.2 nozzle") || name.contains("0.6 nozzle") || name.contains("0.8 nozzle")
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
