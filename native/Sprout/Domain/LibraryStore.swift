import Foundation
import Observation

/// Which file store the Files section is showing — the Bambuddy library, or the printer's own SD
/// card.
///
/// Lives here rather than in a view because `LibraryStore` owns the switch: `reload` re-lists the SD
/// card only when that is the segment on screen, and the SD listing loads once and then persists
/// across segment switches. Both view trees drive the same selection.
enum LibrarySource: String, CaseIterable, Identifiable, Sendable {
    case library
    case printer

    var id: String { rawValue }
    var label: String { self == .library ? "Library" : "Printer" }
}

/// A share target. `Identifiable` so an activity sheet can be driven by `.sheet(item:)`.
struct LibShareItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
}

/// A failure worth interrupting the user for.
struct LibProblem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - LibraryStore

/// The Files section's data layer: the Bambuddy library, the printer's own SD card, the
/// multi-select deletion set, and the download-that-feeds-a-share-sheet.
///
/// Extracted from `LibraryView` so that the macOS Files section drives the same fetches instead of
/// re-implementing them — see `docs/native-rewrite/18-mac-port-architecture.md`. Layout is
/// duplicated between the two view trees because the two layouts genuinely differ; **this is not**.
///
/// There is no poller, and that is not an omission: nothing in Files changes unless the user or an
/// upload changes it. `load()` is driven by the view appearing, `reload()` by ⌘R and
/// pull-to-refresh, and `start()` exists for a caller that has no `.task` to hang the first fetch
/// on.
@Observable
@MainActor
final class LibraryStore {

    // MARK: The library

    /// nil while the first load is in flight. An empty array is a genuinely empty library — the
    /// difference decides between a spinner, a retry banner and "No files yet".
    private(set) var files: [LibraryFile]?
    private(set) var loadFailed = false

    // MARK: Printer onboard storage (SD card)

    private(set) var printerList: PrinterFileList?
    private(set) var printerPath = "/"
    private(set) var printerLoading = false

    /// Which segment is on screen. Written by the view, read by `reload` and `loadPrinterIfNeeded`.
    var source: LibrarySource = .library

    // MARK: Multi-select

    private(set) var selecting = false
    /// Library file ids ticked for bulk deletion.
    private(set) var selected: Set<Int> = []

    // MARK: Results the view presents

    /// The downloaded copy waiting for a share sheet. The view clears it when the sheet closes.
    var shareItem: LibShareItem?
    /// The failure worth interrupting the user for. The view clears it when its alert closes.
    var problem: LibProblem?
    /// True while `share` is minting and downloading. Menu-driven shares have no sheet to host a
    /// spinner, so the view floats the progress instead.
    private(set) var downloadBusy = false

    // MARK: Wiring

    private var client: BambuddyClient?
    /// SD-card paths belong to one machine, so every printer-storage call needs the selection.
    private var printerId: Int = 0
    private var loadTask: Task<Void, Never>?

    nonisolated init() {}

    /// Point the store at a session. Called when the app connects, when it disconnects, and
    /// whenever the selected printer changes.
    ///
    /// Deliberately does NOT clear what is on screen. The iOS view keeps its list across a
    /// Settings → Save today, and a store that blanked here would leave the Files section spinning
    /// instead: the view's `.task` does not re-fire on a reconnect, because the view's identity
    /// never changed, so nothing would call `load` until the tab was left and re-entered.
    /// Point the store at a session. Clears whatever the PREVIOUS session put on screen.
    ///
    /// This used to record and clear nothing, on the reasoning that a refresh should not blank the
    /// list. That is true of a refresh and false of a session change, and the two are different
    /// questions — the classic nearby-predicate mistake this codebase keeps rediscovering.
    ///
    /// It mattered destructively. `selecting`/`selected` were `@State` on `LibraryView`, and
    /// `Shell` tears the whole tab host down whenever `client == nil`, so signing out reset them.
    /// The store is owned by `AppModel` and outlives that. Enter multi-select, tick three files,
    /// sign out, connect to a DIFFERENT Bambuddy: Files reopened with "3 selected" still showing
    /// and Delete issued `DELETE` for the previous library's ids against the new one. Library ids
    /// are small integers, so they collide with real files.
    func attach(client: BambuddyClient?, printerId: Int) {
        let newSession = client !== self.client
        let newPrinter = printerId != self.printerId
        self.client = client
        self.printerId = printerId

        if newSession {
            // Everything here is derived from the server that just went away.
            files = nil                 // back to "never loaded", so the spinner is reachable again
            loadFailed = false
            selecting = false
            selected = []
            shareItem = nil
            problem = nil
        }
        if newSession || newPrinter {
            // Onboard storage is per-MACHINE. `source` is a UI preference and survives; clearing
            // the listing is what makes `loadPrinterIfNeeded` re-list from the root instead of
            // early-returning on a listing that belongs to another printer.
            printerList = nil
            printerPath = "/"
        }
    }

    /// The first fetch, for a caller that has no `.task` to hang it on — the macOS window drives its
    /// sections this way. iOS keeps driving `load` and `loadPrinterIfNeeded` from the screen itself,
    /// so its behaviour is untouched.
    func start() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.load()
            await self?.loadPrinterIfNeeded()
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Loading

    func load() async {
        guard let client else { return }
        do {
            files = try await client.listFiles()
            loadFailed = false
        } catch {
            // A failed fetch is NOT an empty library — keep whatever is on screen and offer a retry.
            files = files ?? []
            loadFailed = true
        }
    }

