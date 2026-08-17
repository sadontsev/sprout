#if os(macOS)
import SwiftUI

/// §4 Files, inspector column (prototype lines 553–583).
///
/// The selected file and nothing else: preview, identity, what the slicer baked in, then the actions
/// that are a long-press menu on iOS. It holds no navigation of its own — the section next door owns
/// which file is selected, and this reads it back out of `@SceneStorage` (see `MacFilesSelection`
/// for why the selection lives there rather than in either view's `@State`).
///
/// Resolving the id against the store on every render is also the selection-reconciliation rule for
/// free: a file that has been deleted, filtered away by a printer switch, or lost to a failed reload
/// simply stops resolving, and the panel says so instead of showing a stale card.
struct MacFilesInspector: View {
    let model: AppModel
    /// Does this instance bring its own `ScrollView`?
    ///
    /// True in the inspector column, which is its own scrolling region. False when the panes fall
    /// back INTO the section (`MacInspectorPlacement`), because the section already scrolls and
    /// nesting one scroll view in another gives an ambiguous height and two scrollbars.
    ///
    /// A parameter rather than a computed `panes` property read from outside, because a SwiftUI
    /// view's `@State` and `@Environment` are only established once it is installed in the
    /// hierarchy — reading `SomeInspector(model:).panes` from another view would evaluate those
    /// wrappers before SwiftUI has set them up.
    var scrolls = true


    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m
    @Environment(\.openWindow) private var openWindow

    @SceneStorage(MacFilesSelection.library) private var selectedId: Int?
    @SceneStorage(MacFilesSelection.printer) private var selectedSdPath: String?

    /// The inspector raises its own delete confirmation because it cannot reach the section's — the
    /// two views are siblings. The COPY is shared through `MacFilesDelete`, so the two prompts
    /// cannot drift into describing the same irreversible action differently.
    @State private var confirmingDelete = false
    @State private var confirmingSdDelete = false
    @State private var lanAlert = false

    /// The selected SD file's first plate, when it has one.
    ///
    /// Fetched here rather than held on the store because it belongs to the SELECTION, not to the
    /// listing: it is re-asked whenever the panel shows a different path, and it is best-effort — a
    /// file the printer cannot describe still has to render its name, size and buttons.
    @State private var plate: PlateInfo?

    /// How wide this panel actually is, which decides whether the SD detail stacks or sits side by
    /// side. Measured rather than inferred from the section, because the panel has two homes of very
    /// different proportions and only it knows which one it is in — see
    /// `MacInspectorPlacement.detailIsHorizontal`.
    @State private var panelWidth: CGFloat = 280

    private var store: LibraryStore { model.library }
    private var locked: LockedActions { LockedActions(mode: model.lanMode, explaining: $lanAlert) }

    private var selected: LibraryFile? {
        guard let selectedId else { return nil }
        return store.files?.first { $0.id == selectedId }
    }

    private var selectedSd: PrinterFile? {
        guard let selectedSdPath else { return nil }
        return store.printerList?.files.first { $0.path == selectedSdPath }
    }

