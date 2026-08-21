#if os(iOS)
// iOS layout. macOS: Views/Mac/Sections/MacExploreSection.
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI

/// One MakerWorld model: what it is, who made it, what you may do with it, and the way to a version.
///
/// **The page exists before the request does.** `open(hit)` used to clear everything and then await
/// `POST /makerworld/resolve`, which itself has to go and read MakerWorld — so for a second or more
/// you stared at the grid you had just tapped, with a spinner in a button somewhere above, and then
/// the whole screen snapped into place. The search hit already carries the id, title, cover, creator
/// and counts, which is most of a header; this builds that header at tap time and fills in the
/// versions when the resolve lands. The transition is the feedback (C1), and the skeleton gives the
/// remaining wait a shape (C2).
struct ModelDetailView: View {
    let model: AppModel
    let client: BambuddyClient
    /// What the grid already knew. Enough for the header, and available on the first frame.
    let hit: MWSearchHit
    var onImported: (() -> Void)?

    @Environment(\.palette) private var c
    @Environment(ExploreModel.self) private var explore

    @State private var resolved: MakerWorldResolved?
    @State private var rows: [MWProfileRow] = []
    @State private var picked: MWProfileRow?
    @State private var failure: MWFailure?
    @State private var importing = false
    @State private var licenceExpanded = false
    @State private var descriptionExpanded = false
    @State private var importResult: ImportReceipt?

    private var design: MWDesign? { resolved?.design }
    private var title: String { design?.title ?? hit.title ?? "Model \(hit.id)" }
    private var creator: String? { design?.designCreator?.name ?? hit.designCreator?.name }
    private var coverUrl: String? { design?.coverUrl ?? hit.cover }
    private var licence: MWLicence? {
        (design?.license ?? hit.license)?.nonEmpty.map { MWLicence(code: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CachedThumb(url: client.makerworldThumbUrl(coverUrl), aspect: 4.0 / 3.0)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)

                header
                if let failure { failureCard(failure) }
                versionsRow
            }
            .padding(.vertical, 16)
        }
        .background(c.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { importBar }
        .task { await load() }
        .sheet(item: $importResult) { receipt in
            ImportReceiptSheet(model: model, client: client, receipt: receipt)
                .presentationDetents([.medium])
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .scaledFont(20, weight: .bold)
                .foregroundStyle(c.t1)

            HStack(spacing: 8) {
                if let creator {
                    Text(verbatim: "@\(creator)")
                        .scaledMono(12, weight: .medium)
                        .foregroundStyle(c.t3)
                }
                let stats = MakerWorldSearch.stats(hit)
                if !stats.isEmpty {
                    Text(verbatim: "·")
                        .scaledMono(12).foregroundStyle(c.t3)
                    Text(stats)
                        .scaledMono(12, weight: .medium)
                        .foregroundStyle(c.t3)
                }
            }

            if let licence {
                Tap { licenceExpanded.toggle() } content: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").scaledFont(11, weight: .semibold)
                        Text(licence.label).scaledFont(12.5, weight: .semibold)
                        Image(systemName: licenceExpanded ? "chevron.up" : "chevron.down")
                            .scaledFont(10, weight: .bold)
                    }
                    .foregroundStyle(c.t2)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Capsule().fill(c.s2))
                    .contentShape(.rect)
                }
                if licenceExpanded, let prose = licence.body ?? licence.title {
                    // MakerWorld's own words, verbatim — never paraphrased into something that
                    // might promise a permission the licence does not grant.
                    Text(verbatim: prose)
                        .scaledFont(12)
                        .foregroundStyle(c.t2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let blurb = MakerWorldSearch.description(original: design?.summary,
                                                        translated: design?.summaryTranslated) {
                // The uploader's description of the MODEL — what the object IS, as opposed to how
                // one profile slices it. Translated when MakerWorld has one, with its formatting.
                VStack(alignment: .leading, spacing: 6) {
                    RichDescription(description: blurb,
                                    lineLimit: descriptionExpanded ? nil : 6)
                    // Offered only when there is genuinely more, and measured on the RENDERED text
                    // rather than the HTML — a short blurb wrapped in figures and spans is long as
                    // markup and short as prose, and a "More" that reveals nothing is the same lie
                    // as a control for a capability the build lacks.
                    if (MakerWorldSearch.markdown(fromHTML: blurb.html)?.count ?? 0) > 260 {
                        Tap { withAnimation(Motion.standard(0.2)) { descriptionExpanded.toggle() } } content: {
                            HStack(spacing: 4) {
                                Text(descriptionExpanded ? "Show less" : "Read more")
                                Image(systemName: descriptionExpanded ? "chevron.up" : "chevron.down")
                                    .scaledFont(9, weight: .bold)
                            }
                            .scaledFont(12.5, weight: .semibold)
                            .foregroundStyle(c.accent)
                            .contentShape(.rect)
                        }
                    }
                }
                .padding(.top, 2)
            }

            if design?.isExclusive == true {
                // Stated up front rather than discovered at the 502. See MakerWorld.failure.
                Label("This model is marked exclusive. The import may be refused.", systemImage: "exclamationmark.triangle")
                    .scaledFont(12, weight: .medium)
                    // `heating`, not `paused`: paused is the print-state BLUE, and a caution painted
                    // in a status colour reads as status.
                    .foregroundStyle(c.heating)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    // MARK: Versions

    @ViewBuilder
    private var versionsRow: some View {
        if resolved == nil && failure == nil {
            // C2 — the wait has a shape that matches what will replace it.
            VStack(alignment: .leading, spacing: 10) {
                Text("READING VERSIONS…")
                    .scaledMono(11, weight: .bold)
                    .foregroundStyle(c.t3)
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(c.s2)
                        .frame(height: 62)
                }
                .redacted(reason: .placeholder)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
        } else if !rows.isEmpty {
            NavigationLink {
                VersionChooserView(model: model, client: client, rows: rows,
                                   design: design, picked: $picked)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(picked == nil ? "Choose a version" : "Version")
                            .scaledMono(11, weight: .bold)
                            .foregroundStyle(c.t3)
                        Text(picked?.title ?? "\(rows.count) available")
                            .scaledFont(14, weight: .semibold)
                            .foregroundStyle(c.t1)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let d = picked?.detail {
                            Text(MakerWorld.metaLine(d))
                                .scaledMono(11.5, weight: .medium)
                                .foregroundStyle(c.t3)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .scaledFont(14, weight: .semibold)
                        .foregroundStyle(c.t3)
                }
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s2))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 18)
        }
    }

    // MARK: Import

    private var importBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(c.line2)
            Tap(disabled: resolved == nil || importing || explore.access.blocksImport, action: doImport) {
                HStack(spacing: 8) {
                    if importing { ProgressView().tint(.black) }
                    Text(importing ? "Importing…" : "Import to library")
                        .scaledFont(16, weight: .bold)
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(resolved == nil || explore.access.blocksImport ? c.s3 : c.accent))
                .contentShape(.rect)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // The remedy, not just the refusal — each of these names a different machine to go and
            // look at, which is the whole value of `MakerWorldAccess`.
            if let why = explore.access.message {
                Text(verbatim: why)
                    .scaledFont(11.5)
                    .foregroundStyle(c.t3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 7)
            }
        }
        .background(.ultraThinMaterial)
    }

