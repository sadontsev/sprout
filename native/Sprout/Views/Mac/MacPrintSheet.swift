#if os(macOS)
import SwiftUI

// The Mac print sheet — prototype §1f.
//
// iOS runs this as a seven-step full-screen wizard (`Views/Overlays/WizardView.swift`) because the
// screen is 390 pt wide and only one decision fits at a time. At 640 they all fit at once, so this
// is ONE page with a pinned footer: plate on the left, filament mapping on the right, the per-print
// options below, and the estimate + Cancel/Send in the footer. `⏎` sends, `⎋` cancels (§7).
//
// **No logic is re-implemented here.** Every rule that decides what gets sent to the printer already
// lives in `Domain/` and is unit-tested there: `AmsMapping` owns the wire array, `FilamentMatch`
// owns what a spool is called, `FilamentIdentity` owns the naming precedence, `PlateReview` owns the
// merge of the two endpoints that describe a plate, and `LibraryFileCaps` owns "does this file have
// toolpaths". This file is layout, presentation and the request.
//
// What it deliberately does NOT do, and why, is at `MacPrintScope` below. Read that first — the
// refusals are the design, not gaps in it.

// MARK: - Scope

/// The two capabilities this sheet does not have, stated once so both the code and the UI copy read
/// from the same place.
///
/// CLAUDE.md's recurring bug is "offering what the backend will refuse", and its rule is that an
/// affordance must be gated on the exact capability it needs. Both entries below are that gate.
enum MacPrintScope {

    // MARK: Slicing

    /// This sheet **prints a file that already carries toolpaths**. It does not slice.
    ///
    /// Slicing is a multi-minute server job with its own progress surface, a nozzle/quality/bed
    /// /supports decision tree and a poll loop (`WizardView.runSliceStep`, ~100 lines). §1f is "one
    /// page with a footer" — there is nowhere in it for a job that takes two minutes and can fail,
    /// and `Views/Mac/` has no slicing surface at all yet. Offering Send for an unsliced file would
    /// enqueue a `.stl` or a plain project `.3mf` the printer cannot execute.
    ///
    /// So an unsliced file opens the sheet, is described honestly, and Send is refused with this
    /// sentence. "Not in this build" beats a button that lies.
    ///
    /// TODO(mac-slice): a `MacSliceSheet` (or a slicing step inside this one, behind its own
    /// progress state) reusing `PresetSelect` + `SliceOverrides` — the two domain types this sheet
    /// therefore does not touch. When it lands, this branch becomes "Slice and print…".
    /// Why this file can never print from here — the TERMINAL branch.
    ///
    /// It kept its old sentence naming the iPhone app and Bambu Studio, but only for the files that
    /// genuinely need it. A sliceable `.3mf` gets `willSliceNote` instead; sending someone to another
    /// app for something this sheet is about to offer was the whole complaint.
    static func cannotSliceReason(_ file: LibraryFile) -> String {
        let kind = LibraryFileCaps.isStl(file)
            ? "An STL is a bare mesh, and Bambuddy hasn’t been confirmed to slice one"
            : "This file carries no toolpaths and isn’t a project Bambuddy can slice"
        return "\(kind), so there is nothing for the printer to run. Slice it in the iPhone app or in "
            + "Bambu Studio, then print the sliced file from here."
    }

    /// Why the button says Slice — the ACTIONABLE branch.
    ///
    /// Short on purpose: it sits above a footer whose button already names the action, and the sheet's
    /// job at that moment is to say what will happen, not to explain slicing.
    static let willSliceNote =
        "This is a project file, so it has no toolpaths yet. Slicing runs on your Bambuddy server and "
        + "produces a new file next to this one; the printer isn’t involved until you send it."

    // MARK: Per-print options

    /// Why bed levelling / flow calibration / timelapse are shown but not switchable.
    ///
    /// The queue request this app has ever proven carries exactly five keys — `printer_id`,
    /// `library_file_id`, `use_ams`, `ams_mapping`, `plate_id` (`WizardView.start`, and
    /// `BambuddyClient.reprint`). `docs/native-rewrite/15-makerworld-design.md:448` says
    /// `PrintQueueItemCreate` also carries "the calibration flags" — but it names `nozzle_offset_cali`
    /// and stops, and **nothing in this repo records the spelling of the other three**.
    ///
    /// That gap is not a detail. A FastAPI/Pydantic model ignores an unrecognised key by default, so
    /// a misspelt `bed_leveling` produces a switch that flips, saves nothing, and changes no print —
    /// row 1 of CLAUDE.md's recurring-bug table exactly ("controls that looked live and silently did
    /// nothing"). The same document's own reviewer reached the same conclusion about the neighbouring
    /// field: *"Do not ship a nozzle picker until the field exists. Say … in the UI."*
    ///
    /// So the rows are drawn — they are real print options and the user should know they exist — with
    /// a padlock instead of a switch and **no on/off claim**, because this sheet has not asked the
    /// printer what its defaults are either.
    ///
    /// TODO(calibration-flags): capture one `GET /openapi.json` from a live Bambuddy, write the
    /// `PrintQueueItemCreate` field names into `docs/native-rewrite/01-api.md`, then give
    /// `MacPrintOption` a `wireKey` and let these become real toggles. Nothing else here changes.
    static let optionsReason =
        "These are set on the printer. Sprout’s queue request carries the file, the plate and the AMS "
        + "mapping only — the calibration fields haven’t been confirmed against this server, and a "
        + "switch that saves nothing is worse than no switch."

    // MARK: Nozzle choice

