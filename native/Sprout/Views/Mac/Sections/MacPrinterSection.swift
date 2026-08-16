#if os(macOS)
import SwiftUI

/// The **Printer** section (§4, prototype `1a` lines 114–218): hero card → four temperature tiles →
/// the AMS strip → an `UP NEXT` line that links to Jobs.
///
/// What iOS's `DashboardView` has and this deliberately does **not**:
///
///  - **`onSettings`** — `⌘,` opens the `Settings` scene, so a gear in the content column would be a
///    second door to one window.
///  - **the header brand block** — the toolbar's printer popup already names the machine and carries
///    its state dot (§3).
///  - **`fleetSwitcher`** — that popup is the *only* printer switcher on Mac (§3). Two switchers is
///    how a machine gets changed by accident.
///  - **the maintenance and alert chips** — they move to the inspector's triage card (§4), which is
///    where "what needs you" lives on this platform.
///
/// What it keeps, unchanged in meaning: the `LockedActions` gating and its one explaining alert,
/// `CooldownCard`, and `TempCard` as the temperature DATA. `DashVM` remains the single source of
/// print-state classification — nothing here re-reads `status.state`.
///
/// Polling is **not** started here. `MacSectionContent` owns every store's lifetime for whichever
/// section is on screen, including `model.jobs`, which backs `UP NEXT` and the inspector's archive
/// cards. A `.task` here would be a second lifetime for one poll.
struct MacPrinterSection: View {
    let model: AppModel

    /// Spelled out because `selection` below is a `private` stored property with a default, which
    /// makes the synthesised memberwise initialiser private too — `MacSectionContent` builds this
    /// view with only `model`.
    init(model: AppModel) {
        self.model = model
    }

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// Where "go to that section" writes. See `MacSectionSelection` for why this is not a bare
    /// `@FocusedValue`.
    private var selection = MacSectionSelection()

    /// Optimistic speed selection, cleared when the server's own value catches up or 15 s elapse.
    @State private var speedOverride: Int?
    @State private var confirmStop = false
    @State private var explainingLock = false

    private var vm: DashVM { model.vm }
    private var lock: LockedActions {
        LockedActions(mode: model.lanMode, explaining: $explainingLock)
    }
    private var speedIdx: Int { speedOverride ?? vm.speedIdx }

