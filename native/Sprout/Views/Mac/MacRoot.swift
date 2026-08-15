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
        .environment(\.palette, palette)
        .environment(\.metrics, .mac)
        .preferredColorScheme(model.theme.colorScheme)
        .task { await model.load() }
        .environment(model)
        .environment(explore)
    }

    private var palette: Palette {
        Palette.forScheme(model.theme.colorScheme ?? scheme)
    }
}
#endif
