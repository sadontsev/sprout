#if os(macOS)
import SwiftUI

/// The menu bar (§7's keyboard table).
///
/// `⌘1`–`⌘6` · `⌘R` refresh · `⌘0` camera · `⌥⌘I` inspector · `⌘F` search.
/// `⌘,` is not here: SwiftUI's `Settings` scene installs it, and declaring a second one would give
/// the app two Settings items.
///
/// Every item reads a `focusedSceneValue`, so with no window open they disable themselves rather
/// than acting on a window that is not there. That matters more on Mac than it sounds: §5.1 expects
/// the app to keep running with the main window closed.
struct MacCommands: Commands {
    @FocusedValue(\.refreshSection) private var refresh
    @FocusedValue(\.selectedSection) private var selectedSection
    @FocusedValue(\.inspectorToggle) private var inspectorToggle

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Replaces the stock "New Window" — Sprout is one window (§Fleet: "one printer at a time",
        // and multiple printer windows are explicitly not shipping).
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await refresh?.run() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(refresh == nil)

            Button(inspectorToggle?.wrappedValue == true ? "Hide Inspector" : "Show Inspector") {
                inspectorToggle?.wrappedValue.toggle()
            }
            .keyboardShortcut("i", modifiers: [.option, .command])
            .disabled(inspectorToggle == nil)

            Divider()

            // The sidebar draws the same shortcut in each row; both sides read TabKey.commandDigit
            // so they cannot drift.
            ForEach(TabKey.macPrimary + TabKey.macBrowse, id: \.self) { key in
                if let digit = key.commandDigit {
                    Button(key.label) { selectedSection?.wrappedValue = key }
                        .keyboardShortcut(KeyEquivalent(digit), modifiers: .command)
                        .disabled(selectedSection == nil)
                }
            }
        }

        CommandGroup(after: .windowArrangement) {
            Button("Camera Window") { openWindow(id: "camera", value: 0) }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
#endif