    private var caption: CGFloat { MacPrinterType.caption(m) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: m.sectionGap) {
                hero

                // Only after a print, and only when the model is willing to say something honest.
                // `CooldownCard` is shared, and now carries neither margins nor iOS density: it
                // reads `@Environment(\.metrics)` exactly as it already read `\.palette`, so it
                // arrives at this section's radius and type with no negative-padding hack. Its
                // CONTENT was always shared; only the margins were ever platform, and those belong
                // to whoever is placing it.
                if let cool = model.cooldown?.vm, cool.phase != .none {
                    CooldownCard(vm: cool)
                }

                if model.lanMode == .off { lanBanner }

                temperatures
                amsCard
                upNext
            }
            .padding(.horizontal, m.gutter)
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .background(c.bg)
        .lockedActionAlert($explainingLock)
        .confirmationDialog("Stop print?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { model.perform("Stop") { try await $0.stop($1) } }
            Button("Keep printing", role: .cancel) {}
        } message: {
            Text("This cancels the current job. It can't be undone.")
        }
        // An enabled-looking speed segment over a blocked control is exactly the bug this prevents:
        // drop a pending override the moment the printer stops accepting the command.
        .onChange(of: model.lanMode) { _, _ in
            if lock.blocked(.speed) { speedOverride = nil }
        }
        .onChange(of: vm.speedIdx) { _, server in
            if server == speedOverride { speedOverride = nil }
        }
        .onChange(of: selection.ownsFocus, initial: true) { _, _ in selection.latch() }
    }

    // MARK: - Hero

    /// Every `DashVM.kind` renders here — live, idle, complete, error, offline, connecting — and only
    /// `.live` gets a progress bar. A machine that is not printing must never carry a bar that looks
    /// like it is moving.
    private var hero: some View {
        MacPrinterCard(padding: 18) {
            HStack(alignment: .top, spacing: 14) {
                platePreview
                VStack(alignment: .leading, spacing: 0) {
                    stateRow
                    // `vm.heroSub` is the job's FILE NAME only while there is a job on screen;
                    // `Dash.present` overwrites it with prose otherwise, and a 14 pt bold
                    // "No response from the printer" reads as a filename.
                    if MacPrinterCopy.hasJobOnScreen(vm.kind), !vm.heroSub.isEmpty {
                        Text(vm.heroSub)
                            .font(.system(size: m.cardTitle + 1, weight: .semibold))
                            .foregroundStyle(c.t1)
                            .lineLimit(2)
                            .textSelection(.enabled)   // a Mac user expects to be able to copy a filename
                            .padding(.top, 7)
                    }
                    heroBody
                        .padding(.top, 14)
                    Spacer(minLength: 14)
                    controlsRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 172, alignment: .top)
        }
    }

    private var stateRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(vm.stateLabel)
                .font(.system(size: m.heroMetric, weight: .bold))
                .tracking(-0.9)
                .foregroundStyle(vm.stateColor.resolve(c))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail = MacPrinterCopy.heroDetail(vm) {
                Text(detail)
                    .font(.system(size: caption, weight: .medium))
                    .foregroundStyle(c.t3)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var heroBody: some View {
        switch vm.kind {
        case .live:
            liveProgress
        case .idle:
            heroSentence(vm.heroSub.isEmpty ? "No active job" : vm.heroSub)
        case .complete:
            heroSentence(vm.awaitingPlateClear
                ? "The queue is paused until you confirm the plate is clear."
                : "The plate is finished.")
        case .error:
            heroSentence("The printer stopped with an error. Check the machine before continuing.")
        case .offline:
            heroSentence(vm.heroSub.isEmpty
                ? "The printer isn't responding. It may be powered off, or off the network."
                : vm.heroSub)
        case .connecting:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Reaching the printer…")
                    .font(.system(size: m.body))
                    .foregroundStyle(c.t2)
            }
        }
    }

    private func heroSentence(_ s: String) -> some View {
        Text(s)
            .font(.system(size: m.body))
            .foregroundStyle(c.t2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var liveProgress: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    RollingNumber(
                        value: vm.progressInt,
                        font: .system(size: m.heroMetric + 3, weight: .bold).monospaced(),
                        color: c.t1
                    )
                    Text(verbatim: "%")
                        .font(.system(size: m.cardTitle + 4, weight: .bold))
                        .foregroundStyle(c.t3)
                }
                Spacer(minLength: 10)
                Text(MacPrinterCopy.etaLine(eta: vm.etaText, done: vm.doneText))
                    .font(.system(size: caption, weight: .medium))
                    .foregroundStyle(c.t2)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.roll(0.6), value: vm.etaText)
                    .lineLimit(1)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(c.s3)
                    Capsule()
                        .fill(vm.stateColor.resolve(c))
                        .frame(width: geo.size.width * min(max(Double(vm.progressInt) / 100, 0), 1))
                        .animation(Motion.outQuad(0.6), value: vm.progressInt)
                }
            }
            .frame(height: 7)
            .accessibilityLabel("Progress")
            .accessibilityValue("\(vm.progressInt) percent")
        }
    }

    // MARK: Plate preview

    /// The plate of the job that is on screen — and, when there isn't one, WHY.
    ///
    /// Gated on the EXACT capabilities, and each failure keeps its own sentence: a job on screen at
    /// all, a camera **stream** token (thumbnails are `?token=`-gated, never `X-API-Key`), an archive
    /// row for that job, and a thumbnail on the row. See `MacPlateAbsence` for the facts that used to
    /// share one tooltip.
    private var platePreview: some View {
        let outcome = MacPrinterCopy.platePreview(
            hasJobOnScreen: MacPrinterCopy.hasJobOnScreen(vm.kind),
            hasCameraToken: model.cameraToken != nil,
            archiveId: vm.reprintArchiveId,
            entries: model.jobs.entries
        )
        // `printLogThumbUrl` answers nil without a token and nil for an explicit null
        // `thumbnail_path`, so a URL here is proof of every gate at once.
        let url: URL? = {
            guard case .entry(let entry) = outcome else { return nil }
            return model.client?.printLogThumbUrl(
                entry.id, token: model.cameraToken, thumbnailPath: entry.thumbnailPath
            )
        }()
        // The `.entry`-with-no-URL case is a client that vanished mid-render; `MacRoot` builds this
        // window only with one, so it is unreachable rather than merely unlikely.
        let reason = outcome.absence?.sentence ?? MacPlateAbsence.noImage.sentence

        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.thumb)
            if let url {
                // `CachedThumb` rather than `AsyncImage`: the section re-renders on every status
                // frame, and a bare AsyncImage re-fetches and re-decodes each time.
                CachedThumb(url: url, size: CGSize(width: 172, height: 172), contentMode: .fit)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(c.t3)
                    // The CAUSE, not the generic word. All six absences read "NO PREVIEW" before
                    // this, so a plate that simply is not written until the print ends looked
                    // identical to a broken token.
                    MacPrinterMonoLabel(outcome.absence?.shortLabel ?? "NO PREVIEW")
                }
            }
        }
        .frame(width: 172, height: 172)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(c.line))
        .help(url == nil ? reason : "Plate preview")
    }

    // MARK: Controls

    /// Actions, then the four-way speed segment. `ViewThatFits` because the wide row genuinely does
    /// not fit the 640 pt minimum content width — a `Spacer(minLength:)` reports its minimum as its
    /// ideal size, so the first candidate is measured at its natural width and still spreads once
    /// chosen.
    private var controlsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                actionButtons
                if MacPrinterCopy.showsSpeed(vm.kind) {
                    Spacer(minLength: 14)
                    speedSegment
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) { actionButtons }
                if MacPrinterCopy.showsSpeed(vm.kind) { speedSegment }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButtons: some View {
        // "The plate needs confirming" and "the print is complete" are two questions, and this
        // button belongs to the first. `Alerts.present` raises "Waiting for the plate" on
        // `awaitingPlateClear` ALONE, and the inspector's triage card renders it — so gating the one
        // control that clears it on `kind == .complete` left the app stating the queue was blocked
        // with no reachable way to unblock it in every other kind. iOS reaches the action a second
        // way, through `Overlay.alerts`; macOS has no alerts surface, so this row is the only door.
        //
        // It leads the row rather than sitting inside the `.complete` case because when the plate
        // needs clearing it IS the primary action — `reprintButton` steps down to secondary beside
        // it for the same reason.
        if vm.awaitingPlateClear { plateClearedButton }

        switch vm.kind {
        case .live:
            pauseButton
            stopButton
            lightButton
        case .idle:
            lightButton
        case .complete:
            reprintButton
            lightButton
        case .error:
            lightButton
        case .offline:
            Text("Controls need the printer online.")
                .font(.system(size: caption, weight: .medium))
                .foregroundStyle(c.t3)
        case .connecting:
            EmptyView()
        }
    }

    private var pauseButton: some View {
        let action: ActionId = vm.isPaused ? .resume : .pause
        // Read the flag here, on the main actor, rather than inside the sendable closure.
        let paused = vm.isPaused
        let blocked = lock.blocked(action)
        return Button(action: lock.press(action) {
            model.perform(paused ? "Resume" : "Pause") { client, id in
                paused ? try await client.resume(id) : try await client.pause(id)
            }
        }) {
            Label {
                Text(paused ? "Resume" : "Pause")
            } icon: {
                Image(systemName: blocked ? "lock.fill" : (paused ? "play.fill" : "pause.fill"))
            }
            .labelStyle(MacPrinterButtonLabelStyle())
        }
        .buttonStyle(MacPrimaryButtonStyle())
        .opacity(lock.style(action) ?? 1)
        .help(blocked ? Lan.blockedHint : (paused ? "Resume the print" : "Pause the print"))
    }

    /// Stop is NEVER lock-gated: a dead emergency stop on a failing print is worse than a command the
    /// printer might reject.
    private var stopButton: some View {
        Button { confirmStop = true } label: {
            Label {
                Text("Stop")
            } icon: {
                Image(systemName: "stop.fill")
            }
            .labelStyle(MacPrinterButtonLabelStyle())
        }
        .buttonStyle(MacSecondaryButtonStyle(role: .destructive))
        .help("Cancel the current job")
    }

    /// The light publishes `system/ledctrl`, not a `print.*` command — the firmware does not verify it
    /// the same way, so it is never lock-gated.
    ///
    /// The label names the ACTION rather than the state, unlike the iOS pill: a Mac push button that
    /// reads "Light ON" is ambiguous about which way pressing it goes.
    private var lightButton: some View {
        let on = vm.lightOn
        return Button {
            model.perform("Light") { try await $0.setLight($1, on: !on) }
        } label: {
            Label {
                Text(on ? "Light off" : "Light on")
            } icon: {
                Image(systemName: on ? "lightbulb.fill" : "lightbulb")
            }
            .labelStyle(MacPrinterButtonLabelStyle())
            .foregroundStyle(on ? c.accent : c.t1)
        }
        .buttonStyle(MacSecondaryButtonStyle())
        .help(on ? "Turn the chamber light off" : "Turn the chamber light on")
    }

    private var plateClearedButton: some View {
        Button {
            model.perform("Plate cleared") { try await $0.clearPlate($1) }
        } label: {
            Label {
                Text("Plate cleared")
            } icon: {
                Image(systemName: "checkmark.square")
            }
            .labelStyle(MacPrinterButtonLabelStyle())
        }
        .buttonStyle(MacPrimaryButtonStyle())
        .help("Confirm the bed is clear so the queue can dispatch")
    }

    /// Re-queue the finished job.
    ///
    /// Gated on `vm.reprintArchiveId`, not on the print being complete: those are two questions, and a
    /// job Bambuddy never archived answers the second yes and the first no. With no archive the button
    /// keeps its place and says what it can actually do — open Files.
    ///
    /// The LAN lock rides the reprint only. Without an archive this control sends the printer nothing
    /// at all, so dimming it and raising "controls are locked" would be the same class of lie pointing
    /// the other way.
    @ViewBuilder
    private var reprintButton: some View {
        let archive = vm.reprintArchiveId
        let blocked = archive != nil && lock.blocked(.printAgain)
        // With no archive the destination is Files, which is reached by changing the section.
        let canOpenFiles = selection.canNavigate
        let core = Button {
            guard let archive else {
                selection.go(to: .library)
                return
            }
            lock.press(.printAgain) {
                model.perform("Print again") { client, id in
                    try await client.reprint(archiveId: archive, printerId: id)
                }
            }()
        } label: {
            Label {
                Text(archive == nil ? "Print something else" : "Print again")
            } icon: {
                Image(systemName: blocked ? "lock.fill" : "arrow.clockwise")
            }
            .labelStyle(MacPrinterButtonLabelStyle())
        }
        // Two different dims, and they must not be spelled the same: `Lan.lockedOpacity` means "the
        // printer refuses this command" and always carries `Lan.blockedHint`.
        .opacity(blocked ? Lan.lockedOpacity : (archive == nil && !canOpenFiles ? MacDim.unavailable : 1))
        .disabled(archive == nil && !canOpenFiles)
        .help(blocked ? Lan.blockedHint
                      : (archive == nil
                            ? (canOpenFiles ? "Nothing was archived for this job — open Files instead"
                                            : "Nothing was archived for this job, and there is no window to open Files in")
                            : "Put this job back in the queue"))

        // Branching the STYLE rather than the button: `buttonStyle(_:)` takes a concrete type, and a
        // `ButtonStyle` value cannot be chosen at runtime without losing the `@Environment` the two
        // styles read their palette from. While the plate still needs confirming, "Plate cleared" is
        // the primary action and this steps down beside it.
        if vm.awaitingPlateClear {
            core.buttonStyle(MacSecondaryButtonStyle())
        } else {
            core.buttonStyle(MacPrimaryButtonStyle())
        }
    }

    // MARK: Speed

    /// 1…4, straight off `Dash.speedLabels` so the names cannot drift from the ones `DashVM` reports.
    private var speeds: [(index: Int, name: String)] {
        (1...4).map { (index: $0, name: Dash.speedLabels[$0]) }
    }

    private var speedSegment: some View {
        let blocked = lock.blocked(.speed)
        return HStack(spacing: 9) {
            HStack(spacing: 5) {
                if blocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: m.monoLabel))
                        .foregroundStyle(c.t3)
                }
                MacPrinterMonoLabel("SPEED")
            }
            HStack(spacing: 2) {
                ForEach(speeds, id: \.index) { speed in
                    let selected = speed.index == speedIdx
                    Button(action: lock.press(.speed) { setSpeed(speed.index) }) {
                        Text(speed.name)
                            .font(.system(size: caption, weight: .semibold))
                            .foregroundStyle(selected ? c.t1 : c.t3)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? c.s4 : .clear)
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: m.primaryControlHeight)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(c.line))
        .opacity(lock.style(.speed) ?? 1)
        .help(blocked ? Lan.blockedHint : "Print speed")
        .fixedSize()
    }

    /// Optimistic: show the new mode immediately and let the server's own value take over when it
    /// catches up. The override also clears on failure and after 15 s, so a dropped command cannot
    /// leave the segment lying about which mode the printer is in.
    ///
    /// The failure goes to `model.toast`, which `MacRoot` now renders — the segment snapping back to
    /// the old mode is a symptom, not a message.
    ///
    /// Deliberately duplicated from `DashboardView` rather than hoisted: it is UI optimism about one
    /// control, and the two trees already own their own control layouts. What is NOT duplicated is
    /// which mode the printer reports — that is `DashVM.speedIdx` — nor how a failure reads, which is
    /// `JobsStore.failureText` (Bambuddy's own `detail`, which beats a transport description).
    private func setSpeed(_ index: Int) {
        guard let mode = SpeedMode(rawValue: index), let client = model.client else { return }
        speedOverride = index
        let id = model.printerId
        Task {
            do {
                try await client.setSpeed(id, mode: mode)
                try? await Task.sleep(for: .seconds(15))
                if speedOverride == index { speedOverride = nil }
            } catch {
                speedOverride = nil
                model.toast = .failure("Speed failed — \(JobsStore.failureText(error))")
            }
        }
    }

    // MARK: - LAN banner

    private var lanBanner: some View {
        MacPrinterCard(fill: c.heatingDim, stroke: c.heating) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: m.body))
                        .foregroundStyle(c.heating)
                    Text(Lan.bannerTitle)
                        .font(.system(size: m.cardTitle, weight: .semibold))
                        .foregroundStyle(c.t1)
                }
                Text(Lan.bannerBody)
                    .font(.system(size: caption))
                    .foregroundStyle(c.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Temperatures

    /// Four across at Mac metrics (§8) — the iOS grid is two per row. `TempCard.present` decides WHICH
    /// cards exist; only the arrangement is platform.
    ///
    /// A machine that reports fewer readouts (an A1: nozzle + bed) shares the full width between them
    /// rather than leaving quarter-width tiles beside an empty half row.
    private var temperatures: some View {
        // `heatingEnabled` false on a finished print: a bed coming down off 60° is not heating for a
        // job and must not shimmer as if it were.
        let cards = TempCard.present(vm, heatingEnabled: vm.kind != .complete)
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: m.cardGap),
            count: min(max(cards.count, 1), 4)
        )
        return LazyVGrid(columns: columns, spacing: m.cardGap) {
            ForEach(cards) { tempTile($0) }
        }
    }

    private func tempTile(_ card: TempCard) -> some View {
        let barColor = card.heating ? c.heating : c.running
        // A 4 % floor so a cold or unset card still shows a sliver rather than an empty track.
        let pct = card.target > 0 ? max(4, min(100, Double(card.now) / Double(card.target) * 100)) : 4

        return MacPrinterCard(padding: 13, stroke: card.active ? c.accent : c.line) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    MacPrinterMonoLabel(card.label.uppercased())
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if card.heating {
                        PulseDot(color: barColor, size: 6, period: 1.4)
                    } else {
                        RoundedRectangle(cornerRadius: 3).fill(barColor)
                            .frame(width: 6, height: 6).opacity(0.9)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    RollingNumber(
                        value: card.now,
                        font: .system(size: m.heroMetric - 4, weight: .bold).monospaced(),
                        color: c.t1
                    )
                    Text(verbatim: card.target > 0 ? "/\(card.target)°" : "°")
                        .font(.system(size: m.cardTitle, weight: .semibold))
                        .foregroundStyle(c.t3)
                        .monospacedDigit()
                }
                .padding(.top, 9)

                HeatBar(pct: pct, heating: card.heating, color: barColor, track: c.s3, height: 4)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - AMS strip

    private var amsCard: some View {
        MacPrinterCard(padding: 15) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    MacPrinterMonoLabel(PrinterProfile.forPrinter(model.printer).amsLabel.uppercased())
                    Text(MacPrinterCopy.amsSummary(slots: vm.ams, units: vm.amsUnits))
                        .font(.system(size: caption, weight: .medium))
                        .foregroundStyle(c.t3)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    MacSectionLink(
                        title: TabKey.ams.label,
                        canNavigate: selection.canNavigate
                    ) {
                        selection.go(to: .ams)
                    }
                }

                if vm.ams.isEmpty {
                    Text("No filament unit is reporting. Slots appear here once the printer sees one.")
                        .font(.system(size: caption))
                        .foregroundStyle(c.t3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Four across, wrapping. The H2C reports nine slots over three units; a fixed
                    // four-wide row that scrolled sideways (the iOS answer, where width is scarce)
                    // would hide five of them behind a gesture on a machine that has the room.
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: m.cardGap), count: 4),
                        spacing: m.cardGap
                    ) {
                        ForEach(vm.ams) { slotChip($0) }
                    }
                }
            }
        }
    }

    private func slotChip(_ slot: AmsSlotVM) -> some View {
        HStack(spacing: 10) {
            Swatch(value: slot.color, size: 26, radius: 7, empty: slot.empty)
            VStack(alignment: .leading, spacing: 3) {
                Text(slot.label)
                    .font(.system(size: m.body - 1, weight: .semibold))
                    .foregroundStyle(slot.empty ? c.t3 : c.t1)
                    .lineLimit(1)
                if slot.active {
                    Text("printing now")
                        .font(.system(size: m.body - 2.5, weight: .medium))
                        .foregroundStyle(c.accent)
                } else if !slot.empty {
                    Text(slot.pct)
                        .font(.system(size: m.body - 2.5, weight: .medium))
                        .foregroundStyle(c.t3)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 4)
            Text(MacPrinterCopy.slotTag(slot, unitCount: vm.amsUnits.count))
                .font(.mono(m.monoLabel, weight: .medium))
                .foregroundStyle(c.t3)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(slot.empty ? c.s1 : c.s2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    slot.active ? c.accent : c.line,
                    style: StrokeStyle(lineWidth: slot.active ? 1.5 : 1, dash: slot.empty ? [3, 2.5] : [])
                )
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Up next

    private var upNext: some View {
        // `JobsStore.upNext` already answers the real question: pending jobs aimed at THIS printer,
        // plus the untargeted ones that can land here. The queue is server-wide, so a plain "first
        // pending job" would advertise another machine's work.
        let queued = JobsStore.upNext(model.jobs.queue, printerId: model.printerId)
        return MacPrinterCard(padding: 13) {
            HStack(spacing: 12) {
                MacPrinterMonoLabel("UP NEXT")

                if let next = queued.first {
                    Text(JobsStore.queueName(next))
                        .font(.system(size: m.body, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let duration = queueDuration(next) {
                        Text(duration)
                            .font(.system(size: caption, weight: .medium))
                            .foregroundStyle(c.t3)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    if queued.count > 1 {
                        Text(verbatim: "+ \(queued.count - 1) more queued")
                            .font(.system(size: caption, weight: .medium))
                            .foregroundStyle(c.t3)
                            .monospacedDigit()
                    }
                } else {
                    // Three different sentences, because "still loading", "the fetch failed" and
                    // "the queue is genuinely empty" are three different facts.
                    Text(MacPrinterCopy.queueEmpty(queue: model.jobs.queue, failed: model.jobs.queueFailed))
                        .font(.system(size: caption, weight: .medium))
                        .foregroundStyle(c.t3)
                    Spacer(minLength: 8)
                }

                MacSectionLink(title: TabKey.jobs.label, canNavigate: selection.canNavigate) {
                    selection.go(to: .jobs)
                }
            }
        }
    }

    private func queueDuration(_ job: QueueItem) -> String? {
        guard let seconds = job.printTimeSeconds?.double, seconds > 0 else { return nil }
        return Dash.fmtDuration(seconds / 60)
    }
}

// MARK: - Shared chrome

/// The card chrome every block on the Printer section and its inspector shares: `s1` fill, hairline,
/// and §8's radius and padding read from `Metrics`.
///
/// Defined once and used from both files so the section and its inspector cannot drift apart. Named
/// for this section on purpose — five other Mac sections are being written into the same module, and
/// a generic `MacCard` is a name collision waiting to happen.
struct MacPrinterCard<Content: View>: View {
    var padding: CGFloat?
    var fill: Color?
    var stroke: Color?
    private let content: Content

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    init(
        padding: CGFloat? = nil,
        fill: Color? = nil,
        stroke: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.fill = fill
        self.stroke = stroke
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding ?? m.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
                    .fill(fill ?? c.s1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
                    .stroke(stroke ?? c.line)
            )
    }
}

/// The small tracked monospace heading — `UP NEXT`, `THIS JOB`, `RECENT` (§8's `monoLabel`).
struct MacPrinterMonoLabel: View {
    let text: String
    var tint: Color?

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.mono(m.monoLabel, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(tint ?? c.t3)
    }
}

/// Icon + title at the button metrics the two Mac button styles expect. A `LabelStyle` rather than an
/// `HStack` per button so the icon/title gap is written once.
struct MacPrinterButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.font(.system(size: 12, weight: .semibold))
            configuration.title
        }
    }
}

/// Type steps this section needs beyond §8's named tokens.
enum MacPrinterType {
    /// Secondary running text: §8's `body` (13 pt on Mac) less one step.
    ///
    /// Written once. Both files and `MacSectionLink` want it, and the literal had already been
    /// spelled out a second time as `m.body - 1.5` inside the speed segment — which is exactly how
    /// two "captions" end up a point apart.
    static func caption(_ m: Metrics) -> CGFloat { m.body - 1.5 }
}

/// The dim for a control that is unavailable for a reason that is **not** the LAN lock.
///
/// The same value as `Lan.lockedOpacity` today, and deliberately a different constant.
/// `Lan.lockedOpacity` is documented as *the one* visual treatment for "the printer refuses this
/// command": it is always paired with a `lock.fill` glyph and `Lan.blockedHint`. Spelling "no camera
/// token", "no frame to save" and "no window to navigate" with the same constant gave one signal
/// three meanings and made the two indistinguishable in code review even where the tooltips differ.
/// Every use of THIS one carries a `.help` naming its own reason, and the two may diverge visually
/// without hunting down which call sites meant which.
enum MacDim {
    static let unavailable: Double = 0.4
}

/// Where "go to that section" writes, held across focus changes.
///
/// Two questions, and `@FocusedValue(\.selectedSection)` only ever answered the second:
///
///  - **"Is there a section selection this view can change?"** — what a navigation link needs.
///  - **"Is this view's window the FOCUSED one right now?"** — what `.focusedSceneValue` reports.
///
/// They part company the moment a sibling window becomes key. `MacWindow` publishes the selection
/// with `.focusedSceneValue`, so opening the camera window — which the inspector's own "Open in
/// window" button does — makes the focused value nil for views *inside the main window too*, and the
/// section immediately drew three dimmed, disabled links because a sibling window was in front of
/// it. The viewer and Settings windows do the same.
///
/// The latch only takes a value while `controlActiveState == .key`, i.e. while the focused scene
/// genuinely IS this view's window. Without that guard a second main window would latch its
/// sibling's binding and navigate the wrong window.
///
/// `MacCommands` is the one place a bare `@FocusedValue` answers the right question: a menu item with
/// no focused window has nothing to drive, and disabling it is correct.
@MainActor
struct MacSectionSelection: DynamicProperty {
    @FocusedValue(\.selectedSection) private var focused
    @Environment(\.controlActiveState) private var controlActive
    @State private var latched: Binding<TabKey>?

    /// True while the published selection belongs to THIS view's window.
    var ownsFocus: Bool { controlActive == .key && focused != nil }

    /// Take the published binding, if it is ours to take. `@State`'s setter is non-mutating, so this
    /// composes from a `.onChange` in the host's body — a `DynamicProperty` cannot observe on its own.
    func latch() {
        if ownsFocus { latched = focused }
    }

    private var binding: Binding<TabKey>? { focused ?? latched }

    /// Whether navigating is possible at all — the question a link actually asks.
    var canNavigate: Bool { binding != nil }

    func go(to key: TabKey) { binding?.wrappedValue = key }
}

/// A "go to that section" link, drawn as the prototype's teal `Hardware ›` / `Jobs ›`.
///
/// One implementation for the section's two links and the inspector's `Open Hardware`, which were
/// the same twelve lines twice.
///
/// Disabled rather than inert when there is no selection to change — a link that swallows the click
/// is the failure this codebase keeps re-learning — and dimmed as well as disabled, because
/// `.buttonStyle(.plain)` draws nothing of its own and `.disabled` alone leaves it pixel-identical
/// to a live one.
struct MacSectionLink: View {
    let title: String
    let canNavigate: Bool
    let action: () -> Void

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: m.monoLabel, weight: .bold))
            }
            .font(.system(size: MacPrinterType.caption(m), weight: .semibold))
            .foregroundStyle(c.accent)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canNavigate)
        .opacity(canNavigate ? 1 : MacDim.unavailable)
        .help(canNavigate ? "Open \(title)" : "There is no Sprout window to open \(title) in")
    }
}

