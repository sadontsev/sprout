#if os(macOS)
import AVKit
import SwiftUI

// Timelapse and ipcam recordings, in their own window.
//
// iOS has played these since the SD browser existed; the Mac inspector said so out loud —
// "Timelapse and camera recordings play in the iPhone app" — which is an accurate description of a
// gap and a poor thing for a Mac user to read on a Mac. Nothing about the capability is
// platform-bound: AVKit plays an `.mp4` on both, and the download that precedes it is the same
// `FileDownloadDelegate` both already share.

// MARK: - The request

/// Which recording the player window is showing.
///
/// Identity is the **path**, so double-clicking the same recording twice raises the one window rather
/// than opening a second player of the same video — the same rule, for the same reason, as
/// `MacViewerRequest`.
struct MacVideoRequest: Codable, Hashable, Identifiable {
    let printerId: Int
    let path: String
    /// What the title bar says: the printer's timestamped filename, read as a date.
    let name: String

    var id: String { "\(printerId):\(path)" }

    static func == (lhs: MacVideoRequest, rhs: MacVideoRequest) -> Bool {
        lhs.printerId == rhs.printerId && lhs.path == rhs.path
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(printerId)
        hasher.combine(path)
    }
}

/// The single entry point, matching `MacViewer`.
///
/// `printerId` is explicit because a `PrinterFile` does not carry one — the listing is already scoped
/// to a printer, so the row has only a path. One initialiser rather than an overload that substitutes
/// a default: which machine a recording came from is not something to guess at a call site.
enum MacVideoWindow {
    @MainActor
    static func open(_ pf: PrinterFile, printerId: Int, using openWindow: OpenWindowAction) {
        openWindow(id: "video", value: MacVideoRequest(printerId: printerId, path: pf.path,
                                                       name: SdFileCaps.displayName(pf)))
    }
}

// MARK: - Download state

/// Progress and result of one recording's download.
///
/// A class, not view state, because the progress callback fires **off** the main thread and a
/// main-actor object is the only thing safe to hand it — the same reasoning, and the same shape, as
/// iOS's `SdDownloadState`.
@MainActor
@Observable
final class MacVideoDownload {
    var written: Int64 = 0
    var total: Int64 = 0
    var localURL: URL?
    var failure: String?

    nonisolated init() {}

    /// nil until the server declares a length. An ipcam chunk runs to ~250 MB, so a bar that cannot
    /// say how far along it is must show that it cannot, rather than sit at zero.
    var percent: Int? {
        guard total > 0 else { return nil }
        return min(100, Int((Double(written) / Double(total) * 100).rounded()))
    }
}

// MARK: - The window

