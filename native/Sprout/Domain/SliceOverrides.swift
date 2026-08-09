import Foundation

// Pure builders for per-slice parameter overrides. Bambuddy's slice API takes only preset
// REFERENCES — but local presets support `inherits` plus a delta of keys (Bambuddy resolves the
// base; the slicer sidecar flattens inheritance too). So "advanced mode" = upsert an ephemeral
// local preset carrying just the user's changed keys, then slice referencing it. Same mechanism
// the "+ Supports" twins use (deploy/bambuddy/ensure-support-profiles.py), generalized.
//
// Key names and value shapes are verified against BambuStudio's PrintConfig.cpp: preset JSON
// values are STRINGS ("1"/"0" bools, "15%" percents). Only scalar-safe keys are exposed —
// per-extruder ARRAY keys (speeds are 5-element (extruder,variant) arrays on the H2-series) are
// deliberately excluded until the app can read base preset content and rewrite whole arrays.

/// The user's per-slice parameter changes. Every field is optional: nil means "inherit the base
/// preset", which is what keeps the emitted delta down to only what actually changed.
struct SliceOverrides: Hashable, Sendable {
    /// `wall_loops` (0–1000; stock is ~2).
    var wallLoops: Double?
    /// `sparse_infill_density`, a percentage 0–100.
    var infillDensity: Double?
    /// `sparse_infill_pattern`.
    var infillPattern: String?
    /// `top_surface_pattern`.
    var topPattern: String?
    /// `enable_prime_tower`.
    var primeTower: Bool?
    /// `prime_tower_width` in mm (the slicer's minimum is 2).
    var primeTowerWidth: Double?
    /// `enable_support` — the advanced path, which supersedes the "+ Supports" twin swap when set.
    var support: Bool?
    /// `support_type`: normal(auto) | tree(auto) | normal(manual) | tree(manual).
    var supportType: String?
    /// `support_style`: default | grid | snug | tree_slim | tree_strong | tree_hybrid | tree_organic.
    var supportStyle: String?
    /// `support_threshold_angle`, 1–90°.
    var supportAngle: Double?
    /// `filament_flow_ratio`. This one lives on the FILAMENT preset, not the process preset, and
    /// the H2-series stores it as a 3-element per-variant array.
    var flowRatio: Double?
}

// MARK: - Pickable values

extension SliceOverrides {
    static let infillPatterns: [String] = [
        "grid", "gyroid", "cubic", "triangles", "honeycomb", "lightning", "adaptivecubic", "crosshatch",
    ]
    static let topPatterns: [String] = ["monotonic", "monotonicline", "concentric", "alignedrectilinear"]
    static let supportTypes: [String] = ["tree(auto)", "normal(auto)"]
    static let supportStyles: [String] = [
        "default", "snug", "tree_slim", "tree_strong", "tree_hybrid", "tree_organic",
    ]
}

// MARK: - Which keys are set

extension SliceOverrides {
    /// One flag per PROCESS key, listed once so `hasProcessOverrides` and `overrideCount` can never
    /// disagree about what counts as a process override. `flowRatio` is absent on purpose: it goes
    /// on the filament preset, not this one.
    private var processKeysPresent: [Bool] {
        [
            wallLoops != nil, infillDensity != nil, infillPattern != nil, topPattern != nil,
            primeTower != nil, primeTowerWidth != nil, support != nil, supportType != nil,
            supportStyle != nil, supportAngle != nil,
        ]
    }

    var hasProcessOverrides: Bool { processKeysPresent.contains(true) }

    var hasFilamentOverrides: Bool { flowRatio != nil }

    /// Count of active overrides — drives the "n changed" badge on the Advanced accordion.
    var overrideCount: Int {
        processKeysPresent.filter { $0 }.count + (flowRatio != nil ? 1 : 0)
    }
}

// MARK: - Delta builders

extension SliceOverrides {
    /// The delta process-preset `setting` payload inheriting `baseQualityName`, or nil when nothing
    /// is overridden (so an untouched slice causes no preset churn at all).
    ///
    /// `presetName` is the reusable local-preset row name — one row per machine, updated in place,
    /// so slicing does not accumulate a preset row per job.
    func processDelta(inheriting baseQualityName: String, presetName: String) -> [String: JSONValue]? {
        guard hasProcessOverrides else { return nil }
        var s: [String: JSONValue] = [
            "type": .string("process"),
            "name": .string(presetName),
            "from": .string("User"),
            "inherits": .string(baseQualityName),
        ]
        if let v = wallLoops {
            s["wall_loops"] = .string(String(clampedInt(v, lower: 0, upper: Int.max)))
        }
        if let v = infillDensity {
            s["sparse_infill_density"] = .string("\(clampedInt(v, lower: 0, upper: 100))%")
        }
        if let v = infillPattern { s["sparse_infill_pattern"] = .string(v) }
        if let v = topPattern { s["top_surface_pattern"] = .string(v) }
        if let v = primeTower { s["enable_prime_tower"] = .string(presetBool(v)) }
        if let v = primeTowerWidth {
            // No rounding here — a tower width is a real millimetre value, only floored at the
            // slicer's minimum.
            s["prime_tower_width"] = .string(presetNumber(max(2, v)))
        }
        if let v = support { s["enable_support"] = .string(presetBool(v)) }
        if let v = supportType { s["support_type"] = .string(v) }
        if let v = supportStyle { s["support_style"] = .string(v) }
        if let v = supportAngle {
            s["support_threshold_angle"] = .string(String(clampedInt(v, lower: 1, upper: 90)))
        }
        return s
    }

    /// The delta filament-preset `setting`, or nil when the flow ratio is untouched.
    ///
    /// `variants` is the machine's per-(extruder,variant) array length for filament keys —
    /// H2-series: 3, single-extruder: 1. The same value is replicated across every slot, which is
    /// the safe uniform override.
    func filamentDelta(
        inheriting baseFilamentName: String,
        presetName: String,
        variants: Int = 3
    ) -> [String: JSONValue]? {
        guard let ratio = flowRatio else { return nil }
        let flow = presetNumber(min(2, max(0.5, ratio)))
        return [
            "type": .string("filament"),
            "name": .string(presetName),
            "from": .string("User"),
            "inherits": .string(baseFilamentName),
            "filament_flow_ratio": .array(Array(repeating: .string(flow), count: max(1, variants))),
        ]
    }
}

// MARK: - Value formatting

/// BambuStudio's `"1"` / `"0"` boolean convention for preset JSON.
private func presetBool(_ b: Bool) -> String { b ? "1" : "0" }

/// Renders a number the way preset JSON expects it: an integral value must serialise as "2", never
/// "2.0", because the slicer compares these values as text. Non-integral values keep the shortest
/// form that round-trips. Interpolation is used rather than a formatter so the output can never
/// pick up a comma decimal separator from the device locale.
private func presetNumber(_ v: Double) -> String {
    // The magnitude bound also rejects NaN and infinity, either of which would trap `Int64(_:)`.
    if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
    return "\(v)"
}

/// Round to the nearest integer and clamp into `lower...upper` without trapping.
///
/// The clamp is done in Double space on purpose: `Int(_:)` on a Double outside Int's range is a
/// hard crash, and a numeric text field bound to one of these sliders can produce exactly that.
private func clampedInt(_ v: Double, lower: Int, upper: Int) -> Int {
    guard v.isFinite else { return lower }
    let r = v.rounded()
    if r <= Double(lower) { return lower }
    if r >= Double(upper) { return upper }
    return Int(r)
}
