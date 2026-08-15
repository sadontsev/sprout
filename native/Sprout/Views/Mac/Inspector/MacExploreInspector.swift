#if os(macOS)
import SwiftUI

/// The selected MakerWorld model (§4 Explore).
///
/// On Mac there is no model *page*: the grid is the content and this is the detail, which is exactly
/// §4's rule — content is the thing, the inspector is what is selected. Nothing here navigates.
///
/// It is driven by an **id**, not by a hit, and that is deliberate. A clicked tile supplies a hit
/// (title, cover, creator and counts on the first frame, so the header exists before the request
/// does), but a pasted link supplies only a model id and no hit will ever exist for it. Keying on
/// the id makes those the same path instead of two.
struct MacExploreInspector: View {
    let model: AppModel
    let explore: ExploreModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    @SceneStorage(MacExploreSelection.key) private var selectedId: Int?

    /// The resolve and the rows built from it — **one** stored value, because they are one fact.
    ///
    /// They used to be two `@State`s that `apply` wrote together: an invariant maintained by
    /// remembering to. Making the rows part of the value means one resolve's rows can never sit
    /// under another resolve's design, and there is nothing left to keep in step by hand.
    @State private var loaded: Loaded?
    /// A RESOLVE failure. Kept apart from the import outcome in `explore.imports` on purpose: "MakerWorld
    /// wouldn't describe this model" and "MakerWorld wouldn't release this file" are different
    /// questions with different remedies, and collapsing them is how this codebase's recurring bug
    /// arrives.
    @State private var failure: MWFailure?

    /// Imports, keyed by the model each one belongs to.
    ///
    /// A **dictionary**, not one slot, and the difference is a bug the copy under the button
    /// invites: "Import runs in the background… Browsing continues." With a single slot, starting B
    /// while A was still downloading destroyed A's record — A's button went live again (a second,
    /// identical download of the same file), A's completion then flipped B out of "Importing…", and
    /// whichever finished last had its receipt shown under whichever model happened to be selected.
    /// The key *is* the tag here; as a field beside the state it was free to name a different model
    /// than the state it guarded.

    /// A resolve, with everything derived from it that the panel needs more than once.
    private struct Loaded {
        let resolved: MakerWorldResolved
        let rows: [MWProfileRow]

        init(_ r: MakerWorldResolved) {
            resolved = r
            rows = MakerWorld.rows(r)
        }
    }

    /// Where one model's import has got to. Three states, because "running" and "finished" and
    /// "refused" want three different things on screen.
    private var resolved: MakerWorldResolved? { loaded?.resolved }
    private var rows: [MWProfileRow] { loaded?.rows ?? [] }
    private var design: MWDesign? { resolved?.design }
    /// What the grid already knew, when the selection came from the grid. Looked up in `hits` rather
    /// than `orderedHits` because a lookup does not care about order and sorting 100 hits per body
    /// evaluation would be work done for nothing.
    private var hit: MWSearchHit? { explore.hits.first { $0.id == selectedId } }

    private func title(_ id: Int) -> String {
        design?.title ?? hit?.title ?? "Model \(id)"
    }
    private var creator: String? {
        (design?.designCreator?.name ?? hit?.designCreator?.name).flatMap { $0.isEmpty ? nil : $0 }
    }
    private var coverUrl: URL? {
        model.client?.makerworldThumbUrl(design?.coverUrl ?? hit?.cover)
    }

    /// The licence, from the resolve when it has landed and from the hit before it has — so the one
    /// obligation that actually bites is on screen from the first frame rather than appearing a
    /// second later. `MakerWorld.licence` carries MakerWorld's own prose when it ships any.
    private var licence: MWLicence? {
        if let design, let full = MakerWorld.licence(design) { return full }
        return hit?.license?.nonEmpty.map { MWLicence(code: $0) }
    }

