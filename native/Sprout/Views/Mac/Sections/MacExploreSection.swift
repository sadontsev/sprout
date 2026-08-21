#if os(macOS)
import AppKit
import SwiftUI

// MARK: - The selection both columns share

/// Where Explore's selected model id lives.
///
/// `MacSectionContent` builds the section and the inspector as two separate views, so they cannot
/// pass a `@Binding` between them — the selection has to live somewhere both can reach.
/// `@SceneStorage` is that somewhere, and it also means a relaunch reopens on the model you were
/// looking at, which is the promise `ExploreModel` already makes about the results themselves.
enum MacExploreSelection {
    /// Declared once because BOTH columns read it. Two string literals would be free to drift, and
    /// the failure would be silent: clicking a tile would simply stop reaching the inspector.
    ///
    /// The stored type is `Int?`, not an `Int` with a sentinel. `@SceneStorage` does hold optionals
    /// — `MacFilesSelection` stores `Int?` and `String?` in this same window — so a `0` meaning
    /// "nothing" was a second spelling of nil plus an untested invariant ("MakerWorld ids are
    /// positive") for no gain.
    static let key = "mac.explore.selected"
}

/// Sizes Explore's two columns share.
///
/// One definition, because the section and the inspector are two files drawing one screen: the same
/// derived size spelled twice is free to drift, and a caption that is 11.5 pt in the grid and 11 pt
/// in the panel beside it is the kind of drift nobody ever files. `Metrics` names no caption size,
/// so these derive from the one it does name and a density change still moves them.
///
/// It belongs *in* `Metrics` — that file is shared with five other sections being edited in
/// parallel, so the move is reported rather than made here.
enum MacExploreType {
    /// System captions: the sort label, a chip, the scope note, a panel's supporting line.
    static func caption(_ m: Metrics) -> CGFloat { m.monoLabel + 2 }
    /// The smallest text on the screen — the footnote under a control that explains the control.
    static func footnote(_ m: Metrics) -> CGFloat { m.monoLabel + 1 }
}

// MARK: - Section

/// MakerWorld browsing, as the content column (§4 Explore).
///
/// Three rules govern this screen and every one of them was learnt the expensive way — see
/// `ExploreModel` and `MakerWorldSearch` for the measurements:
///
/// 1. **The grid is never blanked while loading.** `ExploreModel.startFetch` keeps the outgoing hits
///    until the replacement lands; this dims them under a progress bar. An empty scroll reads as
///    slower than the request actually is.
/// 2. **Input is never dropped.** Every entry point is cancel-and-replace, so clicking a category
///    during a search works. The old `guard !searching` made that click do nothing at all.
/// 3. **The sort reorders the LOADED hits, client-side, and says so.** MakerWorld's search honours
///    no ordering parameter — eight names were probed and all of them shuffled the list exactly as
///    much as a nonsense value. So the server's own order is labelled "MakerWorld's order", never
///    "Relevance", and a local sort states its scope in words.
///
/// Clicking a tile changes the SELECTION and nothing else (§4): the grid does not scroll, reload or
/// navigate, because on Mac the model detail *is* the inspector.
struct MacExploreSection: View {
    let model: AppModel
    let explore: ExploreModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    @SceneStorage(MacExploreSelection.key) private var selectedId: Int?
    @FocusState private var fieldFocused: Bool

    private var caption: CGFloat { MacExploreType.caption(m) }

    /// The owner's own collections, from their Trellis.
    ///
    /// `laPushUrl`, **not** `resolvePushUrl`: collections are plain authenticated HTTP with no APNs
    /// involved, so they must not disappear when Live-Activity push is switched off. That predicate
    /// only *nearly* answered the question, and switching push off silently removed this feature.
    private var collectionsClient: CollectionsClient {
        CollectionsClient(baseUrl: model.config.flatMap(ConfigRules.laPushUrl),
                          apiKey: model.config?.apiKey ?? "")
    }

    /// Is there a Trellis to ask for folders at all?
    ///
    /// **Every place that offers a folder asks this one question.** The chip did and the cold shelf
    /// did not, so clearing the Trellis endpoint after the folders had loaded took the chip away and
    /// left the shelf's tiles clickable — straight onto a fetch with no base URL. "We have folders
    /// in hand" and "we can open one" are different questions; `collections.isEmpty` answers the
    /// first and this answers the second.
    private var canOpenCollections: Bool { collectionsClient.isAvailable }