// MARK: - Window-free logic

/// Why the hero's plate tile is empty.
///
/// Six different facts used to share one tooltip — "The server has no plate image for this job" —
/// and it was wrong about five of them. Each is a different thing for the user to do, or not do, so
/// each keeps its own sentence.
enum MacPlateAbsence: Equatable {
    /// Idle, offline or connecting. `currentArchiveId` is documented as "current **or most
    /// recent**", so in these states it names the PREVIOUS print — showing that plate beside "No
    /// active job" under a "Plate preview" tooltip presented last night's job as this one.
    case noJob
    /// Thumbnails are gated by the camera **stream** token in `?token=`, never by `X-API-Key`.
    case noToken
    /// A running or finished job Bambuddy never archived — started from the printer's own screen or
    /// off its SD card. There is no row to carry an image.
    case notArchived
    /// The archive has not arrived yet. Transient, and not the server saying anything.
    case archiveLoading
    /// Loaded, and no row carries this archive id. The row is usually written when the print ends.
    case archiveMissing
    /// An explicit null `thumbnail_path` — the server saying it has no image, not a fetch to retry.
    case noImage

    /// Two or three words for the tile itself.
    ///
    /// The full `sentence` lives in a tooltip, which is invisible until hovered and impossible to
    /// report. Six distinct causes were all rendering as the single word "NO PREVIEW", so the tile
    /// looked permanently broken rather than temporarily empty — and the commonest cause is not a
    /// fault at all: a plate image is written when a print ENDS, so a running job has none yet.
    var shortLabel: String {
        switch self {
        case .noJob: "NO JOB"
        case .noToken: "NO TOKEN YET"
        case .notArchived: "NOT ARCHIVED"
        case .archiveLoading: "LOADING…"
        case .archiveMissing: "AFTER THE PRINT"
        case .noImage: "NO PLATE IMAGE"
        }
    }