    func loadPrinter(_ path: String) async {
        guard let client else { return }
        printerLoading = true
        defer { printerLoading = false }
        if let r = try? await client.listPrinterFiles(printerId, path: path) {
            printerList = r
            printerPath = r.path.isEmpty ? path : r.path
        } else {
            // Silent on purpose: an unreadable folder reads as empty rather than as a broken tab.
            printerList = PrinterFileList(path: path, files: [])
        }
    }

    /// The SD listing loads the first time the segment is opened and then persists across segment
    /// switches. Driven by the view's `.task(id: source)`, so it also covers a view that mounts with
    /// the printer segment already selected.
    func loadPrinterIfNeeded() async {
        guard source == .printer, printerList == nil else { return }
        await loadPrinter("/")
    }

    /// What ⌘R and pull-to-refresh call.
    func reload() async {
        // The SD segment has its own spinner, so re-list it too when it is the one on screen.
        if source == .printer { await loadPrinter(printerPath) }
        await load()
    }

    // MARK: - Multi-select

    func beginSelecting() { selecting = true }

    func isSelected(_ id: Int) -> Bool { selected.contains(id) }

    func toggleSelection(_ id: Int) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func exitSelect() {
        selecting = false
        selected = []
    }

    // MARK: - Deleting

    func deleteLibrary(_ f: LibraryFile) async {
        guard let client else { return }
        do {
            try await client.deleteFile(f.id)
            await load()
        } catch {
            problem = LibProblem(title: "Couldn’t delete", message: error.localizedDescription)
        }
    }

    func bulkDelete() async {
        guard let client else { return }
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

    /// Delete one file from the printer's onboard storage and re-list the folder.
    ///
    /// The caller closes any sheet or player showing the file FIRST: they are modal presentations,
    /// and an error alert raised from underneath one would never appear.
    func deleteSd(_ pf: PrinterFile) async {
        guard let client else { return }
        do {
            try await client.deletePrinterFile(printerId, path: pf.path)
            await loadPrinter(printerPath)
        } catch {
            problem = LibProblem(title: "Couldn’t delete", message: error.localizedDescription)
        }
    }

    // MARK: - Share

    /// Download a library file to the cache and hand it to `shareItem`.
    ///
    /// `cacheName` is the filename the local copy is saved under. It is passed in because the
    /// display-name rules that produce it (`LibraryBrowse.displayName` → `safeShareName`) still live
    /// beside the iOS view; when they move to `Domain/` — the macOS Files section needs them to
    /// render a single row — this parameter should move with them and be computed here.
    func share(_ f: LibraryFile, cacheName: String) async {
        guard let client else { return }
        downloadBusy = true
        defer { downloadBusy = false }
        do {
            // The slicer token IS the auth and is single-use and short-lived, so it is minted per
            // share and the download carries no headers at all. The filename lands in a path
            // segment, so it goes through the sanitiser first — an empty `filename` is not caught by
            // the client's `?? "model-{id}.stl"` default and would leave the URL a segment short.
            let downloadName = LibraryDownloadName.pathSegment(f.filename, fallback: "model-\(f.id)")
            let url = try await client.mintFileDownloadUrl(f.id, filename: downloadName)
            let dest = LibCache.url(for: cacheName)
            let local = try await FileDownloadDelegate.run(URLRequest(url: url), to: dest)
            shareItem = LibShareItem(url: local)
        } catch {
            problem = LibProblem(title: "Couldn’t download", message: error.localizedDescription)
        }
    }

    /// Download a file from the printer's own storage and hand it to the same `shareItem`.
    ///
    /// Deliberately a sibling of `share(_:cacheName:)` rather than a branch inside it: the two differ
    /// in the one place that matters most, and merging them would put a credential decision behind an
    /// `if`. A library share **mints a single-use slicer token into the URL and sends no headers**; an
    /// SD download is authenticated by the `X-API-Key` **header** and 401s on the bare URL. Getting
    /// that backwards fails identically in both directions — a 401 that looks like a missing file.
    ///
    /// `downloadBusy` is shared with the library share on purpose. It is what both platforms' Share
    /// buttons already disable on, and two downloads in flight race on the single `shareItem`: the
    /// sheet can end up pointing at the other file's local copy. One flag, one at a time, either kind.
    ///
    /// The cache name comes from the entry's own `name` — a `PrinterFile`'s name is its display name,
    /// with no percent-encoding — but it still goes through the separator sanitiser, because the value
    /// is whatever the printer's listing said and it lands in a filename.
    func shareSd(_ pf: PrinterFile) async {
        guard let client, SdFileCaps.canDownload(pf) else { return }
        downloadBusy = true
        defer { downloadBusy = false }
        guard let url = client.printerFileDownloadUrl(printerId, path: pf.path) else {
            problem = LibProblem(title: "Couldn’t download",
                                 message: "That file’s path can’t be turned into a URL.")
            return
        }
        var request = URLRequest(url: url)
        for (key, value) in client.authHeaders() { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let dest = LibCache.url(for: LibraryDownloadName.fileName(pf.name, fallback: "printer-file"))
            shareItem = LibShareItem(url: try await FileDownloadDelegate.run(request, to: dest))
        } catch {
            problem = LibProblem(title: "Couldn’t download", message: error.localizedDescription)
        }
    }
}

// MARK: - Downloads and cache

/// Moved out of `LibraryView` with `share`: the SD-card sheet and the SD video player download
/// through these too, and on macOS so will the Files section. Nothing here is view or platform
/// specific.
enum LibCache {
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
final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
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
