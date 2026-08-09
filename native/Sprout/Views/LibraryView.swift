import AVKit
import SwiftUI
import UIKit

// MARK: - Pure browse helpers

/// Which store the Files tab is showing.
private enum LibrarySource: String, CaseIterable, Identifiable, Sendable {
    case library
    case printer

    var id: String { rawValue }
    var label: String { self == .library ? "Library" : "Printer" }
}

/// The type chips above the list. Counts are computed against the UNFILTERED list, so they never
/// move as the user types.
private enum LibraryTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case models
    case sliced

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .models: "Models"
        case .sliced: "Sliced"
        }
    }
}

private enum LibraryLayout: Sendable { case grid, list }

/// Filter / search / naming rules for the library list. Pure, so the view never re-derives them.
private enum LibraryBrowse {
    /// A file is "sliced" when it carries G-code or was produced by slicing for a model.
    static func isSliced(_ f: LibraryFile) -> Bool {
        (f.fileType ?? "").contains("gcode") || !(f.slicedForModel ?? "").isEmpty
    }

    /// Upload names arrive percent-encoded (`Adapter%20hexagon.stl`). A malformed escape decodes to
    /// nil, in which case the raw name is still better than nothing.
    static func displayName(_ f: LibraryFile) -> String {
        let raw = [f.printName, f.filename].compactMap { $0 }.first { !$0.isEmpty } ?? "file-\(f.id)"
        return raw.removingPercentEncoding ?? raw
    }

    /// Display names are user-derived and may contain path separators that a cache filename would
    /// misread as directories.
    static func safeShareName(_ name: String) -> String {
        let n = name
            .replacingOccurrences(of: "[/\\\\:]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "file" : n
    }

    /// The query matches BOTH the decoded display name and the raw filename, so "hexagon" finds
    /// `Adapter%20hexagon.stl` whichever form the user has in mind.
    static func filter(_ files: [LibraryFile], _ filter: LibraryTypeFilter, _ query: String) -> [LibraryFile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return files.filter { f in
            let sliced = isSliced(f)
            if filter == .sliced, !sliced { return false }
            if filter == .models, sliced { return false }
            if q.isEmpty { return true }
            return displayName(f).lowercased().contains(q) || (f.filename).lowercased().contains(q)
        }
    }

    /// Directories first, then locale name order.
    static func sortPrinterFiles(_ files: [PrinterFile]) -> [PrinterFile] {
        files.sorted { a, b in
            a.isDirectory == b.isDirectory
                ? a.name.localizedCompare(b.name) == .orderedAscending
                : a.isDirectory
        }
    }

    /// The containing folder of an SD path, always with a leading slash. `/` is its own parent.
    static func parentPath(_ path: String) -> String {
        var p = path
        if p.hasSuffix("/") { p.removeLast() }
        guard let slash = p.lastIndex(of: "/") else { return "/" }
        let parent = String(p[p.startIndex..<slash])
        return parent.isEmpty ? "/" : parent
    }
}

private enum LibraryFormat {
    /// Decimal MB/KB, matching the server's own accounting. Zero and nil both render as nothing —
    /// an unknown size should take up no space rather than claim "0 B".
    static func bytes(_ n: Double?) -> String {
        guard let n, n != 0, n.isFinite else { return "" }
        if n > 1e6 { return String(format: "%.1f MB", n / 1e6) }
        if n > 1e3 { return String(format: "%.0f KB", n / 1e3) }
        return "\(Int(n)) B"
    }
}

// MARK: - Small shared value types

/// A share target. `Identifiable` so the activity sheet can be driven by `.sheet(item:)`.
private struct LibShareItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
}

/// A failure worth interrupting the user for.
private struct LibProblem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - LibraryView

/// The Files tab: the Bambuddy library (grid/list, search, bulk delete, share, print) and the
/// printer's own SD card (folders, sliced-3MF preview sheet, timelapse/ipcam video player).
///
/// Two auth schemes live side by side here and must not be swapped: library thumbnails are gated by
/// the camera **stream** token in `?token=` (an `X-API-Key` there 401s), while every SD-card URL —
/// listings, downloads, poster JPEGs, plate thumbnails — is gated by `X-API-Key`. That is why the
/// library uses `AsyncImage` and the SD card uses `PrinterFileImage`.
struct LibraryView: View {
    let model: AppModel

    @Environment(\.palette) private var c