    var sentence: String {
        switch self {
        case .noJob: "There's no current job to preview. Past prints and their plates are in Jobs."
        case .noToken: "Waiting for a camera token from the server — plate images need one."
        case .notArchived: "This job wasn't archived, so there's no plate image for it."
        case .archiveLoading: "Loading this job's archive entry…"
        case .archiveMissing: "The archive has no entry for this job yet."
        case .noImage: "The server has no plate image for this job."
        }
    }
}

/// What the plate tile resolved to: a row to build a thumbnail URL from, or a reason there is none.
enum MacPlatePreview: Equatable {
    case entry(PrintLogEntry)
    case absent(MacPlateAbsence)

    var absence: MacPlateAbsence? {
        if case .absent(let why) = self { return why }
        return nil
    }
}

/// A tinted card's colour pair: the stroke, and the **tuned** fill behind it.
///
/// `Palette` ships a `*Dim` companion for every state colour, and their alphas differ between light
/// and dark — a computed `tint.opacity(0.10)` is therefore a different colour from the one every
/// other tinted surface on the platform draws, in at least one of the two schemes. This exists so
/// the pairing is picked once, by name, rather than re-derived per card.
///
/// Not `StateColor`, which is the print-state ladder and has no `accent` rung; an informational
/// alert is teal, and bending it into `idle` would be a colour lie to avoid a five-case enum.
enum MacTint: Equatable {
    case accent, running, heating, error, idle

