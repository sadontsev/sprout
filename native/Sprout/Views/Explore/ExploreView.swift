#if os(iOS)
// iOS layout. macOS: Views/Mac/Sections/MacExploreSection.
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI

/// MakerWorld, as a page.
///
/// **It used to be a sheet pretending to be a screen.** `MakerWorldPanel` lived inside a
/// `fullScreenCover` that painted its own scrim and card, capped itself at 88 % of the screen, and
/// had to measure its own content (`onGeometryChange` → `contentHeight` → `.frame(maxHeight:)`) to
/// stop a greedy `ScrollView` floating the card in mid-screen. Four ways in, an 88-row picker and a
/// gallery all lived in that box. The comment block explaining the centring bug was the tell: the
/// container was fighting the content.
///
/// A `NavigationStack` replaces all of it — the scrim, the grabber, the measured height and the
/// `maxHeight` frame are simply deleted. Pushing the detail also buys the thing that was missing
/// most: a back button that returns to the results you came from, with the query still in the field
/// and the grid where you left it, because the session now lives in `ExploreModel` rather than in
/// this view's `@State`.
struct ExploreView: View {
    let model: AppModel
    let client: BambuddyClient
    /// Fires once a file has landed in the library, so a list already on screen can refetch.
    var onImported: (() -> Void)?
    @Environment(\.palette) private var c
    @Environment(ExploreModel.self) private var explore

    @FocusState private var fieldFocused: Bool
    @Namespace private var tiles

    var body: some View {
        @Bindable var explore = explore
        return NavigationStack(path: $explore.path) {
            ExploreRoot(model: model, client: client, onImported: onImported,
                        fieldFocused: $fieldFocused, tiles: tiles)
                .navigationTitle("MakerWorld")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Restored: the sort control was lost when Explore moved off the old sheet, so
                    // the grid sorted but nothing could ask it to.
                    ToolbarItem(placement: .topBarLeading) {
                        // Hidden, not merely inert, inside a collection: Trellis serves a folder in
                        // MakerWorld's own order and takes no `orderBy`, so an order control there
                        // would be offering a capability the other end does not have.
                        if !explore.hits.isEmpty, explore.acceptsMakerWorldRequest {
                            Menu {
                                Picker("Order", selection: Binding(get: { explore.sort },
                                                                   set: { explore.setSort($0) })) {
                                    ForEach(MakerWorldSearch.Sort.allCases) { Text($0.label).tag($0) }
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                            }
                            .accessibilityLabel("Order results. Currently \(explore.sort.label).")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { model.overlay = nil }
                    }
                }
                .navigationDestination(for: MWSearchHit.self) { hit in
                    ModelDetailView(model: model, client: client, hit: hit, onImported: onImported)
                        // C1's other half: the tapped tile visibly BECOMES the page, so the
                        // transition itself is the feedback rather than a spinner somewhere above.
                        .navigationTransition(.zoom(sourceID: hit.id, in: tiles))
                }
        }
        .tint(c.accent)
        .task {
            // Only on the first arrival — re-entering an existing session should not re-ask.
            if explore.access.worthRetrying || explore.access == .checking {
                explore.access = await client.makerWorldAccess()
            }
            if explore.navs.isEmpty {
                // MakerWorld's own taxonomy rather than a hardcoded copy. A failure is silent on
                // purpose: browse simply does not appear, and the field still searches and opens
                // links.
                explore.navs = MakerWorldSearch.browsable((try? await explore.searchClient.navs()) ?? [])
            }
            if explore.recent.isEmpty {
                explore.recent = await client.recentMakerWorldImports()
            }
            explore.loadColdStart()
        }
    }
}

/// The results page itself: a pinned field and chips over a grid that scrolls under them.
private struct ExploreRoot: View {
    let model: AppModel
    let client: BambuddyClient
    var onImported: (() -> Void)?
    @FocusState.Binding var fieldFocused: Bool
    let tiles: Namespace.ID

    @Environment(\.palette) private var c
    @Environment(ExploreModel.self) private var explore

    @State private var showFilters = false

    /// The owner's own collections, from their Trellis.
    ///
    /// `laPushUrl`, **not** `resolvePushUrl`: collections are plain authenticated HTTP with no APNs
    /// involved, so they must not disappear when Live-Activity push is switched off.
    private var collectionsClient: CollectionsClient {
        CollectionsClient(baseUrl: model.config.flatMap(ConfigRules.laPushUrl),
                          apiKey: model.config?.apiKey ?? "")
    }

