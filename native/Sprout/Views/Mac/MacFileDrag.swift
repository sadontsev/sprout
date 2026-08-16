#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dragging a library file OUT of Sprout, into Finder or a slicer (§5.3).
///
/// A **promise**, not a file: the bytes are not on this Mac when the drag begins. The library lives
/// on the Bambuddy server, and a `.3mf` is routinely tens of megabytes, so downloading on mouse-down
/// would freeze the drag for as long as the transfer took — for a gesture the user may well abandon
/// over the Dock. `NSItemProvider.registerFileRepresentation` is the promise: the drag starts
/// instantly, and the closure runs only if something actually accepts the drop.
///
/// The download itself is the one the Share path already uses — `mintFileDownloadUrl` plus
/// `FileDownloadDelegate`. That matters beyond DRY: the slicer token **is** the auth, it is
/// single-use and short-lived, and the URL carries no headers. Minting it at drop time rather than
/// at drag time is what keeps it from expiring in the user's hand.
enum MacFileDrag {

    /// The provider for one library file.
    ///
    /// Returned from `.onDrag`, which SwiftUI calls at the START of the gesture — so everything here
    /// must be cheap. Nothing touches the network until `loadHandler` runs.
    @MainActor
    static func provider(for file: LibraryFile, model: AppModel) -> NSItemProvider {
        let provider = NSItemProvider()
        let name = LibraryFilePromise.filename(for: file)
        provider.suggestedName = name

        // `fileOptions: []` — NOT `.openInPlace`. The receiver COPIES what it is given, which is
        // what we want: the staged file is in our cache directory and is ours to delete. Promising
        // open-in-place would hand Finder a URL inside the app's container and invite it to be
        // opened, moved or trashed from there.
        provider.registerFileRepresentation(
            forTypeIdentifier: LibraryFilePromise.typeIdentifier(for: file),
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 100)
            let task = Task { @MainActor in
                do {
                    let url = try await stage(file, model: model, progress: progress)
                    completion(url, false, nil)
                } catch {
                    // Reported to the receiver AND to the user. Finder's own failure is a silent
                    // non-copy, and a drag that simply produces no file is indistinguishable from a
                    // missed drop target.
                    model.toast = .failure("Couldn’t export \(name) — \(JobsStore.failureText(error))")
                    completion(nil, false, error)
                }
            }
            // Cancelling the Progress is how a receiver says it no longer wants the file — Finder
            // does this when a copy is cancelled. Without this the download runs to completion into
            // a cache nobody will read.
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }

    /// The directory each drag stages into. Named so a drop can recognise our own export.
    static let stagingPrefix = "sprout-drag-"

    /// Is this URL one WE just vended?
    ///
    /// The window accepts a drop anywhere (§5.3), so a drag that starts in the Files grid and is
    /// released back over Sprout would be handed straight to the importer — and the file the user
    /// just exported would be re-uploaded as a duplicate. Abandoning a drag over the window you
    /// dragged from is the most ordinary way to cancel one; it must not be a way to duplicate a file.
    static func isOwnExport(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.hasPrefix(stagingPrefix) }
    }

    /// Download to a per-drag directory and return the local URL.
    ///
    /// A directory per drag, not a unique filename, because the receiver takes the name from the
    /// URL's last component and it has to be the real one. Two concurrent drags of different files
    /// would otherwise race for one cache path — and two drags of the SAME file would have the
    /// second overwrite the first mid-copy.
    @MainActor
    private static func stage(_ file: LibraryFile,
                              model: AppModel,
                              progress: Progress) async throws -> URL {
        guard let client = model.client else {
            throw SproutError("Not connected to a server.")
        }
        // The filename lands in a PATH SEGMENT of the download URL, so it goes through the
        // sanitiser that exists for that — a different question from the name written to disk,
        // which is `LibraryFilePromise.filename`.
        let segment = LibraryDownloadName.pathSegment(file.filename, fallback: "model-\(file.id)")
        let url = try await client.mintFileDownloadUrl(file.id, filename: segment)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(LibraryFilePromise.filename(for: file))

        return try await FileDownloadDelegate.run(URLRequest(url: url), to: dest) { written, total in
            guard total > 0 else { return }
            progress.completedUnitCount = Int64(Double(written) / Double(total) * 100)
        }
    }
}

extension View {
    /// Make this row or card draggable as a file (§5.3).
    ///
    /// SwiftUI renders the view itself as the drag image, which is why `MacFileDrag` vends no
    /// preview of its own — the card the user grabbed is a better representation than a
    /// reconstructed thumbnail, and it cannot go stale.
    func macFileDrag(_ file: LibraryFile, model: AppModel) -> some View {
        onDrag { MacFileDrag.provider(for: file, model: model) }
    }
}
#endif
