#if os(macOS)
import AppKit
import SwiftUI

/// The three ways a file reaches the library on Mac, behind one door.
///
/// `Add file ▾` in the toolbar, a drop on the window or the Dock icon (§5.3), and Finder's "Open
/// with" all end up in `ingest`. One entry point on purpose: they are the same operation, and three
/// implementations would drift into three different answers about where the file lands.
enum MacFileImport {
    /// The toolbar's *From Files…*.
    @MainActor
    static func present(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = UploadFileKind.all
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Add a model or sliced file to your library."
        guard panel.runModal() == .OK else { return }
        ingest(panel.urls, model: model)
    }

    /// The shared landing point for a panel pick, a window drop and a Dock drop.
    ///
    /// Goes through the same `LibraryUploader` the iOS build uses — it already stages out of the
    /// security scope, reports progress, and survives the user navigating away mid-transfer,
    /// because it holds the client rather than a view.
    @MainActor
    static func ingest(_ urls: [URL], model: AppModel) {
        guard let client = model.client else {
            model.toast = "Connect to a server before adding files."
            return
        }
        // `LibraryUploader` runs one transfer at a time by design (`guard !busy` returns early), so
        // a multi-file drop is fed in sequence. Firing them all at once would silently discard
        // every file after the first — the drop would look like it worked and land one file.
        Task {
            for url in urls {
                while model.uploader.busy { try? await Task.sleep(for: .milliseconds(120)) }
                model.uploader.upload(url, client: client, model: model) {
                    Task { await model.library.load() }
                }
            }
        }
    }

    /// *Paste a link* (§3).
    ///
    /// This item does NOT exist on iOS, and the comment in `LibraryView` explains why: a
    /// programmatic `UIPasteboard` read has needed user consent since iOS 16 and simply returns nil
    /// from a menu action, so the item would have been a second door to the same room with nothing
    /// behind it. `NSPasteboard` has no such restriction, so on Mac the item does the thing it
    /// says — and when the clipboard holds nothing usable it says that, rather than opening an
    /// empty Explore and letting the user guess.
    ///
    /// The pasted text is handed to the ordinary search path, which already turns a MakerWorld URL
    /// into an "Open model N" row.
    @MainActor
    static func pasteLink(model: AppModel, explore: ExploreModel) -> Bool {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else {
            model.toast = "There’s nothing on the clipboard to open."
            return false
        }
        explore.query = raw
        explore.search(raw)
        return true
    }
}
#endif
