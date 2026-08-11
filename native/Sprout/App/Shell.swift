import SwiftUI

/// Config gate → tab host → overlays. The single place that decides what the app is showing.
struct Shell: View {
    @Environment(\.palette) private var c
    /// The device's scheme, used only when the preference is `system`.
    @Environment(\.colorScheme) private var scheme
    @State private var model = AppModel()
    @State private var showSettings = false
    /// The MakerWorld browse session. Owned here rather than by the Explore page, because the page
    /// is mounted by a `fullScreenCover` and dying with it is exactly the bug (F2) — leaving and
    /// re-entering must return to the results, the query and the scroll position you left behind.
    @State private var explore = ExploreModel()

    var body: some View {
        ZStack {
            c.bg.ignoresSafeArea()

            if !model.configLoaded {
                // Hold the splash rather than flashing onboarding at someone already set up.
                ProgressView().tint(c.accent)
            } else if model.client == nil {
                SettingsView(model: model, isOnboarding: true)
            } else {
                main
            }
        }
        .environment(\.palette, Palette.forScheme(model.theme.colorScheme ?? scheme))
        .preferredColorScheme(model.theme.colorScheme)
        .task { await model.load() }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model, isOnboarding: false)
        }
        .fullScreenCover(item: Binding(get: { model.overlay }, set: { model.overlay = $0 })) { overlay in
            OverlayHost(model: model, overlay: overlay)
        }
        .overlay(alignment: .bottom) {
            // The animation lives on the container, not at the mutation site: `model.toast` is
            // written from half a dozen failure paths across the app and none of them wrap the
            // assignment in `withAnimation`, so without this the banner's move/opacity transition
            // never plays and it cuts in and out.
            ZStack {
                if let toast = model.toast {
                    ToastBanner(text: toast) { model.toast = nil }
                }
            }
            .animation(Motion.standard(0.28), value: model.toast)
        }
        .environment(model)
        .environment(explore)
    }

    private var main: some View {
        MainTabs(model: model, onSettings: { showSettings = true })
    }
}

extension Overlay: Identifiable {
    var id: String {
        switch self {
        case .camera: "camera"
        case .upload: "upload"
        case .alerts: "alerts"
        case .wizard(let f): "wizard-\(f.id)"
        case .stlViewer(let f): "stl-\(f.id)"
        case .layerViewer(let f): "layers-\(f.id)"
        }
    }
}

/// Routes the active overlay to its view. Kept separate so `Shell` stays a readable outline.
struct OverlayHost: View {
    let model: AppModel
    let overlay: Overlay

    var body: some View {
        switch overlay {
        case .camera: CameraOverlay(model: model)
        case .upload:
            // Explore is a PAGE, not a sheet — see ExploreView for what the sheet chrome was doing
            // wrong. It still arrives through the overlay slot because that is how this app
            // presents anything full-screen.
            if let client = model.client {
                ExploreView(model: model, client: client)
            } else {
                Color.clear.onAppear { model.overlay = nil }
            }
        case .alerts: AlertsOverlay(model: model)
        case .wizard(let file): WizardView(model: model, file: file)
        case .stlViewer(let file): StlViewerOverlay(model: model, file: file)
        case .layerViewer(let file): LayerViewerOverlay(model: model, file: file)
        }
    }
}

/// Transient failure message. Auto-dismisses; tapping clears it early.
struct ToastBanner: View {
    let text: String
    let onDismiss: () -> Void
    @Environment(\.palette) private var c

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(c.t1)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s3))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(c.line2))
            .padding(.horizontal, 20)
            .padding(.bottom, 96)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onTapGesture(perform: onDismiss)
            // Keyed on the message. Replacing `model.toast` with a different string keeps this view
            // at the same structural position, so an un-keyed `.task` would not restart and the new
            // message would run out whatever was left of the previous banner's five seconds.
            .task(id: text) {
                try? await Task.sleep(for: .seconds(5))
                // A cancelled sleep means a newer message replaced this one (or the banner is going
                // away); dismissing here would clear the toast that just arrived.
                guard !Task.isCancelled else { return }
                onDismiss()
            }
    }
}
