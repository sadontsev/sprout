#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Where the selection lives

/// The Files selection, and why it is `@SceneStorage` rather than `@State`.
///
/// `MacFilesSection` and `MacFilesInspector` are SIBLINGS — both are constructed by
/// `MacSectionContent`, which this pass does not own. So there is no parent to hold the selection in
/// `@State` and no binding to thread down to the inspector. Of the places both halves *can* reach,
/// scene storage is the only one that is still per-window: two windows open on the same library are
/// allowed to have two different files selected, which parking it on `AppModel` would forbid, and
/// SwiftUI restores it with the scene for free.
///
/// **The keys are a persisted format**, exactly like `TabKey`'s raw values and `mac.section` —
/// renaming one silently resets the user's selection instead of failing.
enum MacFilesSelection {
    /// The selected LIBRARY file's `id`.
    static let library = "mac.files.selected"
    /// The selected SD file's PATH. An SD entry has no library id at all (`PrinterFile.id` *is* its
    /// path), so the two selections cannot share one key even though only one is ever on screen.
    static let printer = "mac.files.selectedSd"
    static let layout = "mac.files.layout"
    static let sort = "mac.files.sort"
}

/// Grid or list. The prototype's switch, persisted per scene so it survives a relaunch.
enum MacFilesLayout: String, CaseIterable, Identifiable, Sendable {
    case grid, list

    var id: String { rawValue }
    var label: String { self == .grid ? "Grid" : "List" }
}

/// How the loaded files are ordered.
///
/// **There is deliberately no "date added", which is what the prototype's `Sorted by date added`
/// asks for**, and the reason differs by segment — which is why the justification the sort control
/// shows is a function of the segment rather than one sentence printed over both:
///
/// - **Library.** `LibraryFile` publishes no timestamp — not on `GET /library/files` and not on the
///   per-file detail record — so the control would have to sort on `id` descending and *call* that a
///   date.
/// - **Printer SD.** `PrinterFile` *declares* an `mtime`, so the library's reason is simply false
///   here. But "the field is on the model" and "the server sends a value this app can read" are two
///   different questions, and only the second one may gate a control. Nothing in this app has ever
///   read a value out of `mtime`: it is undocumented (`docs/native-rewrite/01-api.md:494` lists it
///   as `mtime?` and stops), no probe has recorded one, and a string of unknown shape sorts
///   correctly only by luck — `"1700000000"` and `"999999999"` compare backwards as text. Shipping
///   a `Date modified` order over that is the same bet as calling `id` descending a date.
///
/// TODO(mtime): capture one real `GET /printers/{id}/files` response, write the format down in
/// `docs/native-rewrite/01-api.md`, then add a `.date` case gated on the loaded rows actually
/// carrying readable stamps — with the unreadable ones kept in a trailing group in the printer's own
/// order, the way `VersionGrouping` handles versions that publish no settings.
///
/// A predicate that answers a nearby question is the recurring bug in this codebase, so the default
/// is named for what it actually is: the order the server sent. Same discipline, and deliberately
/// the same wording, as Explore labelling its unsorted results "MakerWorld's order" rather than
/// "Relevance".
enum MacFileSort: String, CaseIterable, Identifiable, Sendable {
    case server, name, size, type

    var id: String { rawValue }

    /// What the menu row says.
    ///
    /// `server` takes the segment because "Library order" is a lie while the printer's own storage is
    /// on screen — the order came from the printer, not from Bambuddy's library listing.
    func label(in source: LibrarySource) -> String {
        switch self {
        case .server: source == .printer ? "Printer’s order" : "Library order"
        case .name: "Name"
        case .size: "Size"
        case .type: "Type"
        }
    }

    /// What the collapsed control says. `server` is not "sorted by" anything, and saying so is the
    /// whole reason the case exists.
    func summary(in source: LibrarySource) -> String {
        self == .server ? label(in: source) : "Sorted by \(label(in: source).lowercased())"
    }
}

/// One breadcrumb: the label, and the path clicking it navigates to.
struct MacFileCrumb: Identifiable, Hashable, Sendable {
    let name: String
    let path: String

    /// Paths are unique within one breadcrumb trail, which is what makes them usable as identity.
    var id: String { path }
}

// MARK: - Pure browse helpers

/// Filter / sort / naming rules for the Mac Files section.
///
/// **This duplicates `LibraryBrowse`, and it should not have to.** That type is `private` inside
/// `LibraryView.swift`, which is wrapped in `#if os(iOS)`, so it is unreachable from here twice
/// over. `LibraryStore.share(_:cacheName:)` already carries a note saying these rules should move to
/// `Domain/` the moment the Mac section needs them — that moment is now, but `LibraryView.swift` and
/// `Domain/` are not files this pass owns. Until they move, the two copies must agree, so the shared
/// rules are copied verbatim rather than re-derived.
enum MacFileBrowse {
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
    static func filter(_ files: [LibraryFile], query: String) -> [LibraryFile] {
        let q = normalise(query)
        guard !q.isEmpty else { return files }
        return files.filter {
            displayName($0).lowercased().contains(q) || $0.filename.lowercased().contains(q)
        }
    }

    /// The same question — "does this row's name contain what was typed" — asked of the SD listing.
    ///
    /// It needs its own function rather than a generic one because the two row types answer "what is
    /// this called?" differently: a `LibraryFile` has a `printName`/`filename` pair and arrives
    /// percent-encoded, while a `PrinterFile`'s `name` **is** its display name. Folders are matched
    /// too — a folder is a thing you are looking for.
    ///
    /// This existing at all is a defect fix: `sdRows` used to ignore `query` entirely, so the search
    /// field sat live and enabled over the Printer SD segment and filtered nothing. That is row 1 of
    /// CLAUDE.md's recurring-bug table verbatim — a control that looks live and silently does
    /// nothing.
    static func filterPrinterFiles(_ files: [PrinterFile], query: String) -> [PrinterFile] {
        let q = normalise(query)
        guard !q.isEmpty else { return files }
        return files.filter { $0.name.lowercased().contains(q) }
    }

