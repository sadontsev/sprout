#if os(macOS)
import SwiftUI

/// The main window (§1, prototype `1a`).
///
/// Three columns: sidebar · content · inspector. The inspector is `.inspector(isPresented:)` on the
/// detail column and **not** a third `NavigationSplitView` column — as a third column, toggling it
/// re-lays-out the split view and shoves the sidebar, which §1 forbids.
struct MacWindow: View {
    let model: AppModel
    let explore: ExploreModel

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// `@AppStorage`, NOT `@SceneStorage` — and this is a deliberate departure from §1.
    ///
    /// §1 specifies `@SceneStorage` for the section and the inspector; §10 requires that "launching
    /// opens on the section you last used, with the inspector where you left it". Those two cannot
    /// both be satisfied, because `@SceneStorage` is written through macOS's **window restoration**,
    /// which only runs when `NSQuitAlwaysKeepsWindows` is on — and it is off by default ("Close
    /// windows when quitting an application"). Measured on a clean quit: the section was left on
    /// Jobs and the next launch opened on Printer, with no saved-state directory ever created for
    /// the bundle.
    ///
    /// The behaviour is the requirement and the mechanism was the suggestion, so the mechanism gave
    /// way. `UserDefaults` also costs nothing here: §Fleet keeps this app to one window, so there is
    /// no second scene that would want its own section.
    ///
    /// Per-ITEM selections stay `@SceneStorage` on purpose — restoring "file 412 is selected" across
    /// a relaunch would point the inspector at something the server may no longer have.
    ///
    /// Stored as the raw string because `TabKey`'s raw values are already the persisted format.
    @AppStorage("mac.section") private var sectionRaw = TabKey.printer.rawValue
    @AppStorage("mac.inspector") private var inspectorPreferred = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var windowWidth: CGFloat = 1440

    private var section: TabKey {
        get { TabKey(rawValue: sectionRaw) ?? .printer }
        nonmutating set { sectionRaw = newValue.rawValue }
    }

    private var sectionBinding: Binding<TabKey> {
        Binding(get: { section }, set: { section = $0 })
    }

    private var collapse: MacCollapse { .forWidth(windowWidth) }

    /// What the user's preference was before the window got too narrow to honour it, so widening
    /// again restores what they had rather than leaving the inspector off for good.
    @State private var inspectorPreferredWhenWide: Bool?

    /// The inspector's visibility.
    ///
    /// Deliberately still just the preference: the toggle must keep working at any width, because a
    /// control that silently does nothing is the failure mode this codebase keeps rediscovering.
    /// The WIDTH rule is applied as a transition in `onChange` below — auto-hide on the way down,
    /// restore on the way up — rather than as a condition here, which would have made `⌥⌘I` dead
    /// below 1180.
    private var inspectorShown: Binding<Bool> {
        Binding(get: { inspectorPreferred }, set: { inspectorPreferred = $0 })
    }

    /// Navigate for a request from outside the view tree, and clear the ones nothing else will.
    ///
    /// A `.section` request is fully served by arriving there, so this consumes it. A `.file`
    /// request is only HALF served — the Files section still has to select the id — so it is left
    /// set for `MacFilesSection.consumePendingOpen` to finish and clear.
    ///
    /// Clearing matters because `onChange` fires on a CHANGE. `.section(.printer)` was consumed and
    /// never cleared, so a second identical request assigned the value already held, `onChange` did
    /// not fire, and nothing happened — the reason `MacPrintSheet` documents for not navigating to
    /// Jobs after a send.
    private func consumePendingOpen(_ request: MacOpenRequest?) {
        guard let request else { return }
        section = request.section
        if request.isServedByArriving { model.pendingOpen = nil }
    }

    /// Mirror the inspector's visibility onto the model, so a section can compensate for what the
    /// inspector was carrying — see `AppModel.inspectorVisible`.
    private func publishInspectorVisibility() {
        model.inspectorVisible = inspectorPreferred
    }