    var body: some View {
        @Bindable var explore = explore
        return VStack(spacing: 0) {
            // Pinned, not scrolled. The chips used to live inside the ScrollView, so the categories
            // vanished the moment you looked at any results (F6).
            searchField
            if case .resolve(let id) = explore.intent { openModelSuggestion(id) }
            if fieldFocused, !explore.suggestions.isEmpty { suggestionRows }
            // The row itself is unconditional: gating it on the category list would make it
            // vanish whenever `homepage/nav` fails, and collections are reached from it.
            chips
            Divider().overlay(c.line2)

            content
        }
        .background(c.bg)
        .sheet(isPresented: $showFilters) {
            // The stored `printerCode` is a snapshot from whenever the toggle was last switched on.
            // Reconciled here rather than trusted: see `MWSearchFilters.reconciled(printerCode:)`.
            let code = MWPrinterCode.code(forModel: model.printer?.model)
            ExploreFilterSheet(draft: explore.filters.reconciled(printerCode: code),
                               printerCode: code,
                               printerModel: model.printer?.model) { explore.setFilters($0) }
        }
        // C6 — the field used to fire only on submit, so every query cost a tap. Keyed on the text,
        // so typing another character cancels this and restarts the wait; `ExploreModel` then
        // cancels the in-flight request itself, and `activeQuery` stops a straggler landing.
        //
        // A string that parses as a MakerWorld link is deliberately NOT searched: it becomes the
        // suggestion row above instead. Searching for "makerworld.com/models/1400373" would return
        // nothing and look broken, and retitling the button was the old way of saying so.
        .task(id: explore.query) {
            guard case .search(let term) = explore.intent else { explore.suggestions = []; return }
            guard term.count >= 2 else { explore.suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Tapping a suggestion or a hot word already calls `search(term)` directly, for an
            // instant result rather than a 300ms wait. Without this guard the debounce still fires
            // afterward and repeats the identical request — one tap, one search.
            guard term != explore.activeQuery else { return }
            // `search` clears `suggestions` and `suggest` writes them back only while the field
            // still matches, so suggesting has to come second or it is wiped by its own search.
            explore.search(term)
            explore.suggest(term)
        }
    }

    /// MakerWorld's own completions. Tapping one submits it, exactly as typing it would.
    private var suggestionRows: some View {
        VStack(spacing: 0) {
            ForEach(explore.suggestions, id: \.self) { s in
                Tap {
                    explore.query = s
                    fieldFocused = false
                    explore.search(s)
                } content: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").scaledFont(12).foregroundStyle(c.t3)
                        Text(verbatim: s).scaledFont(14).foregroundStyle(c.t1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .contentShape(.rect)
                }
            }
        }
        .padding(.bottom, 6)
    }

    /// The link path, offered rather than guessed at. One row, and it says exactly what it will do.
    private func openModelSuggestion(_ id: Int) -> some View {
        Tap {
            var hit = MWSearchHit(id: id)
            hit.title = "Model \(id)"
            explore.query = ""
            fieldFocused = false
            explore.path.append(hit)
        } content: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.forward.app")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(c.accent)
                Text(verbatim: "Open model \(id)")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(c.t1)
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(c.t3)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.accentDim))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .contentShape(.rect)
        }
    }

    // MARK: Pinned header

    private var searchField: some View {
        @Bindable var explore = explore
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .scaledFont(15, weight: .medium)
                .foregroundStyle(c.t3)

            // "Search or paste a link" is a LABEL. The old placeholder was an example
            // ("benchy, or a makerworld.com link"), which reads as a value the field already holds.
            TextField("Search or paste a link", text: $explore.query)
                .textFieldStyle(.plain)
                .scaledFont(15)
                .foregroundStyle(c.t1)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($fieldFocused)
                .onSubmit(submit)

            if !explore.query.isEmpty {
                Tap { explore.query = "" } content: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(15)
                        .foregroundStyle(c.t3)
                }
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                // Same reason as the sort menu: a folder's contents are the folder's, unfiltered.
                if explore.acceptsMakerWorldRequest {
                    let n = explore.filters.activeCount
                    chip(n == 0 ? "Filters" : "Filters · \(n)", symbol: "line.3.horizontal.decrease",
                         on: n > 0, toggleable: false) {
                        showFilters = true
                    }
                }
                if collectionsClient.isAvailable {
                    let on = explore.showingCollections || explore.activeCollection != nil
                    // Tapping the selected chip turns it OFF and restores what was underneath.
                    // Without this the chip is a one-way door: it looks selected, the query is still
                    // in the field, and there is no way back to the results it replaced.
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
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 10)
    }

    /// `toggleable` says whether tapping this chip again would turn it off. Every chip here is one
    /// EXCEPT Filters: tapping it always reopens the sheet, so drawing the xmark and the "turns
    /// this off" hint on it would claim a capability it does not have — the same shape as the
    /// LAN-mode buttons and the menu-bar predicate this codebase keeps re-learning about. `on`
    /// still drives the selected look and the `.isSelected` trait for Filters, because a filter
    /// really is active; only the "this is a toggle" affordance is withheld.
    private func chip(_ title: String, symbol: String? = nil, on: Bool, toggleable: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Tap(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).scaledFont(11, weight: .semibold)
                }
                Text(title).scaledFont(13, weight: .semibold)
                // Says the chip is a toggle rather than a destination, so "how do I get out of
                // this" has a visible answer instead of being a thing you have to guess.
                if on, toggleable {
                    Image(systemName: "xmark")
                        .scaledFont(9, weight: .bold)
                        .opacity(0.75)
                }
            }
            .foregroundStyle(on ? c.accent : c.t2)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Capsule().fill(on ? c.accentDim : c.s2))
            .overlay { Capsule().stroke(c.accent, lineWidth: on ? 1.5 : 0) }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(toggleable ? (on ? "Turns this off and returns to your results" : "")
                                      : "Opens the filters")
    }

    // MARK: Body

    private var content: some View {
        VStack(spacing: 0) {
            // A failure over results that are still good — see `staleNote`.
            if let error = explore.searchError, !explore.hits.isEmpty { staleNote(error) }
            resultsArea
        }
    }

    /// A fetch that failed over results that are still on screen.
    ///
    /// The full-screen error state cannot cover this case and never will: `startFetch` deliberately
    /// keeps the outgoing hits, so `hits.isEmpty` is false and that branch does not fire — leaving
    /// the grid showing results for a sort or a filter that is no longer what the controls say,
    /// with nothing anywhere admitting the new one failed. "There is nothing to show" and "what is
    /// shown is stale" are two states; the first gets the screen, the second gets a line above the
    /// grid it is lying about. The Mac build has drawn this since the port; iOS showed nothing.
    private func staleNote(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").scaledFont(11, weight: .semibold)
            Text(verbatim: "Couldn’t load that — these are the previous results. \(error)")
                .scaledFont(12)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(c.t2)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var resultsArea: some View {
        if let error = explore.searchError, explore.hits.isEmpty {
            ExploreMessage(symbol: "exclamationmark.triangle", title: "Couldn’t load that", message: error)
        } else if explore.showingCollections {
            collectionList
        } else if explore.hits.isEmpty && explore.loading {
            // A skeleton of the real shape, so filling in reads as completion rather than a jump cut.
            ExploreSkeletonGrid()
        } else if !explore.hits.isEmpty {
            grid
        } else if explore.isCold {
            ExploreShelves(client: client, collectionsClient: collectionsClient)
        } else if !explore.loading {
            ContentUnavailableView.search
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 14) {
                ForEach(Array(explore.hits.enumerated()), id: \.element.id) { index, hit in
                    NavigationLink(value: hit) {
                        ExploreTile(hit: hit, client: client)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: hit.id, in: tiles)
                    .onAppear {
                        // Prefetch rather than a Load more button (F9): kick the next page when the
                        // 8th-from-last tile appears, so paging happens before the user reaches the end.
                        if index >= explore.hits.count - 8 { explore.loadMore(collectionsClient) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if explore.loadingMore {
                ProgressView().tint(c.t3).padding(.bottom, 20)
            }

            if let note = explore.loadMoreError {
                HStack(spacing: 8) {
                    Text(verbatim: note)
                        .scaledFont(12)
                        .foregroundStyle(c.t2)
                    Button("Retry") {
                        // `loadMore` now refuses to run again while `loadMoreError` is set — see
                        // the comment on it — so the button clears it first rather than the retry
                        // silently doing nothing.
                        explore.loadMoreError = nil
                        explore.loadMore(collectionsClient)
                    }
                    .scaledFont(12, weight: .semibold)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        // C5: while a replacement is in flight the outgoing results stay, dimmed, rather than the
        // grid blanking — an empty scroll reads as slower than the request actually is.
        .opacity(explore.loading ? 0.4 : 1)
        .overlay(alignment: .top) {
            if explore.loading { ExploreLoadingBar() }
        }
        .animation(Motion.standard(0.2), value: explore.loading)
    }

    @ViewBuilder
    private var collectionList: some View {
        if explore.collections.isEmpty && !explore.loading {
            ExploreMessage(symbol: "bookmark",
                           title: "No collections",
                           message: "Collections you make on MakerWorld show up here.")
        } else {
            List(explore.collections) { folder in
                Tap { explore.openCollection(folder, client: collectionsClient) } content: {
                    HStack(spacing: 12) {
                        CachedThumb(url: client.makerworldThumbUrl(folder.cover), size: CGSize(width: 52, height: 52))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(folder.title)
                                .scaledFont(15, weight: .semibold)
                                .foregroundStyle(c.t1)
                            Text("\(folder.count) model\(folder.count == 1 ? "" : "s")")
                                .scaledMono(11.5, weight: .medium)
                                .foregroundStyle(c.t3)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .scaledFont(14, weight: .semibold)
                            .foregroundStyle(c.t3)
                    }
                    .contentShape(.rect)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func submit() {
        switch explore.intent {
        case .idle:
            return
        case .resolve(let id):
            // A pasted link takes the SAME path a tapped tile does — the detail page resolves it.
            // Search adds entry points, not a second flow.
            var hit = MWSearchHit(id: id)
            hit.title = "Model \(id)"
            explore.query = ""
            fieldFocused = false
            explore.path.append(hit)
        case .search(let q):
            fieldFocused = false
            explore.search(q)
        }
    }
}

// MARK: - Pieces

/// A result tile. Counts sit ON the cover in a scrim so the text underneath is two lines, not four
/// (F7) — four lines of metadata under a 4:3 image made the grid mostly text.
struct ExploreTile: View {
    let hit: MWSearchHit
    let client: BambuddyClient
    @Environment(\.palette) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CachedThumb(url: client.makerworldThumbUrl(hit.cover), aspect: 4.0 / 3.0)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    let stats = MakerWorldSearch.stats(hit)
                    if !stats.isEmpty {
                        Text(stats)
                            .scaledMono(10.5, weight: .semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if MakerWorldSearch.isAdult(hit) {
                        Text("18+")
                            .scaledMono(9, weight: .bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if hit.isStaffPicked == true {
                        Text("Featured")
                            .scaledMono(9, weight: .bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(c.accent.opacity(0.85)))
                            .padding(6)
                    }
                }

            Text(hit.title ?? "Untitled")
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(c.t1)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let by = hit.designCreator?.name, !by.isEmpty {
                Text(verbatim: "@\(by)")
                    .scaledMono(10.5, weight: .medium)
                    .foregroundStyle(c.t3)
                    .lineLimit(1)
            }
        }
    }
}

/// The shape the content will take, shown while it loads.
struct ExploreSkeletonGrid: View {
    @Environment(\.palette) private var c

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 14) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(c.s2)
                            .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 4).fill(c.s2).frame(height: 11)
                        RoundedRectangle(cornerRadius: 4).fill(c.s2).frame(width: 70, height: 9)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .overlay(alignment: .top) { ExploreLoadingBar() }
    }
}

/// A 2 pt indeterminate bar under the header. Gives the wait a shape without claiming a percentage
/// nobody can compute.
struct ExploreLoadingBar: View {
    @Environment(\.palette) private var c
    @State private var shift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(c.accent)
                .frame(width: geo.size.width * 0.35, height: 2)
                .offset(x: shift ? geo.size.width * 0.65 : -geo.size.width * 0.0)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shift)
        }
        .frame(height: 2)
        // HIDDEN under Reduce Motion, not stopped — the only site here where freezing would lie.
        // The rest offset is `-geo.size.width * 0.0`, i.e. ZERO, so a stopped bar is a 35 %-wide
        // capsule parked at the left edge: a determinate bar apparently stuck at 35 %. This view
        // exists (see its own comment) to give the wait a shape "without claiming a percentage
        // nobody can compute", and freezing it claims exactly that percentage. The redacted
        // skeleton grid underneath already says "loading".
        .opacity(reduceMotion ? 0 : 1)
        .onAppear { if !reduceMotion { shift = true } }
    }
}

/// A plain message block. Used where `ContentUnavailableView` would not carry the server's own
/// sentence — MakerWorld's failure strings each name the machine at fault and must survive intact.
struct ExploreMessage: View {
    let symbol: String
    let title: String
    let message: String
    @Environment(\.palette) private var c

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .scaledFont(30, weight: .light)
                .foregroundStyle(c.t3)
            Text(title)
                .scaledFont(16, weight: .semibold)
                .foregroundStyle(c.t1)
            Text(verbatim: message)
                .scaledFont(13)
                .foregroundStyle(c.t2)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
