#if os(iOS)
// iOS layout. macOS: Views/Mac/Sections/MacExploreSection.
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI

/// Every photo of every version, in one pager.
///
/// **It swipes between VERSIONS, not just within one version's photos.** That is the one idea taken
/// from the image-first option that was not shipped: when you are choosing between versions of the
/// same object, the thing you actually want is to flick through them side by side. Confining the
/// pager to a single version's photos would make the gallery a detail of a row rather than a way to
/// choose.
///
/// Versions with no photos are **not skipped** — they appear with a stated empty frame. Skipping
/// them would make the counter lie about where you are in the list, and would hide the fact that
/// most versions of a popular model publish nothing.
struct VersionGallery: View {
    /// Every version, in the order the list shows them.
    let items: [VersionGrouping.Placed]
    let client: BambuddyClient
    /// Which version the pager opens on.
    @State var index: Int
    @Binding var picked: MWProfileRow?

    @Environment(\.palette) private var c
    @Environment(\.dismiss) private var dismiss

    init(items: [VersionGrouping.Placed], client: BambuddyClient,
         startAt: Int, picked: Binding<MWProfileRow?>) {
        self.items = items
        self.client = client
        self._index = State(initialValue: startAt)
        self._picked = picked
    }

    private var current: VersionGrouping.Placed? {
        items.indices.contains(index) ? items[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    VersionPhotoPage(item: item, client: client).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .bottom)

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .scaledFont(15, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            Spacer()
            // Position in the whole set, so the counter and the list agree.
            Text(verbatim: "\(index + 1) / \(items.count)")
                .scaledMono(12, weight: .bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.45)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let current {
            VStack(alignment: .leading, spacing: 8) {
                Text(current.row.title)
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let d = current.row.detail {
                    Text(MakerWorld.metaLine(d))
                        .scaledMono(11.5, weight: .medium)
                        .foregroundStyle(.white.opacity(0.7))
                }

                if let notes = current.row.summary {
                    // The maker's own words. `plainText` already stripped the HTML upstream;
                    // `verbatim` keeps SwiftUI from reading what is left as Markdown.
                    Text(verbatim: notes)
                        .scaledFont(12)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    picked = current.row
                    dismiss()
                } label: {
                    Text(picked?.id == current.row.id ? "Chosen" : "Use this")
                        .scaledFont(14, weight: .bold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Capsule().fill(picked?.id == current.row.id ? .white : Color(c.accent)))
                }
                .disabled(picked?.id == current.row.id)
            }
            .padding(16)
            .background {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
    }
}

/// One version's photos, or a stated absence.
private struct VersionPhotoPage: View {
    let item: VersionGrouping.Placed
    let client: BambuddyClient
    @Environment(\.palette) private var c

    private var photos: [String] {
        ([item.row.coverUrl].compactMap { $0 } + item.row.pictures)
    }

    var body: some View {
        if photos.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .scaledFont(34, weight: .ultraLight)
                    .foregroundStyle(.white.opacity(0.35))
                Text("No photos published")
                    .scaledFont(13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // A version's own photos scroll horizontally inside its page; the pager's swipe moves
            // between versions. Nested paging would fight itself, so this is a plain scroll.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(photos, id: \.self) { url in
                        ZoomableImage(url: client.makerworldThumbUrl(url))
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
        }
    }
}

/// One photo, pinch-to-zoom.
private struct ZoomableImage: View {
    let url: URL?
    @State private var scale: CGFloat = 1
    @State private var committed: CGFloat = 1

    var body: some View {
        CachedThumb(url: url, contentMode: .fit)
            .scaleEffect(scale)
            .gesture(
                MagnifyGesture()
                    .onChanged { scale = min(max(committed * $0.magnification, 1), 5) }
                    .onEnded { _ in committed = scale }
            )
            .onTapGesture(count: 2) {
                // A double tap is the way back out of a zoom without pinching in reverse.
                withAnimation(Motion.standard(0.25)) {
                    scale = scale > 1 ? 1 : 2.5
                    committed = scale
                }
            }
    }
}

/// The photo strip under a selected row — depth two of three.
///
/// Only appears when the version actually has more than its cover. A strip of one image repeated is
/// not a gallery, and reserving space for one that never comes is how the absent state reads as
/// broken.
struct VersionPhotoStrip: View {
    let row: MWProfileRow
    let client: BambuddyClient
    let onTap: () -> Void
    @Environment(\.palette) private var c

    private var photos: [String] { ([row.coverUrl].compactMap { $0 } + row.pictures) }

    var body: some View {
        if photos.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(photos, id: \.self) { url in
                        Tap(action: onTap) {
                            CachedThumb(url: client.makerworldThumbUrl(url),
                                        size: CGSize(width: 128, height: 96))
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 96)
        }
    }
}
#endif
