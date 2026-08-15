#if os(iOS)
// Overlays are a fullScreenCover idiom. macOS uses sheets and windows (§7).
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI
import WebKit
import os

// The layer viewer is the same self-contained page the app has always shipped, hosted in a
// WKWebView (see StlViewerOverlay.swift for the shared plumbing and the reasoning).
//
// Nothing here fetches the G-code. The page downloads and parses it ITSELF, because the alternative
// — pulling ~70 MB into Swift, handing it across, and re-parsing it in the page — was the actual
// reason large prints "couldn't be previewed". Parsing in JavaScriptCore JITs the hot loop and the
// output feeds GPU buffers directly, which is why there is no size cap, no segment budget and no
// decimation anywhere in this file.



/// Which G-code the layer viewer scrubs.
enum LayerSource: Equatable {
    /// A sliced file in the Bambuddy library.
    case library(fileId: Int)
    /// A `.gcode.3mf` on the printer's own SD card.
    case printerFile(printerId: Int, path: String)
}

/// Full-screen layer-by-layer preview of a sliced print: a real build plate with a 10 mm grid, an
/// orbitable toolpath model shaded bottom-to-top, amber supports, and a slider that scrubs layers.
///
/// The page downloads and parses the G-code itself — see the file header for why that is not an
/// implementation detail.
struct LayerViewerOverlay: View {
    let model: AppModel
    private let source: LayerSource
    private let title: String
    /// How the close button dismisses. The library entry point is presented through
    /// `AppModel.overlay`, so clearing that IS the dismissal; the SD-card entry point is a
    /// `fullScreenCover` owned by the Files tab, which has to clear its own binding instead — and
    /// would otherwise stay on screen forever with a close button that does nothing visible.
    private let onClose: (() -> Void)?

    @State private var page: String?
    /// The absolute URL handed to the page, kept so a failure logs the URL that was actually asked
    /// for rather than the one the reader assumes it was.
    @State private var pageUrl: String?
    /// nil until the page reports `ready`, which is also the signal that parsing finished.
    @State private var hasSupport: Bool?
    @State private var failure: String?
    @State private var attempt = 0

    init(model: AppModel, file: LibraryFile) {
        self.model = model
        self.source = .library(fileId: file.id)
        // Library names arrive percent-encoded often enough that the raw string is unreadable; a
        // malformed escape decodes to nil, in which case the raw name still beats nothing.
        let raw = [file.printName ?? "", file.filename].first { !$0.isEmpty } ?? "file-\(file.id)"
        self.title = raw.removingPercentEncoding ?? raw
        self.onClose = nil
    }

    /// SD-card entry point — same viewer, different G-code endpoint.
    init(model: AppModel, printerId: Int, path: String, title: String, onClose: @escaping () -> Void) {
        self.model = model
        self.source = .printerFile(printerId: printerId, path: path)
        self.title = title
        self.onClose = onClose
    }

    var body: some View {
        ZStack(alignment: .top) {
            Palette.dark.bg.ignoresSafeArea()

            if let page, failure == nil {
                ViewerWebView(html: page, baseURL: documentBase, onEvent: handle)
                    .id(attempt)
                    .ignoresSafeArea()
            }

            if let failure {
                ViewerFailure(icon: "square.3.layers.3d", message: failure, onRetry: retry)
                    .ignoresSafeArea()
            } else if hasSupport == nil {
                ViewerLoading(label: "LOADING G-CODE…")
                    .ignoresSafeArea()
            }

            ViewerTopBar(title: title) {
                close()
            } trailing: {
                if let hasSupport {
                    supportsPill(hasSupport)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: attempt) { build() }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            model.overlay = nil
        }
    }

    /// Supports are only known once the parser has seen every `; FEATURE:` comment, so this pill
    /// appears with the first frame rather than being guessed from the file's metadata.
    private func supportsPill(_ on: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? Palette.dark.supports : ViewerChrome.offDot)
                .frame(width: 7, height: 7)
            Text(on ? "Supports" : "No supports")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Palette.dark.supports : ViewerChrome.offInk)
        }
        .padding(.horizontal, 11)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(ViewerChrome.pill.opacity(0.55)))
    }

    private var documentBase: URL {
        ViewerJS.documentBase(of: model.client?.baseUrl ?? "")
    }

    private func build() {
        guard page == nil, failure == nil else { return }
        guard let client = model.client else {
            failure = "Not connected to Bambuddy."
            return
        }
        let path = switch source {
        case .library(let fileId): client.gcodePath(fileId)
        case .printerFile(let printerId, let filePath): client.printerGcodePath(printerId, path: filePath)
        }
        let url = client.baseUrl + path
        pageUrl = url
        // The API key rides along in the page source. That is safe here and nowhere else: the
        // document is loaded on the server's own origin from a string we built, so no third-party
        // script can read it — and the G-code endpoints reject the camera stream token outright.
        page = LayerPage.html(
            url: url,
            headers: client.authHeaders(),
            plate: PrinterProfile.forPrinter(model.printer).plate
        )
    }

    private func handle(_ event: ViewerEvent) {
        switch event {
        case .ready(let supports): hasSupport = supports
        case .loaded: break
        case .failed(let message, let status):
            viewerLog.error("Layer page failed (HTTP \(status, privacy: .public)) on \(ViewerJS.loggableUrl(self.pageUrl ?? "<no url>"), privacy: .public) — \(message, privacy: .public)")
            failure = message
        }
    }

    /// Rebuilds the web view from scratch: a failure here is a download or a parse, and neither can
    /// be resumed inside a page that has already shown its error.
    private func retry() {
        page = nil
        pageUrl = nil
        failure = nil
        hasSupport = nil
        attempt += 1
    }
}
#endif
