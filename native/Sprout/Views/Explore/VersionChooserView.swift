#if os(iOS)
// iOS layout. macOS: Views/Mac/Sections/MacExploreSection.
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI

/// Choosing which of a model's versions to import.
///
/// The sharpest problem in the app, and a **data** problem before it is a UI one — see
/// `VersionGrouping` for the measurements and the six rules this screen exists to keep. In short: a
/// model publishes up to 88 versions, 51 of them publish no settings at all, and the axes a user
/// wants (speed, material, filament) are therefore absent on most rows. Every affordance here is
/// gated on data that actually exists, and where it does not exist the screen says so in words.
struct VersionChooserView: View {
    let model: AppModel
    let client: BambuddyClient
    let rows: [MWProfileRow]
    let design: MWDesign?
    @Binding var picked: MWProfileRow?

    @Environment(\.palette) private var c
    @Environment(\.dismiss) private var dismiss

    @State private var sort: VersionGrouping.Sort = .recommended
    @State private var filter = VersionGrouping.Filter()
    @State private var showFilter = false
    @State private var unlabelledExpanded = false
    /// Which version the full-screen gallery opens on, as an index into `visible`.
    @State private var galleryStart: Int?

    /// What the AMS can currently supply. Empty when nothing is loaded or the status has not
    /// arrived — and then no row is called unprintable, because "we don't know" and "you don't have
    /// it" are different facts and only one of them justifies greying a row out.
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

    private var placed: [VersionGrouping.Placed] {
        VersionGrouping.place(rows, defaultInstanceId: design?.defaultInstanceId,
                              trays: loadedTrays)
    }

    private var visible: [VersionGrouping.Placed] {
        VersionGrouping.sorted(VersionGrouping.apply(filter, to: placed), by: sort)
    }

