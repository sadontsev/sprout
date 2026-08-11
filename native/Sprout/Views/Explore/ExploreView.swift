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
                        if !explore.hits.isEmpty {
                            Menu {
                                Picker("Order", selection: $explore.sort) {
                                    ForEach(MakerWorldSearch.Sort.allCases) { Text($0.label).tag($0) }
                                }
                            } label: {
                                Image(systemName: explore.sort.isServerOrder
                                      ? "arrow.up.arrow.down"
                                      : "arrow.up.arrow.down.circle.fill")
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

    /// The owner's own collections, from their la-push.
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
            if !explore.navs.isEmpty || collectionsClient.isAvailable { chips }
            Divider().overlay(c.line2)

            content
        }
        .background(c.bg)
        // C6 — the field used to fire only on submit, so every query cost a tap. Keyed on the text,
        // so typing another character cancels this and restarts the wait; `ExploreModel` then
        // cancels the in-flight request itself, and `activeQuery` stops a straggler landing.
        //
        // A string that parses as a MakerWorld link is deliberately NOT searched: it becomes the
        // suggestion row above instead. Searching for "makerworld.com/models/1400373" would return
        // nothing and look broken, and retitling the button was the old way of saying so.
        .task(id: explore.query) {
            guard case .search(let term) = explore.intent else { return }
            guard term.count >= 2 else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            explore.search(term)
        }
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.accent)
                Text(verbatim: "Open model \(id)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.t1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(c.t3)

            // "Search or paste a link" is a LABEL. The old placeholder was an example
            // ("benchy, or a makerworld.com link"), which reads as a value the field already holds.
            TextField("Search or paste a link", text: $explore.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(c.t1)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($fieldFocused)
                .onSubmit(submit)

            if !explore.query.isEmpty {
                Tap { explore.query = "" } content: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
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

    private func chip(_ title: String, symbol: String? = nil, on: Bool,
                      action: @escaping () -> Void) -> some View {
        Tap(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .semibold))
                // Says the chip is a toggle rather than a destination, so "how do I get out of
                // this" has a visible answer instead of being a thing you have to guess.
                if on {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
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
        .accessibilityHint(on ? "Turns this off and returns to your results" : "")
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if let error = explore.searchError, explore.hits.isEmpty {
            ExploreMessage(symbol: "exclamationmark.triangle", title: "Couldn’t load that", message: error)
        } else if explore.showingCollections {
            collectionList
        } else if explore.hits.isEmpty && explore.loading {
            // A skeleton of the real shape, so filling in reads as completion rather than a jump cut.
            ExploreSkeletonGrid()
        } else if !explore.hits.isEmpty {
            VStack(spacing: 0) {
                if !explore.sort.isServerOrder { scopeNote }
                grid
            }
            .onChange(of: explore.sort) { _, _ in explore.deepenPool(collectionsClient) }
        } else if explore.isCold {
            ExploreShelves(client: client, collectionsClient: collectionsClient)
        } else if !explore.loading {
            ContentUnavailableView.search
        }
    }

    /// What the local sort actually ordered. Says it out loud whenever the loaded set is a sample
    /// of something larger — "Most downloaded" over 20 of 10 000 is not what the words imply.
    private var scopeNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .semibold))
            Text(verbatim: explore.hasMore
                 ? "\(explore.sort.label) — within the \(explore.hits.count) loaded of \(explore.hitTotal ?? explore.hits.count). MakerWorld's search can't sort."
                 : "\(explore.sort.label) — all \(explore.hits.count) results.")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(c.t3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 14) {
                ForEach(Array(explore.orderedHits.enumerated()), id: \.element.id) { index, hit in
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
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(c.t1)
                            Text("\(folder.count) model\(folder.count == 1 ? "" : "s")")
                                .font(.mono(11.5, weight: .medium))
                                .foregroundStyle(c.t3)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
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
                            .font(.mono(10.5, weight: .semibold))
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
                            .font(.mono(9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .padding(6)
                    }
                }

            Text(hit.title ?? "Untitled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.t1)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let by = hit.designCreator?.name, !by.isEmpty {
                Text(verbatim: "@\(by)")
                    .font(.mono(10.5, weight: .medium))
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

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(c.accent)
                .frame(width: geo.size.width * 0.35, height: 2)
                .offset(x: shift ? geo.size.width * 0.65 : -geo.size.width * 0.0)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shift)
        }
        .frame(height: 2)
        .onAppear { shift = true }
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
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(c.t3)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(c.t1)
            Text(verbatim: message)
                .font(.system(size: 13))
                .foregroundStyle(c.t2)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