    // MARK: Actions

    private func load() async {
        // Back-then-forward is instant: the resolve for this model is already in hand.
        if let cached = explore.cachedResolve(hit.id) {
            apply(cached)
            return
        }
        guard resolved == nil else { return }
        do {
            let r = try await client.resolveMakerWorld(MakerWorldSearch.modelUrl(id: hit.id))
            explore.cacheResolve(r, for: hit.id)
            apply(r)
            // A resolve is proof the server is reachable. Without this, one failed probe at open
            // locked the import for the life of the session even as the design rendered fine.
            if explore.access.worthRetrying { explore.access = await client.makerWorldAccess() }
        } catch {
            failure = mwFailure(.resolve, error)
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

    @ViewBuilder
    private func failureCard(_ f: MWFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            UploadErrorCard(text: f.message)
            if f.offerWebLink, let link = MakerWorld.webUrl(modelId: hit.id) {
                Link(destination: link) {
                    HStack(spacing: 6) {
                        Text("Open on MakerWorld").scaledFont(13, weight: .semibold)
                        Image(systemName: "arrow.up.right").scaledFont(11, weight: .bold)
                    }
                    .foregroundStyle(c.accent)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func apply(_ r: MakerWorldResolved) {
        resolved = r
        rows = MakerWorld.rows(r)
        picked = MakerWorld.preselect(rows, defaultInstanceId: r.design.defaultInstanceId)
    }

    private func doImport() {
        guard let r = resolved, !importing, !explore.access.blocksImport else { return }
        importing = true
        failure = nil
        Task {
            defer { importing = false }
            do {
                let res = try await client.importMakerWorld(
                    MakerWorldImportRequest(
                        modelId: r.modelId,
                        // The resolve response's own profile id is the fallback ONLY when no row is
                        // picked at all. Falling back for a picked row that happens to carry no
                        // profileId would quietly import a different profile than the one selected.
                        profileId: picked.map(\.profileId) ?? r.profileId,
                        instanceId: picked?.id,
                        folderId: nil
                    )
                )
                onImported?()
                // A receipt rather than a force-push into the wizard: a browse session used to end
                // in a different screen with no statement of what happened or where the file went.
                importResult = ImportReceipt(response: res)
            } catch {
                failure = mwFailure(.importing, error)
            }
        }
    }
}

/// What an import actually produced, so the sheet can name it.
struct ImportReceipt: Identifiable {
    let response: MakerWorldImportResponse
    var id: Int { response.libraryFileId }
}
#endif