    private static func normalise(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Order the loaded library files. `.server` is the absence of an order and is returned untouched.
    static func sort(_ files: [LibraryFile], by order: MacFileSort) -> [LibraryFile] {
        guard let compare = libraryComparator(for: order) else { return files }
        // Decorate–sort–undecorate. Every comparator falls back to the display name, and
        // `displayName` percent-decodes and allocates — a comparator that calls it recomputes it on
        // BOTH sides of every comparison, i.e. O(n log n) decodes per pass, re-run on every
        // keystroke in the search field. Computing the key once per file makes that O(n).
        return files.map { Keyed(name: displayName($0), file: $0) }
            .sorted(by: compare)
            .map(\.file)
    }

    /// A file paired with its display name, so the sort computes that name once instead of twice per
    /// comparison.
    private struct Keyed {
        let name: String
        let file: LibraryFile
    }

    /// nil for `.server`, which is not an order at all — it is the absence of one, and the caller
    /// returns the server's own sequence untouched.
    ///
    /// A `switch` over every case rather than a `default`, so adding a sort order is a compile error
    /// here instead of a silent fall-through to "unordered".
    private static func libraryComparator(for order: MacFileSort) -> ((Keyed, Keyed) -> Bool)? {
        // Every comparator falls back to the display name, so two 4.2 MB files cannot swap places
        // between renders — `sorted(by:)` is not stable, and a grid that reshuffles on every
        // keystroke looks broken even when the order is technically valid.
        let byName: (Keyed, Keyed) -> Bool = {
            $0.name.localizedCompare($1.name) == .orderedAscending
        }
        switch order {
        case .server:
            return nil
        case .name:
            return byName
        case .size:
            return { a, b in
                let x = a.file.fileSize?.double ?? 0, y = b.file.fileSize?.double ?? 0
                return x == y ? byName(a, b) : x > y
            }
        case .type:
            return { a, b in
                let x = (a.file.fileType ?? "").lowercased(), y = (b.file.fileType ?? "").lowercased()
                return x == y ? byName(a, b) : x < y
            }
        }
    }

    /// Directories always come first, whatever the sort. A folder is not a file, and ordering the
    /// two together by size says nothing about either.
    static func sortPrinterFiles(_ files: [PrinterFile], by order: MacFileSort) -> [PrinterFile] {
        let folders = files.filter(\.isDirectory)
        let rest = files.filter { !$0.isDirectory }
        guard let compare = printerComparator(for: order) else {
            // `.server` keeps the printer's own order within each group, so it partitions rather
            // than sorts — `sorted(by:)` would be free to shuffle equal elements.
            return folders + rest
        }
        return folders.sorted(by: compare) + rest.sorted(by: compare)
    }

    /// nil for `.server`, same contract as `libraryComparator`. Splitting the two groups out before
    /// comparing is also what removed a genuinely dead branch: the old single `sorted(by:)` had to
    /// carry `case .server, .name:` even though `.server` had already returned.
    private static func printerComparator(for order: MacFileSort) -> ((PrinterFile, PrinterFile) -> Bool)? {
        let byName: (PrinterFile, PrinterFile) -> Bool = {
            $0.name.localizedCompare($1.name) == .orderedAscending
        }
        switch order {
        case .server:
            return nil
        case .name:
            return byName
        case .size:
            return { a, b in
                let x = a.size?.double ?? 0, y = b.size?.double ?? 0
                return x == y ? byName(a, b) : x > y
            }
        case .type:
            // The SD listing has no type field, so the extension IS the type here.
            return { a, b in
                let x = (a.name as NSString).pathExtension.lowercased()
                let y = (b.name as NSString).pathExtension.lowercased()
                return x == y ? byName(a, b) : x < y
            }
        }
    }

    /// Decimal MB/KB, matching the server's own accounting. Zero and nil both render as nothing —
    /// an unknown size should take up no space rather than claim "0 B".
    static func bytes(_ n: Double?) -> String {
        guard let n, n != 0, n.isFinite else { return "" }
        if n > 1e6 { return String(format: "%.1f MB", n / 1e6) }
        if n > 1e3 { return String(format: "%.0f KB", n / 1e3) }
        return "\(Int(n)) B"
    }

    /// `/cache/models` → `printer:` › `cache` › `models`, each crumb carrying the path it navigates
    /// to, so the breadcrumb is a control and not a caption.
    static func crumbs(_ path: String) -> [MacFileCrumb] {
        var out = [MacFileCrumb(name: "printer:", path: "/")]
        var running = ""
        for part in path.split(separator: "/") {
            running += "/" + part
            out.append(MacFileCrumb(name: String(part), path: running))
        }
        return out
    }
}

// MARK: - Capability gates

/// Whether the print sheet (1f) exists yet.
///
/// A named constant rather than a comment, because two surfaces ask the question — the file
/// surface's double-click and the inspector's `Print…` — and CLAUDE.md's rule is that an affordance
/// is gated on the exact capability it needs. The capability here is "is there anywhere for this to
/// go", and on macOS the answer is genuinely no: `AppModel.overlay` is the *iOS* presentation
/// mechanism and `MacWindow` presents none of its cases, so `model.overlay = .wizard(f)` would set a
/// value nothing reads and the control would silently do nothing — the exact shape of every row in
/// CLAUDE.md's recurring-bug table. Rather than ship that, both surfaces say why.
///
/// **The two surfaces say it differently, because a menu and a panel can afford different things.**
/// The inspector dims its button and prints the reason underneath it. A menu item cannot do that: a
/// disabled `NSMenuItem` cannot be clicked, carries no tooltip, and the panel that would have
/// explained it is user-collapsible (`⌥⌘I`) — so with the inspector closed, a grey `Print…` had no
/// explanation anywhere on screen. So the menu item stays *clickable* and the click is what surfaces
/// the sentence, which is exactly what `LockedActions.press` does for LAN-blocked controls and for
/// the same reason.
///
/// 1f is built: `MacPrintSheet`. `start` raises `AppModel.pendingPrint`, which `MacWindow`
/// presents — `start` is static and has no view to present from, and routing through the model is
/// what lets the grid and the inspector share one sheet instead of owning one each.
enum MacFilesPrint {
    static let isBuilt = true

    /// nil when printing is available. Non-nil is the sentence the UI shows the user.
    static var unavailableReason: String? {
        isBuilt ? nil : "The print sheet isn’t in this build yet."
    }

    /// The one hook both surfaces call, so 1f has a single place to land.
    @MainActor
    static func start(_ file: LibraryFile, model: AppModel) {
        guard isBuilt else { return }
        model.pendingPrint = file
    }
}

/// The delete confirmation copy, shared by the section and the inspector so two prompts for the same
/// irreversible action cannot drift into saying different things about it.
enum MacFilesDelete {
    static let libraryTitle = "Delete file?"
    static func libraryMessage(_ name: String) -> String {
        "“\(name)” will be removed from the library. This can’t be undone."
    }

