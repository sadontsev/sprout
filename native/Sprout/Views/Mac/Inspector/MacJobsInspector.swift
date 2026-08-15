#if os(macOS)
import SwiftUI

/// The Jobs inspector (§4, prototype `1a` · Jobs inspector): the SELECTED archived run.
///
/// One rule governs it — content is the thing, the inspector is what is selected. So there is no
/// navigation here, nothing about the queue, and nothing about any run but this one. Picking a
/// different row in the History table changes only this column.
///
/// It reads the selection out of the same scene-storage key the section writes, because
/// `MacSectionContent` and `MacInspectorContent` build the two views separately and neither of
/// those files may be edited from here.
struct MacJobsInspector: View {
    let model: AppModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// The same constant the section writes — that key is the entire wiring between the two columns,
    /// which is why it is named in one place (`MacJobsSelection`) rather than spelled out twice.
    @SceneStorage(MacJobsSelection.run) private var selectedId: Int?

    @State private var confirmReprint = false
    @State private var notice: JobActionMessage?
    @State private var lanAlert = false

    private var store: JobsStore { model.jobs }
    private var locked: LockedActions { LockedActions(mode: model.lanMode, explaining: $lanAlert) }

    private var entry: PrintLogEntry? {
        guard let selectedId else { return nil }
        return store.entries?.first { $0.id == selectedId }
    }

    /// The same projection the table row is built from, so the two columns cannot describe one run
    /// two ways.
    private var row: MacJobRow? {
        entry.map {
            MacJobRow($0, symbol: store.currencySymbol, client: model.client, cameraToken: model.cameraToken)
        }
    }

    /// The LAN explanation is attached one level ABOVE the other two, as on iOS: SwiftUI presents
    /// one alert per view, and three stacked on the same view fight over the slot.
    var body: some View {
        column
            .lockedActionAlert($lanAlert)
    }

    private var column: some View {
        Group {
            if let row {
                selected(row)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(c.bg)
        .alert("Print again?", isPresented: $confirmReprint, presenting: entry) { e in
            Button("Cancel", role: .cancel) {}
            Button("Print again") { reprint(e) }
        } message: { e in
            Text(verbatim: "“\(JobsStore.historyName(e))” goes back into the queue.")
        }
        .alert(
            notice?.title ?? "",
            isPresented: macJobsPresented($notice),
            presenting: notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { note in
            Text(verbatim: note.message)
        }
    }

    // MARK: - Nothing selected

    /// Names the surface AND says what fills it. A blank inspector reads as a broken pane.
    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 22))
                .foregroundStyle(c.t3)
            Text("No run selected")
                .font(.system(size: m.cardTitle, weight: .semibold))
                .foregroundStyle(c.t2)
            Text(verbatim: placeholderHint)
                .font(.system(size: 11.5, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(c.t3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, m.cardPadding)
        .padding(.top, 60)
    }

    /// A selection that no longer resolves is a different fact from never having chosen one: the
    /// archive reloads every 15 s and only ever holds the newest 50, so a run you were reading can
    /// genuinely age out from under you.
    private var placeholderHint: String {
        if selectedId != nil && store.entries != nil {
            return "That run is no longer in the newest 50 archived. Pick another row in History."
        }
        return "Pick a row in History to see how the print went, and to send it back to the queue."
    }

    // MARK: - The selected run

    private func selected(_ row: MacJobRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: m.cardGap) {
                snapshot(row)
                heading(row)
                facts(row)
                reprintButton(row)
                footnote
            }
            .padding(m.cardPadding)
        }
        .scrollIndicators(.automatic)
    }

