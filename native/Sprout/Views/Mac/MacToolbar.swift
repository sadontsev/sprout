#if os(macOS)
import SwiftUI

/// The unified toolbar (§3).
///
/// The printer popup here is the **only** printer switcher in the Mac app — `DashboardView`'s
/// `fleetSwitcher` and its `switcherOpen` state do not exist on this platform. One switcher, in
/// window chrome, so that changing machine never looks like navigating.
struct MacToolbar: ToolbarContent {
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
            HStack(spacing: 14) {
                Text(section.label)
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.2)
                Divider().frame(height: 20)
                printerPopup
                MacStatusPillView(vm: model.vm)
            }
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
            Button("Manage printers…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
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
