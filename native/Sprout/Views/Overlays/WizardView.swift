import SwiftUI

/// The 7-step print wizard: File → Printer → Material → Slicing → Review → Map filament → Start.
///
/// A pre-sliced file skips Material/Slicing/Review entirely (`1, 2, 6, 7`), because re-slicing
/// finished G-code is both pointless and destructive — the counter then reads `1/4`…`4/4`.
///
/// Presented as a full-screen cover, but drawn as a 92 %-height bottom sheet over its own scrim so
/// the nested layer/mesh viewers can cover it WITHOUT unmounting it: every answer the user has given
/// lives in this view's state, and a dismissed-and-recreated wizard would lose all of it.
@MainActor
struct WizardView: View {
    let model: AppModel
    let file: LibraryFile

    @Environment(\.palette) private var c

    // MARK: Flow

    @State private var step = 1
    @State private var starting = false
    @State private var scrimIn = false

    // MARK: Choices

    @State private var nozzle: NozzleSize = .mm04
    /// Latches on the first tap: until then the picker follows whatever is physically mounted.
    @State private var nozzleTouched = false
    @State private var filament: Preset?
    @State private var quality: Preset?
    @State private var supports = false
    @State private var selectedPlate = 1
    @State private var bedType: String
    @State private var slot: Int
    @State private var adv = SliceOverrides()
    @State private var advOpen = false
    @State private var showCatalog = false

    // MARK: Loaded data

    @State private var presets: WizardPresets?
    @State private var presetsError: String?
    @State private var assigns: [SlotAssignment] = []
    /// One-shot latch: the loaded-filament default is applied once, then the user owns the choice.
    @State private var defaulted = false
    @State private var slicedFor: String?
    @State private var slicePct = 0
    @State private var result: SliceResult?

    // MARK: Nested surfaces & alerts

    @State private var viewLayers: LayerTarget?
    @State private var show3D = false
    @State private var alert: WizardAlert?
    @State private var lanAlert = false

    init(model: AppModel, file: LibraryFile) {
        self.model = model
        self.file = file
        // 255 is `tray_now`'s "no active tray" sentinel — seeding the mapping with it would map the
        // print onto a slot that does not exist.
        let trayNow = model.status?.status?.trayNow?.int ?? -1
        _slot = State(initialValue: (0...3).contains(trayNow) ? trayNow : 0)
        _bedType = State(initialValue: PrinterProfile.forPrinter(model.printer).bedTypes[0].id)
    }

    // MARK: - Derived

    private var status: PrinterStatus? { model.status?.status }
    private var profile: PrinterProfile { PrinterProfile.forPrinter(model.printer) }
    /// "@BBL A1" / "@BBL H2C" — the suffix BambuStudio stamps on every preset for this machine.
    private var token: String { profile.presetToken }

    private var alreadySliced: Bool { (file.fileType ?? "").contains("gcode") }
    private var steps: [Int] { alreadySliced ? [1, 2, 6, 7] : [1, 2, 3, 4, 5, 6, 7] }
    private var idx: Int { steps.firstIndex(of: step) ?? 0 }

    /// Every tray across EVERY unit. Reading `status.ams[0].tray` here once made 5 of the 9 slots on
    /// a three-unit machine invisible and unprintable.
    private var trays: [AmsTrayRef] { AmsTopology.trayRefs(status) }
    private var mounted: [NozzleSize] { PresetSelect.mountedNozzles(status) }

    private var loaded: [LoadedFilament] {
        guard let presets else { return [] }
        return FilamentMatch.loaded(
            trays: trays,
            assignments: assigns.map { AssignmentLike($0) },
            presets: presets.allFilaments,
            token: token,
            nozzle: nozzle
        ).filter { !$0.isSupport }
    }

    private var printerMismatch: Bool { alreadySliced && !profile.matchesSlicedFor(slicedFor) }

    private var locked: LockedActions { LockedActions(mode: model.lanMode, explaining: $lanAlert) }

    private func title(_ s: Int) -> String {
        switch s {
        case 1: "File"
        case 2: "Printer"
        case 3: "Material"
        case 4: "Slicing"
        case 5: "Review"
        case 6: "Map filament"
        default: "Start print"
        }
    }

    private func caption(_ s: Int) -> String {
        switch s {
        case 1: "The model you picked"
        case 2: "Confirm the target printer"
        case 3: "Pick filament and quality"
        case 4: "Preparing G-code on your server"
        case 5: "Check time and material"
        case 6: "Choose which AMS tray to print from"
        default: "Review, then send it to the queue"
        }
    }

    private func next() { step = steps[min(idx + 1, steps.count - 1)] }

    private func back() {
        // Review's natural "back" is Material: step 4 is a transient progress screen, and landing on
        // it re-runs the slice with unchanged settings. Skipping it lets the user actually change
        // something before Continue re-slices.
        if step == 5, !alreadySliced { step = 3; return }
        step = steps[max(idx - 1, 0)]
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(scrimIn ? 0.55 : 0)
                card(height: geo.size.height * 0.92, bottomInset: geo.safeAreaInsets.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .presentationBackground(.clear)
        .onAppear { withAnimation(Motion.standard(0.22)) { scrimIn = true } }
        .task(id: nozzle) { await loadPresets() }
        .task { await loadSlicedFor() }
        .task(id: step) { await runSliceStep() }
        .onChange(of: mounted.map(\.rawValue).joined(separator: ","), initial: true) { _, _ in
            if !nozzleTouched, !mounted.isEmpty { nozzle = PresetSelect.defaultNozzle(mounted) }
        }
        .onChange(of: loadedKey, initial: true) { _, _ in applyDefaultFilament() }
        .onChange(of: model.overlay) { _, current in
            // Both nested viewers close themselves by clearing `model.overlay` — correct when the
            // shell presents them, but nested over the wizard it would tear the wizard down too and
            // take every answer the user has given with it. Re-assert the wizard and close only the
            // inner cover.
            guard current == nil, viewLayers != nil || show3D else { return }
            model.overlay = .wizard(file)
            viewLayers = nil
            show3D = false
        }
        .alert(
            alert?.title ?? "",
            isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
            presenting: alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { a in
            Text(a.message)
        }
        .fullScreenCover(item: $viewLayers) { target in
            LayerViewerOverlay(model: model, file: target.file)
        }
        .fullScreenCover(isPresented: $show3D) {
            StlViewerOverlay(model: model, file: file)
        }
    }

    private func card(height: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(c.line2)
                .frame(width: 38, height: 5)
                .padding(.top, 8)

            header
            rail

            ScrollView {
                // Keyed on the step so every transition replays the 300 ms fade+rise.
                FadeRise(dy: 10, duration: 0.3) { stepBody }
                    .id(step)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            footerBar(bottomInset: bottomInset)
        }
        .frame(height: height)
        .background(c.sheet)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 24, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 24, style: .continuous
            )
        )
        .lockedActionAlert($lanAlert)
    }

