#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The **Printer** inspector (§4, prototype `1a` lines 508–551): camera tile → triage card → the
/// current job's facts → recent prints.
///
/// **The camera leaves the content column.** That is the single biggest change from iOS, and it is
/// the inspector's rule made concrete: content is the thing, and the inspector is what is LIVE about
/// it. Nothing here navigates except the triage card's one deliberate hand-off to Hardware, which is
/// the card's entire purpose.
///
/// Everything is derived from `DashVM` and the app's stores. Nothing here fetches: the archive cards
/// read `model.jobs`, whose poll `MacSectionContent` owns for the whole Printer section, and Snapshot
/// saves the frame the tile has already decoded rather than asking the server for another.
struct MacPrinterInspector: View {
    let model: AppModel

    /// Spelled out because `selection` below is a `private` stored property with a default, which
    /// makes the synthesised memberwise initialiser private too — `MacInspectorContent` builds this
    /// view with only `model`.
    init(model: AppModel) {
        self.model = model
    }

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m
    @Environment(\.openWindow) private var openWindow

    /// Where the triage card's hand-off writes. See `MacSectionSelection` — a bare `@FocusedValue`
    /// reads nil the instant the camera window this inspector just opened becomes key.
    private var selection = MacSectionSelection()

    @State private var cam = CameraStreamModel()
    @State private var latchedFps: Int?
    /// Whether the tile's renderer has a frame stashed. See `saveSnapshot`.
    @State private var tileHasFrame = false

    private var vm: DashVM { model.vm }
    private var status: PrinterStatus? { model.status?.status }
    private var caption: CGFloat { MacPrinterType.caption(m) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: m.cardGap) {
                header
                cameraBlock
                triageCard
                jobCard
                recentCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .background(c.bg)
        .onChange(of: selection.ownsFocus, initial: true) { _, _ in selection.latch() }
    }

    private var header: some View {
        HStack {
            MacPrinterMonoLabel("PRINTER")
            Spacer(minLength: 0)
            Text(verbatim: "⌥⌘I")
                .font(.mono(m.monoLabel + 1, weight: .medium))
                .foregroundStyle(c.t3)
        }
        .padding(.bottom, 2)
    }

    // MARK: - Camera

    /// The states that can produce a picture at all. Deliberately not `vm.kind != .offline`: a
    /// printer that is still connecting has no camera either, and a tile that sits on "WAKING…"
    /// forever is the lie this list prevents.
    private var cameraPossible: Bool {
        MacPrinterCopy.cameraPossible(kind: vm.kind, isDemo: model.isDemo)
    }

    /// **The window wins** (§5.2). Bambuddy runs ONE ffmpeg per printer and fixes its rate from
    /// whichever viewer created it (`CameraUpstreamClaim`), so a tile that kept streaming behind the
    /// camera window would hand that window its own rate and pay for two HTTP streams to get one
    /// picture. `MacCameraOwnership` is the arbiter; this is the only question the tile may ask it.
    private var tileActive: Bool {
        cameraPossible && model.cameraOwnership.inspectorMayStream(printerId: model.printerId)
    }

    /// True when the live picture has moved to the camera window rather than simply stopping.
    ///
    /// `MacCameraOwnership` tracks windows that are **streaming**, not windows that are open — a
    /// paused camera window releases the claim, because "a window exists" and "a window is using the
    /// camera" are two questions and only the second one collides with this tile. So this is exact:
    /// while it is true, the live picture genuinely is in the window.
    ///
    /// The distinction is the whole point of the badge: the tile keeps its last decoded frame, and
    /// "PAUSED" over a still image invites a click on Retry that would take the claim back.
    private var claimedByWindow: Bool {
        cameraPossible && !model.cameraOwnership.inspectorMayStream(printerId: model.printerId)
    }