@MainActor
struct MacVideoWindowView: View {
    let model: AppModel
    let request: MacVideoRequest?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.metrics) private var m
    @Environment(\.dismiss) private var dismiss

    @State private var download = MacVideoDownload()
    @State private var player: AVPlayer?
    @State private var confirmingDelete = false
    @State private var attempt = 0

    /// Presented HERE, not through the store.
    ///
    /// `shareDownloaded` used to set `store.shareItem`, whose only presenter is inside
    /// `MacFilesSection` — so sharing a recording from a window opened off the menu bar, with Files
    /// never visited, set a value nothing was watching and the button did nothing at all. The same
    /// shape as every row in CLAUDE.md's table, written by me a few hours after quoting it.
    @State private var shareItem: LibShareItem?
    /// A delete that failed, kept so the window can say so itself.
    @State private var deleteFailed: String?

    /// A window scene inherits nothing from `MacRoot`, so the palette is resolved rather than read
    /// from `@Environment` — see `MacViewerWindow`, which carries the same note for the same trap.
    private var c: Palette { Palette.forScheme(model.theme.colorScheme ?? scheme) }

    private var store: LibraryStore { model.library }

    /// The id the request was opened with, falling back to the model's current printer.
    ///
    /// `MacVideoWindow.open(_:using:)` cannot see a printer id, and a restored scene carries whatever
    /// was persisted. Zero is the "not set" value `AppModel.printerId` itself starts at, so it is the
    /// one worth substituting.
    private var printerId: Int { (request?.printerId ?? 0) == 0 ? model.printerId : (request?.printerId ?? 0) }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .background(c.bg)
        .macSceneChrome(model, systemScheme: scheme)
        .navigationTitle(request?.name ?? "Recording")
        .task(id: taskKey) { await fetch() }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .sheet(item: $shareItem) { item in
            MacShareSheet(url: item.url)
        }
        .alert(MacFilesDelete.printerTitle, isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await deleteAndClose() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: MacFilesDelete.printerMessage(request?.name ?? ""))
        }
    }

    private var taskKey: String { "\(request?.id ?? "none"):\(attempt)" }

    @ViewBuilder
    private var content: some View {
        if request == nil {
            centred { Text(verbatim: "No recording.").font(.system(size: 12)).foregroundStyle(c.t3) }
        } else if let failure = deleteFailed ?? download.failure {
            centred {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(c.t3)
                    Text(verbatim: failure)
                        .font(.system(size: 12))
                        .foregroundStyle(c.t2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button("Try again") { attempt += 1 }
                        .buttonStyle(MacSecondaryButtonStyle())
                }
            }
        } else if let player {
            VideoPlayer(player: player)
                .background(Color.black)
        } else {
            centred { progress }
        }
    }

    /// The download readout.
    ///
    /// Why there is a download at all, rather than handing AVPlayer the URL: the endpoint needs an
    /// `X-API-Key` **header**, which `AVURLAsset` cannot be given without a resource loader, and it
    /// ignores `Range` — so streaming would neither authenticate nor seek. iOS records the same two
    /// facts at its own player. Downloading first is the fix on both.
    private var progress: some View {
        VStack(spacing: 10) {
            if let percent = download.percent {
                ProgressView(value: Double(percent), total: 100)
                    .progressViewStyle(.linear)
                    .tint(c.accent)
                    .frame(width: 240)
                Text(verbatim: "Downloading — \(percent) %")
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(c.t3)
                    .monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
                // No `Content-Length`, so there is no percentage to show and none is invented.
                Text(verbatim: download.written > 0
                     ? "Downloading — \(MacFileBrowse.bytes(Double(download.written)))"
                     : "Downloading…")
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(c.t3)
                    .monospacedDigit()
            }
            Text(verbatim: "The printer’s recordings can’t be streamed, so the whole file comes down first.")
                .font(.system(size: 11))
                .foregroundStyle(c.t3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Text(verbatim: request?.name ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(c.t1)
                .lineLimit(1)
            Spacer(minLength: 12)
            // Share only once there is something local to share — before that it would be a second
            // download of a file already coming down.
            Button("Share…") { shareDownloaded() }
                .buttonStyle(MacSecondaryButtonStyle())
                .disabled(download.localURL == nil)
            Button("Delete") { confirmingDelete = true }
                .buttonStyle(MacSecondaryButtonStyle(role: .destructive))
        }
        .padding(.horizontal, m.gutter)
        .padding(.vertical, 10)
        .background(c.s1)
        .overlay(alignment: .top) { Rectangle().fill(c.line).frame(height: 1) }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Plumbing

    private func fetch() async {
        guard let request, let client = model.client else { return }
        // Cleared alongside the download's own error, or the window can never leave the failure
        // branch: `deleteFailed` was written once and by nothing else, so "Try again" re-fetched
        // underneath an error that stayed on screen forever.
        deleteFailed = nil
        download.failure = nil
        download.written = 0
        download.total = 0
        player = nil

        guard let url = client.printerFileDownloadUrl(printerId, path: request.path) else {
            download.failure = "That recording’s path can’t be turned into a URL."
            return
        }
        var urlRequest = URLRequest(url: url)
        for (key, value) in client.authHeaders() { urlRequest.setValue(value, forHTTPHeaderField: key) }

        // The name lands in the caches directory, and the printer's own listing is what named it.
        let dest = LibCache.url(for: LibraryDownloadName.fileName(request.path, fallback: "recording.mp4"))
        let state = download
        do {
            let local = try await FileDownloadDelegate.run(urlRequest, to: dest) { written, total in
                Task { @MainActor in
                    state.written = written
                    state.total = total
                }
            }
            guard !Task.isCancelled else { return }
            download.localURL = local
            let created = AVPlayer(url: local)
            player = created
            created.play()
        } catch {
            guard !Task.isCancelled else { return }
            download.failure = error.localizedDescription
        }
    }

    /// Hands the finished download to the same `shareItem` every other share on this platform uses,
    /// so the presentation is the Files section's and not a second one written here.
    private func shareDownloaded() {
        guard let local = download.localURL else { return }
        shareItem = LibShareItem(url: local)
    }

    /// Stops playback and closes the window BEFORE the delete lands.
    ///
    /// An error from the store raises an alert on the Files section, and a player window left open
    /// over a file that no longer exists is the same defect Quick Look had — a panel describing
    /// something deleted.
    /// Stops playback, deletes, and only THEN closes.
    ///
    /// It used to `dismiss()` before awaiting the delete, which meant a failure had nowhere to land:
    /// `store.deleteSd` reports by setting `store.problem`, whose only presenter is in
    /// `MacFilesSection`, and this window was already gone. A recording that could not be deleted
    /// reported success by vanishing. Now the window stays up and says so.
    private func deleteAndClose() async {
        guard let request else { return }
        player?.pause()
        player = nil
        let entry = PrinterFile(name: (request.path as NSString).lastPathComponent,
                                isDirectory: false, size: nil, path: request.path, mtime: nil)
        let before = store.problem
        await store.deleteSd(entry)
        if let problem = store.problem, problem != before {
            // Claim the store's error so the Files section does not ALSO raise it later, and show it
            // where the action was taken.
            store.problem = nil
            deleteFailed = problem.message
            // Deliberately NOT `attempt += 1`: the recording is still there and still playable, and
            // re-fetching would clear the very message the user needs to read. "Try again" is theirs
            // to press.
            return
        }
        dismiss()
    }
}
#endif
