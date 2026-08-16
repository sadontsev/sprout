#if os(macOS)
import SwiftUI

/// The unified toolbar (§3).
///
/// The printer popup here is the **only** printer switcher in the Mac app — `DashboardView`'s
/// `fleetSwitcher` and its `switcherOpen` state do not exist on this platform. One switcher, in
/// window chrome, so that changing machine never looks like navigating.
struct MacToolbar: ToolbarContent {
    /// The supported way to open the `Settings` scene. This was
    /// `NSApp.sendAction(Selector(("showSettingsWindow:")))` — a PRIVATE selector whose name Apple
    /// has already changed once (`showPreferencesWindow:` before Ventura). `sendAction` returns a
    /// discarded `Bool` when nothing in the responder chain answers, so the wrong name is not an
    /// error: the menu item simply does nothing, which is exactly what it did.
    @Environment(\.openSettings) private var openSettings
    let model: AppModel
    @Binding var section: TabKey
    @Binding var inspectorShown: Bool
    /// True when the sidebar has folded (§1) and navigation has to live here instead.
    let needsSectionPopup: Bool
    let onOpenCamera: () -> Void
    let onAddFromFiles: () -> Void
    let onPasteLink: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if needsSectionPopup { sectionPopup }
        }

        ToolbarItem(placement: .principal) {
            // NO section title here. `MacWindow` sets `.navigationTitle(section.label)`, which macOS
            // already draws in the titlebar — a `Text(section.label)` in this item rendered it a
            // SECOND time, so the window read "Printer … Printer · H2C · PRINTING 13 %". The
            // prototype shows one title, and the window title is the one the system also uses for
            // the Window menu and Mission Control, so this is the copy that goes.
            // Insets, because macOS sizes the glass capsule to this item's CONTENT and the content
            // had almost none of its own.
            //
            // Measured off the shipped build: 14 pt from the capsule's left edge to the "H" of the
            // printer name, and 10 pt from the final "%" to its right edge — so the text was very
            // nearly touching the bubble at both ends and read as having outgrown it.
            //
            // Asymmetric on purpose. `printerPopup` is a `Menu` and carries a borderless button's
            // own leading inset; `MacStatusPillView` is a bare `Text` and carries nothing. Equal
            // padding here would preserve the imbalance rather than correct it, so the trailing side
            // gets the larger share and the two ends come out level at roughly 20 pt.
            HStack(spacing: 14) {
                printerPopup
                MacStatusPillView(vm: model.vm)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button("Camera", systemImage: "video", action: onOpenCamera)
                .help("Open the chamber camera in its own window (⌘0)")

            Menu {
                Button("From Files…", action: onAddFromFiles)
                Button("From MakerWorld") { section = .explore }
                Button("Paste a link", action: onPasteLink)
            } label: {
                Label("Add file", systemImage: "plus")
            }

            Button {
                inspectorShown.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (⌥⌘I)")
        }
    }

    /// Appears only when the sidebar has folded, so navigation is never lost (§1).
    private var sectionPopup: some View {
        Menu {
            Picker("Section", selection: $section) {
                ForEach(TabKey.macPrimary + TabKey.macBrowse, id: \.self) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(section.label, systemImage: "sidebar.leading")
        }
    }

    /// Name + state dot + chevron. The dot means the popup reports state **without being opened**,
    /// which is what §10 asks of it.
    private var printerPopup: some View {
        Menu {
            if model.printers.isEmpty {
                Text("No printers").disabled(true)
            } else {
                Picker("Printer", selection: Binding(
                    get: { model.printerId },
                    set: { model.printerId = $0 }
                )) {
                    ForEach(model.printers) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            // Deliberately opens Settings rather than a bespoke sheet: the server is where printers
            // come from, and there is exactly one place in this app that edits it.
            Button("Manage printers…") { openSettings() }
        } label: {
            HStack(spacing: 8) {
                PulseDot(color: model.vm.stateColor.resolve(palette), size: 7)
                Text(model.printer?.name ?? "Printer")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @Environment(\.palette) private var palette
}
#endif
