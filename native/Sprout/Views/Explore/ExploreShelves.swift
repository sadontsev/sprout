#if os(iOS)
// iOS layout. macOS: Views/Mac/Sections/MacExploreSection.
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI

/// What Explore shows before anything has been asked for.
///
/// A cold screen used to be an empty text field, which says nothing about what the screen is for.
/// Shelves answer "what can I do here" with content rather than instructions: the owner's own
/// collections first because they are theirs, then what they have already pulled in.
///
/// Deliberately built only from what is already in hand — `ExploreModel.recent` and `.collections`.
/// A shelf that fires its own request would make the cold screen slower than the thing it replaced.
struct ExploreShelves: View {
    let client: BambuddyClient
    let collectionsClient: CollectionsClient

    @Environment(\.palette) private var c
    @Environment(ExploreModel.self) private var explore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !explore.collections.isEmpty {
                    shelf("YOUR COLLECTIONS") {
                        ForEach(explore.collections.prefix(8)) { folder in
                            Tap { explore.openCollection(folder, client: collectionsClient) } content: {
                                card(cover: folder.cover,
                                     title: folder.title,
                                     sub: "\(folder.count) model\(folder.count == 1 ? "" : "s")")
                            }
                        }
                    }
                }

                if !explore.recent.isEmpty {
                    shelf("RECENTLY IMPORTED") {
                        ForEach(explore.recent) { item in
                            // The model id is not stored — it is recovered from the source URL with
                            // the same parser the field uses, so a recent row and a pasted link
                            // cannot disagree about what a MakerWorld URL means.
                            let modelId: Int? = {
                                if case .resolve(let id) = MakerWorldSearch.intent(for: item.sourceUrl ?? "") {
                                    return id
                                }
                                return nil
                            }()
                            Tap {
                                guard let modelId else { return }
                                var hit = MWSearchHit(id: modelId)
                                hit.title = item.filename
                                explore.path.append(hit)
                            } content: {
                                card(cover: nil, title: item.filename ?? "Model",
                                     sub: modelId == nil ? "no link stored" : nil)
                            }
                            .disabled(modelId == nil)
                        }
                    }
                }

                if explore.collections.isEmpty && explore.recent.isEmpty {
                    ExploreMessage(symbol: "square.grid.2x2",
                                   title: "Find something to print",
                                   message: "Search MakerWorld, pick a category above, or paste a link "
                                          + "to a model you already have open.")
                        .frame(minHeight: 280)
                }
            }
            .padding(.vertical, 18)
        }
    }

    private func shelf<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .scaledMono(11, weight: .bold)
                .foregroundStyle(c.t3)
                .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) { content() }
                    .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func card(cover: String?, title: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedThumb(url: client.makerworldThumbUrl(cover), size: CGSize(width: 132, height: 99))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text(title)
                .scaledFont(12.5, weight: .semibold)
                .foregroundStyle(c.t1)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let sub {
                Text(sub)
                    .scaledMono(10.5, weight: .medium)
                    .foregroundStyle(c.t3)
            }
        }
        .frame(width: 132, alignment: .leading)
        .contentShape(.rect)
    }
}
#endif
