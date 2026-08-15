#if os(iOS)
// TabView + tabBarMinimizeBehavior. macOS navigates with NavigationSplitView (§7).
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI

/// The app's five top-level sections, hosted by the SYSTEM tab bar.
///
/// `TabKey` itself lives in `Domain/` — it is shared with the macOS sidebar, which shows all six
/// cases. The five listed below are `TabKey.iosTabs`; Explore is not among them.
///
/// This used to be a hand-rolled `HStack` inside a `GlassEffectContainer`, with
/// `.glassEffect(.regular.tint(…).interactive())` on the selected item. It was replaced because
/// `.interactive()` gives a custom view a press reaction and nothing more — the gloss that lenses and
/// stretches when you press the bar and drag along it is the system tab bar's own interaction, and no
/// public API grants it to a custom stack. Apple's "Adopting Liquid Glass" overview is explicit that
/// the way to get the material is to use the standard component and let the system render it. See
/// `docs/native-rewrite/14-liquid-glass-tabbar.md` for the full write-up and the API table.
///
/// Two things follow from the system owning the bar, and both are deletions rather than code:
/// Reduce Transparency is handled for us (the old explicit `accessibilityReduceTransparency` branch
/// is gone), and the bar now contributes a safe-area inset, so screens no longer hand-reserve
/// clearance for a floating overlay.
struct MainTabs: View {
    @Bindable var model: AppModel
    @Environment(\.palette) private var c
    /// Only the Printer tab has a chrome affordance of its own, so this is passed down rather than
    /// pushed through the environment for one consumer.
    let onSettings: () -> Void

    var body: some View {
        // No `withAnimation` around the selection write and no `FadeRise` entrance keyed on the tab:
        // `TabView` animates its own selection change and keeps each tab's view alive, so both would
        // be a second curve fighting the system's.
        TabView(selection: $model.tab) {
            // `image:`, not `systemImage:` — the brand nozzle mark is an asset-catalog template
            // image. See TabNozzle.imageset for why it can't be the `NozzleIcon` Canvas view.
            Tab(TabKey.printer.label, image: "TabNozzle", value: TabKey.printer) {
                DashboardView(model: model, onSettings: onSettings)
            }
            // The remaining four are the SF Symbols closest to the Feather glyphs the RN build used.
            Tab(TabKey.library.label, systemImage: "folder", value: TabKey.library) {
                LibraryView(model: model)
            }
            Tab(TabKey.jobs.label, systemImage: "list.bullet", value: TabKey.jobs) {
                JobsView(model: model)
            }
            Tab(TabKey.ams.label, systemImage: "shippingbox", value: TabKey.ams) {
                AmsView(model: model)
            }
            Tab(TabKey.power.label, systemImage: "power", value: TabKey.power) {
                PowerView(model: model)
            }
        }
        // Lets the bar recede into a pill while reading down a long list and re-expand on the way
        // back up. Every tab is a single ScrollView, so the gesture is always available.
        .tabBarMinimizeBehavior(.onScrollDown)
        // The system tab bar tints its selected item with the app's accent, which defaults to
        // systemBlue — the old hand-rolled bar painted `c.accent` on the glyph itself, so without
        // this the brand teal is lost on the one control that shows it most.
        .tint(c.accent)
    }
}
#endif