    /// Folders belong on the cold screen only when both are true.
    private var showsCollectionShelf: Bool { canOpenCollections && !explore.collections.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(c.line2)
            content
        }
        .background(c.bg)
        .task { await bootstrap() }
        // C6 — the field searches as you type. Keyed on the text, so another character cancels this
        // and restarts the wait; `ExploreModel` then cancels the in-flight request itself and
        // `activeQuery` stops a straggler landing.
        //
        // A string that parses as a MakerWorld link is deliberately NOT searched: it becomes the
        // "Open model N" row instead. Searching for `makerworld.com/models/1400373` returns nothing
        // and looks broken.
        .task(id: explore.query) {
            guard case .search(let term) = explore.intent, term.count >= 2 else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            explore.search(term)
        }
    }

    // MARK: Pinned header

    /// Search field, the link suggestion, and the category chips — pinned above the grid.
    ///
    /// Deliberately **not** `.searchable`. On macOS that puts the field in the window toolbar, which
    /// this detail column shares with the other five sections — Explore's field would either leak
    /// into them or appear and vanish as the sidebar selection changed. The prototype draws it in
    /// content, beside its own sort control, and that is also the only place it can honestly live.
    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                searchField
                sortMenu
            }
            if case .resolve(let id) = explore.intent { openModelRow(id) }
            if !explore.navs.isEmpty || canOpenCollections { chipRow }
        }
        .padding(.horizontal, m.gutter)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }

    private var searchField: some View {
        @Bindable var explore = explore
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(11, weight: .medium)
                .foregroundStyle(c.t3)

            // "Search or paste a link" is a LABEL, not an example. The old placeholder read as a
            // value the field already held.
            TextField("Search or paste a link", text: $explore.query)
                .textFieldStyle(.plain)
                .font(.system(size: m.body))
                .foregroundStyle(c.t1)
                .focused($fieldFocused)
                .onSubmit(submit)

            if !explore.query.isEmpty {
                Button {
                    explore.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(11)
                        .foregroundStyle(c.t3)
                }
                .buttonStyle(.plain)
                // `.help` is a HINT — it is what the pointer gets on hover. VoiceOver needs the
                // control to have a NAME, and an SF Symbol supplies none, so the button announced
                // itself as "button". The sibling field in Files labels it; so does this one now.
                .accessibilityLabel("Clear search")
                .help("Clear the search field")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: m.controlHeight)
        .frame(maxWidth: .infinity)
        // `c.line`, not `c.line2`: the other two fields in this window (Files' search, Printer's)
        // both draw `c.line`, and two search fields in one window with different borders is a
        // difference nobody chose.
        .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).stroke(c.line))
    }

    /// Order. **The label is the honesty**, and it has to survive edits.
    ///
    /// `.relevance` is called "MakerWorld's order" because that is what it is: a search for `spool`
    /// comes back 2, 4, 3, 17, 5, 46 downloads in that order out of 10 000, and identical calls
    /// seconds apart differ. Naming it "Relevance" would claim a ranking nobody performed.
    private var sortMenu: some View {
        @Bindable var explore = explore
        return Menu {
            Picker("Order", selection: $explore.sort) {
                ForEach(MakerWorldSearch.Sort.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: explore.sort.isServerOrder
                      ? "arrow.up.arrow.down"
                      : "arrow.up.arrow.down.circle.fill")
                    .scaledFont(10, weight: .semibold)
                Text(explore.sort.label)
                    .font(.system(size: caption, weight: .medium))
            }
            .foregroundStyle(explore.sort.isServerOrder ? c.t3 : c.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(explore.hits.isEmpty)
        // The label is drawn, but a `Menu` announces its label view as its name only patchily and
        // the current order is the half that matters. Said explicitly, as the iOS build does.
        .accessibilityLabel("Order results. Currently \(explore.sort.label)")
        .help("MakerWorld's search API honours no ordering parameter, so anything but its own order "
              + "reorders the results already loaded.")
    }

    /// The link path, offered rather than guessed at. One row, and it says exactly what it will do.
    private func openModelRow(_ id: Int) -> some View {
        Button {
            explore.query = ""
            fieldFocused = false
            // Selecting is the whole action on Mac: the inspector resolves an id it has never seen
            // in a hit, which is exactly how a pasted link differs from a clicked tile.
            selectedId = id
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.up.forward.app")
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(c.accent)
                Text(verbatim: "Open model \(id)")
                    .font(.system(size: m.cardTitle, weight: .semibold))
                    .foregroundStyle(c.t1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .scaledFont(10, weight: .semibold)
                    .foregroundStyle(c.t3)
            }
            .padding(.horizontal, 11)
            .frame(height: m.controlHeight)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(c.accentDim))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Categories and collections. A chip that is ON is a toggle, not a one-way door — without that,
    /// the chip renders selected, the query is still in the field, and there is no way back to the
    /// results it replaced.
    private var chipRow: some View {
        MacExploreChipFlow(spacing: 7) {
            if canOpenCollections {
                let on = explore.showingCollections || explore.activeCollection != nil
                chip("My collections", symbol: "bookmark", on: on) {
                    if on { explore.exitMode() } else { explore.openCollections(collectionsClient) }
                }
            }
            ForEach(explore.navs) { nav in
                let on = explore.activeNav == nav.key
                chip(nav.name ?? nav.key, on: on) {
                    if on { explore.exitMode() } else { explore.browse(nav) }
                }
            }
        }
    }

    private func chip(_ title: String, symbol: String? = nil, on: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).scaledFont(9, weight: .semibold)
                }
                Text(title).font(.system(size: caption, weight: .semibold))
                // Says the chip is a toggle rather than a destination, so "how do I get out of this"
                // has a visible answer instead of being something to guess at.
                if on { Image(systemName: "xmark").scaledFont(8, weight: .bold).opacity(0.75) }
            }
            .foregroundStyle(on ? c.accent : c.t2)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            // `controlRadius`, not `chipRadius`, despite the name: this is a toggle the user clicks,
            // sitting in the same header as the search field and the sort menu, so it belongs to the
            // control family. `chipRadius` is for tags that only report.
            .background(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous).fill(on ? c.accentDim : c.s2))
            .overlay(RoundedRectangle(cornerRadius: m.controlRadius, style: .continuous)
                .stroke(on ? c.accent : c.line, lineWidth: on ? 1.2 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .help(on ? "Turn this off and go back to your results" : title)
    }

    // MARK: Body

    private var content: some View {
        VStack(spacing: 0) {
            // Which folder you are in, and the way back up to the folder list. Above every branch
            // because an empty folder needs both as much as a full one does.
            if let folder = explore.activeCollection { collectionCrumb(folder) }
            // A failure over results that are still on screen. See `staleNote`.
            if let error = explore.searchError, !explore.hits.isEmpty { staleNote(error) }
            resultsArea
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if let error = explore.searchError, explore.hits.isEmpty {
            MacExploreMessage(symbol: "exclamationmark.triangle",
                              title: "Couldn’t load that",
                              message: error)
        } else if explore.showingCollections {
            collectionGrid
        } else if explore.hits.isEmpty && explore.loading {
            // A skeleton of the real shape, so filling in reads as completion rather than a jump cut.
            skeletonGrid
        } else if !explore.hits.isEmpty {
            VStack(spacing: 0) {
                if !explore.sort.isServerOrder { scopeNote }
                resultGrid
            }
            // Sorting an arbitrary 20 of 10 000 by downloads gives "the most downloaded of a random
            // 20". Deepening the pool first makes the answer mean something; the note above still
            // states the scope, because even 100 of 10 000 is a sample.
            .onChange(of: explore.sort) { _, _ in explore.deepenPool(collectionsClient) }
        } else if explore.isCold {
            shelves
        } else if !explore.loading {
            emptyResult
        }
    }

    /// Nothing came back — and **which** nothing, because three states reach here with three
    /// different remedies and only one of them involves words that could be shortened.
    ///
    /// The single message told someone who had typed nothing, inside a category they had just
    /// picked, to "try fewer words, or pick a category above". A message is an affordance too: copy
    /// that names an action the user cannot take is the same defect as a control that does nothing.
    @ViewBuilder
    private var emptyResult: some View {
        if let folder = explore.activeCollection {
            MacExploreMessage(symbol: "bookmark",
                              title: "Nothing in this collection",
                              message: "“\(folder.title)” has no models in it. Add some on MakerWorld "
                                     + "and they show up here.")
        } else if let navKey = explore.activeNav {
            MacExploreMessage(symbol: "square.grid.2x2",
                              title: "Nothing in this category",
                              message: "MakerWorld returned no models under \(navName(navKey)). Pick "
                                     + "another category, or search for something.")
        } else if let query = explore.activeQuery {
            MacExploreMessage(symbol: "magnifyingglass",
                              title: "Nothing matched",
                              message: "MakerWorld returned no models for “\(query)”. Try fewer words, "
                                     + "or pick a category above.")
        } else {
            // Unreachable — `isCold` catches "nothing has been asked for" above. Kept rather than
            // forcing a query string that does not exist into the sentence.
            MacExploreMessage(symbol: "magnifyingglass",
                              title: "Nothing matched",
                              message: "MakerWorld returned no models. Try a different search, or pick "
                                     + "a category above.")
        }
    }

    /// A category's own name, falling back to its key — read the same way the chip reads it, so a
    /// message and the chip above it cannot call the same category two different things.
    private func navName(_ key: String) -> String {
        explore.navs.first { $0.key == key }?.name ?? key
    }

    /// Which folder is open, and the way back to the folder list.
    ///
    /// Both halves were missing. `ExploreModel.backToCollections` exists for exactly this and was
    /// called from neither view tree, so the only control that touched collections was the chip —
    /// and the chip answers a different question. "Leave collections and go back to my results" is
    /// what the chip's ✕ means; "show me the other folders" is what someone inside a folder is
    /// asking. Two questions, two controls; the chip is left alone.
    private func collectionCrumb(_ folder: MakerWorldCollection) -> some View {
        HStack(spacing: 7) {
            Button {
                explore.backToCollections(collectionsClient)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").scaledFont(9, weight: .bold)
                    Text("My collections").font(.system(size: caption, weight: .semibold))
                }
                .foregroundStyle(c.accent)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Back to the folder list")

            Text(verbatim: "/")
                .font(.system(size: caption))
                .foregroundStyle(c.t3)

            // A String VARIABLE, so this takes the non-Markdown `Text` overload — a folder titled
            // with a bare URL would otherwise render as a blue autolink.
            Text(folder.title)
                .font(.system(size: caption, weight: .semibold))
                .foregroundStyle(c.t1)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(verbatim: "\(folder.count) model\(folder.count == 1 ? "" : "s")")
                .font(.system(size: caption))
                .foregroundStyle(c.t3)
                .monospacedDigit()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, m.gutter)
        .padding(.top, 9)
    }

    /// A fetch that failed over results that are still good.
    ///
    /// The full-screen error state cannot cover this case and never will: Rule 1 deliberately keeps
    /// the outgoing hits, so `hits.isEmpty` is false and that branch does not fire — leaving the
    /// grid showing results for a query that is no longer in the field, with nothing anywhere saying
    /// the new one failed. "There is nothing to show" and "what is shown is stale" are two states;
    /// the first gets the screen, the second gets a line above the grid it is lying about.
    private func staleNote(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(9, weight: .semibold)
            Text(verbatim: "Couldn’t load that — these are the previous results. \(error)")
                .font(.system(size: caption, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(c.heating)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, m.gutter)
        .padding(.top, 9)
    }

    /// What the local sort actually ordered. Said out loud whenever the loaded set is a sample of
    /// something larger — "Most downloaded" over 20 of 10 000 is not what the words imply.
    private var scopeNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").scaledFont(9, weight: .semibold)
            Text(verbatim: explore.hasMore
                 ? "\(explore.sort.label) — within the \(explore.hits.count) loaded of "
                   + "\(explore.hitTotal ?? explore.hits.count). MakerWorld's search can't sort."
                 : "\(explore.sort.label) — all \(explore.hits.count) results.")
                .font(.system(size: caption, weight: .medium))
                // The loaded count ticks upward as pages land.
                .monospacedDigit()
        }
        .foregroundStyle(c.t3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, m.gutter)
        .padding(.top, 9)
    }

    /// Four-up at the prototype's 1440 width, and it reflows rather than clipping: the inspector can
    /// be hidden and the sidebar can fold, so a fixed four-column grid would leave either huge tiles
    /// or a horizontal scrollbar. `.adaptive` is the Mac answer to a window whose width is the user's.
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 168, maximum: 260), spacing: m.cardGap)]
    }

    private var resultGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: m.cardGap) {
                ForEach(Array(explore.orderedHits.enumerated()), id: \.element.id) { index, hit in
                    MacExploreCard(
                        cover: thumbUrl(hit.cover),
                        title: hit.title ?? "Untitled",
                        subtitle: creatorLine(hit),
                        badge: MakerWorldSearch.stats(hit),
                        adult: MakerWorldSearch.isAdult(hit),
                        selected: selectedId == hit.id
                    ) {
                        selectedId = hit.id
                    }
                    .contextMenu { modelMenu(hit.id) }
                    .onAppear {
                        // Prefetch rather than a "Load more" button: kick the next page when the
                        // 8th-from-last tile appears, so paging happens before the end is reached.
                        if index >= explore.hits.count - 8 { explore.loadMore(collectionsClient) }
                    }
                }
            }
            .padding(.horizontal, m.gutter)
            .padding(.vertical, m.cardGap + 2)

            if explore.loadingMore {
                ProgressView().controlSize(.small).padding(.bottom, 18)
            }
        }
        // Rule 1: while a replacement is in flight the outgoing results stay, dimmed, rather than the
        // grid blanking. Never `hits = []` first.
        .opacity(explore.loading ? 0.4 : 1)
        .overlay(alignment: .top) { if explore.loading { loadingBar } }
        .animation(Motion.standard(0.2), value: explore.loading)
    }

    /// The wait, given a shape without claiming a percentage nobody can compute. An indeterminate
    /// `ProgressView` is the platform's own version of the iOS build's hand-animated capsule.
    /// Left at its natural height on purpose: an indeterminate linear `ProgressView` draws its own
    /// sweep, and forcing it to the iOS build's 2 pt clips the animation rather than thinning it.
    private var loadingBar: some View {
        ProgressView()
            .progressViewStyle(.linear)
            .tint(c.accent)
    }

    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: m.cardGap) {
                ForEach(0..<8, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
                            .fill(c.s2)
                            .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        // A `Capsule`, not a radius: these stand in for two lines of TEXT, and at
                        // 8–10 pt tall any radius over ~4 already IS a capsule. Naming the shape
                        // instead of a number also kept these two bars off the radius scale, where
                        // they were the only `.circular` corners left in the file (the default when
                        // `style:` is omitted, which is how they got there).
                        Capsule().fill(c.s2).frame(height: 10)
                        Capsule().fill(c.s2).frame(width: 64, height: 8)
                    }
                }
            }
            .padding(.horizontal, m.gutter)
            .padding(.vertical, m.cardGap + 2)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .overlay(alignment: .top) { loadingBar }
    }

    // MARK: Collections

    @ViewBuilder
    private var collectionGrid: some View {
        if !canOpenCollections {
            // Reachable: the endpoint can be cleared in Settings while this list is on screen. The
            // folders in hand would still be clickable onto a fetch that has nowhere to go, so the
            // capability is stated instead of the stale list being drawn.
            MacExploreMessage(symbol: "bookmark.slash",
                              title: "No Trellis to ask",
                              message: "Your collections come from Trellis, the small service you run "
                                     + "beside Bambuddy. Set its endpoint in Settings › Trellis. It "
                                     + "serves collections whether or not push is switched on.")
        } else if explore.collections.isEmpty && !explore.loading {
            MacExploreMessage(symbol: "bookmark",
                              title: "No collections",
                              message: "Collections you make on MakerWorld show up here.")
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: m.cardGap) {
                    ForEach(explore.collections) { folder in
                        MacExploreCard(
                            cover: thumbUrl(folder.cover),
                            title: folder.title,
                            subtitle: "\(folder.count) model\(folder.count == 1 ? "" : "s")",
                            badge: "",
                            adult: false,
                            selected: false
                        ) {
                            explore.openCollection(folder, client: collectionsClient)
                        }
                    }
                }
                .padding(.horizontal, m.gutter)
                .padding(.vertical, m.cardGap + 2)
            }
            .opacity(explore.loading ? 0.4 : 1)
            .overlay(alignment: .top) { if explore.loading { loadingBar } }
        }
    }

    // MARK: Cold start

    /// What Explore shows before anything has been asked for.
    ///
    /// Built only from what is already in hand — `ExploreModel.recent` and `.collections`. A shelf
    /// that fired its own request would make the cold screen slower than the empty field it replaced.
    ///
    /// Laid out as grid sections rather than the iOS horizontal scrollers: a Mac window is wide, and
    /// content hidden off the right edge of a pointer-driven window is content nobody finds.
    @ViewBuilder
    private var shelves: some View {
        if !showsCollectionShelf && explore.recent.isEmpty {
            MacExploreMessage(symbol: "square.grid.2x2",
                              title: "Find something to print",
                              message: "Search MakerWorld, pick a category above, or paste a link to a "
                                     + "model you already have open.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: m.sectionGap + 6) {
                    // Gated on the same question the chip is gated on — see `canOpenCollections`.
                    // Folders held over from a session that HAD a Trellis are not folders that can
                    // be opened now.
                    if showsCollectionShelf {
                        shelf("YOUR COLLECTIONS") {
                            ForEach(explore.collections.prefix(8)) { folder in
                                MacExploreCard(
                                    cover: thumbUrl(folder.cover),
                                    title: folder.title,
                                    subtitle: "\(folder.count) model\(folder.count == 1 ? "" : "s")",
                                    badge: "", adult: false, selected: false
                                ) {
                                    explore.openCollection(folder, client: collectionsClient)
                                }
                            }
                        }
                    }
                    if !explore.recent.isEmpty {
                        shelf("RECENTLY IMPORTED") {
                            ForEach(explore.recent) { item in
                                // The model id is not stored — it is recovered from the source URL
                                // with the same parser the field uses, so a recent row and a pasted
                                // link cannot disagree about what a MakerWorld URL means.
                                let modelId = recoveredModelId(item)
                                MacExploreCard(
                                    cover: nil,
                                    title: item.filename ?? "Model",
                                    subtitle: modelId == nil ? "no link stored" : nil,
                                    badge: "", adult: false,
                                    selected: modelId.map { $0 == selectedId } ?? false
                                ) {
                                    if let modelId { selectedId = modelId }
                                }
                                // Gated on the exact thing it needs — a link to open — rather than on
                                // "it is a recent import". A row with no stored URL says so and does
                                // not pretend to be clickable.
                                .disabled(modelId == nil)
                            }
                        }
                    }
                }
                .padding(.horizontal, m.gutter)
                .padding(.vertical, m.cardGap + 4)
            }
        }
    }

    private func shelf<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.mono(m.monoLabel, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(c.t3)
            LazyVGrid(columns: gridColumns, spacing: m.cardGap) { content() }
        }
    }

    /// `by hexbench`, or nothing. An absent creator is left off rather than rendered as "by —".
    private func creatorLine(_ hit: MWSearchHit) -> String? {
        guard let name = hit.designCreator?.name, !name.isEmpty else { return nil }
        return "by \(name)"
    }

    private func recoveredModelId(_ item: MakerWorldRecentImport) -> Int? {
        if case .resolve(let id) = MakerWorldSearch.intent(for: item.sourceUrl ?? "") { return id }
        return nil
    }

    // MARK: Menus and actions

    /// The two things a Mac user expects from a right-click on a tile. Neither navigates — the
    /// inspector is where a model is looked at, and a context menu that changed sections would make
    /// the grid a second navigation surface.
    @ViewBuilder
    private func modelMenu(_ id: Int) -> some View {
        Button("Show details") { selectedId = id }
        Divider()
        if let url = MakerWorld.webUrl(modelId: id) {
            Link("Open on MakerWorld", destination: url)
            Button("Copy link") { copyToPasteboard(url.absoluteString) }
        }
    }

    private func copyToPasteboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        // The Bool says whether the pasteboard accepted it; there is nothing useful to do with a
        // refusal from the general pasteboard, so it is discarded deliberately rather than ignored.
        _ = board.setString(text, forType: .string)
    }

    private func thumbUrl(_ cdn: String?) -> URL? { model.client?.makerworldThumbUrl(cdn) }

    private func submit() {
        switch explore.intent {
        case .idle:
            return
        case .resolve(let id):
            explore.query = ""
            fieldFocused = false
            selectedId = id
        case .search(let q):
            fieldFocused = false
            explore.search(q)
        }
    }

    /// The one-time session setup: can we import, what may we browse, and what has already landed.
    ///
    /// Each leg is guarded so re-entering Explore does not re-ask — the browse session is meant to
    /// survive leaving the section, and three refetches on every return is the thing `ExploreModel`
    /// exists to stop.
    ///
    /// A nav failure is silent on purpose: browse simply does not appear, and the field still
    /// searches and still opens links.
    private func bootstrap() async {
        guard let client = model.client else { return }
        if explore.access.worthRetrying || explore.access == .checking {
            explore.access = await client.makerWorldAccess()
        }
        if explore.navs.isEmpty {
            explore.navs = MakerWorldSearch.browsable((try? await explore.searchClient.navs()) ?? [])
        }
        if explore.recent.isEmpty {
            explore.recent = await client.recentMakerWorldImports()
        }
    }
}