    /// The colour itself — a card's hairline, a status dot.
    func solid(_ p: Palette) -> Color {
        switch self {
        case .accent: p.accent
        case .running: p.running
        case .heating: p.heating
        case .error: p.error
        case .idle: p.idle
        }
    }

    /// The palette's own tuned wash behind it. Named as `Palette` names it, so the pairing is
    /// obviously the tokens' rather than something this file invented.
    func dim(_ p: Palette) -> Color {
        switch self {
        case .accent: p.accentDim
        case .running: p.runningDim
        case .heating: p.heatingDim
        case .error: p.errorDim
        case .idle: p.idleDim
        }
    }
}

/// Every branchy predicate on the Printer section and its inspector that decides **what the user is
/// told**.
///
/// Pure, `nonisolated` and in a namespace rather than `private var`s on a `View`, for one reason: a
/// computed property on a view is unreachable from `SproutTests`, and doc 18's Testing section
/// requires window-free Mac logic to be tested. `SproutTests` carries the macOS destination
/// (`project.yml`), so everything here is directly callable from a test case.
enum MacPrinterCopy {

    // MARK: State questions

    /// Is there a JOB on screen — one the printer is running, has just finished, or failed on?
    ///
    /// Two things hang off this, and each used to ask its own nearby question:
    ///
    ///  - `vm.heroSub` is the job's FILE NAME in these states and a sentence about the machine in the
    ///    others, because `Dash.present` overwrites it. Rendering both the same way put
    ///    "No response from the printer" on screen in 14 pt bold, where it reads as a filename.
    ///  - `vm.reprintArchiveId` is `PrinterStatus.currentArchiveId`, "current **or most recent**".
    ///    It names the job on screen only in these states; in the others it names the previous one.
    nonisolated static func hasJobOnScreen(_ kind: DashKind) -> Bool {
        switch kind {
        case .live, .complete, .error: true
        case .idle, .offline, .connecting: false
        }
    }

