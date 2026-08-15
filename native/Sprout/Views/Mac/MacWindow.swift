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

    /// Persisted per scene, so a relaunch opens on the section you left rather than on Printer (§1).
    /// Stored as the raw string because `TabKey`'s raw values are already the persisted format.
    @SceneStorage("mac.section") private var sectionRaw = TabKey.printer.rawValue
    @SceneStorage("mac.inspector") private var inspectorPreferred = true
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

    /// The user's preference AND the room to honour it. Below the threshold the inspector is still
    /// reachable — `.inspector` presents it as an overlay — so the toggle never becomes a dead
    /// control, which is the failure mode §Recurring-bug warns about.
    private var inspectorShown: Binding<Bool> {
        Binding(get: { inspectorPreferred }, set: { inspectorPreferred = $0 })
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
        .onChange(of: collapse.sidebarFitsAsColumn) { _, fits in
            columnVisibility = fits ? .all : .detailOnly
        }
        // Navigate for a Spotlight hit / `bambu:` URL / Dock-opened file (§5.4). Only the SECTION
        // half is consumed here — the request itself stays set so the section that lands can act on
        // the rest of it (selecting the file) and clear it. Splitting the consumption this way is
        // what lets one request cross two views without either needing to know the other.
        .onChange(of: model.pendingOpen) { _, request in
            if let request { section = request.section }
        }
        .task {
            // Also handle a request that arrived BEFORE this window existed — launching by
            // double-clicking a .3mf in Finder delivers the URL before the first scene appears.
            if let request = model.pendingOpen { section = request.section }
        }
        .toolbar {
            MacToolbar(
                model: model,
                section: sectionBinding,
                inspectorShown: inspectorShown,
                needsSectionPopup: collapse.needsToolbarSectionPopup,
                onOpenCamera: { openWindow(id: "camera", value: model.printerId) },
                onAddFromFiles: { MacFileImport.present(model: model) },
                onPasteLink: { MacFileImport.pasteLink(model: model, explore: explore) }
            )
        }
        .toolbarRole(.editor)
        .navigationTitle(section.label)
        // §10: ⌘R refetches the CURRENT section and nothing else.
        .focusedSceneValue(\.refreshSection, RefreshAction { await MacSectionRefresh.run(section, model: model, explore: explore) })
        .focusedSceneValue(\.selectedSection, sectionBinding)
        .focusedSceneValue(\.inspectorToggle, inspectorShown)
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
