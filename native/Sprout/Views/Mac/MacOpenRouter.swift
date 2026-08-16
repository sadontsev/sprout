#if os(macOS)
import AppKit
import SwiftUI

/// Where a URL handed to the app by macOS goes (§5.3, §5.4).
///
/// Three sources arrive at `application(_:open:)` and nowhere else: a file dropped on the Dock
/// icon, a file opened from Finder ("Open with", or double-clicking one of the four declared
/// document types), and a `bambu:` URL — which is what a Spotlight hit opens.
///
/// They are routed here rather than handled in the delegate because the delegate has no model, and
/// because §10 requires all of them to behave identically to a drop on the window: "Dropping a .3mf
/// on the window, on the Dock icon, or opening one from Finder all land in the library the same way
/// and select it in Files."
enum MacOpenRouter {
    @MainActor
    static func route(_ urls: [URL], model: AppModel) {
        let files = urls.filter { $0.isFileURL }
        let schemes = urls.filter { !$0.isFileURL }

        let importable = files.filter(MacDropTarget.accepts)
        if !importable.isEmpty {
            MacFileImport.ingest(importable, model: model)
        }
        // A file we were handed but cannot take is worth saying out loud: the user explicitly chose
        // "Open with Sprout", so silence would read as the app hanging.
        if importable.count < files.count {
            model.toast = .failure("Sprout takes .3mf, .gcode and .stl files.")
        }

        for url in schemes { routeScheme(url, model: model) }
    }

    /// `bambu://file/<id>` selects a library file — the URL a Spotlight hit opens (§5.4). The scheme
    /// is already declared in `CFBundleURLTypes`, so this is wiring rather than new surface.
    @MainActor
    private static func routeScheme(_ url: URL, model: AppModel) {
        guard url.scheme == "bambu" else { return }
        switch url.host() {
        case "file":
            let id = url.pathComponents.dropFirst().first.flatMap(Int.init)
            guard let id else {
                model.toast = .failure("That link doesn’t name a file.")
                return
            }
            // Routed through the model, NOT by writing the selection's storage directly.
            //
            // The sections keep their selection in `@SceneStorage`, which is backed by SwiftUI's
            // scene state-restoration store — not `UserDefaults`. Writing the same key through
            // `UserDefaults` from here compiles, runs, persists, and is read by nobody: the section
            // would never see it. The request goes to the model and the views consume it.
            model.pendingOpen = .file(id)
        case "printer":
            model.pendingOpen = .section(.printer)
        default:
            model.toast = .failure("Sprout doesn’t know how to open that link.")
        }
    }
}

/// A one-shot "show me this" request from outside the view tree (§5.3, §5.4).
///
/// Consumed by whichever view can honour it, which is why it is an enum of INTENTIONS rather than a
/// pile of optional ids: "select file 12" and "go to Printer" are different requests, and a view
/// that can only serve one of them must be able to tell them apart rather than guess from which
/// field happens to be non-nil.
enum MacOpenRequest: Equatable, Hashable {
    /// Select a library file, switching to Files to do it.
    case file(Int)
    /// Just show a section.
    case section(TabKey)

    /// Which section has to be on screen for this request to be servable.
    var section: TabKey {
        switch self {
        case .file: .library
        case .section(let key): key
        }
    }

    /// Is ARRIVING at that section the whole of the service?
    ///
    /// This is the handover rule between the request's two consumers, and it has to be stated
    /// somewhere both can read: `MacWindow` navigates, and then either clears the request or leaves
    /// it for the section that landed to finish. `.section` is finished by arriving. `.file` is only
    /// half finished — `MacFilesSection` still has to select the id — so it must survive the trip.
    ///
    /// Load-bearing because `onChange` fires on a CHANGE. A `.section` request that is served and
    /// NOT cleared makes the next identical request assign the value already held, so `onChange`
    /// never fires and nothing happens. That is not hypothetical: it is why printing from
    /// `MacPrintSheet` could not navigate to Jobs until this was fixed — a jump that works exactly
    /// once, on the first print of a session, is worse than no jump at all.
    var isServedByArriving: Bool {
        switch self {
        case .file: false
        case .section: true
        }
    }
}
#endif
