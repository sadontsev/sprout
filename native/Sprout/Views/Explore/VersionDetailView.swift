import SwiftUI

/// One version, in full: its photos, the maker's own notes, its three numbers, and which of your
/// spools it would use.
///
/// **Absence is the designed state here, not the edge case.** Most versions of a popular model are
/// uploaded without a word of explanation — 51 of 88 on the model this screen was measured against.
/// So when there is nothing to show, this page says so outright rather than rendering an empty
/// frame: the numbers above are all MakerWorld has, and *nothing is missing from the screen*. A page
/// that merely looks bare is indistinguishable from one still loading, and that ambiguity is what
/// makes an app feel broken.
struct VersionDetailView: View {
    let item: VersionGrouping.Placed
    let client: BambuddyClient
    @Binding var picked: MWProfileRow?
    var onOpenGallery: (() -> Void)?

    @Environment(\.palette) private var c
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    private var row: MWProfileRow { item.row }
    private var hasNotes: Bool { row.summary != nil }
    private var hasPhotos: Bool { !row.pictures.isEmpty || row.coverUrl != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if hasPhotos {
                    Tap { onOpenGallery?() } content: {
                        CachedThumb(url: client.makerworldThumbUrl(row.coverUrl), aspect: 4.0 / 3.0)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                if row.pictures.count > 0 {
                                    Text(verbatim: "\(row.pictures.count + 1) photos")
                                        .font(.mono(10.5, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Capsule().fill(.black.opacity(0.55)))
                                        .padding(10)
                                }
                            }
                    }
                }

                Text(row.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(c.t1)

                specs

                notes

                filamentMatch
            }
            .padding(16)
        }
        .background(c.bg)
        .navigationTitle("Version")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { useBar }
    }

    // MARK: Specs

    @ViewBuilder
    private var specs: some View {
        if let d = row.detail {
            HStack(spacing: 0) {
                spec("TIME", d.seconds.map { Dash.fmtDuration($0 / 60) } ?? "—")
                spec("FILAMENT", d.grams.map { "\(Int($0.rounded())) g" } ?? "—")
                spec("PLATES", String(d.plateCount))
            }
        } else {
            Text("MakerWorld publishes no time, weight or material for this version.")
                .font(.system(size: 13))
                .foregroundStyle(c.t2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func spec(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.mono(10, weight: .bold))
                .foregroundStyle(c.t3)
            Text(verbatim: value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(c.t1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Notes

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(hasNotes ? "MAKER'S NOTES" : "NO NOTES")
                .font(.mono(10.5, weight: .bold))
                .foregroundStyle(c.t3)

            if let summary = row.summary {
                // Verbatim, and already reduced from HTML by `MakerWorldSearch.plainText`. Never
                // paraphrased — it is the uploader's description of their own work.
                Text(verbatim: summary)
                    .font(.system(size: 13.5))
                    .foregroundStyle(c.t1)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The sentence that makes an empty page read as finished rather than failed.
                Text("Most versions of a popular model are uploaded without a word of explanation. "
                     + "The numbers above are all MakerWorld has — nothing is missing from this screen.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(c.t3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: What it would use

    @ViewBuilder
    private var filamentMatch: some View {
        if let slots = row.detail?.slots, !slots.isEmpty {
            let trays = loadedTrays
            let assigned = VersionGrouping.assignTrays(slots: slots, trays: trays)
            let short = VersionGrouping.shortfall(slots: slots, trays: trays)

            VStack(alignment: .leading, spacing: 8) {
                Text("FILAMENT THIS VERSION USES")
                    .font(.mono(10.5, weight: .bold))
                    .foregroundStyle(c.t3)

                ForEach(Array(slots.enumerated()), id: \.offset) { i, slot in
                    HStack(spacing: 9) {
                        Swatch(value: FilamentColor.norm(slot.color), size: 14, radius: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "Slot \(i + 1) · \(slot.type ?? "any material")")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(c.t1)
                            if let tray = assigned[i] {
                                Text(verbatim: "matches AMS \(tray.unit + 1), slot \(tray.slot + 1)")
                                    .font(.mono(11, weight: .medium))
                                    .foregroundStyle(c.accent)
                            } else if trays.isEmpty {
                                Text("nothing loaded to compare against")
                                    .font(.mono(11, weight: .medium))
                                    .foregroundStyle(c.t3)
                            } else if let want = slot.type?.uppercased(), short[want] != nil {
                                // Says WHICH problem it is: none at all, or not enough of them.
                                let have = trays.filter { $0.type == want }.count
                                Text(verbatim: have == 0 ? "no \(want) loaded"
                                                         : "only \(have) \(want) tray\(have == 1 ? "" : "s") loaded")
                                    .font(.mono(11, weight: .semibold))
                                    .foregroundStyle(c.heating)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    /// The AMS, flattened. Reads the same status the rest of the app does.
    private var loadedTrays: [VersionGrouping.Tray] {
        var out: [VersionGrouping.Tray] = []
        for unit in model.status?.status?.ams ?? [] {
            for tray in unit.tray ?? [] {
                guard let t = tray.trayType?.uppercased(), !t.isEmpty else { continue }
                out.append(VersionGrouping.Tray(unit: unit.id, slot: tray.id, type: t))
            }
        }
        return out
    }

    // MARK: Use

    private var useBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(c.line2)
            Tap {
                picked = row
                dismiss()
            } content: {
                Text(picked?.id == row.id ? "Chosen" : "Use this version")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(picked?.id == row.id ? c.t2 : .black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(picked?.id == row.id ? c.s2 : c.accent))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }
}
