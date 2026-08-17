import Foundation

/// The body of `POST /library/files/{id}/slice`, as data rather than as a view's local variable.
///
/// It lived inside `WizardView.runSliceStep` — iOS-only, private, and **never tested**: a grep of
/// `SproutTests/` for `export_3mf`, `bed_type` or `filament_preset` returned nothing before this
/// file existed. That was tolerable while one platform sliced. It stops being tolerable the moment
/// macOS needs the same body, because the alternative is a second copy of a wire format, and a
/// second copy of one predicate is the mechanism behind every entry in CLAUDE.md's recurring-bug
/// table.
///
/// Everything here is pure and synchronous. The two things that genuinely need a server — uploading
/// an ephemeral local preset for advanced overrides, and polling the job — stay at the call site.
enum SliceRequest {

    // MARK: - Preset references

    /// How the server wants a preset named: `{id, name}`, plus `source` when the row carried one.
    ///
    /// **`source` is REQUIRED by the server, not optional** — measured: a ref of `{id, name}` alone
    /// comes back `422 {"loc": ["body","printer_preset","source"], "msg": "Field required"}`. It is
    /// still emitted conditionally here because every real row from `GET /slicer/presets` carries one
    /// (`"source": "standard"` on the stock groups), so the conditional has never fired in practice.
    /// If a row ever arrives without it this will 422, and that is worth knowing before it happens
    /// rather than after.
    static func presetRef(_ p: Preset) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(p.id), "name": .string(p.name)]
        if let source = p.source { o["source"] = .string(source) }
        return .object(o)
    }

    /// A reference to a preset this app just uploaded (advanced overrides ride one of these).
    ///
    /// **The id is a STRING even though it is an integer.** `upsertLocalPreset` returns `Int`, and
    /// sending it as a JSON number here is the kind of break that produces a 422 from a server that
    /// otherwise looks like it agreed with you. Pinned by a test.
    static func localRef(id: Int) -> JSONValue {
        .object(["source": .string("local"), "id": .string(String(id))])
    }

    // MARK: - Filament ordering

    /// The chosen filament presets, in the order the server consumes them.
    ///
    /// **Compacted and positional.** Measured: the server reads `filament_presets` positionally
    /// against the USED slots, not against the raw slot numbers — a plate whose only slot is 2, given
    /// `[PLA, PETG]`, printed PLA. So the array is built by walking the used slots in ascending order
    /// and taking whatever preset each one has.
    ///
    /// `compactMap` also means a slot with NO preset closes the gap silently, which is a real bug the
    /// caller must prevent rather than discover — see `missingPresetSlots`.
    static func orderedFilaments(mappedSlots: [Int], presetBySlot: [Int: Preset]) -> [Preset] {
        mappedSlots.compactMap { presetBySlot[$0] }
    }

    /// Used slots with no filament preset chosen — the gap `orderedFilaments` would swallow.
    ///
    /// This exists because the swallowing is invisible and wrong. A plate needing slots `[1, 2]` with
    /// only slot 2 chosen produces a ONE-element list, which then takes the singular
    /// `filament_preset` branch below and slices the whole plate in the wrong material. Nothing
    /// caught that: iOS's step-3 footer is an unconditional Continue. Ask this first and refuse.
    static func missingPresetSlots(mappedSlots: [Int], presetBySlot: [Int: Preset]) -> [Int] {
        mappedSlots.filter { presetBySlot[$0] == nil }
    }

    // MARK: - The body

    /// Assemble the request.
    ///
    /// - Parameters:
    ///   - filaments: already ordered and compacted by `orderedFilaments`.
    ///   - filamentOverride: an ephemeral local preset the caller uploaded, when advanced filament
    ///     overrides are in play. Honoured only in the single-filament case, which is where it is the
    ///     only filament there is.
    static func body(
        plate: Int,
        bedType: String,
        printer: Preset?,
        process: JSONValue?,
        filaments: [Preset],
        filamentOverride: JSONValue? = nil
    ) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "plate": .int(plate),
            "bed_type": .string(bedType),
            "export_3mf": .bool(true),
        ]
        if let printer { body["printer_preset"] = presetRef(printer) }
        if let process { body["process_preset"] = process }

        // Singular for one filament — byte-identical to what has always shipped and is proven against
        // this server. Plural ONLY when there is genuinely more than one, so the overwhelmingly common
        // path is not changed on an untested hunch.
        //
        // The plural branch wins over `filamentOverride` deliberately: that is today's shipped
        // behaviour (the override is only ever built for a single filament), and a test documents it
        // rather than quietly "fixing" it into an untested shape.
        if filaments.count > 1 {
            body["filament_presets"] = .array(filaments.map { presetRef($0) })
        } else if let ref = filamentOverride ?? filaments.first.map({ presetRef($0) }) {
            body["filament_preset"] = ref
        }
        return body
    }
}

/// Can this file be sliced at all?
///
/// Separate from `LibraryFileCaps` only because that type is documented as answering questions about
/// what a file *has*, and this answers what the SLICER will take. Both are capability predicates and
/// both must stay positive.
enum SliceCapability {

    /// A project 3MF that Bambuddy's slicer sidecar can turn into toolpaths.
    ///
    /// **Positive and exact**, so an unrecognised `fileType` is refused rather than offered. The three
    /// tempting negations are all wrong, and each is wrong in a way that ships a control the backend
    /// refuses:
    ///
    ///  - `!LibraryFileCaps.hasGcode(f)` — true for an STL, and for every unknown type.
    ///  - `!LibraryFileCaps.isSliced(f)` — `isSliced` is a LABEL. A plain project `.3mf` naming
    ///    "Creality K2 Pro" in `slicedForModel` is `isSliced == true` and sliceable at the same time.
    ///  - `!LibraryFileCaps.isStl(f)` — admits every unknown type.
    ///
    /// **STL is included, and it is proven end to end rather than inferred.** Measured against the live
    /// server: slicing a `.stl` completes and produces a new library file, with a print time and a
    /// filament weight, exactly as a project 3MF does. The two were first shown to be
    /// indistinguishable to the endpoint (both 202, both reaching "Generating G-code"), and then both
    /// shown to succeed once the server was fixed.
    ///
    /// The failure seen before that fix was a SERVER problem and deliberately not encoded here:
    /// Bambuddy rejected the slicer's output because the sidecar image was two months stale and could
    /// not read the companion profile holding the real start G-code, so it refused to save a file that
    /// "would heat the printer and extrude nothing". Correct of it, and equally true for both file
    /// types — which is exactly why it must not become a capability predicate. A server that is
    /// misconfigured today is not a file that can never be sliced.
    static func canSlice(_ f: LibraryFile) -> Bool {
        ["3mf", "stl"].contains((f.fileType ?? "").lowercased())
    }
}