    /// Shown only for a plate that needs more than one filament, on a dual-nozzle machine.
    ///
    /// `nozzle_mapping` exists on `PrintQueueItemResponse` and `PrintQueueItemUpdate` but **not** on
    /// `PrintQueueItemCreate` (measured — `15-makerworld-design.md:891`), so a queued print cannot
    /// say which extruder runs which material and the firmware auto-picks. Stating it is the
    /// document's own instruction; offering a picker for it would be the recurring bug.
    static let nozzleChoiceNote =
        "The printer picks which nozzle runs which material — a queued print can’t express that choice."
}

// MARK: - Options

/// The three per-print options §1f draws. Labels and the "adds ~ N min" captions only: there is
/// deliberately no `isOn` and no wire key — see `MacPrintScope.optionsReason`.
enum MacPrintOption: String, CaseIterable, Identifiable, Sendable {
    case bedLevelling, flowCalibration, timelapse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bedLevelling: "Bed levelling"
        case .flowCalibration: "Flow calibration"
        case .timelapse: "Timelapse"
        }
    }

    /// What it costs, when it costs time. Timelapse runs alongside the print, so it has no caption —
    /// inventing "adds ~ 0 min" for it would be a number nobody measured.
    var addedTime: String? {
        switch self {
        case .bedLevelling: "adds ~ 2 min"
        case .flowCalibration: "adds ~ 5 min"
        case .timelapse: nil
        }
    }
}

// MARK: - Refusals

/// Why Send is off, phrased for the user. One value so the sheet cannot show two contradictory
/// reasons, and so the ordering below is a single decision rather than a chain of `if`s in `body`.
struct MacPrintProblem: Equatable, Sendable {
    let title: String
    let message: String
    /// True for a condition the user cannot fix from this sheet — draws in `error` rather than
    /// `heating`, because "load a spool" and "this file can never print here" deserve different weight.
    var terminal: Bool = false

    /// What the user can DO about it, when the answer is an action this sheet offers.
    ///
    /// A separate field rather than a third `terminal` state, because `terminal` answers "can this be
    /// fixed here at all" and this answers "and if so, with which button" — two questions, and
    /// overloading one Bool to carry both is the shape CLAUDE.md's table is made of. `nil` means the
    /// notice is informational: fix the thing it names and the gate clears itself.
    var remedy: Remedy?

    enum Remedy: Equatable, Sendable {
        /// There is nothing to print, but there IS something to slice. The footer offers Slice.
        case slice
    }
}

/// Every precondition for pressing Send, evaluated in the order the user should hear them.
///
/// Pure and `internal` on purpose: these are the same guards `WizardView.start` re-asks at press
/// time, and they are the last thing that happens before a physical machine moves. A future
/// `MacPrintSheetTests` can drive this without a window.
enum MacPrintGate {

    /// - Parameters:
    ///   - usedSlots: the 1-based filament slots THIS PLATE consumes — from
    ///     `filament-requirements?plate_id=`, never the unfiltered file-wide list.
    ///   - trayBySlot: slot → global tray id. A slot with no entry is "not chosen yet".
    ///   - loadedTrays: the AMS as it is right now, so a spool pulled since the choice is caught.
    /// - Parameters:
    ///   - hasToolpaths: `LibraryFileCaps.hasGcode` of the file that would actually be PRINTED — the
    ///     slice output once one exists, not the file the sheet was opened with. Passed in rather than
    ///     derived here for exactly that reason: this function must not assume the two are the same.
    ///   - canSlice: `SliceCapability.canSlice` of the file the sheet was opened with. Decides whether
    ///     "nothing to print" is a dead end or a first step.
    ///   - presetBySlot: the filament preset chosen for each used slot, when slicing. Empty when there
    ///     is nothing to slice; see guard 5b.
    static func evaluate(
        file: LibraryFile,
        hasToolpaths: Bool,
        canSlice: Bool,
        printerMismatch: Bool,
        slicedFor: String?,
        printerName: String?,
        hasStatus: Bool,
        loadedTrays: [AmsTrayRef],
        usedSlots: [Int],
        trayBySlot: [Int: Int],
        presetBySlot: [Int: Preset] = [:]
    ) -> MacPrintProblem? {
        // 1. Is there anything to print at all — and if not, is there anything to SLICE?
        //
        // `hasToolpaths` is `hasGcode`, NOT `isSliced`: a plain project .3mf carries a
        // `slicedForModel` and no toolpaths, and `isSliced` would wave it through. That is the exact
        // pair CLAUDE.md's table names. What is new is the second question — the same file that
        // cannot be printed is usually precisely the file that can be sliced, and saying only "this
        // cannot print" of a file one button would fix is a refusal that answers the wrong question.
        guard hasToolpaths else {
            return canSlice
                ? MacPrintProblem(
                    title: "Not sliced yet",
                    message: MacPrintScope.willSliceNote,
                    remedy: .slice
                  )
                : MacPrintProblem(
                    title: "Nothing to print yet",
                    message: MacPrintScope.cannotSliceReason(file),
                    terminal: true
                  )
        }
        // 2. Is it G-code for THIS machine? Another machine's toolpaths can crash the head.
        if printerMismatch {
            return MacPrintProblem(
                title: "Sliced for another printer",
                message: "This file was sliced for \(slicedFor ?? "another machine"), not for "
                    + "\(printerName ?? "this printer"). Reslice it before printing — G-code from "
                    + "another machine can crash the toolhead.",
                terminal: true
            )
        }
        // 3. Is there an AMS to map to?
        //
        // Two questions, deliberately not one predicate. `trays.isEmpty` is true both while the
        // status store is still connecting and when a connected printer genuinely reports no trays,
        // and only the second is a fact about the machine. Printing "no AMS trays" at a printer that
        // simply has not answered yet is the same shape as rendering "you have none" from a response
        // that also means "we could not ask".
        if !hasStatus {
            return MacPrintProblem(
                title: "Waiting for the printer",
                message: "No status has arrived from \(printerName ?? "the printer") yet, so there are "
                    + "no AMS trays to map to. This clears on its own once it reports in."
            )
        }
        if loadedTrays.isEmpty {
            return MacPrintProblem(
                title: "No AMS trays reported",
                message: "\(printerName ?? "The printer") reports no AMS trays. Load filament, then reopen this sheet."
            )
        }
        // 4. Slots past what `ams_mapping` can address. Named, never truncated.
        if let over = AmsMapping.unmappable(usedSlots: usedSlots).first {
            return MacPrintProblem(
                title: "Too many filaments",
                message: "This plate asks for filament slot \(over), which this app can’t address.",
                terminal: true
            )
        }
        // 5. "Every filament this plate needs has a tray" — NOT "a tray is selected", and NOT "how
        //    many filaments". `ams_mapping` carries one entry per slot; an unmapped slot reaches the
        //    printer as -1 and the firmware picks a spool at random.
        let unmapped = AmsMapping.unmapped(usedSlots: usedSlots, trays: trayBySlot)
        if !unmapped.isEmpty {
            return MacPrintProblem(
                title: unmapped.count == 1 ? "Filament \(unmapped[0]) has no tray" : "Some filaments have no tray",
                message: usedSlots.count > 1
                    ? "This plate uses \(usedSlots.count) filaments. Choose a tray for "
                        + unmapped.map { "filament \($0)" }.joined(separator: ", ") + " above."
                    : "Choose which AMS tray to print from."
            )
        }
        // 5b. "…and every one of those trays resolves to a filament preset." Only when slicing.
        //
        // This is the gap `SliceRequest.orderedFilaments` would swallow: `compactMap` closes it, so a
        // plate needing slots [1, 2] with a preset for only slot 2 produces a ONE-element list, takes
        // the SINGULAR `filament_preset` branch, and slices the whole plate in the wrong material.
        // iOS has shipped that bug — its step-3 footer is an unconditional Continue — and the Mac
        // refuses instead. Skipped entirely when `presetBySlot` is empty, which is the print-only path.
        if !presetBySlot.isEmpty {
            let missing = SliceRequest.missingPresetSlots(mappedSlots: usedSlots, presetBySlot: presetBySlot)
            if !missing.isEmpty {
                return MacPrintProblem(
                    title: missing.count == 1 ? "Filament \(missing[0]) has no material" : "Some filaments have no material",
                    message: "Slicing needs to know which material each filament is. Choose a tray whose "
                        + "spool the slicer recognises for "
                        + missing.map { "filament \($0)" }.joined(separator: ", ") + "."
                )
            }
        }
        // 6. "…and those trays still hold filament." The AMS is live while this sheet is open.
        let stale = AmsMapping.stale(trays: trayBySlot, loaded: loadedTrays)
        if !stale.isEmpty {
            return MacPrintProblem(
                title: "That tray is empty now",
                message: "The spool for " + stale.map { usedSlots.count > 1 ? "filament \($0)" : "this print" }
                    .joined(separator: ", ") + " was removed. Pick another tray."
            )
        }
        return nil
    }
}