    // MARK: - Chrome

    // No safe-area padding: this is a bottom sheet at 92 % height, so its top edge already sits
    // below the notch. Adding the top inset pushed the header ~59 pt further down on top of that,
    // leaving a dead band above "Cancel".
    private var header: some View {
        HStack(spacing: 0) {
            // Cancel is the primary escape from a multi-step flow — tinted like a real button, not
            // muted secondary text that reads as disabled.
            Tap { model.overlay = nil } content: {
                Text("Cancel")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(c.accent)
                    .contentShape(.rect)
            }

            VStack(spacing: 2) {
                Text(title(step))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(c.t1)
                Text(caption(step))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(c.t3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            Text("\(idx + 1)/\(steps.count)")
                .font(.mono(12))
                .foregroundStyle(c.t3)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    private var rail: some View {
        HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element) { i, s in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(i <= idx ? c.accent : c.s3)
                        .frame(height: 3)
                    Text(title(s).uppercased())
                        .font(.mono(8.5))
                        .tracking(0.3)
                        .foregroundStyle(i <= idx ? c.accent : c.t3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
    }

    /// Footer button config for the current step. Slicing has none — it is a progress screen with
    /// nothing to confirm.
    private var footer: FooterAction? {
        if step == 4 { return nil }
        if step == 7 {
            return FooterAction(
                label: starting ? "Starting…" : "Start print",
                bg: c.accent, fg: c.accentInk,
                locked: locked.blocked(.startPrint),
                run: locked.press(.startPrint) { start() }
            )
        }
        if step == 5 {
            return FooterAction(label: "Looks good", bg: c.accent, fg: c.accentInk, locked: false) { next() }
        }
        return FooterAction(label: "Continue", bg: c.s3, fg: c.t1, locked: false) { next() }
    }

    @ViewBuilder
    private func footerBar(bottomInset: CGFloat) -> some View {
        if let footer {
            HStack(spacing: 12) {
                if idx > 0, step != 7 {
                    Tap { back() } content: {
                        Text("Back")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(c.t1)
                            .padding(.horizontal, 22)
                            .frame(height: 52)
                            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(c.s3))
                    }
                }
                Tap(disabled: starting, action: footer.run) {
                    HStack(spacing: 8) {
                        if footer.locked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(footer.fg)
                        }
                        Text(footer.label)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(footer.fg)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(footer.bg))
                }
                .opacity(footer.locked ? Lan.lockedOpacity : 1)
            }
            .padding(18)
            .padding(.bottom, bottomInset + 16)
            .overlay(alignment: .top) { Rectangle().fill(c.line).frame(height: 1) }
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case 1: stepFile
        case 2: stepPrinter
        case 3: stepMaterial
        case 4: stepSlicing
        case 5: stepReview
        case 6: stepMapFilament
        default: stepStart
        }
    }

    // MARK: Step 1 — File

    private var stepFile: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("SELECTED FILE")

            Text(displayName)
                .font(.system(size: 19, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(c.t1)
            Text("\(file.fileType ?? "file") · \(alreadySliced ? "pre-sliced" : "will be sliced")")
                .font(.mono(12, weight: .medium))
                .foregroundStyle(c.t3)
                .padding(.top, 5)
                .padding(.bottom, 16)

            if alreadySliced {
                if printerMismatch {
                    NoticeCard(
                        icon: "exclamationmark.triangle",
                        tint: c.error,
                        background: c.errorDim,
                        border: c.error,
                        text: "Sliced for \(slicedFor ?? "another machine") — not for \(model.printer?.name ?? "this printer"). G-code from another machine can crash the toolhead. Reslice the model instead.",
                        textColor: c.t1
                    )
                    .padding(.bottom, 14)
                }
                plateReview(fileId: file.id, sliced: true)
            } else if isStl {
                stlPreview
                // The RN build offers "Texturize first" alongside this; the stl-texturize sidecar
                // has no Swift client yet, so only the viewer is wired up.
                ActionCard(
                    icon: "cube",
                    title: "View in 3D",
                    subtitle: "Inspect the full-resolution mesh — rotate, zoom, switch shading"
                ) { show3D = true }
                .padding(.top, 14)
            } else {
                // Multi-plate projects expose every plate here — only the picked one gets sliced.
                plateReview(fileId: file.id, sliced: false)
            }
        }
    }

    private var isStl: Bool { (file.fileType ?? "").lowercased() == "stl" }

    /// Raw STLs have no slicer plates yet, so a plate review would be an empty grey box.
    private var stlPreview: some View {
        Tap { show3D = true } content: {
            ZStack {
                Color(hex: 0x0A0B0C)
                VStack(spacing: 9) {
                    Image(systemName: "cube")
                        .font(.system(size: 30))
                        .foregroundStyle(c.t3)
                    Text("Tap to inspect the mesh")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(c.t3)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(c.line))
        }
    }

    // MARK: Step 2 — Printer

    private var stepPrinter: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("PRINT ON")
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(c.s3)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "cpu").font(.system(size: 26)).foregroundStyle(c.t2)
                    }
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.printer?.name ?? "Printer")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(c.t1)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status?.connected == true ? c.running : c.idle)
                            .frame(width: 6, height: 6)
                        Text(printerSubtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(c.t2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s2))

