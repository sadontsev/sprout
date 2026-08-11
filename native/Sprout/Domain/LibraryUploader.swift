import Foundation
import Observation

/// Uploading a picked document to the library.
///
/// Lifted out of `UploadSheet` because the sheet is going away: with Explore promoted to a page, the
/// "Add a file" sheet had nothing left to do but hold a two-item menu, and `+` is a native `Menu`
/// now (F10). The transfer itself was never the sheet's business — it already outlived the sheet, by
/// design.
///
/// A model rather than view state so that stays true: the task holds the client, not a view, so
/// navigating away mid-upload costs nothing and the toast still lands.
@Observable
@MainActor
final class LibraryUploader {
    private(set) var busy = false
    private(set) var fraction: Double = 0
    var error: String?

    var percent: Int { Int((fraction * 100).rounded()) }

    /// Stage the picked document, then upload it with progress.
    func upload(_ picked: URL, client: BambuddyClient, model: AppModel,
                onUploaded: (() -> Void)? = nil) {
        guard !busy else { return }
        error = nil
        fraction = 0
        busy = true

        Task {
            defer { busy = false }
            do {
                // Off the main actor: copying tens of megabytes is not main-thread work. The picker
                // hands back a security-scoped URL readable only between start/stopAccessing, and
                // the upload outlives that window — hence the copy.
                let staged = try await Task.detached(priority: .userInitiated) {
                    try stageUploadCopy(picked)
                }.value
                defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }

                let name = staged.lastPathComponent
                _ = try await client.uploadFile(staged, name: name) { [weak self] f in
                    Task { @MainActor in self?.fraction = f }
                }
                onUploaded?()
                model.toast = "\(name) added to your library"
            } catch {
                self.error = "Upload failed — " + (uploadApiDetail(error) ?? error.localizedDescription)
            }
        }
    }
}