    /// The archived plate image. Gated by the camera STREAM token in `?token=`, not `X-API-Key` —
    /// `printLogThumbUrl` already returns nil when there is no token or no server-side thumbnail, so
    /// `CachedThumb` falls back to its own placeholder rather than firing a request that 401s.
    private func snapshot(_ row: MacJobRow) -> some View {
        CachedThumb(url: row.thumb, aspect: 4.0 / 3.0)
            // The clip goes on the COMPOSITE: a `.fill` image inside an overlay is not clipped by a
            // shape declared inside that overlay.
            .clipShape(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line)
            )
    }

    private func heading(_ row: MacJobRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(c.t1)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(verbatim: row.outcome.label.uppercased())
                    .font(.mono(10, weight: .bold))
                    .foregroundStyle(row.outcome.color(c))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(row.outcome.dim(c)))
                if !row.startedAbsolute.isEmpty {
                    Text(verbatim: row.startedAbsolute)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(c.t3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func facts(_ row: MacJobRow) -> some View {
        VStack(spacing: 9) {
            fact("Duration", row.durationText)
            fact("Filament", row.filamentDetail)
            fact("Energy", row.energyText)
            fact("Cost", row.costText)
            // Which machine ran it. Not in the prototype, which draws a single-printer window — but
            // the fleet is a list and the archive is server-wide, so without this the inspector is
            // silent about the one fact that tells two identical file names apart.
            if let printer = row.printerName, !printer.isEmpty {
                fact("Printer", printer)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        // `m.cardRadius`, like the snapshot directly above it. Two stacked cards in one 320 pt
        // column with two different corner radii read as a rendering mistake, and the radius is a
        // §8 density token, not this card's own decision.
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value)
                .font(.mono(11.5, weight: .medium))
                // Every one of these can tick over between two selections of the same run.
                .monospacedDigit()
                .foregroundStyle(c.t1)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Print again

    /// **The gate is the archive id, not the outcome.**
    ///
    /// `DashVM.reprintArchiveId` carries the same warning for the live card: "the print finished" is
    /// a NEARBY question, not this one. A job Bambuddy never archived — started from the printer's
    /// own screen or off its SD card, or a FINISH that landed before the archive row was written —
    /// reports no id, and `POST /queue/` has nothing to send. `JobsStore.reprint` guards on exactly
    /// this and returns silently, which is what made the iOS button do NOTHING when tapped.
    ///
    /// So the button is genuinely `.disabled` here and the reason is printed underneath. That is the
    /// opposite treatment from the LAN gate below, and deliberately: a LAN lock is temporary and the
    /// user can fix it, so that control stays pressable and explains itself on click. A missing
    /// archive is permanent for this row, and a control that will never work should not invite a
    /// click.
    private func reprintButton(_ row: MacJobRow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                locked.press(.printAgain) { confirmReprint = true }()
            } label: {
                // The greed goes on the LABEL, not on the Button: the style paints its background
                // around `configuration.label`, so a `maxWidth` outside the button would stretch the
                // hit area and leave the teal capsule text-width.
                Text("Print again").frame(maxWidth: .infinity)
            }
            .buttonStyle(MacPrimaryButtonStyle())
            .disabled(!hasArchive(row))
            // ONE dim, not two. `MacPrimaryButtonStyle` already fades a disabled button to 0.4, and
            // `.locked(_:by:)` multiplies `Lan.lockedOpacity` — also 0.4 — on top of it: with no
            // archive AND Developer Mode off the button landed at 0.16, effectively invisible rather
            // than "explained". The two gates answer two different questions and only one of them
            // can be acted on at a time, so only one of them draws: while the row is permanently
            // disabled the button style owns the dim, and the LAN dim applies to a button that is
            // otherwise live.
            .opacity(hasArchive(row) ? (locked.style(.printAgain) ?? 1) : 1)
            .help(reprintHelp(row))

            if !hasArchive(row) {
                Text("Bambuddy has no archive for this run, so there's no file to send back. Prints started from the printer's own screen or its SD card land here without one.")
                    .font(.system(size: 11, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(c.t3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    /// "Can this run EVER be re-queued?" — a permanent fact about the row, and the whole of the
    /// `.disabled` decision. Deliberately not folded together with the LAN gate, which asks the
    /// different and temporary question "will the printer accept commands right now?".
    private func hasArchive(_ row: MacJobRow) -> Bool { row.archiveId != nil }

    private func reprintHelp(_ row: MacJobRow) -> String {
        if !hasArchive(row) { return "No archived copy of this print exists on the server." }
        if locked.blocked(.printAgain) { return Lan.blockedHint }
        return "Queue this archived job again on \(model.printer?.name ?? "the selected printer")."
    }

    /// Says what the button will actually do. The request is
    /// `POST /queue/ {printer_id, archive_id, use_ams: true}` — Bambuddy re-reads the archived job's
    /// own settings, so this must NOT promise "the same slot mapping you chose", which is a claim
    /// about the server that nothing here verifies.
    private var footnote: some View {
        Text(verbatim: "Sends the archived job back to \(model.printer?.name ?? "the selected printer")'s queue with AMS on. It lines up behind whatever is printing now.")
            .font(.system(size: 11, weight: .regular))
            .lineSpacing(3.5)
            .foregroundStyle(c.t3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reprint(_ entry: PrintLogEntry) {
        Task {
            let outcome = await store.reprint(entry, printerId: model.printerId)
            if let outcome { notice = outcome }
        }
    }
}
#endif