            Text("Switch printers from the dashboard header.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(c.t3)
                .padding(.top, 13)
        }
    }

    private var printerSubtitle: String {
        let state = status?.connected == true ? "Connected" : "Offline"
        guard let p = model.printer else { return state }
        let location = (p.location?.isEmpty == false) ? " · \(p.location!)" : ""
        return "\(profile.printerPresetBase)\(location) · \(state)"
    }

    // MARK: Step 3 — Material

    private var stepMaterial: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("NOZZLE")
            HStack(spacing: 9) {
                ForEach(NozzleSize.allCases, id: \.rawValue) { n in
                    nozzleChip(n)
                }
            }
            .padding(.bottom, 6)

            if !mounted.isEmpty, !mounted.contains(nozzle) {
                NoticeCard(
                    icon: "exclamationmark.triangle",
                    tint: c.heating,
                    background: c.heatingDim,
                    border: nil,
                    text: "A \(nozzle.rawValue) mm nozzle isn’t mounted right now (\(mounted.map(\.rawValue).joined(separator: " / ")) mm installed). Slicing works, but swap the nozzle before printing.",
                    textColor: c.t2
                )
                .padding(.bottom, 6)
            }

            Spacer().frame(height: 16)

            if presets == nil {
                loadingRow("Loading slicer presets…")
            } else if let presetsError {
                NoticeCard(
                    icon: "exclamationmark.triangle",
                    tint: c.error,
                    background: c.errorDim,
                    border: c.error,
                    text: presetsError,
                    textColor: c.t1
                )
            } else {
                materialSection
                Spacer().frame(height: 22)
                qualitySection
                Spacer().frame(height: 22)
                bedPlateSection
                Spacer().frame(height: 22)
                supportsSection
                advancedSection
            }
        }
    }

    private func nozzleChip(_ n: NozzleSize) -> some View {
        let on = nozzle == n
        let isMounted = mounted.contains(n)
        return Tap {
            // Stops the picker from snapping back to the hardware default on the next status frame.
            nozzleTouched = true
            nozzle = n
        } content: {
            VStack(spacing: 2) {
                Text(n.rawValue)
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(on ? c.accent : c.t1)
                Text(isMounted ? "mounted" : "mm")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isMounted ? c.running : c.t3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(c.accent, lineWidth: on ? 1.5 : 0)
            }
        }
    }

    @ViewBuilder
    private var materialSection: some View {
        SectionLabel(loaded.isEmpty ? "MATERIAL" : "LOADED IN THE PRINTER")

        if !loaded.isEmpty {
            VStack(spacing: 9) {
                ForEach(loaded) { f in
                    loadedRow(f)
                }
            }
        }

        Tap { showCatalog.toggle() } content: {
            HStack(spacing: 6) {
                Image(systemName: showCatalog || loaded.isEmpty ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(c.t3)
                Text(loaded.isEmpty ? "CHOOSE A FILAMENT" : "OR PICK ANOTHER FILAMENT")
                    .font(.mono(11))
                    .tracking(1)
                    .foregroundStyle(c.t3)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .padding(.top, loaded.isEmpty ? 0 : 14)

        if showCatalog || loaded.isEmpty {
            let catalog = presets?.catalog ?? []
            if catalog.isEmpty {
                Text("No filament profiles for this machine at \(nozzle.rawValue) mm.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c.t3)
                    .padding(.top, 11)
            } else {
                VStack(spacing: 9) {
                    ForEach(catalog) { m in
                        Tap { filament = m } content: {
                            HStack(spacing: 0) {
                                Text(m.name.replacingOccurrences(of: " \(token)", with: ""))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(c.t1)
                                Spacer(minLength: 8)
                                if filament?.id == m.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(c.accent)
                                }
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
                            .overlay {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .stroke(c.accent, lineWidth: filament?.id == m.id ? 1.5 : 0)
                            }
                        }
                    }
                }
                .padding(.top, 11)
            }
        }
    }

    private func loadedRow(_ f: LoadedFilament) -> some View {
        let selected = f.preset != nil && filament?.id == f.preset?.id
        // A vendor colour name beats anything computed; the HSL namer is the fallback.
        let name = f.colorName ?? FilamentColor.name(f.colorHex)
        return Tap(disabled: f.preset == nil) {
            if let p = f.preset {
                filament = p
                slot = f.slot
            }
        } content: {
            HStack(spacing: 13) {
                Swatch(value: f.colorHex, size: 30, radius: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name.map { "\($0) · \(f.material)" } ?? f.material)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(c.t1)
                    Text("Slot \(f.slot + 1)\(f.preset == nil ? " · no matching profile" : "")")
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(c.t3)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(c.accent)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(c.accent, lineWidth: selected ? 1.5 : 0)
            }
            .opacity(f.preset == nil ? 0.5 : 1)
        }
    }

    @ViewBuilder
    private var qualitySection: some View {
        SectionLabel("QUALITY")
        let qualities = presets?.qualities ?? []
        if qualities.isEmpty {
            Text("No quality profiles for \(profile.printerPresetBase) at \(nozzle.rawValue) mm. Pick another nozzle size.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(c.t3)
                .lineSpacing(3)
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)],
                spacing: 9
            ) {
                ForEach(qualities) { q in
                    qualityCard(q)
                }
            }
        }
    }

    /// Splits "0.20mm Standard @BBL A1" into the big "0.20" and its "Standard" label. Word-wise
    /// rather than by regex so a profile that omits the layer height still yields a usable label.
    private func qualityParts(_ name: String) -> (height: String, label: String) {
        var words = name.split(separator: " ").map(String.init)
        var height = ""
        if let i = words.firstIndex(where: { $0.hasSuffix("mm") && ($0.first?.isNumber ?? false) }) {
            height = String(words[i].dropLast(2))
            words.remove(at: i)
        }
        return (height, words.joined(separator: " ").replacingOccurrences(of: " \(token)", with: ""))
    }

    private func qualityCard(_ q: Preset) -> some View {
        let on = quality?.id == q.id
        let (height, label) = qualityParts(q.name)
        return Tap { quality = q } content: {
            VStack(alignment: .leading, spacing: 5) {
                Text(height)
                    .font(.system(size: 19, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(on ? c.accent : c.t1)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c.t2)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(c.accent, lineWidth: on ? 1.5 : 0)
            }
        }
    }

    @ViewBuilder
    private var bedPlateSection: some View {
        SectionLabel("BUILD PLATE")
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)],
            spacing: 9
        ) {
            // `id` is the canonical bed_type the slicer expects; the label is display-only.
            ForEach(profile.bedTypes) { b in
                Tap { bedType = b.id } content: {
                    Text(b.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(bedType == b.id ? c.accent : c.t1)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 14)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(c.accent, lineWidth: bedType == b.id ? 1.5 : 0)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var supportsSection: some View {
        if let q = quality, presets?.supportByBase[q.name] != nil {
            // Slices with the quality's provisioned "+ Supports" twin rather than a flag.
            Tap { supports.toggle() } content: {
                HStack(spacing: 13) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 19))
                        .foregroundStyle(supports ? c.supports : c.t2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Supports")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(supports ? c.supports : c.t1)
                        Text("Tree supports under overhangs. Adds print time + material; shown in amber in the layer view.")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(c.t3)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Capsule()
                        .fill(supports ? c.supports : c.s4)
                        .frame(width: 48, height: 29)
                        .overlay(alignment: supports ? .trailing : .leading) {
                            Circle()
                                .fill(.white)
                                .frame(width: 23, height: 23)
                                .padding(.horizontal, 3)
                        }
                        .animation(Motion.spring(0.24), value: supports)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(c.supports, lineWidth: supports ? 1.5 : 0)
                }
            }
        } else if presets?.hasSupportProfile == false {
            NoticeCard(
                icon: "info.circle",
                tint: c.t3,
                background: c.s2,
                border: nil,
                text: "Supports aren’t set up yet. Run the one-time provisioning on your server (deploy/bambuddy/ensure-support-profiles.py) and a Supports toggle appears here.",
                textColor: c.t3
            )
        }
    }

    /// Per-slice parameter overrides. Hidden entirely without admin credentials so the feature never
    /// dead-ends on a 403 — preset writes are admin-gated server-side.
    @ViewBuilder
    private var advancedSection: some View {
        if model.client?.hasAdminLogin == true {
            Spacer().frame(height: 22)
            HStack(spacing: 8) {
                Tap { advOpen.toggle() } content: {
                    HStack(spacing: 8) {
                        Image(systemName: advOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(c.t3)
                        Text("ADVANCED")
                            .font(.mono(11))
                            .tracking(1)
                            .foregroundStyle(c.t3)
                        if adv.overrideCount > 0 {
                            Text("\(adv.overrideCount) changed")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(c.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.accentDim))
                        }
                    }
                    .contentShape(.rect)
                }
                Spacer(minLength: 0)
                if adv.overrideCount > 0 {
                    Tap { adv = SliceOverrides() } content: {
                        Text("Reset")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(c.accent)
                            .contentShape(.rect)
                    }
                }
            }

            if advOpen {
                VStack(alignment: .leading, spacing: 16) {
                    advRow("WALL LOOPS") {
                        Chips<Double>(options: [(nil, "Preset"), (2, "2"), (3, "3"), (4, "4"), (6, "6")],
                                      selected: adv.wallLoops) { adv.wallLoops = $0 }
                    }
                    advRow("INFILL DENSITY") {
                        Chips<Double>(options: [(nil, "Preset"), (10, "10%"), (15, "15%"), (25, "25%"), (40, "40%"), (100, "100%")],
                                      selected: adv.infillDensity) { adv.infillDensity = $0 }
                    }
                    advRow("INFILL PATTERN") {
                        Chips<String>(options: rawChips(SliceOverrides.infillPatterns),
                                      selected: adv.infillPattern, compact: true) { adv.infillPattern = $0 }
                    }
                    advRow("TOP SURFACE") {
                        Chips<String>(options: rawChips(Array(SliceOverrides.topPatterns.prefix(3))),
                                      selected: adv.topPattern) { adv.topPattern = $0 }
                    }
                    advRow("PRIME TOWER") {
                        Chips<Bool>(options: [(nil, "Preset"), (true, "On"), (false, "Off")],
                                    selected: adv.primeTower) { adv.primeTower = $0 }
                    }
                    advRow("SUPPORT STYLE") {
                        Chips<String>(options: rawChips(SliceOverrides.supportStyles),
                                      selected: adv.supportStyle, compact: true) { adv.supportStyle = $0 }
                    }
                    advRow("SUPPORT ANGLE") {
                        Chips<Double>(options: [(nil, "Preset"), (25, "25°"), (30, "30°"), (40, "40°"), (55, "55°")],
                                      selected: adv.supportAngle) { adv.supportAngle = $0 }
                    }
                    advRow("FLOW RATIO") {
                        Chips<Double>(options: [(nil, "Preset"), (0.95, "0.95"), (0.98, "0.98"), (1.02, "1.02"), (1.05, "1.05")],
                                      selected: adv.flowRatio) { adv.flowRatio = $0 }
                    }
                    Text("“Preset” keeps the profile’s value. Changes apply to this slice via a reusable “Sprout Custom” profile on your server — stock presets are never modified.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(c.t3)
                        .lineSpacing(3)
                }
                .padding(.top, 12)
            }
        }
    }

    private func advRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label)
                .font(.mono(11))
                .tracking(1)
                .foregroundStyle(c.t3)
            content()
        }
    }

    /// "Preset" (= inherit) plus one chip per raw slicer value, which doubles as its own label.
    private func rawChips(_ values: [String]) -> [(String?, String)] {
        [(nil, "Preset")] + values.map { (Optional($0), $0) }
    }

    // MARK: Step 4 — Slicing

    private var stepSlicing: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                RollingNumber(
                    value: slicePct,
                    font: .system(size: 46, weight: .bold),
                    color: c.t1,
                    digitHeight: 54
                )
                Text("%")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(c.t3)
                    .padding(.bottom, 3)
            }
            HeatBar(pct: Double(slicePct), heating: false, color: c.accent, track: c.s3, height: 5)
                .containerRelativeFrame(.horizontal) { width, _ in width * 0.78 }
                .padding(.top, 18)
            Text("Slicing on your server…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(c.t2)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: Step 5 — Review

    private var stepReview: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Reviews the NEWLY produced sliced file when the slice returned one.
            plateReview(fileId: result?.libraryFileId ?? file.id, sliced: true)
            NoticeCard(
                icon: "info.circle",
                tint: c.accent,
                background: c.accentDim,
                border: nil,
                text: "Nothing prints yet. Review the plate, then map filament to a tray.",
                textColor: c.t2
            )
            .padding(.top, 14)
        }
    }

    // MARK: Step 6 — Map filament

    private var stepMapFilament: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("AMS SLOT")
            if trays.isEmpty {
                Text("No AMS trays reported yet. Load filament in the printer, then come back.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c.t3)
                    .lineSpacing(3)
            } else {
                // One row per REAL tray across every unit — a hardcoded four-row list showed AMS 1
                // only on a three-unit machine, and labelled the rows ambiguously.
                let multi = Set(trays.map(\.unitId)).count > 1
                VStack(spacing: 9) {
                    ForEach(trays, id: \.globalId) { t in
                        trayRow(t, multi: multi)
                    }
                }
                Text("Tap a slot to map this print's filament.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c.t3)
                    .padding(.top, 13)
            }
        }
    }

    private func trayRow(_ t: AmsTrayRef, multi: Bool) -> some View {
        let empty = (t.trayType ?? "").isEmpty
        let color = FilamentColor.norm(t.trayColor)
        let position = multi ? "\(t.unitLabel) · Slot \(t.localId + 1)" : "Slot \(t.localId + 1)"
        let contents = empty
            ? "Empty"
            : [FilamentColor.name(color), t.trayType].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return Tap(disabled: empty) { slot = t.globalId } content: {
            HStack(spacing: 13) {
                Swatch(value: color, size: 28, radius: 8, empty: empty)
                Text("\(position) · \(contents)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(c.t1)
                Spacer(minLength: 0)
                if slot == t.globalId {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(c.accent)
                }
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(c.accent, lineWidth: slot == t.globalId ? 1.5 : 0)
            }
            .opacity(empty ? 0.4 : 1)
        }
    }

    // MARK: Step 7 — Start print

    private var stepStart: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("READY TO PRINT")
            VStack(spacing: 0) {
                SummaryRow(key: "File", value: displayName)
                SummaryRow(key: "Printer", value: model.printer?.name ?? "—")
                SummaryRow(key: "Material", value: (filament?.name ?? "As sliced").replacingOccurrences(of: " \(token)", with: ""))
                SummaryRow(key: "Mapped to", value: "Slot \(slot + 1)")
                SummaryRow(key: "Est. time", value: estimatedTime)
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s2))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            NoticeCard(
                icon: "thermometer.medium",
                tint: c.heating,
                background: c.heatingDim,
                border: nil,
                text: "Nozzle and bed heat first (~3 min). You can pause or stop anytime.",
                textColor: c.t2
            )
            .padding(.top, 14)
        }
    }

    private var estimatedTime: String {
        // The finite bound matters: `Int(_:)` traps on NaN/infinity, which a garbage payload can hand
        // us straight from the slice result.
        guard let s = result?.printTimeSeconds, s.isFinite, s > 0, s < 1e12 else { return "—" }
        return "\(Int((s / 60).rounded())) min"
    }

    // MARK: - Shared pieces

    private func plateReview(fileId: Int, sliced: Bool) -> some View {
        WizardPlateReview(
            client: model.client,
            fileId: fileId,
            camToken: model.cameraToken,
            plateIndex: selectedPlate,
            sliced: sliced,
            onSelectPlate: { selectedPlate = $0 },
            onViewLayers: { viewLayers = LayerTarget(file: layerFile(id: fileId)) }
        )
    }

    /// The layer viewer wants a `LibraryFile`; after a slice the G-code lives under a NEW id, so the
    /// original record can't be reused unchanged.
    private func layerFile(id: Int) -> LibraryFile {
        guard id != file.id else { return file }
        return LibraryFile(id: id, filename: file.filename, fileType: "gcode.3mf", printName: file.printName)
    }

    /// Library names arrive percent-encoded; a name that isn't valid encoding stays as-is rather than
    /// collapsing to nothing.
    private var displayName: String {
        let candidates = [file.printName ?? "", file.filename, "file-\(file.id)"]
        let raw = candidates.first { !$0.isEmpty } ?? "file-\(file.id)"
        return raw.removingPercentEncoding ?? raw
    }

    private func SectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.mono(11))
            .tracking(1)
            .foregroundStyle(c.t3)
            .padding(.bottom, 12)
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(c.accent)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(c.t3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    // MARK: - Data loading

    private var loadedKey: String {
        guard presets != nil else { return "" }
        return loaded.map { "\($0.slot):\($0.preset?.id ?? "")" }.joined(separator: ",")
    }

    private func loadPresets() async {
        guard let client = model.client else { return }
        do {
            let data = try await client.getPresets()
            let p = try BambuddyClient.decoder.decode(PresetsResponse.self, from: data)
            let assignments = await client.listAssignments(printerId: model.printerId)
            guard !Task.isCancelled else { return }

            let stock = p.standard?.printer ?? []
            // Exact nozzle variant first; the 0.4 machine preset is the safe fallback because it is
            // the only one every A1/H2 profile set is guaranteed to ship.
            let printerPreset =
                stock.first { $0.name == PresetSelect.printerPresetNameFor(profile.printerPresetBase, nozzle: nozzle) }
                ?? stock.first { $0.name == "\(profile.printerPresetBase) 0.4 nozzle" }
                ?? stock.first { $0.name == profile.printerPresetBase }

            let process = PresetSelect.selectProcess(p, token: token, nozzle: nozzle)
            let allFilaments = p.standard?.filament ?? []

            presets = WizardPresets(
                printer: printerPreset,
                qualities: process.qualities,
                supportByBase: process.supportByBase,
                hasSupportProfile: process.hasSupportProfile,
                catalog: FilamentMatch.catalog(in: allFilaments, token: token, nozzle: nozzle),
                allFilaments: allFilaments
            )
            presetsError = nil
            assigns = assignments
            quality = PresetSelect.pickDefaultQuality(process.qualities)
        } catch {
            guard !Task.isCancelled else { return }
            presets = WizardPresets()
            presetsError = "Couldn’t load slicer presets — \(errorText(error))"
        }
    }

    /// Pre-sliced files carry the target machine inside the 3MF; reading it is what catches
    /// wrong-printer G-code before it reaches the toolhead.
    private func loadSlicedFor() async {
        guard alreadySliced, let client = model.client else { return }
        guard let plates = try? await client.getPlates(file.id) else { return }
        slicedFor = plates.embeddedPrinter ?? file.slicedForModel
    }

    private func applyDefaultFilament() {
        guard !defaulted, let presets else { return }
        // `slot` is the GLOBAL tray id, the same space `tray_now` speaks.
        let active = loaded.first { $0.slot == (status?.trayNow?.int ?? -1) && $0.preset != nil }
            ?? loaded.first { $0.preset != nil }
        if let active, let preset = active.preset {
            filament = preset
            slot = active.slot
            defaulted = true
        } else if !trays.isEmpty, let first = presets.catalog.first {
            filament = first
            defaulted = true
        }
    }

    // MARK: - Slicing

    private func runSliceStep() async {
        guard step == 4, let client = model.client else { return }

        if alreadySliced {
            // Nothing to slice — hold a beat so the step doesn't flash past, then move on.
            result = SliceResult(
                printTimeSeconds: file.printTimeSeconds?.double,
                filamentUsedG: file.filamentUsedGrams?.double,
                libraryFileId: file.id
            )
            slicePct = 100
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            step = 5
            return
        }

        slicePct = 5
        do {
            // Supports ON -> slice with the quality's "+ Supports" twin profile.
            let processPreset = (supports ? quality.flatMap { presets?.supportByBase[$0.name] } : nil) ?? quality

            var processRef = processPreset.map { presetRef($0) }
            var filamentRef = filament.map { presetRef($0) }

            // Advanced overrides ride an ephemeral LOCAL preset that inherits the chosen profile and
            // carries only the changed keys, so stock presets are never touched.
            if client.hasAdminLogin, let processPreset, adv.hasProcessOverrides,
               let setting = adv.processDelta(inheriting: processPreset.name, presetName: "Sprout Custom \(token)") {
                let id = try await client.upsertLocalPreset(
                    name: "Sprout Custom \(token)", presetType: "process", setting: setting
                )
                processRef = .object(["source": .string("local"), "id": .string(String(id))])
            }
            if client.hasAdminLogin, let filament, adv.hasFilamentOverrides {
                // H2-series filament keys are per-(extruder, variant) arrays of length 3; a
                // single-extruder machine takes one element.
                let variants = (model.printer?.nozzleCount ?? 1) > 1 ? 3 : 1
                if let setting = adv.filamentDelta(
                    inheriting: filament.name,
                    presetName: "Sprout Custom Filament \(token)",
                    variants: variants
                ) {
                    let id = try await client.upsertLocalPreset(
                        name: "Sprout Custom Filament \(token)", presetType: "filament", setting: setting
                    )
                    filamentRef = .object(["source": .string("local"), "id": .string(String(id))])
                }
            }

            var body: [String: JSONValue] = [
                "plate": .int(selectedPlate),
                "bed_type": .string(bedType),
                "export_3mf": .bool(true),
            ]
            if let p = presets?.printer { body["printer_preset"] = presetRef(p) }
            if let processRef { body["process_preset"] = processRef }
            if let filamentRef { body["filament_preset"] = filamentRef }

            let jobId = try await client.slice(file.id, body: body)

            // Bounded by wall clock (90 × 1.5 s ≈ 135 s) rather than by a job state we might never
            // see. Leaving step 4 cancels this task; the SERVER job deliberately keeps running.
            for _ in 0..<90 {
                try Task.checkCancellation()
                let job = try await client.getSliceJob(jobId)
                slicePct = min(95, slicePct + 6)   // the server reports no usable progress
                if job.status == "completed" {
                    result = SliceResult(
                        printTimeSeconds: job.printTimeSeconds?.double,
                        filamentUsedG: job.filamentUsedG?.double,
                        libraryFileId: job.libraryFileId
                    )
                    slicePct = 100
                    step = 5
                    return
                }
                if job.status == "failed" || job.status == "error" {
                    throw SproutError(job.errorMessage ?? "Slice failed")
                }
                try await Task.sleep(for: .milliseconds(1500))
            }
            throw SproutError("Slice timed out")
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            // Land back on Material, never on a dead progress screen.
            alert = WizardAlert(title: "Slicing failed", message: errorText(error))
            step = 3
        }
    }

    private func presetRef(_ p: Preset) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(p.id), "name": .string(p.name)]
        if let source = p.source { o["source"] = .string(source) }
        return .object(o)
    }

    // MARK: - Start

    private func start() {
        guard let client = model.client else { return }
        if printerMismatch {
            alert = WizardAlert(
                title: "Wrong printer",
                message: "This file was sliced for \(slicedFor ?? "another machine"). Reslice it for \(model.printer?.name ?? "this printer") before printing."
            )
            return
        }
        guard trays.contains(where: { $0.globalId == slot && !($0.trayType ?? "").isEmpty }) else {
            alert = WizardAlert(title: "Pick a slot", message: "Choose which AMS slot to print from first.")
            return
        }
        starting = true
        let libraryFileId = result?.libraryFileId ?? file.id
        let printerId = model.printerId
        let plate = selectedPlate
        let mappedSlot = slot
        Task {
            do {
                // `ams_mapping` is Bambu's own print-command field: indexed by FILAMENT, valued by
                // GLOBAL tray id (Bambuddy decodes it as gid >= 254 -> external, >= 128 -> HT, else
                // gid/4 + gid%4). Index and value swapped debits the wrong spool and cannot address
                // anything past the first unit at all.
                try await client.enqueue([
                    "printer_id": .int(printerId),
                    "library_file_id": .int(libraryFileId),
                    "use_ams": .bool(true),
                    "ams_mapping": .array([.int(mappedSlot)]),
                    "plate_id": .int(plate),
                ])
                model.overlay = nil
                model.tab = .printer
            } catch {
                starting = false
                alert = WizardAlert(title: "Couldn’t start", message: errorText(error))
            }
        }
    }

    private func errorText(_ error: Error) -> String {
        if let e = error as? BambuddyError { return e.detail }
        return error.localizedDescription
    }
}