    /// Speed is a print setting the machine will accept while running or idle. Offering it on a
    /// finished, failed, offline or still-connecting machine would be a control aimed at nothing.
    nonisolated static func showsSpeed(_ kind: DashKind) -> Bool {
        kind == .live || kind == .idle
    }

    /// The states that can produce a picture at all.
    ///
    /// Deliberately not `kind != .offline`: a printer that is still connecting has no camera either,
    /// and a tile that sits on "WAKING…" forever is the lie this list prevents. The demo has no
    /// physical camera at all, which is a stated absence rather than a state to wait out.
    nonisolated static func cameraPossible(kind: DashKind, isDemo: Bool) -> Bool {
        !isDemo && [.live, .idle, .complete, .error].contains(kind)
    }

    /// The camera tile's badge.
    ///
    /// Quotes the rate actually streaming rather than the one the path would choose now, so it can
    /// never advertise a number the video is not being delivered at. `PLAYING IN WINDOW` leads
    /// because "the picture moved" and "the picture stopped" are different facts and only one of them
    /// invites a click on Retry.
    nonisolated static func cameraBadge(
        claimedByWindow: Bool,
        tileActive: Bool,
        isLive: Bool,
        fps: Int?
    ) -> String {
        if claimedByWindow { return "PLAYING IN WINDOW" }
        guard tileActive else { return "PAUSED" }
        guard isLive, let fps else { return "WAKING…" }
        return "LIVE · \(fps) fps"
    }