    var body: some View {
        MacInspectorScroll(scrolls: scrolls) {
            Group {
                if store.source == .printer {
                    if let pf = selectedSd { printerDetail(pf) } else { placeholder }
                } else if let f = selected {
                    libraryDetail(f)
                } else {
                    placeholder
                }
            }
            .padding(m.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(c.bg)
        .lockedActionAlert($lanAlert)
        .alert(MacFilesDelete.libraryTitle, isPresented: $confirmingDelete, presenting: selected) { f in
            Button("Delete", role: .destructive) {
                // Drop the selection before the request goes out, so this panel does not sit on a
                // file that is being removed underneath it.
                selectedId = nil
                Task { await store.deleteLibrary(f) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { f in
            Text(verbatim: MacFilesDelete.libraryMessage(MacFileBrowse.displayName(f)))
        }
        .alert(MacFilesDelete.printerTitle, isPresented: $confirmingSdDelete, presenting: selectedSd) { pf in
            Button("Delete", role: .destructive) {
                selectedSdPath = nil
                Task { await store.deleteSd(pf) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pf in
            Text(verbatim: MacFilesDelete.printerMessage(pf.name))
        }
    }

    // MARK: - Nothing selected

    @ViewBuilder
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: placeholderTitle)
                .font(.system(size: m.cardTitle, weight: .semibold))
                .foregroundStyle(c.t1)
            Text(verbatim: placeholderMessage)
                .font(.system(size: m.body))
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .macInspectorPlaceholder()
    }

    /// A selection that no longer resolves is a different situation from never having selected
    /// anything, and saying "Select a file" to someone whose file has just been deleted is the kind
    /// of near-miss answer this codebase keeps paying for.
    private var placeholderTitle: String {
        if store.source == .printer {
            return selectedSdPath == nil ? "No file selected" : "That file is gone"
        }
        if selectedId == nil { return "No file selected" }
        return store.files == nil ? "Loading…" : "That file is gone"
    }

    private var placeholderMessage: String {
        if store.source == .printer {
            return selectedSdPath == nil
                // "…and remove it" was accurate when Delete was the only thing this panel could do.
                // It now plays recordings, scrubs layers and downloads, so the sentence would be
                // describing a smaller app than the one on screen.
                ? "Pick a file on the printer’s storage to preview it, play it, or download it."
                : "It is no longer in this folder on the printer."
        }
        if selectedId == nil {
            return "Pick a file to see its preview, what the slicer baked into it, and what you can do with it."
        }
        return store.files == nil
            ? "Waiting for the library listing."
            : "It is no longer in the library."
    }

    // MARK: - A library file

    @ViewBuilder
    private func libraryDetail(_ f: LibraryFile) -> some View {
        VStack(alignment: .leading, spacing: m.cardGap) {
            preview(f)
            identity(f)
            statsCard(f)
            actions(f)
        }
    }

    /// The plate preview.
    ///
    /// The prototype captions this "PLATE 1 OF 1". That caption is **not drawn**: the plate count
    /// comes from `/plates`, which nothing here has fetched, and the file's own thumbnail is one
    /// image whether the 3MF holds one plate or six. Captioning it with the file type says something
    /// true about the picture that is actually on screen.
    private func preview(_ f: LibraryFile) -> some View {
        CachedThumb(url: thumbUrl(f), aspect: 4.0 / 3.0)
            // The clip goes on the composite: a `.fill` image is flexible, so a `clipShape` placed
            // inside the overlay clips nothing.
            .clipShape(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line)
            )
            .overlay(alignment: .bottom) {
                Text(verbatim: (f.fileType ?? "file").uppercased())
                    .font(.mono(m.monoLabel, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(c.t3)
                    .padding(.bottom, 8)
            }
    }

    /// Name and the one-line identity beneath it.
    ///
    /// The prototype's "· added 11 Aug" is absent because there is nothing to put there:
    /// `LibraryFile` carries no timestamp on the listing OR on the per-file detail record. Inventing
    /// one from the id would be a guess wearing a date's clothes.
    private func identity(_ f: LibraryFile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: MacFileBrowse.displayName(f))
                .font(.system(size: m.cardTitle, weight: .semibold))
                .foregroundStyle(c.t1)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: identityLine(f))
                .font(.mono(11, weight: .medium))
                .foregroundStyle(c.t3)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func identityLine(_ f: LibraryFile) -> String {
        var parts = [(f.fileType ?? "file").uppercased()]
        let size = MacFileBrowse.bytes(f.fileSize?.double)
        if !size.isEmpty { parts.append(size) }
        // `slicedForModel` names the machine a file was PREPARED for. It is a label, not a
        // capability — a plain project .3mf carries one and holds no toolpaths at all — so it is
        // shown here and gates nothing.
        if let machine = f.slicedForModel, !machine.isEmpty { parts.append("for \(machine)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Slicer stats

    /// What the slicer baked into the file.
    ///
    /// Print time and filament weight come off the LISTING. Layer height and per-slot materials live
    /// in `LibraryFile.metadata`, which Bambuddy only populates on `GET /library/files/{id}` — the
    /// detail record. Nothing in this pass fetches that (a view may not make network calls, and
    /// `LibraryStore` is not a file this pass owns), so those two rows are drawn **only when the
    /// data is actually present**, rather than showing "0.20 mm" derived from nothing or an empty
    /// swatch row that reads as "no materials".
    ///
    /// Which line explains the absence is `statsNote`'s job, and it is a genuinely different question
    /// per file — see the note there.
    private func statsCard(_ f: LibraryFile) -> some View {
        let slots = f.metadata?.filamentSlots ?? []
        let layer = f.metadata?.layerHeight?.double
        let hasLayer = (layer ?? 0) > 0
        return VStack(alignment: .leading, spacing: 9) {
            statRow("Print time", printTime(f))
            statRow("Filament", filamentWeight(f))

            if hasLayer, let layer {
                statRow("Layer height", String(format: "%.2f mm", layer))
            }
            if !slots.isEmpty { materialsRow(slots) }

            Divider().overlay(c.line)

            Text(verbatim: Self.statsNote(f, slots: slots, hasLayer: hasLayer))
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(m.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line))
    }

    private func materialsRow(_ slots: [FileMetadata.FilamentSlot]) -> some View {
        HStack(spacing: 0) {
            Text("Materials")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Indexed rather than by value: two slots of the same colour are a real and ordinary
            // thing, and identifying swatches by their contents would collapse them.
            HStack(spacing: 5) {
                ForEach(slots.indices, id: \.self) { i in
                    Swatch(value: FilamentColor.norm(slots[i].color), size: 14, radius: Metrics.swatchRadius(14))
                }
            }
        }
    }

    /// The sentence under the divider — and the three questions that used to share one predicate.
    ///
    /// It was `slots.isEmpty ? missingMetadataNote : slotMappingNote`. **`slots.isEmpty` answers "do
    /// we have a slot list in hand?", while the note it selected asserts "the library listing doesn't
    /// carry it" — a claim about *fetching*.** Two different questions, and the gap between them is
    /// where the wrong answers lived:
    ///
    /// - A `.stl` has no slicer metadata to fetch, ever. Telling that user the data is merely
    ///   un-fetched is a promise nothing can keep: `LibraryStore` gaining the per-file detail fetch
    ///   would not add a single row to an STL's card.
    /// - And once that fetch does land, a file with a layer height but no slots would have drawn the
    ///   Layer-height row *and*, directly underneath it, the note saying layer height isn't carried.
    ///
    /// So the questions are separated and each is named for itself: `carriesSlicerMetadata` is "could
    /// this file type have any?", `f.metadata == nil` is "has the detail record been read?", and the
    /// slot/layer values are "is anything actually on screen?".
    private static func statsNote(
        _ f: LibraryFile,
        slots: [FileMetadata.FilamentSlot],
        hasLayer: Bool
    ) -> String {
        // Swatches are on screen; the only thing left to say is what happens to them at print time.
        if !slots.isEmpty { return slotMappingNote }
        // A layer height came back, so the detail record HAS been read — it simply lists no slots.
        if hasLayer { return noSlotsNote }
        if !carriesSlicerMetadata(f) { return noSlicerMetadataNote }
        if f.metadata == nil { return metadataNotFetchedNote }
        return metadataEmptyNote
    }

    /// **"Could this file carry slicer metadata at all?"**
    ///
    /// Deliberately not spelled `isStl` at the call site even though an STL is today's only answer of
    /// no, and deliberately not `isSliced`: a plain project `.3mf` is not sliced and still carries a
    /// layer height and a filament list, so `isSliced` would answer a third, nearby question. An STL
    /// is a bare triangle mesh — no slicer ever wrote into it and none ever will.
    ///
    /// TODO: this belongs beside `isSliced`/`hasGcode`/`isStl` in `Domain/LibraryFileCaps.swift`,
    /// which is not a file this pass owns. Two copies of a capability predicate is the exact
    /// mechanism CLAUDE.md records for `hasGcode` and `isSliced` drifting apart.
    private static func carriesSlicerMetadata(_ f: LibraryFile) -> Bool {
        !LibraryFileCaps.isStl(f)
    }

    /// The prototype's second sentence — "Both materials are loaded" — is deliberately dropped. That
    /// is a claim about what is in the AMS right now, and nothing on this panel has checked.
    private static let slotMappingNote =
        "Slot mapping is checked against the AMS when you print."

    /// The detail record has been read and lists no slots — so this is a fact about the FILE, not
    /// about what has been fetched.
    private static let noSlotsNote =
        "This file’s slicer metadata lists no per-slot materials."

    /// Nothing will ever fill these rows in for this file, so it does not promise that anything might.
    private static let noSlicerMetadataNote =
        "An STL is a bare mesh: there is no layer height and no material list inside it. Those appear once a file has been through a slicer."

    /// The one case the old single note was right about: the data exists, this listing just doesn't
    /// carry it.
    private static let metadataNotFetchedNote =
        "Layer height and per-slot materials are in this file’s slicer metadata, which the library listing doesn’t carry."

    private static let metadataEmptyNote =
        "This file’s slicer metadata carries no layer height and no material list."

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value)
                .font(.mono(11.5, weight: .medium))
                .foregroundStyle(c.t1)
                .monospacedDigit()
        }
    }

    /// `Dash.fmtDuration` takes minutes and already answers "—" for a missing or nonsensical value,
    /// so there is no second opinion about what an absent estimate looks like.
    private func printTime(_ f: LibraryFile) -> String {
        guard let seconds = f.printTimeSeconds?.double else { return "—" }
        return Dash.fmtDuration(seconds / 60)
    }

    private func filamentWeight(_ f: LibraryFile) -> String {
        guard let grams = f.filamentUsedGrams?.double, grams > 0, grams.isFinite else { return "—" }
        return String(format: "%.0f g", grams)
    }

    // MARK: Actions

    private func actions(_ f: LibraryFile) -> some View {
        let printBlocked = MacFilesPrint.unavailableReason
        let canViewModel = LibraryFileCaps.isStl(f)
        // `hasGcode`, NOT `isSliced`. `isSliced` answers "was this prepared by a slicer?" — a plain
        // project .3mf carries a `slicedForModel` and no toolpaths at all, and asking for its layers
        // returns 404. This is the exact predicate CLAUDE.md's recurring-bug table names.
        let canViewLayers = LibraryFileCaps.hasGcode(f)

        return VStack(alignment: .leading, spacing: 7) {
            Button {
                guard printBlocked == nil else { return }
        // Opening the sheet is NOT printing, so it is not gated on `.startPrint`.
        //
        // It was, and that made Mac slicing unreachable on the machine it was built for. With LAN
        // Developer Mode off the printer refuses `.startPrint`, `locked.press` therefore intercepted
        // this click and raised "Printer controls are locked" — and `MacFilesPrint.start` never ran,
        // so the sheet never opened, so the Slice button inside it could never be pressed. Slicing
        // runs on Bambuddy and needs no permission from the printer at all; the thing that DOES need
        // it is Send, which the sheet gates itself and correctly.
        //
        // The recurring bug, one step further out than usual: not a control gated on a nearby
        // capability, but a DOOR gated on what lies beyond it.
                MacFilesPrint.start(f, model: model)
            } label: {
                // Named for what the sheet will OFFER, so the route to slicing is visible from here.
                // A project file's next step is a slice, and calling that button "Print…" is how the
                // whole feature stayed hidden even once the door was open.
                Text(SliceCapability.canSlice(f) && !LibraryFileCaps.hasGcode(f) ? "Slice…" : "Print…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MacPrimaryButtonStyle())
            .disabled(printBlocked != nil)

            HStack(spacing: 7) {
                Button { openViewer(f, mode: .model) } label: {
                    Text("View in 3D").frame(maxWidth: .infinity)
                }
                .buttonStyle(MacSecondaryButtonStyle())
                .disabled(!canViewModel)
                .help(canViewModel ? "Open the mesh viewer" : Self.noMeshNote)

                Button { openViewer(f, mode: .layers) } label: {
                    Text("View layers").frame(maxWidth: .infinity)
                }
                .buttonStyle(MacSecondaryButtonStyle())
                .disabled(!canViewLayers)
                .help(canViewLayers ? "Scrub this file layer by layer" : Self.noLayersNote)
            }

            HStack(spacing: 7) {
                Button { Task { await share(f) } } label: {
                    Text("Share…").frame(maxWidth: .infinity)
                }
                .buttonStyle(MacSecondaryButtonStyle())
                .disabled(store.downloadBusy)

                Button { confirmingDelete = true } label: {
                    Text("Delete").frame(maxWidth: .infinity)
                }
                .buttonStyle(MacSecondaryButtonStyle(role: .destructive))
            }

            // A dimmed control that explains itself beats a live-looking one that fails. The tooltips
            // above are for the mouse; these lines are for everyone else.
            reason(printBlocked)
            reason(canViewModel ? nil : Self.noMeshNote)
            reason(canViewLayers ? nil : Self.noLayersNote)
        }
    }

    private static let noMeshNote =
        "View in 3D reads STL meshes. A .3mf is a zip container it can’t open."
    private static let noLayersNote =
        "View layers needs toolpaths, and only a sliced .gcode.3mf has them."

    @ViewBuilder
    private func reason(_ text: String?) -> some View {
        if let text {
            Text(verbatim: text)
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - A file on the printer's SD card

    /// The panel for an entry on the printer's own storage.
    ///
    /// It used to be a name, a size, a path and one Delete button, under a sentence ending
    /// *"Deleting is the only action available here."* That sentence was true of the panel and false
    /// of the printer: the card serves a plate render, a poster JPEG, the file's bytes and the G-code
    /// of a sliced print, and iOS had been using all four for as long as the SD browser existed.
    ///
    /// So the panel now mirrors the library's — preview, identity, stats, action row, reasons — and
    /// the reasons that remain are the two that are actually true. See `SdFileCaps`.
    private func printerDetail(_ pf: PrinterFile) -> some View {
        Group {
            if MacInspectorPlacement.detailIsHorizontal(width: panelWidth), !pf.isDirectory {
                // The drawer: wide and short. Preview on the left, everything else beside it.
                HStack(alignment: .top, spacing: m.cardGap) {
                    sdPreview(pf)
                    VStack(alignment: .leading, spacing: m.cardGap) {
                        sdIdentity(pf)
                        sdPathCard(pf)
                        sdActions(pf)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // The column: narrow and tall, and the shape the library panel next door uses.
                VStack(alignment: .leading, spacing: m.cardGap) {
                    if !pf.isDirectory { sdPreview(pf) }
                    sdIdentity(pf)
                    sdPathCard(pf)
                    if pf.isDirectory {
                        reason("Double-click in the list to open this folder.")
                    } else {
                        sdActions(pf)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelWidth = $0 }
        // Only a sliced 3MF has plates to describe, and the fetch is best-effort: a file the printer
        // cannot describe still has to show its name, size and buttons. Keyed on the path so
        // selecting a different entry re-asks rather than keeping the previous file's numbers.
        .task(id: pf.path) {
            plate = nil
            guard SdFileCaps.canViewLayers(pf), let client = model.client else { return }
            plate = try? await client.getPrinterFilePlates(model.printerId, path: pf.path).plates.first
        }
    }

    private func sdIdentity(_ pf: PrinterFile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: plate?.name ?? SdFileCaps.displayName(pf))
                .font(.system(size: m.cardTitle, weight: .semibold))
                .foregroundStyle(c.t1)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: sdMeta(pf))
                .font(.mono(11, weight: .medium))
                .foregroundStyle(c.t3)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sdPathCard(_ pf: PrinterFile) -> some View {
        Text(verbatim: pf.path)
            .font(.mono(11))
            .foregroundStyle(c.t2)
            .lineLimit(2)
            .truncationMode(.head)
            .fixedSize(horizontal: false, vertical: true)
            .padding(m.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line))
    }

    /// The plate render for a sliced file, the printer's poster for a recording, a glyph otherwise.
    ///
    /// Headers, not a token: the printer's images are `X-API-Key` gated and the bare URL 401s, which
    /// is the exact inverse of the library thumbnails a few lines up.
    @ViewBuilder
    private func sdPreview(_ pf: PrinterFile) -> some View {
        let shape = RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
        Group {
            switch SdFileCaps.preview(pf) {
            case .plate:
                CachedThumb(url: model.client?.printerPlateThumbUrl(model.printerId, path: pf.path),
                            aspect: 1, contentMode: .fit,
                            headers: model.client?.authHeaders() ?? [:],
                            fallbackSymbol: SdFileCaps.symbol(pf))
            case .poster(let path):
                CachedThumb(url: model.client?.printerFileDownloadUrl(model.printerId, path: path),
                            aspect: 16.0 / 9.0,
                            headers: model.client?.authHeaders() ?? [:],
                            fallbackSymbol: SdFileCaps.symbol(pf))
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .offset(x: 1)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
            case .glyph:
                Rectangle()
                    .fill(c.thumb)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: SdFileCaps.symbol(pf))
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(c.t3)
                    }
            }
        }
        // Capped, unlike the library's preview above, because this panel has two homes and they are
        // very different widths. In the inspector COLUMN (236–320 pt) the cap never binds. In the
        // bottom DRAWER the panel is as wide as the window, and an unconstrained square plate render
        // became a ~1400 pt image that pushed every action below the fold of a 320 pt drawer — the
        // buttons were reachable only by scrolling, which for the panel whose whole point is those
        // buttons is the same as not having them.
        .frame(maxWidth: 280, alignment: .leading)
        // On the composite, never inside the overlay — an overlay is not clipped to its base, and a
        // `.fill` image is flexible enough to escape one.
        .clipShape(shape)
        .overlay(shape.strokeBorder(c.line))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Size, plus whatever the plates endpoint could tell us.
    ///
    /// Print time and weight only — the same two iOS shows.
    ///
    /// `PlateInfo.filaments` **is** populated here, and that is measured rather than assumed: a real
    /// `/printers/2/files/plates?path=/02_basket.gcode.3mf` answers
    /// `filaments: [{slot_id: 1, type: "PETG", color: "#000000", used_grams: 82.8}]` alongside
    /// `print_time_seconds: 13967`. So drawing a materials row is now a question of design rather than
    /// of evidence, and it is deliberately not drawn yet: this panel is one line of monospace, and
    /// naming a material next to a colour swatch is the surface that produced the wizard's brown spool
    /// labelled "Orange". Whatever shows filament here should read inventory, not just this record.
    private func sdMeta(_ pf: PrinterFile) -> String {
        if pf.isDirectory { return "Folder" }
        var parts = [MacFileBrowse.bytes(pf.size?.double)]
        if let seconds = plate?.printTimeSeconds?.double, seconds > 0 {
            parts.append(Dash.fmtDuration(seconds / 60))
        }
        if let grams = plate?.filamentUsedGrams?.double, grams > 0 {
            parts.append("\(Int(grams.rounded())) g")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    /// The action row, in the library panel's order so the two panels read as one design.
    ///
    /// Play and View layers are mutually exclusive in practice — an `.mp4` is never a `.gcode.3mf` —
    /// so the headline row is one button wide, and Share/Delete pair underneath exactly as they do for
    /// a library file.
    @ViewBuilder
    private func sdActions(_ pf: PrinterFile) -> some View {
        VStack(spacing: 7) {
            if SdFileCaps.canPlay(pf) {
                Button { MacVideoWindow.open(pf, printerId: model.printerId, using: openWindow) } label: {
                    Text("Play").frame(maxWidth: .infinity)
                }
                .buttonStyle(MacPrimaryButtonStyle())
            }
            if SdFileCaps.canViewLayers(pf) {
                Button { MacViewer.open(sd: pf, printerId: model.printerId, using: openWindow) } label: {
                    Text("View layers").frame(maxWidth: .infinity)
                }
                .buttonStyle(MacPrimaryButtonStyle())
            }

            HStack(spacing: 7) {
                Button { Task { await shareSd(pf) } } label: {
                    Text("Share…").frame(maxWidth: .infinity)
                }
                .buttonStyle(MacSecondaryButtonStyle())
                .disabled(store.downloadBusy)

                Button { confirmingSdDelete = true } label: {
                    Text("Delete").frame(maxWidth: .infinity)
                }
                .buttonStyle(MacSecondaryButtonStyle(role: .destructive))
            }

            // The two things that genuinely cannot be done, said plainly and separately. They are
            // separate because they are refused for different reasons, and the single sentence that
            // used to bundle them ("printing and layer preview work on library files") was half true
            // — which is worse than either half alone, because it taught the reader to disbelieve the
            // accurate part too.
            reason(SdFileCaps.noPrintNote)
            reason(SdFileCaps.canViewLayers(pf) || SdFileCaps.canPlay(pf) ? nil : SdFileCaps.noLayersNote)
        }
    }

    /// Shares a file off the printer's storage. Same re-entrancy guard as the library's `share`, and
    /// for the same reason: two downloads race on the store's single `shareItem`.
    private func shareSd(_ pf: PrinterFile) async {
        guard !store.downloadBusy else { return }
        await store.shareSd(pf)
    }

    // MARK: - Plumbing

    /// Layers and meshes are meant to be ONE window with a segment (§5.4), keyed by file — so this
    /// should open or refocus it. `AppModel.overlay` is the iOS presentation mechanism and is inert
    /// on macOS, so a window is still the right shape.
    ///
    /// **It does not refocus yet, and the comment that said it did was describing the intention.**
    /// `openWindow(id:value:)` reuses a window only when the VALUE compares equal, and
    /// `MacViewerRequest` synthesises `Hashable` over `fileId`, `name` *and* `mode` — so tapping
    /// "View in 3D" and then "View layers" on one file opens two windows. The value answers two
    /// questions, "which window is this?" (the file) and "which segment does it open on?" (the mode),
    /// and only the first may take part in identity. Same defect, same wording, in
    /// `MacFilesSection.openViewer`.
    ///
    /// TODO(1g): hand-write `Hashable`/`Equatable` on `MacViewerRequest` keyed on `fileId` alone,
    /// carrying `mode` as the opening segment. `Windows/MacViewerWindow.swift` is not a file this
    /// pass owns.
    private func openViewer(_ f: LibraryFile, mode: MacViewerRequest.Mode) {
        // `MacViewer.open`, not a raw `openWindow`. `MacViewerRequest` hashes on `fileId` ALONE, so
        // that "View in 3D" then "View layers" reuses one window instead of opening two — but equal
        // values also mean SwiftUI delivers no new `mode`, so the second click would merely raise the
        // window. `MacViewer.open` carries the mode through `MacViewerRoute` alongside, which is the
        // only path that makes the segment actually change.
        MacViewer.open(f, mode: mode, using: openWindow)
    }

    /// `LibraryStore.share` carries no re-entrancy guard of its own, and two shares in flight race on
    /// the single `shareItem` — the sheet can end up pointing at the other file's local copy. The
    /// button above is already `.disabled(store.downloadBusy)`; this is the same rule stated where a
    /// future caller cannot forget it.
    ///
    /// TODO(LibraryStore): this belongs on the store, which owns `downloadBusy`. That file is not
    /// owned by this pass, and `MacFilesSection.share` carries the identical guard for the same
    /// reason.
    private func share(_ f: LibraryFile) async {
        guard !store.downloadBusy else { return }
        await store.share(f, cacheName: MacFileBrowse.safeShareName(MacFileBrowse.displayName(f)))
    }

    private func thumbUrl(_ f: LibraryFile) -> URL? {
        // Token in the query, never `X-API-Key` — the thumbnail endpoint 401s on the header.
        model.client?.fileThumbUrl(f.id, token: model.cameraToken, thumbnailPath: f.thumbnailPath)
    }
}
#endif