// MARK: - Local value types

/// What the presets request produced, flattened for the view.
private struct WizardPresets {
    var printer: Preset?
    var qualities: [Preset] = []
    var supportByBase: [String: Preset] = [:]
    /// Tri-state: nil when the presets request failed, so the "supports aren't provisioned" card
    /// isn't shown for what is really a network error.
    var hasSupportProfile: Bool?
    var catalog: [Preset] = []
    var allFilaments: [Preset] = []
}

/// What the wizard carries forward from the slice — including the NEW library file id, which is what
/// actually gets enqueued.
private struct SliceResult {
    var printTimeSeconds: Double?
    var filamentUsedG: Double?
    var libraryFileId: Int?
}

private struct FooterAction {
    let label: String
    let bg: Color
    let fg: Color
    let locked: Bool
    let run: () -> Void
}

private struct WizardAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct LayerTarget: Identifiable {
    let file: LibraryFile
    var id: Int { file.id }
}

// MARK: - Small components

/// Key/value line in the step-7 summary.
private struct SummaryRow: View {
    let key: String
    let value: String
    @Environment(\.palette) private var c

    var body: some View {
        HStack {
            Text(key)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(c.t2)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.t1)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .trailing)
        }
        .padding(14)
        .overlay(alignment: .bottom) { Rectangle().fill(c.line).frame(height: 1) }
    }
}