    /// Both sizes come from `MacExploreType`, which the section column also reads — one definition
    /// for one screen. See the type for why it is not in `Metrics` yet.
    private var caption: CGFloat { MacExploreType.caption(m) }
    private var footnote: CGFloat { MacExploreType.footnote(m) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: m.cardGap) {
                if let id = selectedId {
                    cover
                    heading(id)
                    if model.isDemo {
                        demoNote(id)
                    } else {
                        if let failure { failureCard(failure, id: id) }
                        versionsCard
                        importBlock(id)
                    }
                } else {
                    empty
                }
            }
            // The prototype's 16 pt aside padding. `cardPadding` is the nearest thing Metrics names
            // for "inset from a panel's edge", and it moves with the density.
            .padding(m.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(c.bg)
        // Keyed on the selection, so clicking another tile cancels the resolve that is in flight
        // rather than letting it land under the new model's title.
        .task(id: selectedId) { await load() }
    }

    // MARK: Nothing selected

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(c.t3)
            Text("Nothing selected")
                .font(.system(size: m.cardTitle, weight: .semibold))
                .foregroundStyle(c.t2)
            Text(verbatim: "Click a model to see its versions and import it.")
                .font(.system(size: caption))
                .foregroundStyle(c.t3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: Header

    /// `ThumbCache`, not `AsyncImage` — the same cover is very likely already decoded from the tile
    /// that was clicked, so selecting a model costs no network at all.
    private var cover: some View {
        CachedThumb(url: coverUrl, aspect: 4.0 / 3.0)
            .clipShape(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.line))
    }