// MARK: - Matching

/// Which loaded spools could serve one of the plate's filaments.
///
/// Pure, and separated from the view for the same reason `AmsMapping` is: this decides what the
/// printer pulls from. **Identity is never recomputed from a hex colour here** — every candidate is
/// described by `LoadedFilament.identity`, which is `FilamentIdentity.resolve` reading the inventory
/// record. That is row 4 of CLAUDE.md's recurring-bug table ("a brown spool labelled Orange").
enum MacFilamentMatching {

    /// Loaded spools that match what the plate asks for in that slot: same material AND the exact
    /// same colour. Empty when the requirement says nothing usable — "unknown" is not a match.
    ///
    /// Two deliberate differences from `WizardView.applyDefaultFilament`'s multi-filament rule, both
    /// because this sheet prints an ALREADY-SLICED file rather than slicing one:
    ///
    /// - **No `preset != nil` filter.** A slicer preset is what tells the slicer how to flow a
    ///   material; a pre-sliced print needs a tray, not a profile. Requiring one here would hide a
    ///   perfectly printable spool because BambuStudio ships no profile under its name.
    /// - **`material` counts as well as `product`.** `FilamentIdentity.product` is nil whenever the
    ///   inventory spool names nothing beyond the bare material, so matching on `product` alone can
    ///   never match an ordinary "PLA" tray. The colour still has to be exact, and a match is only
    ///   ever *used* when there is exactly one — see `autoFill`.
    static func candidates(
        for want: FilamentRequirements.Requirement?,
        in loaded: [LoadedFilament]
    ) -> [LoadedFilament] {
        guard let want else { return [] }
        let type = (want.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty, let color = FilamentColor.norm(want.color) else { return [] }
        return loaded.filter { spool in
            let id = spool.identity
            guard id.colorHex == color else { return false }
            if let product = id.product, product.localizedCaseInsensitiveContains(type) { return true }
            return id.material?.caseInsensitiveCompare(type) == .orderedSame
        }
    }

    /// Pre-fill ONLY where the answer is unambiguous — exactly one loaded spool matches the plate's
    /// requirement for that slot.
    ///
    /// A nearest-colour guess is the "brown spool labelled Orange" bug one layer up: with several
    /// rows on screen the user cannot tell which were guesses, so anything unsure is left blank and
    /// the row says what is missing instead.
    ///
    /// `activeTray` is the one concession, and only for a single-filament plate whose requirement
    /// nothing could answer (the fetch failed, or the file lists no slots): the tray the printer is
    /// already pulling from is a fact, not a guess, and it is visible in the one row on screen.
    /// Unlike iOS there is no "…else the first loaded spool" fallback — with room to explain, a named
    /// blank beats an arbitrary pick.
    static func autoFill(
        usedSlots: [Int],
        requirement: (Int) -> FilamentRequirements.Requirement?,
        loaded: [LoadedFilament],
        activeTray: Int?,
        into trays: inout [Int: Int]
    ) {
        guard !loaded.isEmpty else { return }
        for slot in usedSlots where trays[slot] == nil {
            let matches = candidates(for: requirement(slot), in: loaded)
            if matches.count == 1, let only = matches.first {
                trays[slot] = only.slot
            }
        }
        if usedSlots.count == 1, let slot = usedSlots.first, trays[slot] == nil,
           requirement(slot) == nil, let activeTray,
           loaded.contains(where: { $0.slot == activeTray }) {
            trays[slot] = activeTray
        }
    }
}

/// One row of the mapping table: the slot the plate needs, what the file asks for there, and the
/// tray bound to it.
private struct MacFilamentRow: Identifiable {
    let slot: Int
    /// What the FILE wants — colour and material as the slicer recorded them.
    let want: FilamentRequirements.Requirement?
    let tray: AmsTrayRef?
    /// What is really in that tray, **read from inventory** via `FilamentMatch.identity`.
    let identity: FilamentIdentity?
    /// How many loaded spools match `want`. Drives the remedy sentence, not the selection.
    let candidateCount: Int