/// Icon + body-text card. Every warning/info block in the wizard is one of these.
private struct NoticeCard: View {
    let icon: String
    let tint: Color
    let background: Color
    let border: Color?
    let text: String
    let textColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(textColor)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(background))
        .overlay {
            if let border {
                RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(border)
            }
        }
    }
}

/// Tappable row with a tinted icon tile, a title and a subtitle.
private struct ActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @Environment(\.palette) private var c

    var body: some View {
        Tap(action: action) {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(c.accentDim)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: icon).font(.system(size: 17)).foregroundStyle(c.accent)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(c.t1)
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(c.t3)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(c.t3)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
        }
    }
}

/// A wrapping row of single-select chips. `nil` is a real option here — it is the "Preset" chip,
/// meaning "inherit whatever the profile says".
private struct Chips<Value: Hashable>: View {
    let options: [(Value?, String)]
    let selected: Value?
    var compact: Bool = false
    let onSelect: (Value?) -> Void

    @Environment(\.palette) private var c

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let on = option.0 == selected
                Tap { onSelect(option.0) } content: {
                    Text(option.1)
                        .font(.system(size: compact ? 12 : 12.5, weight: .semibold))
                        .foregroundStyle(on ? c.accent : c.t2)
                        .padding(.horizontal, compact ? 12 : 13)
                        .frame(height: compact ? 32 : 34)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? c.accentDim : c.s2))
                }
            }
        }
    }
}