    private func heading(_ id: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title(id))
                .font(.system(size: m.cardTitle + 1, weight: .semibold))
                .foregroundStyle(c.t1)
                .fixedSize(horizontal: false, vertical: true)
            if !byline.isEmpty {
                Text(byline)
                    .font(.system(size: caption, weight: .medium))
                    .foregroundStyle(c.t3)
                    .monospacedDigit()
            }
            if let licence {
                Text(licence.obligation)
                    .font(.system(size: caption))
                    .foregroundStyle(c.t3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(licence.label)
            }
            if let caution = design.map(MakerWorld.availability)?.caution {
                // Stated up front rather than discovered at the 502. `heating`, not `paused`: paused
                // is the print-state blue, and a caution painted in a status colour reads as status.
                Label(caution, systemImage: "exclamationmark.triangle")
                    .font(.system(size: caption, weight: .medium))
                    .foregroundStyle(c.heating)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `by hexbench · 12.4k downloads · 3.1k likes`.
    ///
    /// The hit's counts win when there is a hit, because they are the numbers the tile already
    /// showed — a figure that changes between the grid and the inspector reads as a bug even when
    /// both are true. Zero is a real answer and is shown; **absent is not zero** and is omitted.
    private var byline: String {
        var parts: [String] = []
        if let creator { parts.append("by \(creator)") }
        if let hit {
            let stats = MakerWorldSearch.stats(hit)
            if !stats.isEmpty { parts.append(stats) }
        } else if let design {
            if let d = design.downloadCount {
                parts.append("\(MakerWorldSearch.compact(d)) download\(d == 1 ? "" : "s")")
            }
            if let l = design.likeCount {
                parts.append("\(MakerWorldSearch.compact(l)) like\(l == 1 ? "" : "s")")
            }
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Demo

    /// Demo mode reaches MakerWorld for real (search is anonymous and needs no server) but resolves
    /// and imports through `DemoServer`, which answers neither.
    ///
    /// `GET /makerworld/status` in the demo replies `can_download: true`, so `MakerWorldAccess` says
    /// `.ready` and the Import button would look live and then fail — the recurring bug exactly. It
    /// is said out loud here instead.
    private func demoNote(_ id: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Demo mode", systemImage: "eye")
                .font(.mono(m.monoLabel, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(c.t3)
            Text(verbatim: "Search and browse are live — they talk to MakerWorld directly. Reading a "
                 + "model's versions and importing it need a real Bambuddy server, so neither runs here.")
                .font(.system(size: caption))
                .foregroundStyle(c.t2)
                .fixedSize(horizontal: false, vertical: true)
            if let url = MakerWorld.webUrl(modelId: id) {
                Link("Open on MakerWorld", destination: url)
                    .font(.system(size: caption, weight: .semibold))
                    .foregroundStyle(c.accent)
            }
        }
        .padding(m.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.line))
    }

    // MARK: Versions

    @ViewBuilder
    private var versionsCard: some View {
        if resolved == nil && failure == nil {
            // The wait has the shape of what will replace it.
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("READING VERSIONS…")
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6).fill(c.s2).frame(height: 11)
                }
                RoundedRectangle(cornerRadius: 9).fill(c.s2).frame(height: m.primaryControlHeight)
            }
            .redacted(reason: .placeholder)
            .padding(m.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        } else if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("VERSIONS")
                Text(versionSummary)
                    .font(.system(size: caption))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                chooseVersionButton
                chooseVersionCaveat
            }
            .padding(m.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.line))
        } else if resolved != nil {
            // Resolved, and MakerWorld listed nothing. Said rather than left as a gap where the card
            // was — an absent card reads as a rendering fault, and Import still works from the
            // resolve's own profile.
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel("VERSIONS")
                Text(verbatim: "MakerWorld lists no separate versions for this model. Import takes the "
                     + "one profile it published.")
                    .font(.system(size: caption))
                    .foregroundStyle(c.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(m.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).stroke(c.line))
        }
    }

    /// `88 published · 7 fit your filament` / `51 publish no settings` / `9 name no filament…`.
    ///
    /// **Rule 2 of `VersionGrouping`: say the gap out loud.** A bare "88 versions" implies 88
    /// sortable, comparable rows when 51 of them publish no time, weight or material at all —
    /// including, on model 40146, the one MakerWorld itself pre-selects.
    ///
    /// The "fit your filament" clause appears **only when the AMS has actually been read**. With no
    /// trays known, `VersionGrouping.place` marks nothing as needing filament, so every labelled row
    /// would silently be counted as fitting — a number that answers "how many rows are labelled?"
    /// while wearing the words of "how many can I print?". That is the nearby-question bug, so the
    /// clause is replaced by a statement of what is not known.
    ///
    /// Built as an `AttributedString` rather than by concatenating `Text`: `Text + Text` is
    /// deprecated from macOS 26, and one attributed value keeps the whole thing a single wrapping
    /// paragraph instead of a stack of lines that break independently.
    private var versionSummary: AttributedString {
        let counts = versionCounts
        var out = tinted("\(counts.total) published", c.t2)
        if knowsFilament {
            out += tinted("  ·  ", c.t2)
            out += tinted("\(counts.fitting) fit your filament", c.t1)
        }
        if counts.unlabelled > 0 {
            out += tinted("\n\(counts.unlabelled) publish no settings", c.t2)
        }
        // Why the fitting count is smaller than the arithmetic suggests. Without this line the rows
        // that name no filament simply vanish from a sentence that accounts for every other row.
        if knowsFilament, counts.filamentUnpublished > 0 {
            out += tinted("\n\(counts.filamentUnpublished) name no filament, so they aren’t checked "
                          + "against yours", c.t3)
        }
        if !knowsFilament {
            out += tinted("\nNo AMS reading yet, so nothing is checked against your filament.", c.t3)
        }
        return out
    }

    private func tinted(_ text: String, _ colour: Color) -> AttributedString {
        var piece = AttributedString(text)
        piece.foregroundColor = colour
        return piece
    }

    /// The version chooser is a 900×640 sheet and **it is not built yet**.
    ///
    /// So the control is dimmed and says why, rather than opening nothing or opening something
    /// half-made: CLAUDE.md's rule is that a dimmed control which explains itself beats a live-looking
    /// one, and "Not in this build" beats a button that lies.
    private var chooseVersionButton: some View {
        Button {
            // TODO(version-chooser): present the 900×640 sheet. Deliberately a no-op until it
            // exists — a button that opens nothing is worse than one that says it cannot.
        } label: {
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Image(systemName: "lock").font(.system(size: 10, weight: .semibold))
                Text("Choose a version")
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MacSecondaryButtonStyle())
        .disabled(true)
        .help("The version chooser isn’t in this build yet.")
    }

    /// What Import will actually do while the chooser is missing — named, not implied.
    private var chooseVersionCaveat: some View {
        Text(verbatim: "Not in this build yet. " + importPlan)
            .font(.system(size: footnote))
            .foregroundStyle(c.t3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Which version Import will take, and **whose choice it was**.
    ///
    /// Two questions that the old single sentence collapsed into one: "what did MakerWorld
    /// recommend?" and "what will Import use?". `MakerWorld.preselect` deliberately *rejects*
    /// MakerWorld's `defaultInstanceId` when that profile publishes no details — measured on model
    /// 40146, where their pre-selected profile answers `400` — so in precisely the case this caption
    /// exists for, the old copy credited MakerWorld with a version it had not recommended.
    private var importPlan: String {
        guard let picked else {
            return "Import takes the one profile the resolve published."
        }
        guard let theirs = design?.defaultInstanceId else {
            return "MakerWorld names no recommended version, so Import uses \(picked.title)."
        }
        if picked.id == theirs {
            return "Import uses MakerWorld’s recommended version, \(picked.title)."
        }
        if !rows.contains(where: { $0.id == theirs }) {
            return "MakerWorld’s recommended version isn’t among the ones it listed, so Import uses "
                + "\(picked.title)."
        }
        return "MakerWorld’s recommended version publishes no print details, and those are the ones "
            + "it most often refuses to release — so Import uses \(picked.title) instead."
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.mono(m.monoLabel, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(c.t3)
    }

    // MARK: Import

    @ViewBuilder
    private func importBlock(_ id: Int) -> some View {
        let busy = importing(id)
        let others = elsewhereRunning(besides: id)
        VStack(alignment: .leading, spacing: 8) {
            Button { doImport(id) } label: {
                HStack(spacing: 7) {
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "Importing…" : "Import to Library")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MacPrimaryButtonStyle())
            // Gated on the exact capability: a resolve in hand AND a server that can download. Not
            // on "is the app connected", which is the nearby question and would offer a button the
            // backend refuses. `importing(id)` — THIS model's import, not "an import is running":
            // another model downloading is not a reason to refuse this one, and saying it were
            // would contradict the line at the bottom of this block.
            .disabled(resolved == nil || busy || explore.access.blocksImport)

            // The remedy, not just the refusal — each of these names a different machine to go and
            // look at, which is the whole value of `MakerWorldAccess`.
            if let why = explore.access.message {
                Text(verbatim: why)
                    .font(.system(size: footnote))
                    .foregroundStyle(c.t3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch explore.imports[id] {
            case .landed(let res): receiptCard(res)
            case .failed(let f):   failureCard(f, id: id)
            case .running, .none:  EmptyView()
            }

            Text(verbatim: "Import runs in the background and reports where the file landed. "
                 + "Browsing continues.")
                .font(.system(size: footnote))
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)

            // The promise above, kept visible. Without it a download started from another model is
            // invisible the moment you click a different tile, which reads as "it stopped".
            if others > 0 {
                Label {
                    Text(verbatim: "\(others) other import\(others == 1 ? "" : "s") still running")
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                .font(.system(size: footnote, weight: .medium))
                .foregroundStyle(c.t3)
                .monospacedDigit()
            }
        }
    }

    /// Where the file went, in words. Deliberately **not** a "Show in Files" button: the inspector is
    /// never a second navigation surface (§4), and a control here that changed the section would make
    /// it one.
    private func receiptCard(_ res: MakerWorldImportResponse) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(res.wasExisting == true ? "Already in your library" : "Added to your library",
                  systemImage: "checkmark.circle")
                .font(.system(size: caption, weight: .semibold))
                .foregroundStyle(c.running)
            Text(verbatim: res.filename ?? "Library file \(res.libraryFileId)")
                .font(.mono(m.monoLabel, weight: .medium))
                .foregroundStyle(c.t2)
                .fixedSize(horizontal: false, vertical: true)
            if res.wasExisting == true {
                Text(verbatim: "Nothing was downloaded twice.")
                    .font(.system(size: footnote))
                    .foregroundStyle(c.t3)
            }
        }
        .padding(m.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.runningDim))
    }

    @ViewBuilder
    private func failureCard(_ f: MWFailure, id: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            UploadErrorCard(text: f.message)
            if f.offerWebLink, let url = MakerWorld.webUrl(modelId: id) {
                Link("Open on MakerWorld", destination: url)
                    .font(.system(size: caption, weight: .semibold))
                    .foregroundStyle(c.accent)
            }
        }
    }

    // MARK: Counting

    /// What the AMS can currently supply, upper-cased.
    ///
    /// Read from live status exactly as the iOS `VersionChooserView` does, so the two screens cannot
    /// disagree about what is loaded. **Empty means "we don't know"**, not "you have nothing".
    /// What the AMS holds, as TRAYS. One builder in `VersionGrouping` — three views had their own
    /// copy, and two collapsed it to a set of materials on the way, losing the tray count.
    ///
    /// Empty means "we don't know", not "you have nothing": no row is greyed out on a status that
    /// has not arrived.
    private var loadedTrays: [VersionGrouping.Tray] {
        VersionGrouping.trays(in: model.status?.status)
    }

    /// The materials on hand, for copy that lists them. Derived from the trays so it cannot drift.
    private var printableMaterials: Set<String> { Set(loadedTrays.map(\.type)) }

    private var knowsFilament: Bool { !printableMaterials.isEmpty }

    /// Every number the summary states, from ONE placement pass.
    ///
    /// Three computed properties each calling `VersionGrouping.place` ran it three times per body
    /// evaluation — 88 rows re-walked against the AMS each time — which is exactly the cost this
    /// file refuses to pay on the hit lookup a few lines up.
    private struct VersionCounts {
        var total = 0
        /// Rows MakerWorld publishes no `detail` for at all.
        var unlabelled = 0
        /// Rows whose filament is fully published AND fully loadable from the AMS right now.
        var fitting = 0
        /// Rows that publish a `detail` but name no filament in it — countable, not checkable.
        var filamentUnpublished = 0
    }

    /// `VersionGrouping` is where the honesty lives — the placement is read rather than
    /// re-derived, so the inspector and the (future) chooser cannot report different numbers for
    /// the same model.
    private var versionCounts: VersionCounts {
        let placed = VersionGrouping.place(rows,
                                           defaultInstanceId: design?.defaultInstanceId,
                                           trays: loadedTrays)
        var counts = VersionCounts(total: rows.count)
        for item in placed {
            if item.isUnlabelled {
                counts.unlabelled += 1
            } else if !publishesEveryFilament(item.row) {
                counts.filamentUnpublished += 1
            } else if item.group != .needsFilament {
                counts.fitting += 1
            }
        }
        return counts
    }

    /// Does this row say what filament it needs — every slot of it, by name?
    ///
    /// **Two questions, and the groups answer the other one.** `group != .needsFilament` answers
    /// *"is anything it named missing from the AMS?"*; the words "fit your filament" claim *"we know
    /// what it needs and you have it"*. They part company on a profile that publishes a `detail`
    /// with no filaments in it — `MakerWorld.detail` builds a detail whenever the record exists, so
    /// `slots` comes back empty, nothing is named, nothing can be missing, and the row was counted
    /// as fitting on the strength of having named nothing. The unlabelled test does not catch it:
    /// those rows *have* a detail, just not this part of one. Same for a multi-slot version where
    /// only some slots carry a `type`.
    private func publishesEveryFilament(_ row: MWProfileRow) -> Bool {
        guard let slots = row.detail?.slots, !slots.isEmpty else { return false }
        return slots.allSatisfy { $0.type?.nonEmpty != nil }
    }

    /// The row an import would use while the chooser is missing.
    ///
    /// `MakerWorld.preselect` rather than "MakerWorld's `defaultInstanceId`": their pick is honoured
    /// only when that profile publishes details, because a profile that publishes none is measurably
    /// likely to refuse the download — on model 40146 the pre-selected one answers `400`.
    private var picked: MWProfileRow? {
        MakerWorld.preselect(rows, defaultInstanceId: design?.defaultInstanceId)
    }

    /// Is **this** model downloading? Not "is an import running" — with `explore.imports` keyed by
    /// model those are different questions, and only this one may disable this model's button.
    private func importing(_ id: Int) -> Bool {
        explore.imports[id]?.isRunning ?? false
    }

    /// How many other models are mid-download.
    private func elsewhereRunning(besides id: Int) -> Int {
        explore.imports.filter { key, state in state.isRunning && key != id }.count
    }

    // MARK: Actions

    private func load() async {
        // Reset first: without it the previous model's versions sit under the new model's title for
        // as long as the resolve takes.
        loaded = nil
        failure = nil

        guard let id = selectedId, !model.isDemo else { return }
        // Without this the skeleton below would spin for ever, which is the same lie as a live-looking
        // control: a wait that can never end has to say so.
        guard let client = model.client else {
            failure = MWFailure(message: "Not connected to a Bambuddy server, so this model can’t be "
                                + "read or imported.", offerWebLink: true)
            return
        }
        // Back-then-forward is instant: the resolve for this model may already be in hand.
        if let cached = explore.cachedResolve(id) {
            loaded = Loaded(cached)
            return
        }
        do {
            let r = try await client.resolveMakerWorld(MakerWorldSearch.modelUrl(id: id))
            guard !Task.isCancelled else { return }
            explore.cacheResolve(r, for: id)
            loaded = Loaded(r)
            // A resolve is proof the server is reachable. Without this, one failed probe at launch
            // locks the import for the life of the session even as the design renders fine.
            if explore.access.worthRetrying { explore.access = await client.makerWorldAccess() }
        } catch {
            guard !Task.isCancelled else { return }
            failure = mwFailure(.resolve, error)
        }
    }

    private func doImport(_ id: Int) {
        guard let client = model.client, let r = resolved,
              !importing(id), !explore.access.blocksImport
        else { return }
        // The resolve response's own profile id is the fallback ONLY when no row is picked at all.
        // Falling back for a picked row that happens to carry no profileId would quietly import a
        // different profile than the one shown.
        let request = MakerWorldImportRequest(modelId: r.modelId,
                                              profileId: picked.map(\.profileId) ?? r.profileId,
                                              instanceId: picked?.id,
                                              folderId: nil)
        explore.imports[id] = .running
        Task {
            do {
                let res = try await client.importMakerWorld(request)
                explore.imports[id] = .landed(res)
                // Files may well be on screen in another window, and the cold shelf here lists what
                // has been imported — both are now stale.
                await model.library.load()
                explore.recent = await client.recentMakerWorldImports()
            } catch {
                let f = mwFailure(.importing, error)
                explore.imports[id] = .failed(f)
                // The card says it when this model is the one on screen. When it is not — which is
                // the whole point of a background import — nothing would say it at all, and a
                // failure nobody is shown is the same lie as a control that silently does nothing.
                if selectedId != id { model.toast = f.message }
            }
        }
    }

    /// The status matters: a MakerWorld refusal arrives as a 502 wrapping the upstream status, and
    /// `MakerWorld.failure` needs it to tell "the server can't reach MakerWorld" from "MakerWorld
    /// said no".
    private func mwFailure(_ step: MakerWorld.Step, _ error: Error) -> MWFailure {
        MakerWorld.failure(step: step,
                           status: (error as? BambuddyError)?.status ?? 0,
                           detail: uploadApiDetail(error))
    }
}
#endif