    static let printerTitle = "Delete from printer?"
    static func printerMessage(_ name: String) -> String {
        "“\(name)” will be removed from the printer’s storage. This can’t be undone."
    }
}

// MARK: - MacFilesSection

/// §4 Files, content column (prototype lines 220–262).
///
/// A control row (source · search · sort · layout), a breadcrumb, then the files. The inspector next
/// door shows whatever is selected here; per §4 a click changes **only** the inspector — nothing in
/// this column scrolls, reloads or navigates.
///
/// The chrome is pinned and only the file surface scrolls. That is not decoration: in list mode the
/// surface is a `Table`, which scrolls itself, and a `Table` inside a page-level `ScrollView` gets an
/// unbounded height and two nested scrollers.
struct MacFilesSection: View {
    let model: AppModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// Read by the inspector too — see `MacFilesSelection`.
    @SceneStorage(MacFilesSelection.library) private var selectedId: Int?
    @SceneStorage(MacFilesSelection.printer) private var selectedSdPath: String?
    @SceneStorage(MacFilesSelection.layout) private var layoutRaw = MacFilesLayout.grid.rawValue
    @SceneStorage(MacFilesSelection.sort) private var sortRaw = MacFileSort.server.rawValue

    /// The query is deliberately NOT persisted: reopening the app inside a filtered library, with no
    /// memory of having typed anything, reads as an empty library.
    @State private var query = ""
    @State private var pendingDelete: LibraryFile?
    @State private var pendingSdDelete: PrinterFile?
    @State private var lanAlert = false

    /// Set by `moveSelection` and consumed by the grid's `ScrollViewReader`, so an arrow key reveals
    /// the card it just selected. Deliberately NOT driven off `selectedId`: that also changes on a
    /// mouse click, and scrolling a card the user just clicked out from under the pointer is its own
    /// small bug.
    @State private var scrollTarget: Int?

    /// `onDeleteCommand` is delivered through the responder chain, so the file surface has to be
    /// focusable for the Delete key to reach it. Clicking a card takes focus, which is also what
    /// makes the selection ring mean something — see `cardStroke`.
    @FocusState private var filesFocused: Bool

    /// Four across, as the prototype draws it. A constant rather than a literal in the `GridItem`
    /// array because the arrow keys need the same number: up/down is ±one row, and a row is however
    /// many columns there are.
    private static let gridColumns = 4

    private var store: LibraryStore { model.library }
    private var layout: MacFilesLayout { MacFilesLayout(rawValue: layoutRaw) ?? .grid }
    private var sort: MacFileSort { MacFileSort(rawValue: sortRaw) ?? .server }

    private var allFiles: [LibraryFile] { store.files ?? [] }
    private var shown: [LibraryFile] {
        MacFileBrowse.sort(MacFileBrowse.filter(allFiles, query: query), by: sort)
    }
    private var sdAll: [PrinterFile] { store.printerList?.files ?? [] }
    private var sdRows: [PrinterFile] {
        MacFileBrowse.sortPrinterFiles(
            MacFileBrowse.filterPrinterFiles(sdAll, query: query),
            by: sort
        )
    }

    /// What is on screen right now, filtered and sorted, alongside the unfiltered count the summary
    /// line compares against.
    ///
    /// It exists so `body` computes it **once**. `shown` filters and sorts on every access, and it
    /// used to be read three or four times per render (the summary line, the surface's empty-state
    /// checks, the grid, the table) — four full passes over the library per frame, re-run on every
    /// keystroke. The unread half is not computed at all: while the library is on screen there is no
    /// reason to sort the SD listing, and vice versa.
    private enum VisibleRows {
        case library(rows: [LibraryFile], total: Int)
        case printer(rows: [PrinterFile], total: Int)
    }

    private var visible: VisibleRows {
        store.source == .printer
            ? .printer(rows: sdRows, total: sdAll.count)
            : .library(rows: shown, total: allFiles.count)
    }

    private var locked: LockedActions { LockedActions(mode: model.lanMode, explaining: $lanAlert) }

    // MARK: Body