/// Left-to-right flow that wraps — the layout every `flexWrap: 'wrap'` row in the design needs, and
/// which no stock SwiftUI container provides.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : max(0, x - spacing), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Plate review

/// The sliced-model summary the wizard shows on File and Review: plate picker, thumbnail, the three
/// stat tiles, the detail line and the filament list.
///
/// Two endpoints describe the same file and neither is complete on its own, so both are fetched and
/// merged by `PlateReview.build` — and either may fail without the block being useless.
private struct WizardPlateReview: View {
    let client: BambuddyClient?
    let fileId: Int
    let camToken: String?
    let plateIndex: Int
    var sliced: Bool = true
    var onSelectPlate: ((Int) -> Void)?
    var onViewLayers: (() -> Void)?

    @Environment(\.palette) private var c

    @State private var plates: PlatesResponse?
    @State private var meta: FileMetadata?
    @State private var loading = true
    @State private var failed = false

    private var vm: PlateReviewVM { PlateReview.build(plates: plates, meta: meta, plateIndex: plateIndex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.plateCount > 1, let list = plates?.plates {
                FlowLayout(spacing: 8) {
                    ForEach(list) { p in
                        plateChip(p.index, selected: p.index == vm.plateIndex)
                    }
                }
                .padding(.bottom, 14)
            }

            thumbnail

            if sliced {
                HStack(spacing: 10) {
                    PStat(label: "PRINT TIME", value: PlateReview.fmtSeconds(vm.timeSeconds), sub: nil)
                    PStat(
                        label: "LAYERS",
                        value: vm.layers.map { String($0) } ?? "—",
                        sub: vm.layerHeight.map { String(format: "%.2f mm/layer", $0) }
                    )
                    PStat(
                        label: "FILAMENT",
                        value: vm.grams.map { String(format: "%.1f g", $0) } ?? "—",
                        sub: nil
                    )
                }
                .padding(.top, 14)
            } else if vm.plateCount > 1 {
                Text("This file has \(vm.plateCount) plates. Pick the one to print — only it gets sliced. Time and material are estimated after slicing.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c.t3)
                    .lineSpacing(3)
                    .padding(.top, 13)
            }

            if !detailLine.isEmpty {
                Text(detailLine)
                    .font(.mono(11.5, weight: .medium))
                    .foregroundStyle(c.t3)
                    .padding(.top, 12)
            }

            if failed, !loading {
                Text("Couldn’t read this file's plate details. Time and material may be missing.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c.t3)
                    .padding(.top, 12)
            }

            if !vm.filaments.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(vm.filaments.enumerated()), id: \.offset) { i, f in
                        filamentRow(f, first: i == 0)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 14)
            }

            if !settingsLine.isEmpty {
                Text(settingsLine)
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(c.t3)
                    .padding(.top, 12)
            }
        }
        .task(id: fileId) { await load() }
    }