    // MARK: Hero

    /// The small line beside the state word. Nothing is invented for a state that has nothing to say.
    nonisolated static func heroDetail(_ vm: DashVM) -> String? {
        switch vm.kind {
        case .live:
            guard vm.totalLayers != "0" else { return nil }
            return "layer \(vm.layer) of \(vm.totalLayers)"
        case .complete:
            return vm.awaitingPlateClear ? "plate not cleared" : nil
        case .error:
            return vm.hmsCode
        case .idle, .offline, .connecting:
            return nil
        }
    }

    /// `Dash.fmtDuration` returns "—" for a remaining time the printer has not produced yet — early in
    /// a print, and for the whole of a paused one. Splicing that into "— left · done ~ —" is a
    /// sentence with two blanks in it; saying which part is unknown is one.
    nonisolated static func etaLine(eta: String, done: String) -> String {
        let left = eta == "—" ? "time left unknown" : "\(eta) left"
        guard done != "—" else { return left }
        return "\(left) · done ~ \(done)"
    }

    /// Resolve the hero's plate tile. See `MacPlateAbsence` for why every branch has its own answer.
    nonisolated static func platePreview(
        hasJobOnScreen: Bool,
        hasCameraToken: Bool,
        archiveId: Int?,
        entries: [PrintLogEntry]?
    ) -> MacPlatePreview {
        guard hasJobOnScreen else { return .absent(.noJob) }
        guard hasCameraToken else { return .absent(.noToken) }
        guard let archiveId else { return .absent(.notArchived) }
        guard let entries else { return .absent(.archiveLoading) }
        guard let entry = entries.first(where: { $0.archiveId == archiveId }) else {
            return .absent(.archiveMissing)
        }
        // `printLogThumbUrl` answers nil for an explicit null path; asking here is what lets the
        // tooltip name this cause instead of asserting it for all five.
        guard entry.thumbnailPath != nil else { return .absent(.noImage) }
        return .entry(entry)
    }

