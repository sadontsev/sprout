#if os(iOS)
// iOS layout. macOS: Views/Mac/Sections/MacFilesSection.
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import AVKit
import SwiftUI
import UIKit

// MARK: - Pure browse helpers

private enum LibraryLayout: Sendable { case grid, list }

/// Which full-screen presentation an SD-card file is being handed to.
private enum SdPresentation: Sendable { case player, layers }

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

    /// Every fetch, the source segment and the multi-select set live in `LibraryStore` so the macOS
    /// Files section drives the same copy — see docs/native-rewrite/18-mac-port-architecture.md.
    /// What stays here is layout: which chip is lit, which sheet is up, what is being confirmed.
    private var store: LibraryStore { model.library }

    /// Uploading survives this view: the task holds the client, not the view.
    @State private var uploader = LibraryUploader()
    @State private var picking = false
    @Environment(ExploreModel.self) private var explore
    @State private var filter: LibraryTypeFilter = .all
    @State private var layout: LibraryLayout = .grid
    @State private var query = ""

    @State private var sheetFile: PrinterFile?
    @State private var playFile: PrinterFile?
    /// The SD-card file whose layers are being scrubbed. Presented from here rather than through
    /// `AppModel.overlay`, whose `layerViewer` case carries a `LibraryFile`; an SD file has no
    /// library id, only a path.
    @State private var layerFile: PrinterFile?

    @State private var pendingDelete: LibraryFile?
    @State private var pendingSdDelete: PrinterFile?
    @State private var confirmBulk = false

    private var hasFiles: Bool { !(store.files?.isEmpty ?? true) }
    private var shown: [LibraryFile] { LibraryBrowse.filter(store.files ?? [], filter, query) }
    private var pSorted: [PrinterFile] { LibraryBrowse.sortPrinterFiles(store.printerList?.files ?? []) }

    private func count(_ f: LibraryTypeFilter) -> Int {
        let all = store.files ?? []
        switch f {
        case .all: return all.count
        case .models: return all.filter { !LibraryFileCaps.isSliced($0) }.count
        case .sliced: return all.filter { LibraryFileCaps.isSliced($0) }.count
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
                if store.source == .library { librarySection } else { printerSection }
            }
            .padding(.top, 8)
            // End-of-content breathing room only — the system tab bar insets the safe area for us.
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(c.bg)
        .refreshable { await store.reload() }
        .overlay(alignment: .bottom) { if store.downloadBusy { busyPill } }
        .task { await store.load() }
        .fileImporter(isPresented: $picking, allowedContentTypes: UploadFileKind.all) { result in
            switch result {
            case .success(let url):
                guard let client = model.client else { return }
                uploader.upload(url, client: client, model: model) { Task { await store.load() } }
            case .failure(let error):
                // Cancelling the browser is reported as a failure; it is not one.
                if (error as? CocoaError)?.code != .userCancelled {
                    uploader.error = error.localizedDescription
                }
            }
        }
        .alert("Upload failed", isPresented: Binding(
            get: { uploader.error != nil },
            set: { if !$0 { uploader.error = nil } }
        )) {
            Button("OK", role: .cancel) { uploader.error = nil }
        } message: {
            Text(verbatim: uploader.error ?? "")
        }
        .task(id: store.source) { await store.loadPrinterIfNeeded() }
        // The upload sheet writes into the very library this list is showing.
        .onChange(of: model.overlay) { old, new in
            if old == .upload, new == nil { Task { await store.load() } }
        }
    }

    /// Every modal this screen owns, kept off `body` so the type-checker sees two small expressions
    /// instead of one enormous one.
    private func presentations<V: View>(_ content: V) -> some View {
        // The share sheet and the error alert are driven by store state, so they need bindings into
        // it rather than into `@State`. Only those two read `bound`; everything else goes through
        // `store` as usual.
        @Bindable var bound = model.library
        return content
            .sheet(item: $sheetFile) { file in
            if let client = model.client {
                PrinterFileSheet(
                    client: client,
                    printerId: model.printerId,
                    file: file,
                    onDelete: { Task { await deleteSd(file) } },
                    onPlay: PrinterFiles.isPlayableVideo(file.name) ? { play(file) } : nil,
                    onLayers: PrinterFiles.isSliced3mf(file.name) ? { showLayers(file) } : nil
                )
                // +56 for the close-button row added to the sheet: these detents are FIXED heights,
                // so a new header steals the space from the content rather than growing the sheet.
                .presentationDetents([.height(PrinterFiles.isSliced3mf(file.name) ? 526 : 286)])
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
        .fullScreenCover(item: $layerFile) { file in
            LayerViewerOverlay(
                model: model,
                printerId: model.printerId,
                path: file.path,
                title: file.name,
                onClose: { layerFile = nil }
            )
        }
        .sheet(item: $bound.shareItem) { item in
            LibShareSheet(url: item.url)
        }
        .alert(
            "Delete file?",
            isPresented: presenting($pendingDelete),
            presenting: pendingDelete
        ) { f in
            Button("Delete", role: .destructive) { Task { await store.deleteLibrary(f) } }
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
            Button("Delete", role: .destructive) { Task { await store.bulkDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will be removed from the library. This can’t be undone.")
        }
        .alert(store.problem?.title ?? "", isPresented: presenting($bound.problem)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.problem?.message ?? "")
        }
    }

    private func presenting<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    private var bulkTitle: String {
        let n = store.selected.count
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
            if store.source == .library {
                // A native Menu, not a sheet. With Explore promoted to its own page, the "Add a
                // file" sheet's entire content was a two-item list — a modal to choose between two
                // things that can both be one tap (F10).
                Menu {
                    Button {
                        uploader.error = nil
                        picking = true
                    } label: {
                        Label("From Files", systemImage: "folder")
                    }
                    Button {
                        model.overlay = .upload
                    } label: {
                        Label("From MakerWorld", systemImage: "globe")
                    }
                } label: {
                    Group {
                        if uploader.busy {
                            Text(verbatim: "\(uploader.percent)%")
                                .font(.mono(11, weight: .bold))
                                .foregroundStyle(c.accent)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(c.accent)
                        }
                    }
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(c.accentDim))
                }
                .accessibilityLabel(uploader.busy ? "Uploading, \(uploader.percent) percent" : "Add a file")
            }
        }
        .padding(.horizontal, 20)
    }

    // No "Paste a link" item. It was a second door to the same room — both items opened Explore
    // and the only difference was a focus flag — and making it genuinely different by reading the
    // clipboard does not work: since iOS 16 a programmatic `UIPasteboard` read needs user consent,
    // and from a menu action it simply returns nil. Verified with a real MakerWorld URL on the
    // simulator's pasteboard: `simctl pbpaste` showed the link, the app got nothing.
    //
    // The paste path already exists and already works, because the user does the pasting: the
    // search field says "Search or paste a link" and a pasted URL becomes an "Open model N" row.
    // One door, and it is the one the platform lets us open.

    private var sourcePicker: some View {
        HStack(spacing: 4) {
            ForEach(LibrarySource.allCases) { s in
                Tap { store.source = s } content: {
                    Text(s.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(store.source == s ? c.t1 : c.t2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(store.source == s ? c.s4 : .clear)
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
        if store.loadFailed { retryBanner }
        if hasFiles, !store.selecting { filterRow }
        if hasFiles, store.selecting { selectBar }
        if hasFiles { searchField }

        if store.files == nil, !store.loadFailed {
            ProgressView()
                .tint(c.accent)
                .padding(.top, 40)
        }
        if store.files?.isEmpty == true, !store.loadFailed {
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
            Text(store.selecting ? "Tap to select · Delete removes all selected" : "Tap to print · hold for options")
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
            Tap { Task { await store.load() } } content: {
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
            Tap { store.beginSelecting() } content: {
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
        let selected = store.selected
        return HStack(spacing: 10) {
            Tap { store.exitSelect() } content: {
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
        let selecting = store.selecting
        let sel = store.isSelected(f.id)
        let sliced = LibraryFileCaps.isSliced(f)
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
        let lastId = rows.last?.id
        let selecting = store.selecting
        // Identified by file id, NOT by array position. With a positional identity every row below a
        // deletion (or below the cut of a search keystroke) keeps its view and swaps its contents, so
        // its `AsyncImage` restarts at `.empty` — the whole thumbnail column blanks and re-downloads
        // instead of one row disappearing. The grid above has always keyed on `LibraryFile.id`.
        return VStack(spacing: 0) {
            ForEach(rows) { f in
                let sel = store.isSelected(f.id)
                withMenu(f) {
                    Tap { pick(f) } content: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(c.thumb)
                                .frame(width: 44, height: 44)
                                .overlay { libraryThumb(f, glyphSize: 18, showsProvenance: false) }
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
                if f.id != lastId {
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
        let sliced = LibraryFileCaps.isSliced(f) ? " · sliced" : ""
        return "\(type)\(sliced) · \(LibraryFormat.bytes(f.fileSize?.double))"
    }

    /// Library thumbnails carry the camera stream token in the query, so no header is involved.
    ///
    /// Goes through `LibraryThumb` rather than a bare `AsyncImage` because most of these images are
    /// not pictures of the model — see `PlateImageProbe`. The library list is passed in so a sliced
    /// file can borrow the render of the model it was sliced from.
    @ViewBuilder
    private func libraryThumb(_ f: LibraryFile, glyphSize: CGFloat,
                              showsProvenance: Bool = true) -> some View {
        if let client = model.client, let token = model.cameraToken {
            LibraryThumb(file: f, library: store.files ?? [], client: client, token: token,
                         glyphSize: glyphSize, showsProvenance: showsProvenance)
        } else {
            Image(systemName: LibraryFileCaps.hasGcode(f) ? "shippingbox" : "doc")
                .font(.system(size: glyphSize))
                .foregroundStyle(c.t3)
        }
    }

    /// The long-press menu. It was delete-only once, which left every other per-file action
    /// undiscoverable. Suppressed entirely while selecting, where a long press means nothing.
    @ViewBuilder
    private func withMenu<Content: View>(_ f: LibraryFile, @ViewBuilder content: () -> Content) -> some View {
        if store.selecting {
            content()
        } else {
            content().contextMenu {
                Button { model.overlay = .wizard(f) } label: { Label("Print…", systemImage: "printer") }
                if LibraryFileCaps.isStl(f) {
                    Button { model.overlay = .stlViewer(f) } label: { Label("View in 3D", systemImage: "cube") }
                }
                // hasGcode, not isSliced: only a gcode.3mf has toolpaths to show.
                if LibraryFileCaps.hasGcode(f) {
                    Button { model.overlay = .layerViewer(f) } label: { Label("View layers", systemImage: "square.3.layers.3d") }
                }
                Button { Task { await share(f) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { pendingDelete = f } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func pick(_ f: LibraryFile) {
        if store.selecting {
            store.toggleSelection(f.id)
        } else {
            model.overlay = .wizard(f)
        }
    }

    private func play(_ pf: PrinterFile) { handOff(pf, to: .player) }
    private func showLayers(_ pf: PrinterFile) { handOff(pf, to: .layers) }

    /// Hand a file from the detail sheet to a full-screen presentation. UIKit refuses to present a
    /// full-screen cover while a sheet is still dismissing, so the swap waits out the dismissal
    /// animation.
    private func handOff(_ pf: PrinterFile, to target: SdPresentation) {
        sheetFile = nil
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            switch target {
            case .player: playFile = pf
            case .layers: layerFile = pf
            }
        }
    }

    // MARK: - Printer (SD card) segment

    @ViewBuilder
    private var printerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if store.printerPath != "/" {
                    // `chevron.backward`, not `arrow.up`: this is "go back one level", and an upward
                    // arrow reads as sort order or scroll-to-top. The label also needs an explicit
                    // `contentShape` — a glyph over a background is only hit-tested on the drawn
                    // pixels, so taps that missed the strokes fell THROUGH to the file row behind and
                    // opened it, which is what made the control look broken rather than merely ugly.
                    Tap { Task { await store.loadPrinter(LibraryBrowse.parentPath(store.printerPath)) } } content: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(c.t1)
                            .frame(width: 36, height: 36)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s2))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .accessibilityLabel("Back to \(LibraryBrowse.parentPath(store.printerPath))")
                }
                Text("printer:\(store.printerPath)")
                    .font(.mono(12))
                    .foregroundStyle(c.t3)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 12)
            // Keeps the row above the list: a fall-through here opens a file instead of navigating.
            .zIndex(1)

            // Exclusive branches: an empty media folder used to render "Empty folder" AND the grid's
            // own "No videos here yet." one under the other.
            if store.printerLoading {
                ProgressView().tint(c.accent).padding(.top, 30)
            } else if store.printerList != nil, pSorted.isEmpty {
                LibEmpty(
                    icon: "externaldrive",
                    title: "Empty folder",
                    message: "Nothing here on the printer's onboard storage."
                )
            } else if PrinterFiles.isMediaFolder(store.printerPath) {
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
                Task { await store.loadPrinter(pf.path) }
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
    //
    // Every fetch and every mutation lives in `LibraryStore`. What is left here is the part that is
    // genuinely about THIS screen: dismissing a presentation before an alert can appear, and naming
    // the cache slot a share downloads into.

    private func deleteSd(_ pf: PrinterFile) async {
        // Close the sheet/player first: they are modal presentations, and an error alert raised
        // from underneath one would never appear.
        sheetFile = nil
        playFile = nil
        await store.deleteSd(pf)
    }

    /// The local copy is cached under the file's DISPLAY name, made separator-safe. The naming rules
    /// are `LibraryBrowse`'s, which is why the store is handed the result rather than deriving it.
    private func share(_ f: LibraryFile) async {
        await store.share(f, cacheName: LibraryBrowse.safeShareName(LibraryBrowse.displayName(f)))
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

/// Tap an SD-card file: sliced 3MFs get a real plate preview plus print time and filament weight and
/// a route into the layer viewer, videos get Play, everything gets Download (to the share sheet) and
/// Delete.
///
/// The plate fetch is best-effort — a file the printer cannot describe still has to open.
///
/// `onPlay` and `onLayers` are mutually exclusive in practice (a `.3mf` is never an `.mp4`), so the
/// button row is never more than three wide.
private struct PrinterFileSheet: View {
    let client: BambuddyClient
    let printerId: Int
    let file: PrinterFile
    var onDelete: () -> Void
    var onPlay: (() -> Void)?
    var onLayers: (() -> Void)?

    @Environment(\.palette) private var c
    @Environment(\.dismiss) private var dismiss
    @State private var plate: PlateInfo?
    @State private var busy = false
    @State private var shareItem: LibShareItem?
    @State private var problem: LibProblem?
    @State private var confirmDelete = false

    private var sliced: Bool { PrinterFiles.isSliced3mf(file.name) }
    /// Download demotes itself to a secondary button whenever something else is the headline action.
    private var hasPrimaryAction: Bool { onPlay != nil || onLayers != nil }
    private var downloadInk: Color { hasPrimaryAction ? c.t1 : c.accentInk }

    var body: some View {
        VStack(spacing: 0) {
            // The system's close button for a sheet, in the corner Photos and Mail put it.
            //
            // This sheet had NO dismiss control: a fixed-height detent with no grabber shown, so
            // the only way out was a drag someone had to already know about. `xmark.circle.fill`
            // in `.secondary` is the platform's own affordance for exactly this.
            HStack {
                Spacer()
                Tap(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(c.t3)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Close")
            }
            .padding(.trailing, 6)
            .padding(.top, 6)

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
                if let onLayers {
                    Tap(disabled: busy, action: onLayers) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.3.layers.3d").font(.system(size: 15))
                            Text("Layers").font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(c.accentInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(c.accent))
                        .opacity(busy ? 0.5 : 1)
                    }
                }
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
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(hasPrimaryAction ? c.s3 : c.accent))
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
            // `LibCache.url` takes names that are already separator-safe, and an SD entry's name is
            // whatever the printer's own listing said it was.
            let local = try await FileDownloadDelegate.run(request, to: LibCache.url(for: LibraryBrowse.safeShareName(file.name)))
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
        // Same cache key as the sheet's Download, so a file fetched by one is reused by the other.
        let dest = LibCache.url(for: LibraryBrowse.safeShareName(file.name))
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

// MARK: - Share sheet

/// The system share sheet. SwiftUI's `ShareLink` needs its item up front, but everything shared here
/// only exists after an async download.
private struct LibShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