    private var detailLine: String {
        [
            vm.heightMm.map { "\(trimmed($0)) mm tall" },
            vm.nozzleTemp.map { "\($0)°C nozzle" },
            vm.bedType,
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "  ·  ")
    }

    private var settingsLine: String {
        [vm.printer, vm.process].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    /// "184" rather than "184.0", but never through `Int(_:)` on an out-of-range Double — that traps.
    private func trimmed(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e9 ? String(Int(d)) : String(format: "%.2f", d)
    }

    private func plateChip(_ index: Int, selected: Bool) -> some View {
        Tap { onSelectPlate?(index) } content: {
            Text("Plate \(index)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? c.accent : c.t2)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? c.accentDim : c.s2))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(c.accent, lineWidth: selected ? 1.5 : 0)
                }
        }
    }

    /// Plate thumbnails are gated by the camera STREAM token in `?token=`, not by `X-API-Key` — the
    /// header path answers 401 here.
    private var thumbURL: URL? {
        guard let client, plates?.plates.first(where: { $0.index == vm.plateIndex })?.hasThumbnail == true else {
            return nil
        }
        return client.plateThumbUrl(fileId, plateIndex: vm.plateIndex, token: camToken)
    }

    private var thumbnail: some View {
        ZStack {
            c.thumb
            if let url = thumbURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        Image(systemName: "cube").font(.system(size: 30)).foregroundStyle(c.t3)
                    default:
                        ProgressView().tint(c.t3)
                    }
                }
            } else if loading {
                ProgressView().tint(c.t3)
            } else {
                Image(systemName: "cube").font(.system(size: 30)).foregroundStyle(c.t3)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(c.line))
        .overlay(alignment: .bottomTrailing) {
            if let onViewLayers, !loading {
                Tap(action: onViewLayers) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 12))
                            .foregroundStyle(c.accent)
                        Text("View layers")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0x0A0B0C, opacity: 0.72)))
                }
                .padding(10)
            }
        }
    }

    private func filamentRow(_ f: ReviewFilament, first: Bool) -> some View {
        HStack(spacing: 12) {
            Swatch(value: FilamentColor.norm(f.color), size: 22, radius: 7)
            Text(f.type)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.t1)
            Spacer(minLength: 8)
            Text(usage(f))
                .font(.mono(12, weight: .medium))
                .foregroundStyle(c.t3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(c.line).frame(height: 1) }
        }
    }

    private func usage(_ f: ReviewFilament) -> String {
        var out = f.grams.map { String(format: "%.1f g", $0) } ?? ""
        if let m = f.meters { out += "  ·  " + String(format: "%.2f m", m) }
        return out
    }

    private func load() async {
        guard let client else { return }
        loading = true
        failed = false
        // Both in flight at once: either can fail on its own and the block still renders whatever
        // the other one knows.
        async let platesTask = client.getPlates(fileId)
        async let detailTask = client.getFileDetail(fileId)
        let p = try? await platesTask
        let d = try? await detailTask
        guard !Task.isCancelled else { return }
        plates = p
        meta = d?.metadata
        failed = p == nil && d == nil
        loading = false
    }
}

/// One of the three stat tiles under the plate thumbnail.
private struct PStat: View {
    let label: String
    let value: String
    let sub: String?
    @Environment(\.palette) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.mono(9))
                .tracking(0.8)
                .foregroundStyle(c.t3)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: 19, weight: .bold))
                .monospacedDigit()
                .tracking(-0.5)
                .foregroundStyle(c.t1)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 7)
            if let sub {
                Text(sub)
                    .font(.mono(10.5, weight: .medium))
                    .foregroundStyle(c.t3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
    }
}