    var body: some View {
        let visible = self.visible
        return VStack(alignment: .leading, spacing: m.sectionGap) {
            controlRow
            if store.loadFailed, store.source == .library { retryBanner }
            if model.uploader.busy { uploadProgress }
            if let error = model.uploader.error { uploadError(error) }
            breadcrumb(visible)
            fileSurface(visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Only while a drag is actually in flight. The fact is published on `AppModel` by
            // `MacDropTarget`, which sits on the WINDOW because a drop is accepted anywhere — two
            // views, one fact. This used to read a local `@State` that nothing ever wrote, so the
            // strip was unreachable code and Files gave no sign drag-and-drop existed at all.
            if model.isDropping { dropStrip }
        }
        .animation(Motion.standard(0.18), value: model.isDropping)
        .padding(m.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(c.bg)
        // The FIRST fetch belongs to `MacSectionContent`, which starts and stops the right store for
        // whichever section is on screen. This handles only the user switching segments afterwards —
        // and it is `onChange`, not `.task(id:)`, precisely because `.task(id:)` also fires on
        // appear: `start()` already awaits `load()` then `loadPrinterIfNeeded()`, and both calls
        // check `printerList == nil` before either awaits, so a section opened with `.printer`
        // already selected issued two identical listings.
        .onChange(of: store.source) { Task { await store.loadPrinterIfNeeded() } }
        .onDeleteCommand { deleteSelection() }
        // §5.4. `QLPreviewPanel` is a SYSTEM panel, not a SwiftUI presentation, so unlike the print
        // sheet there is nothing for `MacWindow` to host and no model property to route through.
        //
        // Library only: the panel previews a file the app can render facts for, and an SD entry has
        // no library id — so it gets a sentence naming that rather than an empty panel.
        .onKeyPress(.space) {
            if store.source == .library {
                MacQuickLook.toggle(file: shown.first { $0.id == selectedId }, model: model)
            } else {
                MacQuickLook.toggle(
                    file: nil, model: model,
                    unavailable: "Quick Look reads library files. The printer's own storage carries no preview."
                )
            }
            return .handled
        }
        .modifier(FilesPresentations(
            model: model,
            pendingDelete: $pendingDelete,
            pendingSdDelete: $pendingSdDelete,
            onConfirmedLibraryDelete: { deleted in
                // Only if the file being deleted is the one on show. Right-clicking an UNSELECTED
                // card does not move the selection, so clearing it unconditionally meant deleting
                // file B left the inspector saying "No file selected" about file A, which still
                // exists.
                if selectedId == deleted.id { selectedId = nil }
            },
            onConfirmedPrinterDelete: { deleted in
                if selectedSdPath == deleted.path { selectedSdPath = nil }
            }
        ))
        .lockedActionAlert($lanAlert)
    }

    // MARK: Control row

    private var controlRow: some View {
        HStack(spacing: 10) {
            MacSegmented(
                options: LibrarySource.allCases,
                // Not `LibrarySource.label` ("Library" / "Printer"): §4 names the second segment
                // "Printer SD", because "Printer" beside a printer-shaped app means the machine, not
                // its storage. The store's own label is the one iOS draws and is left alone.
                label: { (s: LibrarySource) in s == .library ? "Library" : "Printer SD" },
                selection: Binding(get: { store.source }, set: { store.source = $0 })
            )
            searchField
            Spacer(minLength: 8)
            sortMenu
            MacSegmented(
                options: MacFilesLayout.allCases,
                label: { (l: MacFilesLayout) in l.label },
                selection: Binding(get: { layout }, set: { layoutRaw = $0.rawValue }),
                compact: true
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(c.t3)
            // A plain `TextField`, not `.searchable`: `.searchable` puts the field in the WINDOW
            // TOOLBAR, which `MacToolbar` owns, and the prototype draws it here — beside the source
            // picker whose contents it filters. Both segments, since both are filtered.
            TextField("Search files", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(c.t1)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(c.t3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .frame(width: 250, height: m.controlHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(c.line))
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(get: { sort }, set: { sortRaw = $0.rawValue })) {
                ForEach(MacFileSort.allCases) { Text(verbatim: $0.label(in: store.source)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(verbatim: sort.summary(in: store.source))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(c.t3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(sortHelp)
    }

    /// The one thing this control must never imply is that it asked the server to reorder anything.
    /// It sorts what is loaded — for the library, that is everything.
    ///
    /// The second sentence is per-segment because the two segments have different reasons for having
    /// no date order, and the single sentence that used to be printed over both was **false on the
    /// printer's**: `LibraryFile` carries no timestamp at all, while `PrinterFile` declares an
    /// `mtime` whose format has never been observed. See `MacFileSort`.
    private var sortHelp: String {
        store.source == .printer
            ? "Reorders the files already loaded. The SD listing declares a modified time, but its format has never been observed, so there is no date order yet."
            : "Reorders the files already loaded. The library listing carries no date, so there is no “date added”."
    }

    // MARK: Breadcrumb

    @ViewBuilder
    private func breadcrumb(_ visible: VisibleRows) -> some View {
        HStack(spacing: 6) {
            if store.source == .library {
                // The Bambuddy library is FLAT — there are no folders to walk, which is why this
                // branch has at most two crumbs while the SD branch below walks a real path.
                crumb("Library", active: query.isEmpty)
            } else {
                printerCrumbs
                if store.printerLoading {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                }
            }
            // The query crumb belongs to BOTH segments now that the search filters both. It is what
            // says on screen that the list has been narrowed, which is the difference between "the
            // printer has three files" and "three of the printer's files match".
            if !query.isEmpty {
                separator
                crumb("“\(query)”", active: true)
            }
            Spacer(minLength: 12)
            Text(verbatim: summaryLine(visible))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(c.t3)
                .monospacedDigit()
        }
    }

    private var printerCrumbs: some View {
        let parts = MacFileBrowse.crumbs(store.printerPath)
        return ForEach(parts) { part in
            if part.id != parts.first?.id { separator }
            if part.id == parts.last?.id {
                crumb(part.name, active: query.isEmpty)
            } else {
                Button { Task { await store.loadPrinter(part.path) } } label: {
                    crumb(part.name, active: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to \(part.path)")
            }
        }
    }

    private func crumb(_ text: String, active: Bool) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(active ? c.t1 : c.t3)
    }

    private var separator: some View {
        Text(verbatim: "›")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(c.line2)
    }

    /// `14 files · 212 MB`, and `7 of 14 files · 96 MB` while a search narrows it. The counts
    /// describe what is on screen — a total that ignores the filter reads as a bug.
    private func summaryLine(_ visible: VisibleRows) -> String {
        switch visible {
        case let .printer(rows, total):
            let files = rows.filter { !$0.isDirectory }
            let folders = rows.count - files.count
            let size = MacFileBrowse.bytes(files.reduce(0) { $0 + ($1.size?.double ?? 0) })
            let head = folders > 0 ? "\(folders) folder\(folders == 1 ? "" : "s") · " : ""
            // Narrowed by the search, so it says so here too — the same "n of N" the library half
            // has always shown. Directories count towards both numbers, because they are rows.
            let tail = rows.count == total
                ? "\(files.count) file\(files.count == 1 ? "" : "s")"
                : "\(rows.count) of \(total) entries"
            return size.isEmpty ? head + tail : "\(head)\(tail) · \(size)"
        case let .library(rows, total):
            let size = MacFileBrowse.bytes(rows.reduce(0) { $0 + ($1.fileSize?.double ?? 0) })
            let count = rows.count == total
                ? "\(rows.count) file\(rows.count == 1 ? "" : "s")"
                : "\(rows.count) of \(total) files"
            return size.isEmpty ? count : "\(count) · \(size)"
        }
    }

    // MARK: The files

    @ViewBuilder
    private func fileSurface(_ visible: VisibleRows) -> some View {
        switch visible {
        case let .printer(rows, total):
            printerSurface(rows: rows, total: total)
        case let .library(rows, total):
            librarySurface(rows: rows, total: total)
        }
    }

    @ViewBuilder
    private func librarySurface(rows: [LibraryFile], total: Int) -> some View {
        if store.files == nil, !store.loadFailed {
            centred { ProgressView().controlSize(.small) }
        } else if total == 0 {
            // A failed fetch is NOT an empty library. `LibraryStore.load` substitutes `[]` so the
            // stale list survives, which means "no files" and "couldn't reach the server" arrive
            // together — and "No files yet" printed under the retry banner is a second, contradictory
            // answer to the same question.
            if !store.loadFailed {
                centred {
                    emptyState(
                        icon: "folder",
                        title: "No files yet",
                        message: "Add an STL, 3MF or sliced G-code with the toolbar’s Add file, and it shows up here."
                    )
                }
            }
        } else if rows.isEmpty {
            centred {
                emptyState(
                    icon: "magnifyingglass",
                    title: "No files match",
                    message: "Nothing in the library matches “\(query)”."
                )
            }
        } else if layout == .grid {
            ScrollView {
                ScrollViewReader { proxy in
                    libraryGrid(rows)
                        .padding(.bottom, 8)
                        // An arrow key that moves the selection off screen has moved nothing the
                        // user can see. `scrollTarget` is written only by `moveSelection`.
                        .onChange(of: scrollTarget) { _, target in
                            guard let target else { return }
                            withAnimation(Motion.standard(0.2)) { proxy.scrollTo(target, anchor: .center) }
                            scrollTarget = nil
                        }
                }
            }
            .scrollIndicators(.automatic)
        } else {
            libraryTable(rows)
        }
    }

    private func libraryGrid(_ rows: [LibraryFile]) -> some View {
        LazyVGrid(
            columns: Array(
                // The minimum keeps the cards from becoming stamps at §1's 640 pt content minimum
                // with the inspector open.
                repeating: GridItem(.flexible(minimum: 118), spacing: m.cardGap),
                count: Self.gridColumns
            ),
            spacing: m.cardGap
        ) {
            ForEach(rows) { card($0) }
        }
        .focusable()
        // The system focus ring would draw around the whole GRID, which says nothing about which
        // card Delete will act on. The card's own ring carries that instead — see `cardStroke`.
        .focusEffectDisabled()
        .focused($filesFocused)
        // A `Table` gets arrow-key selection from AppKit; a `LazyVGrid` gets nothing at all, so
        // before this the grid had no keyboard selection whatsoever and the Delete key could only
        // ever act on a selection the mouse had made.
        .onMoveCommand { moveSelection($0, in: rows) }
    }

    private func card(_ f: LibraryFile) -> some View {
        let on = selectedId == f.id
        return VStack(alignment: .leading, spacing: 0) {
            // Library thumbnails are gated by the camera STREAM token in `?token=`, never by
            // `X-API-Key` (which 401s here), so `CachedThumb` needs no headers at all. The token
            // rotates hourly and is part of the URL, so a rotation costs one re-fetch per visible
            // tile — correct, and far cheaper than a cache key that could serve a 401'd image.
            CachedThumb(url: thumbUrl(f), aspect: 4.0 / 3.0)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) { typeChip(f) }
                .overlay(alignment: .topTrailing) { if LibraryFileCaps.isSliced(f) { slicedTick } }

            Text(verbatim: MacFileBrowse.displayName(f))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(c.t1)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 9)
            Text(verbatim: MacFileBrowse.bytes(f.fileSize?.double))
                .font(.mono(10.5, weight: .medium))
                .foregroundStyle(c.t3)
                .monospacedDigit()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(
            RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
                .strokeBorder(cardStroke(selected: on), lineWidth: on ? 1.5 : 1)
        )
        .contentShape(.rect)
        // The two-count gesture is declared FIRST: a single-tap gesture declared before it claims
        // the first click and the second one never arrives.
        .onTapGesture(count: 2) { requestPrint(f) }
        .onTapGesture { select(f) }
        .contextMenu { fileMenu(f) }
        // §5.3, the other direction. A promise, so grabbing a 60 MB print does not stall the
        // gesture — see `MacFileDrag`.
        .macFileDrag(f, model: model)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// The card's border, and the two questions it answers at once.
    ///
    /// It used to answer only "is this the file the inspector is showing?" — while the Delete key is
    /// delivered to whatever has FOCUS, and the grid draws no focus indication at all
    /// (`.focusEffectDisabled()`). So the one control whose target the user most needs to know was
    /// invisible. Accent means selected *and* the keys will land here; the dimmer ring means
    /// selected but the keyboard is somewhere else.
    private func cardStroke(selected: Bool) -> Color {
        guard selected else { return c.line }
        return filesFocused ? c.accent : c.line2
    }

    private func typeChip(_ f: LibraryFile) -> some View {
        Text(verbatim: (f.fileType ?? "").uppercased())
            .font(.mono(8.5))
            .tracking(0.5)
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.5)))
            .padding(6)
    }

    /// The "prepared by a slicer" badge — `isSliced`, which is a LABEL. It must never be confused
    /// with `hasGcode`, the capability the layer viewer needs; the inspector gates on that one.
    private var slicedTick: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(c.accentInk)
            .frame(width: 14, height: 14)
            .background(Circle().fill(c.accent))
            .padding(6)
    }

    /// The list half of the switch is a real `Table` — columns, keyboard selection and row reuse
    /// come with it, and a hand-stacked list of rows on macOS reads as a phone app that was widened.
    private func libraryTable(_ rows: [LibraryFile]) -> some View {
        Table(rows, selection: $selectedId) {
            TableColumn("Name") { f in
                HStack(spacing: 8) {
                    CachedThumb(url: thumbUrl(f), size: CGSize(width: 22, height: 22))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text(verbatim: MacFileBrowse.displayName(f))
                        .foregroundStyle(c.t1)
                        .lineLimit(1)
                }
                // Dragging out works from list mode too (§5.3). On the name cell rather than the
                // whole row because `Table` builds each column separately — there is no row view to
                // attach it to, and the name is the part a user grabs.
                .macFileDrag(f, model: model)
                // `Metrics.rowHeight` is the density token for exactly this. SwiftUI has no
                // row-height modifier on `Table`, so the tallest cell is where it has to be spent —
                // `minHeight`, never a fixed height, so a row can still grow if a cell needs to.
                .frame(minHeight: m.rowHeight)
            }
            .width(min: 180, ideal: 320)

            TableColumn("Type") { f in
                Text(verbatim: (f.fileType ?? "").uppercased())
                    .font(.mono(10.5, weight: .medium))
                    .foregroundStyle(c.t3)
            }
            .width(min: 60, ideal: 84, max: 130)

            TableColumn("Size") { f in
                Text(verbatim: MacFileBrowse.bytes(f.fileSize?.double))
                    .font(.mono(10.5, weight: .medium))
                    .foregroundStyle(c.t3)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 84, max: 130)
        }
        .focused($filesFocused)
        // `primaryAction` IS a `Table`'s double-click — the same gesture the grid's cards wire by
        // hand. One menu builder feeds both, so right-click means the same thing in either layout.
        .contextMenu(forSelectionType: LibraryFile.ID.self) { ids in
            if let f = rows.first(where: { ids.contains($0.id) }) { fileMenu(f) }
        } primaryAction: { ids in
            if let f = rows.first(where: { ids.contains($0.id) }) { requestPrint(f) }
        }
    }

    // MARK: Printer SD

    @ViewBuilder
    private func printerSurface(rows: [PrinterFile], total: Int) -> some View {
        if store.printerLoading, store.printerList == nil {
            centred { ProgressView().controlSize(.small) }
        } else if total == 0 {
            centred { sdEmptyState }
        } else if rows.isEmpty {
            centred {
                emptyState(
                    icon: "magnifyingglass",
                    title: "No files match",
                    message: "Nothing in this folder matches “\(query)”."
                )
            }
        } else {
            // Always a table: the SD card is a filesystem, and the library's card grid would be
            // claiming thumbnails that this listing does not carry.
            Table(rows, selection: $selectedSdPath) {
                TableColumn("Name") { pf in
                    HStack(spacing: 8) {
                        Image(systemName: sdSymbol(pf))
                            .font(.system(size: 12))
                            .foregroundStyle(pf.isDirectory ? c.accent : c.t3)
                            .frame(width: 16)
                        Text(verbatim: pf.name)
                            .foregroundStyle(c.t1)
                            .lineLimit(1)
                    }
                    .frame(minHeight: m.rowHeight)
                }
                .width(min: 200, ideal: 380)

                TableColumn("Size") { pf in
                    Text(verbatim: pf.isDirectory ? "—" : MacFileBrowse.bytes(pf.size?.double))
                        .font(.mono(10.5, weight: .medium))
                        .foregroundStyle(c.t3)
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 90, max: 140)
            }
            .focused($filesFocused)
            .contextMenu(forSelectionType: PrinterFile.ID.self) { ids in
                if let pf = rows.first(where: { ids.contains($0.id) }), !pf.isDirectory {
                    Button(role: .destructive) { pendingSdDelete = pf } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } primaryAction: { ids in
                // Double-click opens a folder. A FILE deliberately does nothing here: this app
                // cannot print from the printer's own storage — the wizard takes a `LibraryFile` and
                // an SD entry has only a path — so the inspector says so in words rather than a
                // double-click quietly failing.
                if let pf = rows.first(where: { ids.contains($0.id) }), pf.isDirectory {
                    Task { await store.loadPrinter(pf.path) }
                }
            }
        }
    }

    /// An empty SD listing, said honestly.
    ///
    /// This used to read "Empty folder — nothing here on the printer's onboard storage", which is a
    /// positive claim about the printer. It is not one this view is entitled to make:
    /// `LibraryStore.loadPrinter` substitutes `PrinterFileList(files: [])` on **any** error, so an
    /// unreachable printer, a permission failure and a genuinely empty folder all arrive here as the
    /// same value. That is the MakerWorld `total: 0` lesson from CLAUDE.md in a different costume —
    /// never render "you have none" from a response that also means "we could not ask".
    ///
    /// The retry is the remedy the library half has had all along (`retryBanner`).
    ///
    /// TODO(LibraryStore): give the store a `printerLoadFailed` flag — the file is not owned by this
    /// pass — and this splits into the two sentences it wants to be: "this folder is empty" and
    /// "the printer didn't answer".
    private var sdEmptyState: some View {
        emptyState(
            icon: "externaldrive",
            title: "Nothing to show",
            message: "This folder is empty, or the printer didn’t answer — an unreadable folder and an empty one arrive here identically.",
            retry: { Task { await store.loadPrinter(store.printerPath) } }
        )
    }

    private func sdSymbol(_ pf: PrinterFile) -> String {
        if pf.isDirectory { return PrinterFiles.isMediaFolder(pf.path) ? "film" : "folder" }
        if PrinterFiles.isSliced3mf(pf.name) { return "shippingbox" }
        if PrinterFiles.isPlayableVideo(pf.name) { return "film" }
        return "doc"
    }

    // MARK: Menus and actions

    /// Right-click. Deliberately the same items, in the same order, as the iOS long-press menu
    /// (`LibraryView.withMenu`) — including the two that are CONDITIONAL there. Omitting an item
    /// whose request would 404 is this codebase's established answer in a menu.
    ///
    /// `Print…` is the exception, and it is deliberate: it is not omitted and it is not disabled. A
    /// disabled `NSMenuItem` cannot be clicked and has no tooltip, so a grey `Print…` explains itself
    /// nowhere the user can reach — the inspector that carries the sentence is collapsible (`⌥⌘I`).
    /// Left clickable, the click is what surfaces the reason. See `MacFilesPrint`.
    @ViewBuilder
    private func fileMenu(_ f: LibraryFile) -> some View {
        Button {
            requestPrint(f)
        } label: {
            Label("Print…", systemImage: "printer")
        }

        if LibraryFileCaps.isStl(f) {
            Button { openViewer(f, mode: .model) } label: { Label("View in 3D", systemImage: "cube") }
        }
        // `hasGcode`, NOT `isSliced`: only a gcode.3mf carries toolpaths, and `/gcode` answers 404
        // for anything else. The two predicates sound like synonyms and are not — gating on the
        // wrong one is the bug CLAUDE.md's table records against this exact menu item.
        if LibraryFileCaps.hasGcode(f) {
            Button { openViewer(f, mode: .layers) } label: {
                Label("View layers", systemImage: "square.3.layers.3d")
            }
        }
        Divider()
        Button { Task { await share(f) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            // Unlike `Print…`, this one IS disabled while it is unavailable — and it can be, because
            // the reason is already on screen: `FilesPresentations` floats a "Preparing to share…"
            // pill for exactly as long as this is grey.
            .disabled(store.downloadBusy)
        Button(role: .destructive) { pendingDelete = f } label: { Label("Delete", systemImage: "trash") }
    }

    private func select(_ f: LibraryFile) {
        // §4's one rule: selecting changes the INSPECTOR and nothing else. Nothing here scrolls,
        // refetches or navigates.
        selectedId = f.id
        filesFocused = true
    }

    /// Arrow keys in grid mode. Left/right is one card; up/down is one row, which is however many
    /// columns the grid has.
    private func moveSelection(_ direction: MoveCommandDirection, in rows: [LibraryFile]) {
        guard !rows.isEmpty else { return }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -Self.gridColumns
        case .down: step = Self.gridColumns
        @unknown default: return
        }
        guard let current = rows.firstIndex(where: { $0.id == selectedId }) else {
            // Nothing selected, or a selection that no longer resolves: the first arrow key picks
            // the first card rather than doing nothing at all.
            selectedId = rows.first?.id
            scrollTarget = selectedId
            return
        }
        let next = current + step
        guard rows.indices.contains(next) else { return }
        selectedId = rows[next].id
        scrollTarget = rows[next].id
    }

    /// Double-click, and the context menu's `Print…`. Both land here so 1f has one place to arrive.
    ///
    /// The unavailable case **explains itself** instead of returning. It used to `guard … else {
    /// return }` before the `locked.press` that would have surfaced anything, which made a
    /// double-click on any library card a dead gesture — the very failure this file refuses on the
    /// SD side, where the inspector says so in words rather than letting a double-click quietly fail.
    private func requestPrint(_ f: LibraryFile) {
        select(f)
        if let reason = MacFilesPrint.unavailableReason {
            model.toast = .failure(reason)
            return
        }
        // LAN Developer Mode off means the printer refuses `.startPrint` outright. The gate keeps
        // the control clickable so the tap is what surfaces the explanation.
        locked.press(.startPrint) { MacFilesPrint.start(f, model: model) }()
    }

    /// Layers and the mesh viewer are meant to be ONE window with a segment (§5.4, spec line 82).
    ///
    /// **They are not, yet, and the comment that said they were was describing an intention.**
    /// `openWindow(id:value:)` reuses a window only when the VALUE compares equal, and
    /// `MacViewerRequest` synthesises `Hashable` over `fileId`, `name` *and* `mode` — so "View in 3D"
    /// followed by "View layers" on the same file opens a second window. The two questions the value
    /// answers are "which window is this?" (the file) and "which segment does it open on?" (the
    /// mode), and only the first one may take part in identity.
    ///
    /// TODO(1g): `Windows/MacViewerWindow.swift` is not a file this pass owns — the fix is a hand
    /// -written `Hashable`/`Equatable` on `MacViewerRequest` keyed on `fileId` alone, with `mode`
    /// carried as the opening segment. `AppModel.overlay` is the iOS mechanism and would be inert
    /// here, so the window is still the right shape.
    private func openViewer(_ f: LibraryFile, mode: MacViewerRequest.Mode) {
        // `MacViewer.open`, not a raw `openWindow`. `MacViewerRequest` hashes on `fileId` ALONE, so
        // that "View in 3D" then "View layers" reuses one window instead of opening two — but equal
        // values also mean SwiftUI delivers no new `mode`, so the second click would merely raise the
        // window. `MacViewer.open` carries the mode through `MacViewerRoute` alongside, which is the
        // only path that makes the segment actually change.
        MacViewer.open(f, mode: mode, using: openWindow)
    }

    /// The Delete key on the focused file surface. Routes to the same confirmation the menu raises —
    /// a delete key that skipped the alert would be the one destructive path in this app with no
    /// confirmation at all.
    ///
    /// Both halves resolve against the **visible** rows, not the whole listing. The key acts on the
    /// surface that has focus, and a file the search has filtered away is not on that surface: the
    /// library half used to look the selection up in `allFiles`, so an invisible file could be
    /// deleted by a keypress aimed at the grid. The inspector still offers its own Delete for a
    /// selection that has scrolled or filtered out of view, which is where that action belongs.
    private func deleteSelection() {
        if store.source == .printer {
            if let pf = sdRows.first(where: { $0.id == selectedSdPath }), !pf.isDirectory {
                pendingSdDelete = pf
            }
        } else if let f = shown.first(where: { $0.id == selectedId }) {
            pendingDelete = f
        }
    }

    /// `LibraryStore.share` carries no re-entrancy guard of its own, and two shares in flight race on
    /// the single `shareItem`: the sheet can end up pointing at the other file's local copy. The
    /// inspector's button was already `.disabled(store.downloadBusy)`; the context menu was not, so
    /// the guard lives here where BOTH surfaces pass through it rather than in one of them.
    ///
    /// TODO(LibraryStore): this belongs on the store — it owns `downloadBusy` — but that file is not
    /// owned by this pass.
    private func share(_ f: LibraryFile) async {
        guard !store.downloadBusy else { return }
        await store.share(f, cacheName: MacFileBrowse.safeShareName(MacFileBrowse.displayName(f)))
    }

    private func thumbUrl(_ f: LibraryFile) -> URL? {
        model.client?.fileThumbUrl(f.id, token: model.cameraToken, thumbnailPath: f.thumbnailPath)
    }

    // MARK: Chrome

    /// A failed fetch is not an empty library: the banner sits above the files and whatever was
    /// already loaded stays visible underneath it.
    private var retryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13))
                .foregroundStyle(c.t3)
            Text("Couldn’t reach the server.")
                .font(.system(size: m.body, weight: .medium))
                .foregroundStyle(c.t2)
            Spacer(minLength: 8)
            Button("Retry") { Task { await store.load() } }
                .buttonStyle(MacSecondaryButtonStyle())
        }
        .padding(m.cardPadding)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line))
    }

    /// The upload lives on `AppModel`, not on this section, because a drop is accepted anywhere in
    /// the window (§5.3) — a transfer can already be running when Files is first opened. This is the
    /// readout, not the owner.
    private var uploadProgress: some View {
        HStack(spacing: 10) {
            ProgressView(value: model.uploader.fraction)
                .progressViewStyle(.linear)
                .tint(c.accent)
            Text(verbatim: "\(model.uploader.percent) %")
                .font(.mono(11, weight: .bold))
                .foregroundStyle(c.accent)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, m.cardPadding)
        .frame(height: m.primaryControlHeight)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).strokeBorder(c.line))
        .accessibilityLabel("Uploading, \(model.uploader.percent) percent")
    }