    var body: some View {
        VStack(spacing: 0) {
            // Part of the LAYOUT, above the split view (§1) — the toolbar is window chrome and
            // draws above this, so the strip lands directly under it, full width, as drawn.
            if model.isDemo { MacDemoStrip(model: model) }

            NavigationSplitView(columnVisibility: $columnVisibility) {
                MacSidebar(model: model, section: sectionBinding)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
            } detail: {
                MacSectionContent(model: model, explore: explore, section: section)
                    .frame(minWidth: 640)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(c.bg)
                    .inspector(isPresented: inspectorShown) {
                        MacInspectorContent(model: model, explore: explore, section: section)
                            .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
                    }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .background(c.bg)
        .frame(minWidth: 1080, minHeight: 680)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .onAppear { publishInspectorVisibility() }
        .onChange(of: inspectorPreferred) { _, _ in publishInspectorVisibility() }
        .onChange(of: collapse.sidebarFitsAsColumn) { _, fits in
            columnVisibility = fits ? .all : .detailOnly
        }
        // §1's first collapse rule. Without this `MacCollapse.inspectorFitsAsColumn` had no consumer
        // at all — the predicate was written, documented and tested, and the inspector never
        // actually hid. Found by looking at a screenshot of the running app, not by reading.
        //
        // A transition rather than a condition on `inspectorShown`: making the binding false below
        // the threshold would leave `⌥⌘I` looking live and doing nothing, which is the exact bug
        // §Recurring-bug is about.
        .onChange(of: collapse.inspectorFitsAsColumn) { _, fits in
            if fits {
                // Restore what they had before it was taken away — but only if it WAS taken away.
                if let remembered = inspectorPreferredWhenWide {
                    inspectorPreferred = remembered
                    inspectorPreferredWhenWide = nil
                }
            } else if inspectorPreferred {
                inspectorPreferredWhenWide = true
                inspectorPreferred = false
            }
        }
        // Navigate for a Spotlight hit / `bambu:` URL / Dock-opened file (§5.4). Only the SECTION
        // half is consumed here — the request itself stays set so the section that lands can act on
        // the rest of it (selecting the file) and clear it. Splitting the consumption this way is
        // what lets one request cross two views without either needing to know the other.
        .onChange(of: model.pendingOpen) { _, request in
            consumePendingOpen(request)
        }
        .task {
            // Also handle a request that arrived BEFORE this window existed — launching by
            // double-clicking a .3mf in Finder delivers the URL before the first scene appears.
            consumePendingOpen(model.pendingOpen)
            #if DEBUG
            // Open on a named section, for headless UI verification. See `MacWindowProbe`.
            if let raw = ProcessInfo.processInfo.environment["SPROUT_SECTION"],
               let key = TabKey(rawValue: raw) {
                section = key
            }
            #endif
        }
        .toolbar {
            MacToolbar(
                model: model,
                section: sectionBinding,
                inspectorShown: inspectorShown,
                needsSectionPopup: collapse.needsToolbarSectionPopup,
                onOpenCamera: { openWindow(id: "camera", value: model.printerId) },
                onAddFromFiles: { MacFileImport.present(model: model) },
                // `pasteLink` returns "did we start something worth looking at", and that is the
                // only value it produces the caller needs. Discarding it left the search running in
                // a section the user was not on — the sibling item ("From MakerWorld") navigates,
                // this one silently did not.
                onPasteLink: {
                    if MacFileImport.pasteLink(model: model, explore: explore) { section = .explore }
                }
            )
        }
        .toolbarRole(.editor)
        .navigationTitle(section.label)
        // §7 swaps `fullScreenCover` for a sheet with an explicit frame. Presented from the window
        // rather than from the inspector that raises it: a sheet attaches to a window, and the
        // inspector is a column inside one.
        // 1f. The helper owns the 640 pt frame §1f specifies, so no call site can forget it.
        .macPrintSheet(Binding(
            get: { model.pendingPrint },
            set: { model.pendingPrint = $0 }
        ), model: model)
        .sheet(isPresented: Binding(
            get: { model.showAlerts },
            set: { model.showAlerts = $0 }
        )) {
            MacAlertsSheet(model: model, isPresented: Binding(
                get: { model.showAlerts },
                set: { model.showAlerts = $0 }
            ))
        }
        // §10: ⌘R refetches the CURRENT section and nothing else.
        .focusedSceneValue(\.refreshSection, RefreshAction { await MacSectionRefresh.run(section, model: model, explore: explore) })
        .focusedSceneValue(\.selectedSection, sectionBinding)
        .focusedSceneValue(\.inspectorToggle, inspectorShown)
        .focusedSceneValue(\.cameraPrinterId, model.printerId)
    }

    @Environment(\.openWindow) private var openWindow
}

/// A named closure, so `.focusedSceneValue` can carry "refresh whatever is on screen" to the
/// `⌘R` command without the command knowing which section that is.
struct RefreshAction: Equatable {
    let id = UUID()
    let run: @MainActor () async -> Void

    static func == (a: RefreshAction, b: RefreshAction) -> Bool { a.id == b.id }
}
#endif
