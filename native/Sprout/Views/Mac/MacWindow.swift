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

    /// Has the stored inspector preference been cleared once, to undo the auto-hide's damage?
    ///
    /// Builds 22–26 wrote `mac.inspector = false` from the width transition, not from the user — see
    /// `inspectorIsColumn`. Anyone whose window was ever narrow enough to trip it is now carrying a
    /// `false` that nothing will lift, on every launch, at every width, with no visible cause.
    /// Shipping the fix alone leaves them exactly where they were.
    ///
    /// The two cases are indistinguishable on disk: a `false` written by `⌥⌘I` and a `false` written
    /// by the bug look identical. So this resets it once for everybody rather than guessing. It
    /// costs a user who genuinely wanted the inspector off one keystroke to turn it off again, and
    /// it costs a user hit by the bug nothing at all — the asymmetry is the whole argument.
    @AppStorage("mac.inspector.healed") private var healedInspectorPreference = false
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

    /// Is the inspector on screen **as a column** right now?
    ///
    /// A pure function of the user's wish and the width — never a stored third thing.
    ///
    /// It used to be the preference alone, with the width applied as a `onChange` transition that
    /// wrote `inspectorPreferred = false` on the way down and restored it on the way up. That was
    /// wrong in a way no test caught and no short session revealed: **the auto-hide wrote into
    /// `@AppStorage` (persisted) while the value to restore lived in `@State` (not persisted).** One
    /// window narrow enough to trip it — split screen, Stage Manager, a small external display —
    /// and the preference was `false` on disk with nothing left to undo it. Every later launch, at
    /// any width, opened with no inspector and no way to know why. Measured: `pref=false` at 1440 pt
    /// on the first evaluation of a fresh session, before any transition could have run.
    ///
    /// The original objection to computing it — that `⌥⌘I` would be dead below the threshold — is
    /// answered by `inspectorToggle` below rather than by storing state. The shortcut now toggles
    /// whichever surface is actually carrying the panes.
    private var inspectorIsColumn: Bool {
        MacInspectorPlacement.columnShown(preference: inspectorPreferred,
                                          fitsAsColumn: collapse.inspectorFitsAsColumn)
    }

    /// What `.inspector(isPresented:)` binds to.
    ///
    /// The setter **ignores writes made while the column cannot fit**, and that guard is the second
    /// half of the fix above. Removing the `onChange` transition was not enough: SwiftUI's own
    /// `.inspector` writes `false` back through this binding when it hides itself, so below the
    /// threshold the preference was still being overwritten — same corruption, different author.
    /// Measured after the first fix: `pref` went `true → false` on a 1120 pt window with nobody
    /// touching anything.
    ///
    /// So only a decision made while the column is actually available counts as the user's. The
    /// width already decides visibility through `inspectorIsColumn`; it has no business also
    /// deciding what the user wants.
    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { inspectorIsColumn },
            set: { want in
                guard MacInspectorPlacement.acceptsPreferenceWrite(
                        fitsAsColumn: collapse.inspectorFitsAsColumn) else { return }
                inspectorPreferred = want
            }
        )
    }

    /// What `⌥⌘I` drives — and it is deliberately NOT the same binding.
    ///
    /// Above the threshold the panes are a column, so the shortcut toggles the column. Below it
    /// there is no column to toggle and the panes are in the drawer (or inline, on Printer), so it
    /// toggles that instead. Same promise either way — "show or hide the inspector" — and it is
    /// never a control that looks live and does nothing.
    ///
    /// Printer hosts its panes inline in its own scroll view and has no collapse of its own, so
    /// below the threshold there the shortcut still writes the preference. That is honest: on
    /// Printer the panes are always present once the column is gone.
    private var inspectorToggle: Binding<Bool> {
        Binding(
            get: {
                if collapse.inspectorFitsAsColumn { return inspectorPreferred }
                guard MacInspectorPlacement.host(for: section) == .drawer else { return inspectorPreferred }
                return !MacDrawerCollapse.isCollapsed(section)
            },
            set: { want in
                if collapse.inspectorFitsAsColumn || MacInspectorPlacement.host(for: section) != .drawer {
                    inspectorPreferred = want
                } else {
                    MacDrawerCollapse.set(!want, for: section)
                }
            }
        )
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
        model.inspectorVisible = inspectorIsColumn
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
        #if DEBUG
        .onChange(of: "\(windowWidth)|\(inspectorPreferred)|\(model.inspectorVisible)", initial: true) { _, v in
            if ProcessInfo.processInfo.environment["SPROUT_INSPECTOR_LOG"] != nil {
                FileHandle.standardError.write(Data("INSPECTOR w/pref/visible = \(v)\n".utf8))
            }
        }
        #endif
        .onAppear {
            // Before the first publish, so the healed value is the one that reaches `AppModel`.
            if !healedInspectorPreference {
                healedInspectorPreference = true
                inspectorPreferred = true
            }
            publishInspectorVisibility()
        }
        .onChange(of: inspectorIsColumn) { _, _ in publishInspectorVisibility() }
        .onChange(of: collapse.sidebarFitsAsColumn) { _, fits in
            columnVisibility = fits ? .all : .detailOnly
        }
        // §1's first collapse rule is now `inspectorIsColumn`, a condition rather than the
        // `onChange` transition that used to live here. The transition is what corrupted the stored
        // preference — see `inspectorIsColumn` — and a condition cannot: nothing but `⌥⌘I` writes
        // `inspectorPreferred` any more, so the width can never leave a mark that outlives it.
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
            // Open the PRINT SHEET on a library file, for the same reason.
            //
            // The sheet is reached by clicking a button, and a click is the one thing the probe cannot
            // do — so without this the whole slice-and-print surface is unreviewable, which for a Mac
            // app means unreviewable by anyone. Waits for the library because the id has to resolve to
            // a row; gives up rather than hanging if it never arrives.
            if let raw = ProcessInfo.processInfo.environment["SPROUT_PRINT_FILE"], let id = Int(raw) {
                for _ in 0..<40 {
                    if let f = model.library.files?.first(where: { $0.id == id }) {
                        model.pendingPrint = f
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            #endif
        }
        .toolbar {
            MacToolbar(
                model: model,
                section: sectionBinding,
                inspectorShown: inspectorToggle,
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
        .focusedSceneValue(\.inspectorToggle, inspectorToggle)
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