    private func uploadError(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            UploadErrorCard(text: text)
            Button {
                model.uploader.error = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(c.t3)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss upload error")
        }
    }

    /// Drawn only while a drag is over the window (`AppModel.isDropping`). The prototype's
    /// "SPACE = QUICK LOOK" hint is deliberately absent: Quick Look belongs to the unbuilt half of
    /// §5.3, and a keyboard hint for a key that does nothing is the same lie as a live-looking dead
    /// button.
    private var dropStrip: some View {
        HStack(spacing: 10) {
            Text("DROP TARGET")
                .font(.mono(m.monoLabel, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(c.t3)
            Text("Drop .3mf, .gcode or .stl anywhere in this window — or on the Dock icon — to add it here.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(c.t2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous).fill(c.s1))
        .overlay(
            RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
                .strokeBorder(c.accent, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .transition(.opacity)
    }

    private func emptyState(
        icon: String,
        title: String,
        message: String,
        retry: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(c.t3)
            Text(verbatim: title)
                .font(.system(size: m.cardTitle, weight: .semibold))
                .foregroundStyle(c.t1)
            Text(verbatim: message)
                .font(.system(size: m.body))
                .foregroundStyle(c.t3)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Try again") { retry() }
                    .buttonStyle(MacSecondaryButtonStyle())
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: 360)
    }

    private func centred<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.top, 56)
    }

    @Environment(\.openWindow) private var openWindow
}

// MARK: - Presentations

/// Every alert and sheet this section owns, kept in a modifier so `body` stays one small expression
/// for the type-checker — the same reason `LibraryView` has `presentations(_:)`.
///
/// These cover the confirmations this column raises — the right-click menu and the Delete key. The
/// inspector, a sibling view with no way to reach this `@State`, carries its own for its own button;
/// both read their copy out of `MacFilesDelete` so the two prompts cannot describe the same
/// irreversible action differently.
private struct FilesPresentations: ViewModifier {
    let model: AppModel
    @Binding var pendingDelete: LibraryFile?
    @Binding var pendingSdDelete: PrinterFile?
    /// Handed the file that is actually being deleted, so the caller can clear the selection **only
    /// when it is that file**. A right-click does not move the selection, so an unconditional clear
    /// blanked the inspector for a file that still exists.
    let onConfirmedLibraryDelete: (LibraryFile) -> Void
    let onConfirmedPrinterDelete: (PrinterFile) -> Void

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    func body(content: Content) -> some View {
        // `problem` and `shareItem` are STORE state, so they need bindings into the store rather
        // than into `@State`.
        @Bindable var bound = model.library
        let store = model.library

        return content
            .alert(
                MacFilesDelete.libraryTitle,
                isPresented: presenting($pendingDelete),
                presenting: pendingDelete
            ) { f in
                Button("Delete", role: .destructive) {
                    // Clear the selection first — if it IS this file: the inspector resolves it
                    // against `store.files`, so leaving it set would show a file that is being
                    // deleted underneath it.
                    onConfirmedLibraryDelete(f)
                    Task { await store.deleteLibrary(f) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { f in
                Text(verbatim: MacFilesDelete.libraryMessage(MacFileBrowse.displayName(f)))
            }
            .alert(
                MacFilesDelete.printerTitle,
                isPresented: presenting($pendingSdDelete),
                presenting: pendingSdDelete
            ) { pf in
                Button("Delete", role: .destructive) {
                    onConfirmedPrinterDelete(pf)
                    Task { await store.deleteSd(pf) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { pf in
                Text(verbatim: MacFilesDelete.printerMessage(pf.name))
            }
            .alert(store.problem?.title ?? "", isPresented: presenting($bound.problem)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: store.problem?.message ?? "")
            }
            // `.sheet(item:)` clears the binding itself on dismissal, so the sheet's Done button
            // only has to dismiss — nothing has to remember to nil out `shareItem`.
            .sheet(item: $bound.shareItem) { item in
                MacShareSheet(url: item.url)
            }
            .overlay(alignment: .bottom) {
                if store.downloadBusy { busyPill }
            }
    }

    /// Menu- and inspector-driven shares have no sheet to host a spinner while the copy downloads,
    /// so the progress floats — same reasoning as the iOS screen's busy pill. It is also the on-screen
    /// explanation for the `Share…` items being grey while it is up.
    private var busyPill: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Preparing to share…")
                .font(.system(size: m.body, weight: .semibold))
                .foregroundStyle(c.t1)
        }
        .padding(.horizontal, 14)
        .frame(height: m.primaryControlHeight)
        .background(Capsule().fill(c.s1))
        .overlay(Capsule().strokeBorder(c.line))
        .shadow1()
        .padding(.bottom, 18)
    }

    private func presenting<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

/// The Mac end of "Share…".
///
/// iOS hands the downloaded copy to `UIActivityViewController` through `LibShareSheet`. macOS has no
/// equivalent presentation: `ShareLink` is a *button*, not something you present, so the finished
/// download has to land somewhere the user can act on. A small sheet carrying the real system share
/// button and a Finder reveal is that somewhere — and Finder is the answer a Mac user usually wants.
private struct MacShareSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to share")
                .font(.system(size: m.cardTitle, weight: .semibold))
                .foregroundStyle(c.t1)
            Text(verbatim: url.lastPathComponent)
                .font(.mono(11, weight: .medium))
                .foregroundStyle(c.t3)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                ShareLink(item: url) { Text("Share…") }
                    .buttonStyle(MacPrimaryButtonStyle())
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(MacSecondaryButtonStyle())
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .buttonStyle(MacSecondaryButtonStyle())
            }
        }
        .padding(18)
        // A macOS sheet sizes to its content and has no detents, so an explicit frame is the only
        // thing standing between this and a sliver.
        .frame(width: 480, alignment: .leading)
        .background(c.sheet)
    }
}

// MARK: - Segmented control

/// The prototype's pill segmented control: a 2 pt trough in `s2`, the live segment filled with `s4`.
///
/// Hand-drawn rather than `.pickerStyle(.segmented)` for the same reason `MacButtonStyles` exists —
/// the system control paints itself with the *user's* macOS accent colour and system greys, which on
/// this app's near-black `bg` reads as a control borrowed from another app. Colours are palette
/// tokens, heights come from `Metrics`.
private struct MacSegmented<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value
    var compact = false

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button { selection = option } label: {
                    Text(verbatim: label(option))
                        .font(.system(size: compact ? 11.5 : 12, weight: .semibold))
                        .foregroundStyle(on ? c.t1 : c.t3)
                        .padding(.horizontal, compact ? 11 : 14)
                        .frame(height: m.controlHeight - 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(on ? c.s4 : .clear)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(c.line))
        .animation(Motion.standard(0.14), value: selection)
    }
}
#endif