    @State private var source: LibrarySource = .library
    /// nil while the first load is in flight. An empty array is a genuinely empty library — the
    /// difference decides between a spinner, a retry banner and "No files yet".
    @State private var files: [LibraryFile]?
    @State private var loadFailed = false
    @State private var filter: LibraryTypeFilter = .all
    @State private var layout: LibraryLayout = .grid
    @State private var query = ""
    @State private var selecting = false
    @State private var selected: Set<Int> = []

    // Printer onboard storage (SD card).
    @State private var pList: PrinterFileList?
    @State private var pPath = "/"
    @State private var pLoading = false

    @State private var sheetFile: PrinterFile?
    @State private var playFile: PrinterFile?
    @State private var dlBusy = false
    @State private var shareItem: LibShareItem?

    @State private var pendingDelete: LibraryFile?
    @State private var pendingSdDelete: PrinterFile?
    @State private var confirmBulk = false
    @State private var problem: LibProblem?

    private var hasFiles: Bool { !(files?.isEmpty ?? true) }
    private var shown: [LibraryFile] { LibraryBrowse.filter(files ?? [], filter, query) }
    private var pSorted: [PrinterFile] { LibraryBrowse.sortPrinterFiles(pList?.files ?? []) }

    private func count(_ f: LibraryTypeFilter) -> Int {
        let all = files ?? []
        switch f {
        case .all: return all.count
        case .models: return all.filter { !LibraryBrowse.isSliced($0) }.count
        case .sliced: return all.filter { LibraryBrowse.isSliced($0) }.count
        }
    }

    var body: some View {
        presentations(page)
    }

