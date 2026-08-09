import SwiftUI

/// Config gate → tab host → overlays. The single place that decides what the app is showing.
struct Shell: View {
    @Environment(\.palette) private var c
    @State private var model = AppModel()
    @State private var showSettings = false

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
        .task { await model.load() }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model, isOnboarding: false)
        }
        .fullScreenCover(item: Binding(get: { model.overlay }, set: { model.overlay = $0 })) { overlay in
            OverlayHost(model: model, overlay: overlay)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastBanner(text: toast) { model.toast = nil }
            }
        }
        .environment(model)
    }

    private var main: some View {
        VStack(spacing: 0) {
            // Keyed on the tab so each change replays the fade-rise entrance, the same as the RN
            // build's <FadeRise key={tab} dy={8} duration={300}>.
            FadeRise(dy: 8, duration: 0.3) {
                Group {
                    switch model.tab {
                    case .printer: DashboardView(model: model, onSettings: { showSettings = true })
                    case .library: LibraryView(model: model)
                    case .jobs: JobsView(model: model)
                    case .ams: AmsView(model: model)
                    case .power: PowerView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(model.tab)

            TabBar(active: Binding(get: { model.tab }, set: { model.tab = $0 }))
        }
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
        case .upload: UploadSheet(model: model)
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
            .task {
                try? await Task.sleep(for: .seconds(5))
                onDismiss()
            }
    }
}