    var id: Int { slot }
    var isMapped: Bool { tray != nil }
    /// Amber: nothing is bound and nothing loaded matches. The row names the remedy rather than
    /// picking something.
    var needsAttention: Bool { tray == nil }
}

// MARK: - The sheet

/// §1f. Present with `.sheet` and an explicit `.frame(width: 640)` — a macOS sheet sizes to its
/// content, and without the frame this collapses to a sliver.
///
/// ```swift
/// @State private var printTarget: LibraryFile?
/// …
/// .macPrintSheet($printTarget, model: model)
/// ```
@MainActor
struct MacPrintSheet: View {
    let file: LibraryFile
    let model: AppModel
    @Binding var isPresented: Bool

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    // MARK: Choices

    @State private var selectedPlate = 1
    /// Chosen tray per filament SLOT (1-based). Never stores `-1`: a missing key means "not chosen",
    /// which the UI names; `-1` exists only in the wire array `AmsMapping.build` produces.
    @State private var trayBySlot: [Int: Int] = [:]
    /// One-shot latch. Re-opened when the plate changes, because a different plate is a different
    /// question — see `.onChange(of: usedSlots)`.
    @State private var autoFilled = false

    // MARK: Loaded data

    @State private var plates: PlatesResponse?
    @State private var meta: FileMetadata?
    @State private var assigns: [SlotAssignment] = []
    /// What the file about to be printed asks for. `nil` while unasked or unanswerable — which is
    /// **not** the same as "needs nothing"; `usedSlots` falls back to `[1]` for exactly that reason.
    @State private var requirements: FilamentRequirements?
    @State private var loadingPlate = true
    /// Both plate requests came back empty-handed. Kept apart from "the plate records nothing",
    /// which is what an answered-but-sparse file looks like — see `estimate`.
    @State private var plateReadFailed = false

    @State private var starting = false
    @State private var sendFailure: String?

    /// The slicer presets, once fetched. `nil` means "not asked yet or the ask failed" — the
    /// distinction is `presetsError`.
    @State private var presets: SlicePresets?
    /// Why the preset fetch failed, if it did.
    ///
    /// A presets failure must NOT block printing: the tray Menu renders perfectly without them, and
    /// only slicing needs them. So this refuses SLICING with a reason and leaves an already-sliced
    /// file as printable as it was before.
    @State private var presetsError: String?
    @State private var lanAlert = false

    init(file: LibraryFile, model: AppModel, isPresented: Binding<Bool>) {
        self.file = file
        self.model = model
        _isPresented = isPresented
    }

    // MARK: - Derived

    private var status: PrinterStatus? { model.status?.status }
    private var profile: PrinterProfile { PrinterProfile.forPrinter(model.printer) }

    /// Every tray across EVERY unit. Reading `status.ams[0].tray` here once made 5 of the 9 slots on
    /// a three-unit machine invisible and unprintable.
    private var trays: [AmsTrayRef] { AmsTopology.trayRefs(status) }
    private var assignmentLikes: [AssignmentLike] { assigns.map { AssignmentLike($0) } }

    /// The spools physically loaded, named by the domain — and, once the presets are in, carrying the
    /// slicer preset each tray resolves to.
    ///
    /// This used to pass `presets: []` with a comment defending it because "this sheet never slices".
    /// It does now, so the real list goes in, and the existing tray Menu becomes the filament-preset
    /// picker for free — which is why the Mac needs no equivalent of the wizard's whole Material step.
    /// Before the fetch lands (or if it fails) this degrades to exactly the old behaviour: identity,
    /// colour and support classification are unaffected by an empty preset list, so an
    /// already-sliced file stays printable while presets are still loading.
    ///
    /// **`token:` and `nozzle:` are passed explicitly and must stay that way.** They default to
    /// `"@BBL A1"` and `.mm04`; on an H2C those match against the wrong machine and return
    /// plausible-looking wrong presets, silently, with a green suite.
    private var loaded: [LoadedFilament] {
        FilamentMatch.loaded(
            trays: trays,
            assignments: assignmentLikes,
            presets: presets?.allFilaments ?? [],
            token: profile.presetToken,
            nozzle: nozzle
        )
        .filter { !$0.isSupport }
    }

    /// The nozzle the presets are resolved for.
    ///
    /// Read from what is actually mounted rather than offered as a control: the choice selects a
    /// preset FAMILY, not machine behaviour, and `nozzle_mapping` is absent from
    /// `PrintQueueItemCreate` — so the app cannot say which nozzle runs which material regardless
    /// (`MacPrintScope.nozzleChoiceNote`). On a machine with two unequal nozzles mounted this picks
    /// one and the note names it, rather than the sheet pretending the choice is not being made.
    private var nozzle: NozzleSize {
        PresetSelect.defaultNozzle(PresetSelect.mountedNozzles(status))
    }