    private var page: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                sourcePicker
                if source == .library { librarySection } else { printerSection }
            }
            .padding(.top, 8)
            .padding(.bottom, 120)   // clearance for the floating tab bar
        }
        .scrollIndicators(.hidden)
        .background(c.bg)
        .refreshable { await refresh() }
        .overlay(alignment: .bottom) { if dlBusy { busyPill } }
        .task { await load() }
        // The SD listing loads the first time the segment is opened and then persists across
        // segment switches.
        .task(id: source) {
            if source == .printer, pList == nil { await loadPrinter("/") }
        }
        // The upload sheet writes into the very library this list is showing.
        .onChange(of: model.overlay) { old, new in
            if old == .upload, new == nil { Task { await load() } }
        }
    }

    /// Every modal this screen owns, kept off `body` so the type-checker sees two small expressions
    /// instead of one enormous one.
    private func presentations<V: View>(_ content: V) -> some View {
        content
            .sheet(item: $sheetFile) { file in
            if let client = model.client {
                PrinterFileSheet(
                    client: client,
                    printerId: model.printerId,
                    file: file,
                    onDelete: { Task { await deleteSd(file) } },
                    onPlay: PrinterFiles.isPlayableVideo(file.name) ? { play(file) } : nil
                )
                .presentationDetents([.height(PrinterFiles.isSliced3mf(file.name) ? 470 : 230)])
                .presentationCornerRadius(24)
                .presentationBackground(c.s1)
            }
        }
        .fullScreenCover(item: $playFile) { file in
            if let client = model.client {
                SdVideoPlayer(
                    client: client,
                    printerId: model.printerId,
                    file: file,
                    onDelete: { Task { await deleteSd(file) } },
                    onClose: { playFile = nil }
                )
            }
        }
        .sheet(item: $shareItem) { item in
            LibShareSheet(url: item.url)
        }
        .alert(
            "Delete file?",
            isPresented: presenting($pendingDelete),
            presenting: pendingDelete
        ) { f in
            Button("Delete", role: .destructive) { Task { await deleteLibrary(f) } }
            Button("Cancel", role: .cancel) {}
        } message: { f in
            Text("“\(LibraryBrowse.displayName(f))” will be removed from the library. This can’t be undone.")
        }
        .alert(
            "Delete from printer?",
            isPresented: presenting($pendingSdDelete),
            presenting: pendingSdDelete
        ) { pf in
            Button("Delete", role: .destructive) { Task { await deleteSd(pf) } }
            Button("Cancel", role: .cancel) {}
        } message: { pf in
            Text("“\(pf.name)” will be removed from the printer’s storage. This can’t be undone.")
        }
        .alert(bulkTitle, isPresented: $confirmBulk) {
            Button("Delete", role: .destructive) { Task { await bulkDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will be removed from the library. This can’t be undone.")
        }
        .alert(problem?.title ?? "", isPresented: presenting($problem)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem?.message ?? "")
        }
    }

    private func presenting<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    private var bulkTitle: String {
        let n = selected.count
        return "Delete \(n) \(n == 1 ? "file" : "files")?"
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Files")
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(c.t1)
            Spacer(minLength: 12)
            // Upload belongs to the library only — there is no way to push a file onto the SD card.
            if source == .library {
                Tap { model.overlay = .upload } content: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(c.accent)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(c.accentDim))
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private var sourcePicker: some View {
        HStack(spacing: 4) {
            ForEach(LibrarySource.allCases) { s in
                Tap { source = s } content: {
                    Text(s.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(source == s ? c.t1 : c.t2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(source == s ? c.s4 : .clear)
                        )
                }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: - Library segment

    @ViewBuilder
    private var librarySection: some View {
        if loadFailed { retryBanner }
        if hasFiles, !selecting { filterRow }
        if hasFiles, selecting { selectBar }
        if hasFiles { searchField }

        if files == nil, !loadFailed {
            ProgressView()
                .tint(c.accent)
                .padding(.top, 40)
        }
        if files?.isEmpty == true, !loadFailed {
            LibEmpty(
                icon: "folder",
                title: "No files yet",
                message: "Upload an STL, 3MF, or sliced G-code and it'll show up here.",
                cta: "Upload a model"
            ) { model.overlay = .upload }
        }
        if hasFiles, shown.isEmpty {
            Text(noMatchText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
        if hasFiles, !shown.isEmpty {
            if layout == .grid { grid } else { list }
            Text(selecting ? "Tap to select · Delete removes all selected" : "Tap to print · hold for options")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
        }
    }

    private var noMatchText: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? "No files match." : "No files match “\(q)”."
    }

    /// A failed fetch is not an empty library: the banner sits ABOVE the chrome and the stale list
    /// stays visible below it.
    private var retryBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18))
                .foregroundStyle(c.t3)
            Text("Couldn’t reach the server.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(c.t2)
            Spacer(minLength: 8)
            Tap { Task { await load() } } content: {
                Text("Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(c.t1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s3))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(c.line))
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(LibraryTypeFilter.allCases) { k in
                    let on = filter == k
                    Tap { filter = k } content: {
                        HStack(spacing: 6) {
                            Text(k.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(on ? c.accent : c.t2)
                            Text("\(count(k))")
                                .font(.mono(11))
                                .foregroundStyle(on ? c.accent : c.t3)
                        }
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? c.accentDim : c.s2))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Shows the mode it switches TO, not the one in use.
            Tap { layout = layout == .grid ? .list : .grid } content: {
                squareButton(layout == .grid ? "list.bullet" : "square.grid.2x2")
            }
            Tap { selecting = true } content: {
                squareButton("checkmark.square")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func squareButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(c.t2)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s2))
    }

    private var selectBar: some View {
        HStack(spacing: 10) {
            Tap { exitSelect() } content: {
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(c.t1)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s2))
            }
            Text(selected.isEmpty ? "Tap files to select" : "\(selected.count) selected")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.t2)
                .frame(maxWidth: .infinity)
            Tap(disabled: selected.isEmpty) { confirmBulk = true } content: {
                Text("Delete")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(selected.isEmpty ? c.t3 : c.error)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected.isEmpty ? c.s2 : c.errorDim)
                    )
                    .opacity(selected.isEmpty ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(c.t3)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search files")
                        .font(.system(size: 13.5))
                        .foregroundStyle(c.t3)
                }
                TextField("", text: $query)
                    .font(.system(size: 13.5))
                    .foregroundStyle(c.t1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
            }
            if !query.isEmpty {
                Tap { query = "" } content: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(c.t3)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.line))
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: - Library grid / list

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)],
            spacing: 13
        ) {
            ForEach(shown) { f in
                gridCell(f)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func gridCell(_ f: LibraryFile) -> some View {
        let sel = selected.contains(f.id)
        let sliced = LibraryBrowse.isSliced(f)
        return withMenu(f) {
            Tap { pick(f) } content: {
                VStack(alignment: .leading, spacing: 0) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(c.thumb)
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .overlay { libraryThumb(f, glyphSize: 26) }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(selecting && sel ? c.accent : c.line, lineWidth: selecting && sel ? 2 : 1)
                        }
                        .overlay(alignment: .topLeading) {
                            Text((f.fileType ?? "").uppercased())
                                .font(.mono(8.5))
                                .tracking(0.5)
                                .foregroundStyle(Color.white.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.5)))
                                .padding(8)
                        }
                        .overlay(alignment: .topTrailing) {
                            if selecting {
                                selectionDot(sel)
                                    .padding(7)
                            } else if sliced {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(c.accentInk)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(c.accent))
                                    .padding(7)
                            }
                        }

                    Text(LibraryBrowse.displayName(f))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(c.t1)
                        .lineLimit(1)
                        .padding(.top, 9)
                    Text(LibraryFormat.bytes(f.fileSize?.double))
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(c.t3)
                        .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(selecting && !sel ? 0.55 : 1)
            }
        }
    }

    private func selectionDot(_ sel: Bool) -> some View {
        ZStack {
            Circle().fill(sel ? c.accent : Color.black.opacity(0.5))
            if sel {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(c.accentInk)
            } else {
                Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var list: some View {
        let rows = shown
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let f = rows[index]
                let sel = selected.contains(f.id)
                withMenu(f) {
                    Tap { pick(f) } content: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(c.thumb)
                                .frame(width: 44, height: 44)
                                .overlay { libraryThumb(f, glyphSize: 18) }
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(LibraryBrowse.displayName(f))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(c.t1)
                                    .lineLimit(1)
                                Text(subtitle(f))
                                    .font(.mono(11, weight: .medium))
                                    .foregroundStyle(c.t3)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if selecting {
                                ZStack {
                                    Circle().fill(sel ? c.accent : .clear)
                                    if sel {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(c.accentInk)
                                    } else {
                                        Circle().strokeBorder(c.line2, lineWidth: 1.5)
                                    }
                                }
                                .frame(width: 22, height: 22)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(c.t3)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(selecting && sel ? c.accentDim : .clear)
                    }
                }
                if index < rows.count - 1 {
                    Rectangle().fill(c.line).frame(height: 1)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(c.line))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func subtitle(_ f: LibraryFile) -> String {
        let type = (f.fileType ?? "").uppercased()
        let sliced = LibraryBrowse.isSliced(f) ? " · sliced" : ""
        return "\(type)\(sliced) · \(LibraryFormat.bytes(f.fileSize?.double))"
    }

    /// Library thumbnails carry the camera stream token in the query — `AsyncImage` can fetch them
    /// as-is because no header is involved.
    @ViewBuilder
    private func libraryThumb(_ f: LibraryFile, glyphSize: CGFloat) -> some View {
        if let url = model.client?.fileThumbUrl(f.id, token: model.cameraToken, thumbnailPath: f.thumbnailPath) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.12))) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.clear
                }
            }
        } else {
            Image(systemName: (f.fileType ?? "").contains("gcode") ? "shippingbox" : "doc")
                .font(.system(size: glyphSize))
                .foregroundStyle(c.t3)
        }
    }

    /// The long-press menu. It was delete-only once, which left every other per-file action
    /// undiscoverable. Suppressed entirely while selecting, where a long press means nothing.
    @ViewBuilder
    private func withMenu<Content: View>(_ f: LibraryFile, @ViewBuilder content: () -> Content) -> some View {
        if selecting {
            content()
        } else {
            content().contextMenu {
                Button { model.overlay = .wizard(f) } label: { Label("Print…", systemImage: "printer") }
                if (f.fileType ?? "").lowercased() == "stl" {
                    Button { model.overlay = .stlViewer(f) } label: { Label("View in 3D", systemImage: "cube") }
                }
                if LibraryBrowse.isSliced(f) {
                    Button { model.overlay = .layerViewer(f) } label: { Label("View layers", systemImage: "square.3.layers.3d") }
                }
                Button { Task { await share(f) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { pendingDelete = f } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func pick(_ f: LibraryFile) {
        if selecting {
            if selected.contains(f.id) { selected.remove(f.id) } else { selected.insert(f.id) }
        } else {
            model.overlay = .wizard(f)
        }
    }

    private func exitSelect() {
        selecting = false
        selected = []
    }

    /// Hand a file from the detail sheet to the player. UIKit refuses to present a full-screen cover
    /// while a sheet is still dismissing, so the swap waits out the dismissal animation.
    private func play(_ pf: PrinterFile) {
        sheetFile = nil
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            playFile = pf
        }
    }

    // MARK: - Printer (SD card) segment

    @ViewBuilder
    private var printerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if pPath != "/" {
                    Tap { Task { await loadPrinter(LibraryBrowse.parentPath(pPath)) } } content: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(c.t2)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.s2))
                    }
                }
                Text("printer:\(pPath)")
                    .font(.mono(12))
                    .foregroundStyle(c.t3)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 12)

            if pLoading {
                ProgressView().tint(c.accent).padding(.top, 30)
            } else {
                if pList != nil, pSorted.isEmpty {
                    LibEmpty(
                        icon: "externaldrive",
                        title: "Empty folder",
                        message: "Nothing here on the printer's onboard storage."
                    )
                }
                if PrinterFiles.isMediaFolder(pPath) {
                    mediaGrid
                } else {
                    ForEach(pSorted) { pf in
                        printerRow(pf)
                    }
                    if pSorted.contains(where: { !$0.isDirectory }) {
                        Text("Tap a file for preview & actions · hold to delete")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(c.t3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    /// The videos in a media folder, newest first — the printer timestamps its filenames, so a
    /// descending name sort IS a descending date sort.
    private var mediaFiles: [PrinterFile] {
        pSorted
            .filter { !$0.isDirectory && PrinterFiles.isPlayableVideo($0.name) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedDescending }
    }

    @ViewBuilder
    private var mediaGrid: some View {
        if mediaFiles.isEmpty {
            Text("No videos here yet.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(c.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(mediaFiles) { pf in
                    Tap { playFile = pf } content: {
                        VStack(alignment: .leading, spacing: 0) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(c.thumb)
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .overlay {
                                    PrinterFileImage(
                                        url: model.client?.printerFileDownloadUrl(
                                            model.printerId,
                                            path: PrinterFiles.mediaThumbPath(pf.path)
                                        ),
                                        headers: model.client?.authHeaders() ?? [:]
                                    )
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.line))
                                .overlay {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white)
                                        .offset(x: 1)
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(Color.black.opacity(0.45)))
                                }

                            Text(PrinterFiles.mediaLabel(pf.name))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(c.t1)
                                .lineLimit(1)
                                .padding(.top, 8)
                            Text(LibraryFormat.bytes(pf.size?.double))
                                .font(.mono(10.5, weight: .medium))
                                .foregroundStyle(c.t3)
                                .padding(.top, 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contextMenu {
                        Button(role: .destructive) { pendingSdDelete = pf } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func printerRow(_ pf: PrinterFile) -> some View {
        let row = Tap {
            if pf.isDirectory {
                Task { await loadPrinter(pf.path) }
            } else {
                sheetFile = pf
            }
        } content: {
            HStack(spacing: 12) {
                Image(systemName: rowSymbol(pf))
                    .font(.system(size: 18))
                    .foregroundStyle(pf.isDirectory ? c.accent : c.t3)
                    .frame(width: 20)
                Text(pf.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(c.t1)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if pf.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(c.t3)
                } else {
                    Text(LibraryFormat.bytes(pf.size?.double))
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(c.t3)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(c.line))
            .padding(.bottom, 9)
        }
        // Folders have nothing to long-press for, and an empty context menu still opens on hold.
        if pf.isDirectory {
            row
        } else {
            row.contextMenu {
                Button(role: .destructive) { pendingSdDelete = pf } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func rowSymbol(_ pf: PrinterFile) -> String {
        if pf.isDirectory { return PrinterFiles.isMediaFolder(pf.path) ? "film" : "folder" }
        if PrinterFiles.isSliced3mf(pf.name) { return "shippingbox" }
        if PrinterFiles.isPlayableVideo(pf.name) { return "film" }
        return "doc"
    }

    // MARK: - Busy pill

    /// Menu-driven shares have no sheet to host a spinner, so the progress floats.
    private var busyPill: some View {
        HStack(spacing: 9) {
            ProgressView().tint(c.accent)
            Text("Preparing to share…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.t1)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(Capsule().fill(c.s1))
        .overlay(Capsule().strokeBorder(c.line))
        .shadow1()
        .padding(.bottom, 24)
    }

    // MARK: - Data

    private func load() async {
        guard let client = model.client else { return }
        do {
            files = try await client.listFiles()
            loadFailed = false
        } catch {
            // A failed fetch is NOT an empty library — keep whatever is on screen and offer a retry.
            files = files ?? []
            loadFailed = true
        }
    }

    private func loadPrinter(_ path: String) async {
        guard let client = model.client else { return }
        pLoading = true
        defer { pLoading = false }
        if let r = try? await client.listPrinterFiles(model.printerId, path: path) {
            pList = r
            pPath = r.path.isEmpty ? path : r.path
        } else {
            // Silent on purpose: an unreadable folder reads as empty rather than as a broken tab.
            pList = PrinterFileList(path: path, files: [])
        }
    }

    private func refresh() async {
        // The SD segment has its own spinner, so re-list it too when it is the one on screen.
        if source == .printer { await loadPrinter(pPath) }
        await load()
    }

    private func deleteLibrary(_ f: LibraryFile) async {
        guard let client = model.client else { return }
        do {
            try await client.deleteFile(f.id)
            await load()
        } catch {
            problem = LibProblem(title: "Couldn’t delete", message: error.localizedDescription)
        }
    }

    private func bulkDelete() async {
        guard let client = model.client else { return }
        let ids = Array(selected)
        guard !ids.isEmpty else { return }
        // Partial failure is tolerated and reported — never abort the batch half-way.
        var failed = 0
        await withTaskGroup(of: Bool.self) { group in
            for id in ids {
                group.addTask {
                    do {
                        try await client.deleteFile(id)
                        return false
                    } catch {
                        return true
                    }
                }
            }
            for await didFail in group where didFail { failed += 1 }
        }
        exitSelect()
        await load()
        if failed > 0 {
            problem = LibProblem(
                title: "Some deletes failed",
                message: "\(failed) of \(ids.count) files couldn’t be deleted."
            )
        }
    }

    private func deleteSd(_ pf: PrinterFile) async {
        guard let client = model.client else { return }
        // Close the sheet/player first: they are modal presentations, and an error alert raised
        // from underneath one would never appear.
        sheetFile = nil
        playFile = nil
        do {
            try await client.deletePrinterFile(model.printerId, path: pf.path)
            await loadPrinter(pPath)
        } catch {
            problem = LibProblem(title: "Couldn’t delete", message: error.localizedDescription)
        }
    }

    private func share(_ f: LibraryFile) async {
        guard let client = model.client else { return }
        dlBusy = true
        defer { dlBusy = false }
        do {
            // The slicer token IS the auth and is single-use and short-lived, so it is minted per
            // share and the download carries no headers at all.
            let url = try await client.mintFileDownloadUrl(f.id, filename: f.filename)
            let dest = LibCache.url(for: LibraryBrowse.safeShareName(LibraryBrowse.displayName(f)))
            let local = try await FileDownloadDelegate.run(URLRequest(url: url), to: dest)
            shareItem = LibShareItem(url: local)
        } catch {
            problem = LibProblem(title: "Couldn’t download", message: error.localizedDescription)
        }
    }
}

// MARK: - Empty state

/// The full-screen empty state: icon well, headline, one explanatory line and an optional action.
private struct LibEmpty: View {
    let icon: String
    let title: String
    let message: String
    var cta: String?
    var onCta: (() -> Void)?

    @Environment(\.palette) private var c

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(c.t3)
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(c.s2))
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(c.t1)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(19 - 13)
                .multilineTextAlignment(.center)
                .foregroundStyle(c.t3)
                .frame(maxWidth: 250)
                .padding(.top, 8)
            if let cta, let onCta {
                Tap(action: onCta) {
                    Text(cta)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(c.accentInk)
                        .padding(.horizontal, 24)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.accent))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 48)
    }
}

// MARK: - SD-card file sheet

/// Tap an SD-card file: sliced 3MFs get a real plate preview plus print time and filament weight,
/// everything gets Download (to the share sheet) and Delete; videos also get Play.
///
/// The plate fetch is best-effort — a file the printer cannot describe still has to open.
///
/// There is no Layers action yet: the layer viewer is reached through `Overlay.layerViewer`, which
/// carries a `LibraryFile`. An SD file is addressed by path, so opening it needs an overlay case
/// that takes a G-code URL + headers rather than a library id.
private struct PrinterFileSheet: View {
    let client: BambuddyClient
    let printerId: Int
    let file: PrinterFile
    var onDelete: () -> Void
    var onPlay: (() -> Void)?

    @Environment(\.palette) private var c
    @State private var plate: PlateInfo?
    @State private var busy = false
    @State private var shareItem: LibShareItem?
    @State private var problem: LibProblem?
    @State private var confirmDelete = false

    private var sliced: Bool { PrinterFiles.isSliced3mf(file.name) }
    private var downloadInk: Color { onPlay == nil ? c.accentInk : c.t1 }

    var body: some View {
        VStack(spacing: 0) {
            if sliced {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(c.thumb)
                    .frame(width: 210, height: 210)
                    .overlay {
                        PrinterFileImage(
                            url: client.printerPlateThumbUrl(printerId, path: file.path),
                            headers: client.authHeaders(),
                            contentMode: .fit
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(c.line))
                    .padding(.bottom, 14)
            }

            Text(plate?.name ?? file.name)
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(c.t1)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(meta)
                .font(.mono(11.5, weight: .medium))
                .foregroundStyle(c.t3)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            HStack(spacing: 10) {
                if let onPlay {
                    Tap(disabled: busy, action: onPlay) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 15))
                            Text("Play").font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(c.accentInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.accent))
                        .opacity(busy ? 0.5 : 1)
                    }
                }
                // Download demotes itself to a secondary button whenever Play is the headline action.
                Tap(disabled: busy) { Task { await downloadAndShare() } } content: {
                    HStack(spacing: 8) {
                        if busy {
                            ProgressView().tint(downloadInk)
                        } else {
                            Image(systemName: "arrow.down.to.line").font(.system(size: 15))
                        }
                        Text(busy ? "Downloading…" : "Download")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(downloadInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(onPlay == nil ? c.accent : c.s3))
                    .opacity(busy ? 0.5 : 1)
                }
                Tap(disabled: busy) { confirmDelete = true } content: {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                        .foregroundStyle(c.error)
                        .frame(width: 52, height: 46)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.s3))
                        .opacity(busy ? 0.5 : 1)
                }
            }
            .padding(.top, 18)
        }
        .padding(20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(c.s1)
        .task {
            guard sliced else { return }
            plate = try? await client.getPrinterFilePlates(printerId, path: file.path).plates.first
        }
        .sheet(item: $shareItem) { item in
            LibShareSheet(url: item.url)
        }
        .alert("Delete from printer?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(file.name)” will be removed from the printer’s storage. This can’t be undone.")
        }
        .alert(problem?.title ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem?.message ?? "")
        }
    }

    private var meta: String {
        var parts = [LibraryFormat.bytes(file.size?.double)]
        if let seconds = plate?.printTimeSeconds?.double, seconds > 0 {
            parts.append(Dash.fmtDuration(seconds / 60))
        }
        if let grams = plate?.filamentUsedGrams?.double, grams > 0 {
            parts.append("\(Int(grams.rounded()))g")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    private func downloadAndShare() async {
        busy = true
        defer { busy = false }
        guard let url = client.printerFileDownloadUrl(printerId, path: file.path) else { return }
        var request = URLRequest(url: url)
        // The URL alone 401s — SD endpoints are X-API-Key gated, unlike library thumbnails.
        for (k, v) in client.authHeaders() { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let local = try await FileDownloadDelegate.run(request, to: LibCache.url(for: file.name))
            shareItem = LibShareItem(url: local)
        } catch {
            problem = LibProblem(title: "Couldn’t download", message: error.localizedDescription)
        }
    }
}

// MARK: - SD video player

/// Progress + result of one SD video download.
///
/// A class rather than view state because the progress callback fires off the main thread, and a
/// main-actor object is the only thing safe to hand it.
@MainActor
@Observable
private final class SdDownloadState {
    var written: Int64 = 0
    var total: Int64 = 0
    var localURL: URL?
    var failure: String?

    nonisolated init() {}

    var percent: Int? {
        guard total > 0 else { return nil }
        return min(100, Int((Double(written) / Double(total) * 100).rounded()))
    }
}

/// Full-screen player for the printer's timelapses and ipcam recordings.
///
/// Download-then-play is the only reliable path: the download endpoint answers 200 with the whole
/// body and ignores Range, so AVPlayer cannot stream from it, and the URL needs an `X-API-Key`
/// header that a plain player item cannot send. ipcam chunks run to ~250 MB, which is why the
/// progress bar is real; SD videos are immutable, so a cached copy is reused as-is.
private struct SdVideoPlayer: View {
    let client: BambuddyClient
    let printerId: Int
    let file: PrinterFile
    var onDelete: () -> Void
    var onClose: () -> Void

    @State private var download = SdDownloadState()
    @State private var shareItem: LibShareItem?
    @State private var confirmDelete = false

    private var kind: String {
        file.path.lowercased().hasPrefix("/ipcam") ? "camera recording" : "timelapse"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let url = download.localURL {
                SdVideoBody(url: url)
            } else {
                progressBody
            }
        }
        // Hardcoded, not a palette token: this is a player, and it stays black in either theme.
        .background(Color(hex: 0x0A0B0C).ignoresSafeArea())
        .task {
            await start()
        }
        .sheet(item: $shareItem) { item in
            LibShareSheet(url: item.url)
        }
        .alert("Delete from printer?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(file.name)” will be removed from the printer’s storage. This can’t be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PrinterFiles.mediaLabel(file.name))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(LibraryFormat.bytes(file.size?.double)) · \(kind)")
                    .font(.mono(10.5, weight: .medium))
                    .foregroundStyle(Color(hex: 0x8E9398))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Tap(disabled: download.localURL == nil) {
                if let url = download.localURL { shareItem = LibShareItem(url: url) }
            } content: {
                roundButton("square.and.arrow.up", size: 15, color: .white)
                    .opacity(download.localURL == nil ? 0.4 : 1)
            }
            Tap { confirmDelete = true } content: {
                roundButton("trash", size: 15, color: Color(hex: 0xFF6B6B))
            }
            Tap(action: onClose) {
                roundButton("xmark", size: 17, color: .white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func roundButton(_ symbol: String, size: CGFloat, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.white.opacity(0.08)))
    }

    private var progressBody: some View {
        VStack(spacing: 0) {
            if let failure = download.failure {
                Text(failure)
                    .font(.system(size: 13.5))
                    .lineSpacing(19 - 13.5)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(hex: 0x8E9398))
            } else {
                ProgressView().tint(Color(hex: 0x30D158))
                if let pct = download.percent {
                    Text("\(pct)% · \(LibraryFormat.bytes(Double(download.written))) / \(LibraryFormat.bytes(Double(download.total)))")
                        .font(.mono(13))
                        .foregroundStyle(.white)
                        .padding(.top, 16)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(Color(hex: 0x30D158))
                                .frame(width: geo.size.width * Double(pct) / 100)
                        }
                    }
                    .frame(height: 4)
                    .padding(.top, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 44)
    }

    private func start() async {
        guard download.localURL == nil, download.failure == nil else { return }
        let dest = LibCache.url(for: file.name)
        if FileManager.default.fileExists(atPath: dest.path) {
            download.localURL = dest
            return
        }
        guard let url = client.printerFileDownloadUrl(printerId, path: file.path) else {
            download.failure = "That file has no download URL."
            return
        }
        var request = URLRequest(url: url)
        for (k, v) in client.authHeaders() { request.setValue(v, forHTTPHeaderField: k) }
        request.timeoutInterval = 600

        let state = download
        // The listed size is the fallback: the server omits Content-Length on these, and URLSession
        // then reports -1 for the expected total.
        let listedSize = file.size?.double ?? 0
        let listed = listedSize.isFinite ? Int64(listedSize) : 0
        do {
            let local = try await FileDownloadDelegate.run(request, to: dest) { written, total in
                Task { @MainActor in
                    state.written = written
                    state.total = total > 0 ? total : listed
                }
            }
            download.localURL = local
        } catch {
            download.failure = error.localizedDescription
        }
    }
}

/// Separate view so the player is built only once a local file exists, and is torn down with the
/// screen rather than lingering with an unplayable item.
private struct SdVideoBody: View {
    let url: URL

    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
                player.play()
            }
            .onDisappear {
                player.pause()
                looper = nil
            }
    }
}

// MARK: - Header-authenticated image

/// An image whose URL needs `X-API-Key` — every SD-card asset (poster JPEGs, plate thumbnails).
/// `AsyncImage` cannot send headers, so this fetches the bytes itself and keeps a small cache so
/// scrolling a folder does not re-download the posters.
private struct PrinterFileImage: View {
    let url: URL?
    let headers: [String: String]
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard let url else { return }
            guard let data = await PrinterFileImageCache.shared.data(for: url, headers: headers),
                  let decoded = UIImage(data: data)
            else { return }
            withAnimation(.easeInOut(duration: 0.12)) { image = decoded }
        }
    }
}

private actor PrinterFileImageCache {
    static let shared = PrinterFileImageCache()

    private var store: [URL: Data] = [:]
    private var order: [URL] = []
    private let limit = 80

    func data(for url: URL, headers: [String: String]) async -> Data? {
        if let hit = store[url] { return hit }
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        store[url] = data
        order.append(url)
        if order.count > limit {
            let evicted = order.removeFirst()
            store[evicted] = nil
        }
        return data
    }
}

// MARK: - Downloads, cache, share sheet

private enum LibCache {
    /// A file in the caches directory. Callers pass names that have already been made
    /// path-separator safe.
    static func url(for name: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(name.isEmpty ? "file" : name)
    }
}

/// Downloads one URL to a fixed destination, reporting byte progress.
///
/// `URLSession.download(for:)` reports no progress, and an ipcam chunk runs to ~250 MB — the bar is
/// the difference between "downloading" and "frozen". One session per download keeps the delegate's
/// state trivially isolated; downloads here are user-initiated and rare.
private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var failure: Error?

    private init(destination: URL, onProgress: (@Sendable (Int64, Int64) -> Void)?) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func run(
        _ request: URLRequest,
        to destination: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> URL {
        let delegate = FileDownloadDelegate(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted the moment this method returns, so the move happens here, not in the
        // completion callback.
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw SproutError("Download failed (HTTP \(status)).")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let problem = error ?? failure {
            continuation.resume(throwing: problem)
        } else {
            continuation.resume(returning: destination)
        }
    }
}

/// The system share sheet. SwiftUI's `ShareLink` needs its item up front, but everything shared here
/// only exists after an async download.
private struct LibShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
