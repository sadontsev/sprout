#if os(macOS)
import SwiftUI

/// The inspector's panes as a bottom drawer, for the five sections that cannot take them inline.
///
/// See `MacInspectorPlacement.host(for:)` for why there are two hosts rather than one. In short:
/// Printer is a card stack that scrolls as one page, so its panes join the stack; the other five end
/// in a greedy scrolling child that owns the viewport, and a variable-height block appended after
/// `maxHeight: .infinity` is either clipped away or takes the room the section exists for.
///
/// Applied ONCE, in `MacSectionContent`, rather than added to five section files. Five copies of
/// "and also show the panes when the inspector is hidden" is five chances for one of them to test
/// the wrong flag, and the section that got it wrong would look exactly like the section that was
/// simply not done yet.
///
/// **The drawer is not a second inspector.** It renders the very same `MacInspectorContent` the
/// column does, so there is no parallel copy to keep in step, and the two are mutually exclusive by
/// `MacInspectorPlacement.owner` — which matters beyond tidiness on Explore and Power, whose panes
/// own `.task`s that would otherwise run twice.
/// Where the drawer's per-section collapse lives.
///
/// Shared rather than private to the modifier because `⌥⌘I` has to reach it: below the threshold
/// there is no column for that shortcut to toggle, and a shortcut that silently does nothing is the
/// failure this codebase keeps rediscovering. `MacWindow` writes here; the drawer's `@AppStorage`
/// observes the same key and re-renders.
enum MacDrawerCollapse {
    static func key(_ section: TabKey) -> String { "mac.drawer.collapsed.\(section.rawValue)" }

    static func isCollapsed(_ section: TabKey) -> Bool {
        UserDefaults.standard.bool(forKey: key(section))
    }

    static func set(_ collapsed: Bool, for section: TabKey) {
        UserDefaults.standard.set(collapsed, forKey: key(section))
    }
}

struct MacInspectorDrawer: ViewModifier {
    let model: AppModel
    let explore: ExploreModel
    let section: TabKey

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// Collapsed to its header, per section.
    ///
    /// Per section because the answer genuinely differs by section: the drawer is worth its height
    /// on Jobs, where the selected print's detail is the reason you clicked the row, and often is
    /// not on Explore, where the grid is the point. One shared flag would make dismissing it in one
    /// place remove it everywhere.
    ///
    /// `@AppStorage`, like `mac.section` and for the same measured reason — `@SceneStorage` is
    /// written through window restoration, which is off by default, so a `@SceneStorage` collapse
    /// would silently forget itself on every quit.
    @AppStorage private var collapsed: Bool

    /// The height available to split between the section and the drawer.
    @State private var available: CGFloat = 700

    init(model: AppModel, explore: ExploreModel, section: TabKey) {
        self.model = model
        self.explore = explore
        self.section = section
        _collapsed = AppStorage(wrappedValue: false, MacDrawerCollapse.key(section))
    }

    private var shows: Bool {
        MacInspectorPlacement.shows(.drawer, section: section,
                                    inspectorVisible: model.inspectorVisible)
    }

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if shows {
                Rectangle().fill(c.line).frame(height: 1)
                header
                if !collapsed {
                    MacInspectorContent(model: model, explore: explore, section: section)
                        .frame(height: MacInspectorPlacement.drawerHeight(available: available))
                }
            }
        }
        // Measured on the whole region, so the drawer's share is computed from what the two actually
        // have to divide rather than from the window — the toolbar and the demo strip both sit above
        // this and neither is the drawer's to spend.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { available = $0 }
        .animation(Motion.standard(0.24), value: collapsed)
        .animation(Motion.standard(0.24), value: shows)
    }

    /// Names what the drawer is, and offers the two ways out of it.
    ///
    /// Both are stated rather than left to be discovered: the chevron collapses it to this bar, and
    /// `⌥⌘I` puts the panes back in their column. Without the hint the drawer looks like a permanent
    /// change to the layout rather than the consequence of a narrow window — and the shortcut that
    /// undoes it is the one thing the user cannot guess.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(c.t3)
            MacPrinterMonoLabel(section.label.uppercased())
            Spacer(minLength: 0)
            Text(verbatim: "⌥⌘I")
                .font(.mono(m.monoLabel, weight: .medium))
                .foregroundStyle(c.t3)
        }
        .padding(.horizontal, m.gutter)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.s1)
        .contentShape(Rectangle())
        .onTapGesture { collapsed.toggle() }
        .help(collapsed
              ? "Show the \(section.label) inspector. ⌥⌘I returns it to its own column."
              : "Hide these panes. ⌥⌘I returns them to their own column.")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(section.label) inspector, \(collapsed ? "collapsed" : "expanded")")
    }
}

extension View {
    /// Give this section the inspector's panes as a bottom drawer when there is no column for them.
    func macInspectorDrawer(model: AppModel, explore: ExploreModel, section: TabKey) -> some View {
        modifier(MacInspectorDrawer(model: model, explore: explore, section: section))
    }
}
#endif