    var body: some View {
        List {
            ForEach(VersionGrouping.Group.allCases) { group in
                let items = visible.filter { $0.group == group }
                if !items.isEmpty {
                    if group.isUnlabelled {
                        unlabelledSection(items)
                    } else {
                        Section {
                            ForEach(items) { row(  $0) }
                        } header: {
                            Text(verbatim: "\(group.title) · \(items.count)")
                                .scaledMono(11, weight: .bold)
                                .foregroundStyle(c.t3)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(c.bg)
        .navigationTitle("Choose a version")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { countBar }
        .safeAreaInset(edge: .bottom) { pickBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(VersionGrouping.Sort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilter = true } label: {
                    Image(systemName: filter.isActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { galleryStart != nil }, set: { if !$0 { galleryStart = nil } }
        )) {
            NavigationStack {
                VersionGallery(items: visible, client: client,
                               startAt: galleryStart ?? 0, picked: $picked)
            }
        }
        .sheet(isPresented: $showFilter) {
            VersionFilterSheet(filter: $filter,
                               materials: VersionGrouping.materialsPresent(rows),
                               resultCount: { VersionGrouping.apply($0, to: placed).count },
                               loadedSpools: printableMaterials.sorted())
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Bars

    /// Rule 2 — the count says what is true, not what sounds tidy.
    private var countBar: some View {
        let unlabelled = placed.filter(\.isUnlabelled).count
        return Text(VersionGrouping.countLine(matching: visible.count,
                                              total: placed.count,
                                              unlabelled: unlabelled))
            .scaledMono(11.5, weight: .semibold)
            .foregroundStyle(c.t3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
    }

    /// The current pick, visible from row 60 — otherwise choosing is a memory test.
    private var pickBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(c.line2)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(picked == nil ? "No version chosen" : picked!.title)
                        .scaledFont(13.5, weight: .semibold)
                        .foregroundStyle(c.t1)
                        .lineLimit(1)
                    if let d = picked?.detail {
                        Text(MakerWorld.metaLine(d))
                            .scaledMono(11, weight: .medium)
                            .foregroundStyle(c.t3)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Tap { dismiss() } content: {
                    Text("Use this")
                        .scaledFont(14, weight: .bold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Capsule().fill(picked == nil ? c.s3 : c.accent))
                }
                .disabled(picked == nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: Rows

    private func row(_ item: VersionGrouping.Placed) -> some View {
        let selected = picked?.id == item.row.id
        // Rule 6 — shown, greyed, with the remedy. Never hidden, and never silently unselectable
        // without saying why.
        let blocked = item.group == .needsFilament

        return VStack(alignment: .leading, spacing: 0) {
            Tap { picked = item.row } content: {
                HStack(alignment: .top, spacing: 11) {
                    versionThumb(item.row)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.row.title)
                                .scaledFont(13.5, weight: .semibold)
                                .foregroundStyle(c.t1)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            ForEach(item.marks, id: \.self) { mark in
                                Text(mark)
                                    .scaledMono(8.5, weight: .bold)
                                    .foregroundStyle(c.accent)
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(c.accentDim))
                            }
                        }

                        if let detail = item.row.detail {
                            HStack(spacing: 8) {
                                Text(MakerWorld.metaLine(detail))
                                    .scaledMono(11, weight: .medium)
                                    .foregroundStyle(c.t3)
                                ForEach(Array(detail.slots.prefix(4).enumerated()), id: \.offset) { _, sl in
                                    Swatch(value: FilamentColor.norm(sl.color), size: 9, radius: 5)
                                }
                            }
                            if let remedy = item.remedy {
                                Text(verbatim: remedy)
                                    .scaledMono(11, weight: .semibold)
                                    .foregroundStyle(c.heating)
                            }
                        } else {
                            // The absent state, said in words rather than rendered as "—".
                            Text("No settings published")
                                .scaledMono(11, weight: .medium)
                                .foregroundStyle(c.t3)
                        }

                        if item.row.summary == nil && item.row.pictures.isEmpty {
                            Text("No photos or notes published")
                                .scaledFont(11)
                                .foregroundStyle(c.t3.opacity(0.8))
                        }
                    }

                    Spacer(minLength: 0)

                    if selected {
                        Image(systemName: "checkmark")
                            .scaledFont(15, weight: .bold)
                            .foregroundStyle(c.accent)
                    }
                }
                .opacity(blocked ? 0.55 : 1)
                .contentShape(.rect)
            }
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)

            // Depth two of three, and only for the row you have actually chosen — 88 rows each
            // carrying a photo reel would be the grid's stutter all over again.
            if selected {
                VersionPhotoStrip(row: item.row, client: client) {
                    galleryStart = visible.firstIndex { $0.id == item.id } ?? 0
                }
                .padding(.top, 10)
                detailsLink(item)
                    .padding(.top, 8)
            }
        }
        .listRowBackground(selected ? c.accentDim : c.s1)
    }

    /// The chevron into the version's own page. Dimmed when there is nothing behind it but the
    /// numbers already on the row — a live-looking control that opens an empty page is the bug this
    /// codebase keeps shipping.
    @ViewBuilder
    private func detailsLink(_ item: VersionGrouping.Placed) -> some View {
        let hasMore = item.row.summary != nil || !item.row.pictures.isEmpty
        NavigationLink {
            VersionDetailView(item: item, client: client, picked: $picked,
                              onOpenGallery: { galleryStart = visible.firstIndex { $0.id == item.id } ?? 0 })
        } label: {
            HStack(spacing: 4) {
                Text(hasMore ? "Details" : "Details — nothing more published")
                    .scaledFont(12.5, weight: .semibold)
                Image(systemName: "chevron.right")
                    .scaledFont(10, weight: .bold)
            }
            .foregroundStyle(hasMore ? c.accent : c.t3)
        }
    }

    private func versionThumb(_ row: MWProfileRow) -> some View {
        Group {
            if row.coverUrl != nil {
                CachedThumb(url: client.makerworldThumbUrl(row.coverUrl),
                            size: CGSize(width: 64, height: 48))
            } else {
                // A designed absence, not a spinner that never ends.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(c.s2)
                    .frame(width: 64, height: 48)
                    .overlay {
                        Text("NO PHOTO")
                            .scaledMono(7.5, weight: .bold)
                            .foregroundStyle(c.t3)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The 51. Collapsed, explained, and in MakerWorld's own order.
    private func unlabelledSection(_ items: [VersionGrouping.Placed]) -> some View {
        Section {
            DisclosureGroup(isExpanded: $unlabelledExpanded) {
                ForEach(items) { row($0) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "No published settings · \(items.count)")
                        .scaledMono(11, weight: .bold)
                        .foregroundStyle(c.t3)
                    Text(VersionGrouping.unlabelledExplanation)
                        .scaledFont(11)
                        .foregroundStyle(c.t3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The filter, with a primary button that reads the live result count — so a filter that would
/// return nothing can be seen to before it is applied.
struct VersionFilterSheet: View {
    @Binding var filter: VersionGrouping.Filter
    let materials: [String]
    /// Counts the result of a candidate filter without applying it.
    let resultCount: (VersionGrouping.Filter) -> Int
    /// What is actually on the machine, named rather than implied.
    let loadedSpools: [String]

    @Environment(\.palette) private var c
    @Environment(\.dismiss) private var dismiss
    @State private var draft = VersionGrouping.Filter()

    var body: some View {
        NavigationStack {
            Form {
                if !materials.isEmpty {
                    Section {
                        ForEach(materials, id: \.self) { m in
                            Toggle(m, isOn: Binding(
                                get: { draft.materials.contains(m) },
                                set: { on in
                                    if on { draft.materials.insert(m) } else { draft.materials.remove(m) }
                                }))
                        }
                    } header: {
                        Text("MATERIAL")
                    } footer: {
                        // Rule 4, stated where it applies.
                        Text("Built from the materials these versions name. Universal versions always pass.")
                    }
                }

                Section {
                    Toggle("Only versions with photos or notes", isOn: $draft.onlyWithPhotosOrNotes)
                    Toggle("Only what I can print now", isOn: $draft.onlyPrintableNow)
                } footer: {
                    if loadedSpools.isEmpty {
                        Text("Nothing is loaded right now, so this can't narrow anything.")
                    } else {
                        Text(verbatim: "Matches what's loaded: \(loadedSpools.joined(separator: ", ")).")
                    }
                }

                Section {
                    Toggle("Include versions with no published settings", isOn: $draft.includeUnlabelled)
                } footer: {
                    // Rule 3 — the filter says what it does with the unlabelled rows rather than
                    // silently dropping half the model.
                    Text("Most versions of a popular model publish nothing to filter on. "
                         + "Turning this off hides them entirely.")
                }
            }
            .navigationTitle("Filter versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { draft = VersionGrouping.Filter() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Show \(resultCount(draft)) version\(resultCount(draft) == 1 ? "" : "s")") {
                        filter = draft
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { draft = filter }
        }
    }
}
#endif
