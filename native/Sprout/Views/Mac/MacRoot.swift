#if os(macOS)
import SwiftUI

/// The macOS config gate — the Mac counterpart to `Shell`.
///
/// Three states, same as iOS and for the same reasons: hold the splash while the Keychain read is
/// in flight rather than flashing onboarding at someone already set up; onboarding when there is no
/// client; the window otherwise.
struct MacRoot: View {
    let model: AppModel
    let explore: ExploreModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if !model.configLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.bg)
            } else if model.client == nil {
                MacOnboardingView(model: model)
            } else {
                MacWindow(model: model, explore: explore)
            }
        }
        // Mounted at the ROOT, not inside `MacWindow`, so it covers onboarding too — a failed
        // Connect writes here as well — and so it survives the config gate flipping underneath it.
        .overlay(alignment: .bottom) {
            // The animation lives on the container, not at the mutation site: `model.toast` is
            // written from a dozen failure paths across the app and none of them wrap the
            // assignment in `withAnimation`, so without this the banner cuts in and out.
            ZStack {
                if let toast = model.toast {
                    MacToast(text: toast) { model.toast = nil }
                }
            }
            .animation(Motion.standard(0.28), value: model.toast)
        }
        .environment(\.palette, palette)
        .environment(\.metrics, .mac)
        .preferredColorScheme(model.theme.colorScheme)
        // §5.3, on the ROOT so a drop is accepted anywhere in the window.
        .macDropTarget(model: model)
        .task { await model.load() }
        // Files opened from the Dock, from Finder's "Open with", and `bambu:` URLs all arrive
        // through `application(_:open:)` and land in the same place a drop does. The handler is
        // installed here rather than in the delegate because it needs the model; the delegate
        // buffers anything that arrives before this runs, which is the launch-by-double-clicking-a
        // -3mf case — otherwise the file that started the app is the one file it ignores.
        .task { MacAppDelegate.setOpenHandler { urls in MacOpenRouter.route(urls, model: model) } }
        // §5.4: index the library into Spotlight, incrementally, on every refresh.
        //
        // Driven from the ROOT rather than from the Files section on purpose — the library is
        // refreshed by uploads, drops and deletes that happen while Files is not on screen, and an
        // index that only updated when someone was looking at Files would be stale exactly when it
        // mattered. `sync` is a diff, so the overwhelmingly common pass does nothing at all.
        .onChange(of: model.library.files) { _, files in
            guard let files else { return }
            MacSpotlightIndexer.shared.sync(files)
        }
        // Signing out means these files are no longer reachable. Leaving them searchable would
        // offer hits that open an app which can no longer find them — worse than no hits, because
        // Spotlight is trusted and the failure reads as Sprout having lost the file.
        .onChange(of: model.client == nil) { _, disconnected in
            if disconnected { MacSpotlightIndexer.shared.clear() }
        }
        .environment(model)
        .environment(explore)
    }

    private var palette: Palette {
        Palette.forScheme(model.theme.colorScheme ?? scheme)
    }
}
#endif