// MARK: - Pieces

/// One tile: cover, counts on the cover, title, and one line under it.
///
/// The counts sit ON the cover in a scrim so the text beneath is two lines rather than four — four
/// lines of metadata under a 4:3 image made the grid mostly text.
private struct MacExploreCard: View {
    let cover: URL?
    let title: String
    let subtitle: String?
    let badge: String
    let adult: Bool
    let selected: Bool
    let action: () -> Void

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // `ThumbCache`, not `AsyncImage`: a bare AsyncImage in a grid re-fetches and
                // re-decodes every cover on the way back up, so the grid gets slower the more of it
                // you have seen.
                CachedThumb(url: cover, aspect: 4.0 / 3.0)
                    .overlay(alignment: .bottomTrailing) {
                        if !badge.isEmpty {
                            Text(badge)
                                .font(.mono(m.monoLabel, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .background {
                                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)],
                                                   startPoint: .top, endPoint: .bottom)
                                }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        // Marked, not hidden: silently dropping hits would contradict the result
                        // count the same response reports.
                        if adult {
                            Text("18+")
                                .font(.mono(m.monoLabel - 1, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(Capsule().fill(.black.opacity(0.65)))
                                .padding(5)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: m.cardTitle, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle {
                        Text(subtitle)
                            .font(.mono(m.monoLabel, weight: .medium))
                            .foregroundStyle(c.t3)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            .background(c.s1)
            .clipShape(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous))
            // On the composite, never inside the overlay: an overlay does not clip to its base, and a
            // `.fill` image is flexible, so a clipShape in there would clip nothing.
            .overlay(
                RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
                    .stroke(selected ? c.accent : (hovering ? c.line2 : c.line),
                            lineWidth: selected ? 1.5 : 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.standard(0.12), value: hovering)
        .animation(Motion.standard(0.15), value: selected)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A plain message block, used where `ContentUnavailableView` would throw away the server's own
/// sentence — MakerWorld's failure strings each name the machine at fault and must survive intact.
private struct MacExploreMessage: View {
    let symbol: String
    let title: String
    let message: String

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .scaledFont(26, weight: .light)
                .foregroundStyle(c.t3)
            // Two points over a card heading: an empty state's title has to out-rank the sentence
            // under it, and `screenTitle` is the toolbar's size, not a body-copy heading.
            Text(title)
                .font(.system(size: m.cardTitle + 2, weight: .semibold))
                .foregroundStyle(c.t1)
            Text(verbatim: message)
                .font(.system(size: m.body))
                .foregroundStyle(c.t2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Chips that wrap onto as many rows as they need.
///
/// A horizontal `ScrollView` was the iOS answer and is the wrong one here: on a pointer-driven
/// window, categories parked off the right edge are categories nobody discovers, and there is no
/// scroll indicator to say they exist. Wrapping keeps every chip visible at every window width, and
/// keeps the content column from ever scrolling sideways.
///
/// **Known duplication.** `FlowLayout` (`AmsView`, `WizardView`) and `ActionFlow` (`AlertsOverlay`)
/// are the same algorithm; all three are `#if os(iOS)`, which is why this exists rather than reusing
/// one. The fix is one tested type in `Views/Components/`, which touches four files this pass does
/// not own — it is reported rather than half-done here.
private struct MacExploreChipFlow: Layout {
    var spacing: CGFloat = 7

    /// Row-break the subviews at their natural sizes. Called from both protocol methods with the
    /// same width, so the measured size and the placed positions cannot disagree.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (points, CGSize(width: widest, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arranged = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? arranged.size.width, height: arranged.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let arranged = arrange(subviews, width: bounds.width)
        for (view, point) in zip(subviews, arranged.points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                       anchor: .topLeading,
                       proposal: ProposedViewSize(view.sizeThatFits(.unspecified)))
        }
    }
}
#endif