    /// The rate the next connection will ask for — nil until `NWPathMonitor` reports, because the
    /// number goes INTO the URL and a guess corrected a moment later restarts the stream.
    private var pathFps: Int? {
        let path = model.networkPath
        guard path.resolved else { return nil }
        return CameraRate.tile(isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    private var streamURL: URL? {
        guard let client = model.client, let token = model.cameraToken, let fps = latchedFps else { return nil }
        return client.streamUrl(model.printerId, token: token, fps: fps)
    }

    /// Fills an EMPTY latch only. Never overwriting a live one is the whole point: a changed URL is a
    /// dropped socket, and the tile is usually the camera's only viewer, so it also pays the
    /// printer's cold start again.
    private func latchFpsIfIdle() {
        guard tileActive, latchedFps == nil else { return }
        latchedFps = pathFps
    }

    @ViewBuilder
    private var cameraBlock: some View {
        if model.isDemo {
            // Named for what it is rather than dressed up as a feed that is about to arrive.
            note(icon: "video.slash",
                 text: "The chamber camera streams from the printer, so it isn’t part of the demo.")
        } else if !cameraPossible {
            note(icon: "video.slash",
                 text: vm.kind == .connecting
                     ? "The camera appears once the printer answers."
                     : "The camera needs the printer online.")
        } else if model.cameraToken == nil {
            // The stream and every thumbnail are gated by a camera STREAM token in `?token=`, not by
            // the API key. Without one there is nothing to show, and saying so beats a black tile.
            note(icon: "key.slash",
                 text: "Waiting for a camera token from the server.")
        } else {
            cameraTile
        }
    }

    private var cameraTile: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                c.thumb
                if let url = streamURL {
                    // `holdLastFrameWhenInactive` is what makes `PLAYING IN WINDOW` true. Without
                    // it, going inactive runs `renderer.stop()` → `flushAndRemoveImage()`, and the
                    // badge promising "the last frame the tile decoded" sat over a black rectangle.
                    CameraStreamView(
                        url: url,
                        active: tileActive,
                        model: cam,
                        holdLastFrameWhenInactive: true
                    )
                }

                HStack(spacing: 5) {
                    if tileActive && cam.isLive {
                        PulseDot(color: c.error, size: 5, period: 2.0)
                    } else {
                        Circle().fill(c.t3).frame(width: 5, height: 5)
                    }
                    Text(MacPrinterCopy.cameraBadge(
                        claimedByWindow: claimedByWindow,
                        tileActive: tileActive,
                        isLive: cam.isLive,
                        fps: latchedFps
                    ))
                        .font(.mono(m.monoLabel, weight: .semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.72)))
                .padding(10)
                .help(claimedByWindow
                      ? "The camera window has the live stream. This is the last frame the tile decoded."
                      : "The chamber camera, at the rate this window asked for.")

                MacPrinterMonoLabel("CHAMBER CAM")
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)

            HStack(spacing: 8) {
                // `WindowGroup(id:"camera", for: Int.self)` is keyed by printer, so this re-fronts an
                // already-open window rather than stacking a second one — the action is the same
                // either way. Only the LABEL branches, and on a claim that is a sufficient condition
                // for the window existing: while the window is streaming, "Show window" is exact;
                // otherwise the window may be closed or merely paused, and "Open in window" is true
                // of both because opening one that exists just fronts it.
                tileButton(claimedByWindow ? "Show window" : "Open in window",
                           help: "The chamber camera in its own window (⌘0)") {
                    openWindow(id: "camera", value: model.printerId)
                }
                // Gated on the EXACT capability: a decoded frame in the renderer's stash. Not on
                // `cam.isLive` — the tile deliberately holds its last frame while the camera window
                // owns the stream, and that frame is perfectly saveable — and not on a camera token,
                // which was the gate when this fetched `/camera/snapshot` over HTTP.
                tileButton(
                    "Snapshot",
                    enabled: tileHasFrame,
                    help: tileHasFrame
                        ? "Save the frame on screen"
                        : "Nothing has been decoded yet — the frame appears a few seconds after the camera wakes.",
                    action: saveSnapshot
                )
                Spacer(minLength: 0)
                Text(verbatim: "⌘0")
                    .font(.mono(m.monoLabel + 0.5, weight: .medium))
                    .foregroundStyle(c.t3)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
        }
        .background(c.s1)
        .clipShape(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.line))
        // A fresh mount is a fresh `CameraNSView`, hence a fresh `CameraRenderer` with an empty
        // stash. Tracking it here rather than reading `frameStash.latest()` in the body: the stash
        // is lock-guarded plain state, not `@Observable`, so a view that read it would never
        // re-render when the first frame landed and the button would stay dimmed over a live picture.
        .onAppear { tileHasFrame = false }
        .onChange(of: cam.isLive) { _, live in if live { tileHasFrame = true } }
        // A cold camera takes seconds to produce a frame and the badge must not claim LIVE over a
        // blank tile. Clearing the flag is the load-bearing half: the renderer only ever sets
        // `isLive` true, so this reset is what lets the NEXT connection's first frame register.
        .onChange(of: streamURL) { _, _ in cam.isLive = false }
        // Take the rate when streaming starts, so a path update can never rewrite the URL of a live
        // connection. `initial: true` because NWPathMonitor's first callback routinely lands AFTER
        // the tile is already active, leaving the latch empty with nothing else due to fill it.
        .onChange(of: tileActive, initial: true) { _, active in
            cam.isLive = false
            if active { latchFpsIfIdle() }
        }
        .onChange(of: pathFps, initial: true) { _, _ in latchFpsIfIdle() }
        // The latch is deliberately NOT released when the camera window takes the claim: clearing it
        // nils `streamURL`, which unmounts the host view and takes the last decoded frame with it —
        // and the last frame under `PLAYING IN WINDOW` is the whole of §5.2's fallback. Releasing it
        // here is safe because the tile has already been replaced by a note, so there is no frame
        // left to lose and the path is worth re-reading.
        .onChange(of: cameraPossible) { _, possible in
            if !possible { latchedFps = nil }
        }
    }

    /// `enabled` dims as well as disabling. `.buttonStyle(.plain)` draws nothing of its own, so a
    /// `.disabled` chip is pixel-identical to a live one — a control that looks pressable and is not
    /// is the exact failure this codebase keeps re-learning.
    ///
    /// `MacDim.unavailable`, not `Lan.lockedOpacity`: nothing here is refused by the printer, and the
    /// LAN dim is documented as the one treatment for that specific fact.
    private func tileButton(
        _ title: String,
        enabled: Bool = true,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: caption, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: m.minControlHeight)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.s3))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : MacDim.unavailable)
        .help(help)
    }

    /// Save the frame that is on screen.
    ///
    /// The renderer's stash, not a `/camera/snapshot` fetch, and that is a correctness change rather
    /// than a shortcut. The snapshot endpoint only produces a fresh frame while the camera is
    /// actually streaming; cold, it replays the last cached frame forever with no way to tell
    /// (`DashboardView` carries the same note, which is why the tile streams instead of polling
    /// stills). So the HTTP version could hand back a *different* picture from the one the user was
    /// looking at, and a stale one at that. It is also the second implementation of a feature
    /// `MacCameraWindow.saveFrame` already had, with its own gate, its own file extension and its
    /// own failure copy.
    ///
    /// The bytes are written straight through: `frameStash` holds the compressed JPEG, so there is
    /// no decode and no re-encode, and `.jpg` is what the file actually is.
    ///
    /// Failures go to `model.toast`, which `MacRoot` renders. A modal alert for "there is no frame
    /// yet" would be the heavier of two answers to the smaller of two problems.
    private func saveSnapshot() {
        guard let jpeg = cam.renderer?.frameStash.latest() else {
            // Reachable despite the button's gate: the stream can be torn down between the render
            // that enabled it and the click.
            model.toast = .failure("There's no frame to save yet.")
            return
        }
        let panel = NSSavePanel()
        // A fixed pattern, not a locale style: this is a FILENAME, and a locale that formats a date
        // with slashes writes path separators into it.
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        panel.nameFieldStringValue =
            "\(model.printer?.name ?? "printer") \(stampFormatter.string(from: Date())).jpg"
        panel.allowedContentTypes = [.jpeg]

        // `beginSheetModal`/`begin`, never `runModal()`. This is main-actor code, and a modal session
        // holds the main actor's executor for as long as the panel is open — the status store, the
        // poll loops and every other `@MainActor` hop stall behind a file dialog nobody has answered.
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try jpeg.write(to: url)
            } catch {
                model.toast = .failure("Couldn’t save the snapshot — \(error.localizedDescription)")
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    // MARK: - Triage

    /// What the printer is complaining about right now.
    private var alerts: [AlertVM] {
        Alerts.present(
            status,
            caps: AlertCaps(connected: vm.kind != .offline, canControl: true, model: model.printer?.model)
        )
    }

    /// What the machine's hardware wants doing. `HardwareStore` already holds the maintenance load,
    /// and `maintenanceItems` is `[]` while it is loading or after a failure — the card counts
    /// problems it can prove, so an unknown state reads as "nothing to say", never "nothing wrong".
    /// Through `MacHardwareTriage`, the one the Hardware section uses — NOT a second call to
    /// `HardwareTriage.items` with its own arguments.
    ///
    /// This built its own, answering `nozzlesKnown` with `!(status?.nozzles ?? []).isEmpty`. That
    /// misses the H2's nozzle RACK, where the machine reports its nozzles somewhere else entirely —
    /// so this card could say the nozzles were unknown about a printer that had just reported them,
    /// while the Hardware section one click away said the opposite. Two callers, two answers, one
    /// question.
    private var triage: [HardwareTriage.Item] {
        MacHardwareTriage.items(model, dash: vm)
    }

    /// The iOS dashboard's maintenance chip AND its alert chip, merged into the one card §4 puts
    /// here — but NOT merged into one count. "2 alerts" and "2 things need you" are answers to
    /// different questions, and adding them would produce a number nothing on screen can explain.
    @ViewBuilder
    private var triageCard: some View {
        let alertList = alerts
        let items = triage
        let headline = HardwareTriage.headline(items)

        if !alertList.isEmpty || headline != nil {
            let tone = MacPrinterCopy.triageTone(alertList)
            // `Palette`'s own dim tokens, not `tint.opacity(0.10)`. The `*Dim` colours are tuned per
            // scheme — light mode does not use dark mode's alphas — so a computed opacity is a
            // different colour from the one every other tinted card on the platform draws, including
            // the section's own `lanBanner` six inches to the left.
            MacPrinterCard(padding: 13, fill: tone.dim(c), stroke: tone.solid(c)) {
                VStack(alignment: .leading, spacing: 9) {
                    // Up to three, then a count. A 320 pt column that lists nine HMS notices is a
                    // wall nobody reads.
                    ForEach(alertList.prefix(3)) { alertRow($0) }
                    if alertList.count > 3 {
                        Text(verbatim: "+ \(alertList.count - 3) more")
                            .font(.system(size: caption, weight: .medium))
                            .foregroundStyle(c.t3)
                    }

                    if let headline {
                        if !alertList.isEmpty { Divider().overlay(c.line) }
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Circle().fill(c.heating).frame(width: 7, height: 7)
                                Text(headline)
                                    .font(.system(size: m.cardTitle, weight: .semibold))
                                    .foregroundStyle(c.t1)
                            }
                            Text(verbatim: HardwareTriage.detail(items))
                                .font(.system(size: caption))
                                .foregroundStyle(c.t2)
                                .fixedSize(horizontal: false, vertical: true)
                            MacSectionLink(
                                title: "Open Hardware",
                                canNavigate: selection.canNavigate
                            ) {
                                // Land on the segment that raised the loudest item, exactly as the
                                // iOS chip does — the same `HardwareTriage.Segment` the store's
                                // selection uses, so there is no mapping to disagree with.
                                if let first = items.first { model.hardware.segment = first.segment }
                                selection.go(to: .ams)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Display only. The actions an `AlertVM` carries (resume, stop, plate cleared) are all offered by
    /// the hero card six inches to the left — including "Plate cleared", which is now shown whenever
    /// the plate needs confirming rather than only on a `.complete` machine, so this card can no
    /// longer state that the queue is blocked with nothing on screen able to unblock it. `.lookup`
    /// needs a browser hand-off that belongs to a dedicated alerts surface, which macOS does not have
    /// yet; a button here that did nothing would be worse than the sentence it replaced.
    private func alertRow(_ alert: AlertVM) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Per-ALERT level, not the card's tint: the card is coloured by the worst one, and a
            // warning sitting under an error must not borrow the error's red.
            Circle()
                .fill(MacPrinterCopy.alertTone(alert.level).solid(c))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(alert.title)
                        .font(.system(size: m.cardTitle, weight: .semibold))
                        .foregroundStyle(c.t1)
                    if let code = alert.code {
                        Text(code)
                            .font(.mono(m.monoLabel, weight: .medium))
                            .foregroundStyle(c.t3)
                            .textSelection(.enabled)   // the code is what you paste into a search
                    }
                }
                Text(alert.detail)
                    .font(.system(size: caption))
                    .foregroundStyle(c.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - This job

    /// One label/value line. `mono` marks the ticking and measured values, which take tabular figures
    /// so the column stops jittering once a second.
    private struct Fact: Identifiable {
        let label: String
        let value: String
        var mono = false
        var id: String { label }
    }

    /// This printer's archive rows, and whether the server named a printer on any of them.
    private var archive: (rows: [PrintLogEntry], unattributed: Bool) {
        MacPrinterCopy.printerArchive(model.jobs.entries, printerId: model.printerId)
    }

    /// The archive row behind what is on screen.
    ///
    /// While a print runs, `currentArchiveId` names it exactly — and an exact id needs no attribution
    /// filter, because it came from THIS printer's own status. Otherwise fall back to the newest row
    /// this printer ran, which is what "LAST JOB" means.
    private var jobEntry: PrintLogEntry? {
        if let hit = namedJobEntry { return hit }
        return archive.rows.first
    }

    /// The row `currentArchiveId` names outright, if it is loaded. Separate because a NAMED row needs
    /// no attribution — it came from this printer's own status — while a picked one does.
    private var namedJobEntry: PrintLogEntry? {
        guard let archiveId = vm.reprintArchiveId else { return nil }
        return (model.jobs.entries ?? []).first { $0.archiveId == archiveId }
    }

    /// True when the row on the job card was PICKED rather than named, out of an archive that records
    /// no printer at all — so "LAST JOB" is the server's last job, not provably this machine's.
    private var jobEntryUnattributed: Bool {
        archive.unattributed && namedJobEntry == nil && jobEntry != nil
    }

    private var jobCard: some View {
        let live = vm.kind == .live
        let facts = live ? liveFacts : finishedFacts
        // Four states, not two. `JobsStore.loadHistory` answers a failed fetch with `entries = []`
        // plus `historyFailed`, so "the archive didn't load" and "an archive with nothing in it" are
        // the SAME value — and rendering the failure as "Nothing has been printed on this machine
        // yet" turned a transport error into a confident claim about the machine's whole history.
        let empty = MacPrinterCopy.archiveEmpty(
            entries: model.jobs.entries,
            failed: model.jobs.historyFailed,
            matched: jobEntry != nil
        )
        return MacPrinterCard(padding: 13) {
            VStack(alignment: .leading, spacing: 11) {
                MacPrinterMonoLabel(live ? "THIS JOB" : "LAST JOB")
                if facts.isEmpty, let empty {
                    Text(empty)
                        .font(.system(size: caption))
                        .foregroundStyle(c.t3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(facts) { factRow($0) }
                    }
                    if jobEntryUnattributed {
                        unattributedNote("The archive doesn’t record which printer ran this.")
                    }
                }
            }
        }
    }

    /// Said, not silently assumed. `MacPrinterCopy.printerArchive` falls back to the whole archive
    /// when the server names no printer on any row, because hiding every print would be its own lie —
    /// but those rows are then not KNOWN to be this machine's, and neither card may imply they are.
    private func unattributedNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: caption))
            .foregroundStyle(c.t3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func factRow(_ fact: Fact) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(fact.label)
                .font(.system(size: caption, weight: .medium))
                .foregroundStyle(c.t3)
            Spacer(minLength: 8)
            Text(fact.value)
                .font(fact.mono ? .mono(caption, weight: .medium)
                                : .system(size: caption, weight: .medium))
                .foregroundStyle(c.t1)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// What is knowable about a RUNNING print, and nothing else.
    ///
    /// The prototype lists "Filament used" and "Energy so far"; neither exists mid-print. The status
    /// payload carries no gram count, and `PlugPoller.kwh` is the plug's total for TODAY, not this
    /// job's — labelling it "Energy so far" would be a number that is wrong by however much else ran
    /// today.
    ///
    /// **"Power now" is not here either, and that is the fix rather than an omission.** `if let watts`
    /// answers "has the plug ever reported", not "is it reporting now" — two questions, and only the
    /// second one entitles a row to the word *now*. `MacSectionContent` runs `PowerStore` only while
    /// the Power section is on screen, and `PowerStore.stop()` cancels the pollers without clearing
    /// `hero.watts`, so one visit to Power left this printing that frozen reading, labelled "now",
    /// for the rest of the session. Nothing on the Printer section is entitled to a live wattage
    /// until `PowerStore` can say whether a reading is current; the Power section, one click away,
    /// polls it properly.
    private var liveFacts: [Fact] {
        var out: [Fact] = []
        if let started = startedAt {
            out.append(Fact(label: "Started", value: Dash.fmtClock(started), mono: true))
            let minutes = Date().timeIntervalSince(started) / 60
            if minutes > 0 {
                out.append(Fact(label: "Elapsed", value: Dash.fmtDuration(minutes), mono: true))
            }
        }
        if vm.totalLayers != "0" {
            out.append(Fact(label: "Layer", value: "\(vm.layer) / \(vm.totalLayers)", mono: true))
        }
        out.append(Fact(label: "Time left", value: vm.etaText, mono: true))
        out.append(Fact(label: "Done", value: vm.doneText, mono: true))
        out.append(Fact(label: "Speed", value: vm.speedLabel))
        if let active = vm.ams.first(where: { $0.active }) {
            out.append(Fact(label: "Filament", value: "\(active.label) · \(active.unitLabel)"))
        }
        return out
    }

    /// A finished job's facts come from the archive row, where the totals genuinely exist.
    private var finishedFacts: [Fact] {
        guard let entry = jobEntry else { return [] }
        var out: [Fact] = []
        out.append(Fact(label: "Job", value: JobsStore.historyName(entry)))
        out.append(Fact(label: "Result", value: entry.status.capitalized))
        if let finished = entry.completedAt ?? entry.startedAt {
            out.append(Fact(label: "Finished", value: PrintTime.relative(finished), mono: true))
        }
        if let seconds = entry.durationSeconds?.double, seconds > 0 {
            out.append(Fact(label: "Duration", value: Dash.fmtDuration(seconds / 60), mono: true))
        }
        if let grams = entry.filamentUsedGrams?.double, grams > 0 {
            out.append(Fact(label: "Filament used", value: "\(Int(grams.rounded())) g", mono: true))
        }
        if let kwh = entry.energyKwh?.double, kwh > 0 {
            out.append(Fact(label: "Energy", value: String(format: "%.2f kWh", kwh), mono: true))
        }
        if let cost = entry.cost?.double, cost > 0 {
            out.append(Fact(label: "Cost", value: Money.format(model.jobs.currencySymbol, cost), mono: true))
        }
        return out
    }

    /// When the running print began, from its archive row. Bambuddy writes naive LOCAL timestamps, and
    /// `PrintTime.parse` is the one place that knows it.
    private var startedAt: Date? {
        guard vm.kind == .live,
              let archiveId = vm.reprintArchiveId,
              let entry = (model.jobs.entries ?? []).first(where: { $0.archiveId == archiveId }),
              let iso = entry.startedAt else { return nil }
        return PrintTime.parse(iso)
    }

    // MARK: - Recent

    /// The prototype's `RECENT` is an event feed — bed levelling, filament engaged. The printer
    /// publishes no such stream and Bambuddy stores none, so this shows the thing that IS recorded:
    /// the last few prints on this machine. Inventing an event log would be the more faithful mock
    /// and the less honest screen.
    private var recentCard: some View {
        let found = archive
        let rows = Array(found.rows.prefix(4))
        let empty = MacPrinterCopy.archiveEmpty(
            entries: model.jobs.entries,
            failed: model.jobs.historyFailed,
            matched: !rows.isEmpty
        )
        return MacPrinterCard(padding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                MacPrinterMonoLabel("RECENT PRINTS")
                if let empty {
                    Text(empty)
                        .font(.system(size: caption))
                        .foregroundStyle(c.t3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(MacPrinterCopy.resultTone(entry.status).solid(c))
                                    .frame(width: 6, height: 6)
                                Text(JobsStore.historyName(entry))
                                    .font(.system(size: caption, weight: .medium))
                                    .foregroundStyle(c.t2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(PrintTime.relative(entry.completedAt ?? entry.startedAt))
                                    .font(.mono(m.monoLabel + 1, weight: .medium))
                                    .foregroundStyle(c.t3)
                                    .monospacedDigit()
                            }
                        }
                    }
                    if found.unattributed {
                        unattributedNote("The archive doesn’t record which printer ran these.")
                    }
                }
            }
        }
    }

    // MARK: - Shared

    private func note(icon: String, text: String) -> some View {
        MacPrinterCard(padding: 13, fill: c.s2) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: m.body))
                    .foregroundStyle(c.t3)
                Text(text)
                    .font(.system(size: caption))
                    .foregroundStyle(c.t3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}
#endif