    private var vm: PlateReviewVM { PlateReview.build(plates: plates, meta: meta, plateIndex: selectedPlate) }

    /// Whether the file already carries toolpaths — `hasGcode`, the capability, never `isSliced`,
    /// the label.
    private var alreadySliced: Bool { LibraryFileCaps.hasGcode(file) }
    private var slicedFor: String? { plates?.embeddedPrinter ?? file.slicedForModel }
    private var printerMismatch: Bool { alreadySliced && !profile.matchesSlicedFor(slicedFor) }

    /// The filament slots this print has to bind to trays. `[1]` when the requirements could not be
    /// fetched — never `[]`, which `AmsMapping.isComplete` reads as "unknown" rather than "satisfied".
    private var usedSlots: [Int] {
        let ids = requirements?.usedSlotIds ?? []
        return ids.isEmpty ? [1] : ids
    }

    private var isMultiFilament: Bool { usedSlots.count > 1 }

    private func requirement(for slot: Int) -> FilamentRequirements.Requirement? {
        requirements?.usedSlots.first { ($0.slotId ?? 1) == slot }
    }

    private var rows: [MacFilamentRow] {
        let spools = loaded
        return usedSlots.map { slot in
            let tray = trayBySlot[slot].flatMap { gid in trays.first { $0.globalId == gid } }
            return MacFilamentRow(
                slot: slot,
                want: requirement(for: slot),
                tray: tray,
                // Read from inventory. Naming the colour from the hex here is what printed
                // "Orange PLA" beside a brown swatch of "Clay Brown" Bambu PLA Wood.
                identity: tray.map { FilamentMatch.identity(for: $0, in: assignmentLikes) },
                candidateCount: MacFilamentMatching.candidates(for: requirement(for: slot), in: spools).count
            )
        }
    }

    /// Fetch and flatten the slicer presets for this machine.
    ///
    /// `getPresets()` returns raw `Data`, not a decoded response — the decode belongs to the caller,
    /// and until now the only caller was the iOS wizard.
    private func loadPresets() async {
        guard SliceCapability.canSlice(file), let client = model.client else { return }
        do {
            let data = try await client.getPresets()
            let response = try BambuddyClient.decoder.decode(PresetsResponse.self, from: data)
            guard !Task.isCancelled else { return }
            presets = SlicePresets.build(
                from: response,
                printerPresetBase: profile.printerPresetBase,
                token: profile.presetToken,
                nozzle: nozzle
            )
            presetsError = nil
        } catch {
            guard !Task.isCancelled else { return }
            presets = nil
            presetsError = JobsStore.failureText(error)
        }
    }

    private var problem: MacPrintProblem? {
        MacPrintGate.evaluate(
            file: file,
            hasToolpaths: alreadySliced,
            canSlice: SliceCapability.canSlice(file),
            printerMismatch: printerMismatch,
            slicedFor: slicedFor,
            printerName: model.printer?.name,
            hasStatus: status != nil,
            loadedTrays: trays,
            usedSlots: usedSlots,
            trayBySlot: trayBySlot
        )
    }

    private var locked: LockedActions { LockedActions(mode: model.lanMode, explaining: $lanAlert) }

    /// A tray's human position: "AMS 2 · Slot 1", "AMS HT". Never the raw global id, which renders as
    /// "Slot 129" for the HT unit.
    private func trayLabel(_ tray: AmsTrayRef) -> String {
        Set(trays.map(\.unitId)).count > 1
            ? "\(tray.unitLabel) · Slot \(tray.localId + 1)"
            : "Slot \(tray.localId + 1)"
    }