    // MARK: AMS

    /// Loaded count, plus the WORST humidity across units.
    ///
    /// The maximum rather than unit 0's: an AMS 2 Pro and an AMS HT sit at very different readings,
    /// and the one worth a single summary line is the one the triage card would flag.
    nonisolated static func amsSummary(slots: [AmsSlotVM], units: [AmsUnitVM]) -> String {
        guard !slots.isEmpty else { return "not reporting" }
        let loaded = slots.filter { !$0.empty }.count
        var parts = ["\(loaded) of \(slots.count) slots loaded"]
        if let rh = units.compactMap(\.humidity).max() {
            parts.append("\(Int(rh.rounded())) % RH")
        }
        return parts.joined(separator: " · ")
    }

    /// Slot naming. A bare number is ambiguous the moment a second unit is fitted — both units have a
    /// tray 1 — so the unit's own label leads once there is more than one.
    nonisolated static func slotTag(_ slot: AmsSlotVM, unitCount: Int) -> String {
        unitCount > 1 ? "\(slot.unitLabel) · \(slot.localId + 1)" : "\(slot.localId + 1)"
    }

    // MARK: Empty states

    /// "Still loading", "the fetch failed" and "genuinely empty" are three different facts.
    nonisolated static func queueEmpty(queue: [QueueItem]?, failed: Bool) -> String {
        if queue == nil { return "Loading the queue…" }
        if failed { return "The queue didn't load." }
        return "Nothing queued."
    }

    /// The archive's empty states, for both the inspector's job card and its recent-prints list —
    /// which had four states between them and got two of them wrong in one place and right in the
    /// other, 100 lines apart.
    ///
    /// `matched` is "does this printer have rows in what loaded", kept apart from "did anything
    /// load": an archive that came back full of another machine's prints is not an empty archive,
    /// and a failed fetch is not proof that nothing was ever printed.
    ///
    /// nil when there is nothing to say — the caller has rows to draw.
    nonisolated static func archiveEmpty(
        entries: [PrintLogEntry]?,
        failed: Bool,
        matched: Bool
    ) -> String? {
        guard let entries else { return "Loading the archive…" }
        if matched { return nil }
        if failed && entries.isEmpty { return "The archive didn’t load." }
        if entries.isEmpty { return "Nothing has been printed on this server yet." }
        return "No prints recorded for this printer yet."
    }

    // MARK: Tints

    /// The triage card's tint: the worst alert on it.
    ///
    /// With no alerts at all the card is carrying a SERVICE item only, which is a warning — amber,
    /// never red. A `nil` maximum is that case, not an absent one.
    nonisolated static func triageTone(_ alerts: [AlertVM]) -> MacTint {
        switch alerts.map(\.level).max() {
        case .error: .error
        case .warning: .heating
        case .info: .accent
        case nil: .heating
        }
    }

    /// One alert row's own level — NOT the card's tint. The card is coloured by the worst alert on
    /// it, and a warning sitting under an error must not borrow the error's red.
    nonisolated static func alertTone(_ level: AlertLevel) -> MacTint {
        switch level {
        case .error: .error
        case .warning: .heating
        case .info: .accent
        }
    }

    /// A recorded print's outcome. Anything that is not a known success or failure keeps the neutral
    /// colour rather than being guessed into one of them — the archive carries statuses this app has
    /// never seen.
    nonisolated static func resultTone(_ result: String) -> MacTint {
        switch result.lowercased() {
        case "completed", "success", "finished": .running
        case "failed", "error": .error
        case "cancelled", "canceled": .heating
        default: .idle
        }
    }

    // MARK: Archive attribution

    /// Did this archived print run on THIS printer?
    ///
    /// Not the same question as `JobsStore.upNext`'s, and the filter must not be copied across.
    /// `upNext` keeps rows with no `printerId` because an untargeted job in a server-wide QUEUE *can
    /// land* on this machine. An untargeted row in the ARCHIVE already ran, somewhere unknown —
    /// claiming it for this printer attributes another machine's failure to this one.
    ///
    /// `unattributed` is the honest escape hatch: when the archive names no printer on ANY row, the
    /// server is not recording which machine ran what, and hiding every row would be its own lie.
    /// The caller says so in the card's copy rather than silently adopting them.
    nonisolated static func ranOnPrinter(_ entry: PrintLogEntry, printerId: Int) -> Bool {
        entry.printerId == printerId
    }

    /// True when no row in the archive names a printer at all — the server does not record it, so
    /// per-printer filtering can only produce an empty list.
    nonisolated static func archiveNamesNoPrinter(_ entries: [PrintLogEntry]) -> Bool {
        !entries.isEmpty && entries.allSatisfy { $0.printerId == nil }
    }

    /// The archive rows to show for one printer, and whether they had to be taken unattributed.
    nonisolated static func printerArchive(
        _ entries: [PrintLogEntry]?,
        printerId: Int
    ) -> (rows: [PrintLogEntry], unattributed: Bool) {
        guard let entries else { return ([], false) }
        if archiveNamesNoPrinter(entries) { return (entries, true) }
        return (entries.filter { ranOnPrinter($0, printerId: printerId) }, false)
    }
}
#endif