    /// Library names arrive percent-encoded; a name that isn't valid encoding stays as-is rather than
    /// collapsing to nothing.
    private var displayName: String {
        let candidates = [file.printName ?? "", file.filename, "file-\(file.id)"]
        let raw = candidates.first { !$0.isEmpty } ?? "file-\(file.id)"
        return raw.removingPercentEncoding ?? raw
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: m.sectionGap) {
                    topRow
                    plateChips
                    optionsSection
                    notices
                }
                .padding(.horizontal, m.gutter)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A cap, not a height: a single-filament plate makes a short sheet and a nine-slot one
            // scrolls instead of growing past the display.
            .frame(maxHeight: 460)
            footer
        }
        .background(c.sheet)
        .task(id: file.id) { await loadFile() }
        // Presets are fetched ONLY for a file that can actually be sliced.
        //
        // `GET /slicer/presets` is 189 rows on an H2C, and the overwhelmingly common case here is an
        // already-sliced file that needs none of them. Keying on `canSlice` rather than firing
        // unconditionally is what keeps opening the sheet on a `gcode.3mf` exactly as cheap as it was
        // before slicing existed.
        .task(id: "presets-\(file.id)-\(SliceCapability.canSlice(file))") { await loadPresets() }
        // Per PLATE, and keyed on the exact (file, plate) pair that will be enqueued. Unfiltered,
        // `filament-requirements` reports every slot in the FILE — a different question, and the one
        // that maps trays this plate never asks for.
        .task(id: "\(file.id)-\(selectedPlate)") { await loadRequirements() }
        .onChange(of: usedSlots) { _, slots in
            // A different plate is a different question. Bindings for slots this plate does not use
            // are dropped rather than carried forward into an array they would mis-index.
            trayBySlot = trayBySlot.filter { slots.contains($0.key) }
            autoFilled = false
            applyAutoFill()
        }
        .onChange(of: loadedKey, initial: true) { _, _ in applyAutoFill() }
        .alert("Couldn’t start", isPresented: presentingFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: sendFailure ?? "")
        }
        .lockedActionAlert($lanAlert)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: "Print \(displayName)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(c.t1)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: subtitle)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(c.t3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, m.gutter)
        .padding(.top, 18)
    }

    /// "H2C · Workshop · plate 1 of 1". Only the parts that are known — a plate count of zero is the
    /// two requests still being in flight, not a file with no plates.
    private var subtitle: String {
        var parts: [String] = []
        if let printer = model.printer {
            parts.append(printer.name)
            if let location = printer.location, !location.isEmpty { parts.append(location) }
        }
        if vm.plateCount > 0 { parts.append("plate \(vm.plateIndex) of \(vm.plateCount)") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Plate + mapping

    private var topRow: some View {
        HStack(alignment: .top, spacing: 16) {
            platePreview
            mappingColumn
        }
    }

    /// Plate thumbnails are gated by the camera STREAM token in `?token=`, not by `X-API-Key` — the
    /// header path answers 401 here.
    private var thumbURL: URL? {
        guard let client = model.client,
              plates?.plates.first(where: { $0.index == vm.plateIndex })?.hasThumbnail == true
        else { return nil }
        return client.plateThumbUrl(file.id, plateIndex: vm.plateIndex, token: model.cameraToken)
    }

    private var platePreview: some View {
        // A 180×150 media surface is card-scale, so it takes `cardRadius`. It is not nested inside
        // another rounded shape — it sits on the sheet's flat background — so there is nothing here
        // to be concentric with.
        CachedThumb(url: thumbURL, size: CGSize(width: 180, height: 150), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line))
            .accessibilityLabel("Plate \(vm.plateIndex) preview")
    }

    private var mappingColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            monoLabel("FILAMENT MAPPING")
            // Nothing else when there is no AMS to map to. `MacPrintGate` already distinguishes
            // "still connecting" from "connected, no trays" and prints one of them in the notice
            // card below — a second sentence here would be a third answer to the same question, and
            // a less precise one.
            if !trays.isEmpty {
                ForEach(rows) { filamentRow($0) }
                note(mappingSummary)
                if isMultiFilament, (model.printer?.nozzleCount ?? 1) > 1 {
                    note(MacPrintScope.nozzleChoiceNote)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one sentence under the table. It describes what is on screen and nothing else — "both
    /// colours matched" is a claim, and it is only made when the match actually happened.
    private var mappingSummary: String {
        let unmapped = rows.filter { !$0.isMapped }
        if unmapped.isEmpty {
            return usedSlots.count == 1
                ? "Mapped to a spool that is loaded now. Change the tray if that is not the one."
                : "Every filament this plate needs is mapped to a loaded spool."
        }
        if unmapped.count == rows.count {
            return "Pick the AMS tray to print from."
        }
        return "\(unmapped.count) of \(rows.count) filaments still need a tray."
    }

    private func filamentRow(_ row: MacFilamentRow) -> some View {
        // Same reasoning as `notices`: every row is unmapped on the first frame, and the auto-fill
        // has not run yet. Amber before the answer is in is noise, not a warning.
        let attention = row.needsAttention && !loadingPlate
        return HStack(spacing: 10) {
            // The colour the FILE asks for, on the left; the colour that will actually come out, in
            // the chip on the right. Two different facts, so two swatches.
            Swatch(value: FilamentColor.norm(row.want?.color), size: 18, radius: Metrics.swatchRadius(18))

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: wantLine(row))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c.t1)
                    .lineLimit(1)
                if attention {
                    Text(verbatim: remedy(row))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(c.heating)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            trayPicker(row)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.s2))
        .overlay(
            RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous)
                .strokeBorder(attention ? c.heating : c.line)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(row))
    }

    /// What the plate asks for in this slot. Falls back to the slot number alone — "Filament 2" is
    /// still true when the file records nothing about it.
    private func wantLine(_ row: MacFilamentRow) -> String {
        var line = "Filament \(row.slot)"
        if let type = row.want?.type, !type.isEmpty { line += " · \(type)" }
        if let grams = row.want?.usedGrams?.double, grams > 0, grams.isFinite {
            line += String(format: " · %.0f g", grams)
        }
        return line
    }

    /// The amber line, and it names the remedy rather than picking something.
    private func remedy(_ row: MacFilamentRow) -> String {
        if row.candidateCount == 0 {
            let want = [row.want?.type, FilamentColor.name(FilamentColor.norm(row.want?.color))]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " in ")
            return want.isEmpty
                ? "No tray chosen. Pick one."
                : "No loaded spool matches \(want). Load one, or choose a tray anyway."
        }
        return "\(row.candidateCount) loaded spools match. Choose which one."
    }

    private func accessibilityLabel(_ row: MacFilamentRow) -> String {
        let bound = row.tray.map { "mapped to \(trayLabel($0)), \(row.identity?.line ?? "")" }
            ?? "not mapped, \(remedy(row))"
        return "\(wantLine(row)), \(bound)"
    }

    /// Every real tray across every unit — a hardcoded four-row list showed AMS 1 only on a
    /// three-unit machine. Empty trays are listed and disabled rather than hidden, so a slot the user
    /// expects to see is visibly empty instead of missing.
    private func trayPicker(_ row: MacFilamentRow) -> some View {
        Menu {
            ForEach(trays, id: \.globalId) { tray in
                let empty = (tray.trayType ?? "").isEmpty
                Button {
                    trayBySlot[row.slot] = tray.globalId
                } label: {
                    Text(verbatim: "\(trayLabel(tray)) · "
                        + (empty ? "Empty" : FilamentMatch.identity(for: tray, in: assignmentLikes).line))
                }
                .disabled(empty)
            }
        } label: {
            HStack(spacing: 7) {
                Swatch(value: row.identity?.colorHex, size: 13, radius: Metrics.swatchRadius(13), empty: row.tray == nil)
                Text(verbatim: row.tray.map(trayLabel) ?? "Choose…")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(row.tray == nil ? c.t3 : c.t1)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(height: m.controlHeight - 4)
        .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.s3))
        .help(row.identity?.line ?? "Choose the AMS tray this filament prints from")
    }

    // MARK: Plates

    /// Only when there is a choice. A row of chips that look tappable and do nothing is the
    /// offered-but-refused shape again.
    @ViewBuilder
    private var plateChips: some View {
        if vm.plateCount > 1, let list = plates?.plates {
            VStack(alignment: .leading, spacing: 9) {
                monoLabel("PLATE")
                HStack(spacing: 8) {
                    ForEach(list) { plate in
                        plateChip(plate.index, selected: plate.index == vm.plateIndex)
                    }
                }
                note("Only the chosen plate is sent. Its filaments are re-read when you switch.")
            }
        }
    }

    private func plateChip(_ index: Int, selected: Bool) -> some View {
        Button { selectedPlate = index } label: {
            Text(verbatim: "Plate \(index)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(selected ? c.accent : c.t2)
                .padding(.horizontal, 12)
                .frame(height: m.controlHeight - 4)
                .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous)
                    .fill(selected ? c.accentDim : c.s2))
                .overlay(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous)
                    .strokeBorder(selected ? c.accent : c.line))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            monoLabel("PRINT OPTIONS")
            ForEach(MacPrintOption.allCases) { optionRow($0) }
            note(MacPrintScope.optionsReason)
        }
    }

    /// A padlock where the prototype draws a switch. There is no on/off state shown, because this
    /// sheet has not asked the printer what its defaults are — claiming "off" would be a second lie
    /// on top of the first. See `MacPrintScope.optionsReason`.
    private func optionRow(_ option: MacPrintOption) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(c.t3)
                .frame(width: 32, alignment: .leading)
            Text(verbatim: option.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(c.t2)
            Spacer(minLength: 8)
            if let added = option.addedTime {
                Text(verbatim: added)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(c.t3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.s2))
        // Dimmed enough to read as "not a control", light enough that the caption stays legible —
        // the row is still information, not a disabled button.
        .opacity(0.72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(option.label), set on the printer")
        .accessibilityHint(MacPrintScope.optionsReason)
    }

    // MARK: Notices

    /// Suppressed while the first fetch is in flight.
    ///
    /// "Filament 1 has no tray" is TRUE on the first frame of every sheet and false a moment later,
    /// once requirements and the inventory land and the auto-fill runs. Flashing a refusal the sheet
    /// is about to withdraw trains the user to ignore it. Send stays disabled throughout, and the
    /// footer's "Reading the plate…" is the reason for that beat.
    @ViewBuilder
    private var notices: some View {
        if let problem, !loadingPlate {
            noticeCard(
                icon: problem.terminal ? "exclamationmark.triangle" : "info.circle",
                tint: problem.terminal ? c.error : c.heating,
                background: problem.terminal ? c.errorDim : c.heatingDim,
                title: problem.title,
                message: problem.message
            )
        }
    }

    private func noticeCard(
        icon: String,
        tint: Color,
        background: Color,
        title: String,
        message: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(c.t1)
                Text(verbatim: message)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(c.t2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(background))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(verbatim: estimate)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(c.t2)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)

            Button("Cancel") { isPresented = false }
                .buttonStyle(MacSecondaryButtonStyle())
                // ⎋. §7.
                .keyboardShortcut(.cancelAction)

            // The LAN gate keeps the button CLICKABLE when it is the thing blocking — the click is
            // what surfaces the explanation. Every other refusal is already printed above the
            // footer, so those disable it instead of hiding behind a press.
            // The verb comes from the gate, so the button and the notice above it cannot disagree
            // about what the next step is. `.slice` is NOT LAN-gated: slicing happens on the user's
            // own Bambuddy and the printer is never contacted, which is the same reasoning
            // `Lan.isBlocked` already gives for `.plateCleared` and `.queueRemove`. Only the send
            // carries `.startPrint`.
            //
            // Disabled for now, because the slice call itself is the next step — a sliceable file
            // shows the note and a dimmed Slice button rather than a live one that does nothing,
            // which is the failure this codebase keeps rediscovering.
            if problem?.remedy == .slice {
                Button {} label: { Text("Slice…") }
                    .buttonStyle(MacPrimaryButtonStyle())
                    .disabled(true)
                    .help("Slicing on the Mac is not in this build yet.")
            } else {
                Button {
                    locked.press(.startPrint) { start() }()
                } label: {
                    Text(starting ? "Starting…" : "Send to printer")
                }
                .buttonStyle(MacPrimaryButtonStyle())
                .disabled(problem != nil || starting)
                .locked(.startPrint, by: locked)
                // ⏎. Inert while the button is disabled, which is the correct behaviour for a sheet
                // whose reason for refusing is on screen.
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, m.gutter)
        .padding(.vertical, 14)
        .background(c.s1)
        .overlay(alignment: .top) { Rectangle().fill(c.line).frame(height: 1) }
    }

    /// Time and material, and **only what is actually known**.
    ///
    /// There is deliberately no price. The prototype's footer reads "2 h 42 m · 86 g · £0.22 est.",
    /// but nothing in `PlatesResponse` or `FileMetadata` carries a cost — the cost fields this app
    /// has are on finished print-log entries, and CLAUDE.md records that they are null until data
    /// accrues. A number computed from a filament price this app was never given would be a
    /// fabrication in the one place the user is deciding whether to spend material.
    private var estimate: String {
        var parts: [String] = []
        if let seconds = vm.timeSeconds, seconds.isFinite, seconds > 0 {
            parts.append(PlateReview.fmtSeconds(seconds))
        }
        if let grams = vm.grams, grams.isFinite, grams > 0 {
            parts.append(String(format: "%.0f g", grams))
        }
        if parts.isEmpty {
            // Three different silences, and only one of them is a fact about the file. Collapsing
            // them into "no time or material" would state, about a request that never answered, the
            // one thing it could not tell us.
            if loadingPlate { return "Reading the plate…" }
            if plateReadFailed { return "Couldn’t read this plate’s details" }
            return "No time or material recorded for this plate"
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Small pieces

    private func monoLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.mono(m.monoLabel))
            .tracking(1.1)
            .foregroundStyle(c.t3)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(c.t3)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presentingFailure: Binding<Bool> {
        Binding(get: { sendFailure != nil }, set: { if !$0 { sendFailure = nil } })
    }

    // MARK: - Loading

    /// Changes whenever the AMS does, so the auto-fill re-runs against a spool that was just loaded.
    private var loadedKey: String {
        loaded.map { "\($0.slot):\($0.identity.colorHex ?? "")" }.joined(separator: ",")
    }

    /// Plates, slicer metadata and the inventory. All three in flight at once: any of them can fail
    /// on its own and the sheet still renders whatever the others know.
    private func loadFile() async {
        guard let client = model.client else { return }
        loadingPlate = true
        async let platesTask = client.getPlates(file.id)
        async let detailTask = client.getFileDetail(file.id)
        async let assignTask = client.listAssignments(printerId: model.printerId)
        let p = try? await platesTask
        let d = try? await detailTask
        let a = await assignTask
        guard !Task.isCancelled else { return }
        plates = p
        meta = d?.metadata
        assigns = a
        plateReadFailed = p == nil && d == nil
        loadingPlate = false
        applyAutoFill()
    }

    /// Best-effort. A genuine failure leaves `requirements` nil and `usedSlots` at `[1]`; blocking
    /// every print on a network blip would be worse than the gap it guards.
    ///
    /// A CANCELLED request is not a failure and must not be written back — `try?` swallows
    /// `URLError.cancelled` into `nil` and the assignment would still run, clearing a requirement
    /// list that had already said "3 filaments".
    private func loadRequirements() async {
        guard let client = model.client else { return }
        let fetched = try? await client.filamentRequirements(file.id, plate: selectedPlate)
        guard !Task.isCancelled else { return }
        requirements = fetched
    }

    private func applyAutoFill() {
        guard !autoFilled, !loaded.isEmpty else { return }
        MacFilamentMatching.autoFill(
            usedSlots: usedSlots,
            requirement: { requirement(for: $0) },
            loaded: loaded,
            activeTray: status?.trayNow?.int,
            into: &trayBySlot
        )
        autoFilled = true
    }

    // MARK: - Send

    private func start() {
        guard let client = model.client, problem == nil else { return }
        starting = true
        let printerId = model.printerId
        let plate = selectedPlate
        // The wire array's semantics — INDEX is the filament slot, VALUE is the global tray id —
        // live on `AmsMapping.build`, which is pure and tested. A plate whose lone filament is slot
        // 3 gets `[-1, -1, tray]`: index 2 is what addresses slot 3, and a one-element array would
        // bind the tray to a filament this plate never asks for.
        let mapping = AmsMapping.build(usedSlots: usedSlots, trays: trayBySlot)
        Task {
            do {
                // Byte-identical in shape to what `WizardView.start` has always sent and what is
                // proven against this server. Nothing extra rides along — see
                // `MacPrintScope.optionsReason`.
                try await client.enqueue([
                    "printer_id": .int(printerId),
                    "library_file_id": .int(file.id),
                    "use_ams": .bool(true),
                    "ams_mapping": .array(mapping.map { .int($0) }),
                    "plate_id": .int(plate),
                ])
                // The sheet closing IS the confirmation: a failure keeps it open and raises the
                // alert below, so a dismissed sheet can only mean the queue accepted it. But a sheet
                // that merely vanishes leaves the user on the Files grid, looking at the file they
                // just queued, with nothing on screen having changed — so this also LANDS them where
                // the job now is, and says so.
                //
                // This was blocked, and the two things blocking it are both fixed:
                //
                //  - `MacWindow.consumePendingOpen` now CLEARS a `.section` request once it has been
                //    served. It did not, and `onChange` fires on a CHANGE — so the second print of a
                //    session assigned the value already held and navigated nowhere. A jump that
                //    works once is worse than no jump.
                //  - `Toast` has a success kind, drawn with a checkmark. Every toast used to get
                //    `exclamationmark.triangle.fill`, and "Queued for printing" under a warning
                //    triangle reads as a refusal.
                //
                // `model.tab` is still deliberately NOT set: nothing on macOS reads it — the section
                // lives in `MacWindow`'s `@AppStorage` — so that line would compile, run, and be
                // read by nobody.
                model.pendingOpen = .section(.jobs)
                model.toast = .success("Queued for printing — \(LibraryBrowse.displayName(file))")
                isPresented = false
            } catch {
                starting = false
                sendFailure = (error as? BambuddyError)?.detail ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Presentation

extension View {
    /// The one-line hook a file surface needs. Owns the `.sheet` **and** the 640 pt frame, so the
    /// width §1f specifies cannot be forgotten at a call site — a macOS sheet sizes to its content
    /// and collapses to a sliver without it.
    ///
    /// `.sheet(item:)` clears the binding itself on dismissal, so nothing has to remember to nil it.
    func macPrintSheet(_ target: Binding<LibraryFile?>, model: AppModel) -> some View {
        sheet(item: target) { file in
            MacPrintSheet(
                file: file,
                model: model,
                isPresented: Binding(
                    get: { target.wrappedValue != nil },
                    set: { if !$0 { target.wrappedValue = nil } }
                )
            )
            .frame(width: 640)
        }
    }
}
#endif
