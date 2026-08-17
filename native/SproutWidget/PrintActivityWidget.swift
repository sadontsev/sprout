import ActivityKit
import SwiftUI
import WidgetKit

/// The lock-screen card and Dynamic Island for a print (or an AMS drying cycle).
///
/// Everything here renders from the fixed `LAColors` hexes rather than the app's theme, because a
/// card pushed by the server has no idea what theme the phone is on and must look identical either
/// way.
struct PrintActivityWidget: Widget {
    /// Horizontal breathing room for content that sits near the expanded Dynamic Island's rounded
    /// corners.
    ///
    /// The system does not inset for the corner ARC, only for the bounds, so a glyph in the top or
    /// bottom row gets sliced by the curve while the middle of the same row is fine. Seen in the
    /// field as "Layer 379/590" rendering as "ayer 379/590" and a countdown losing its last digit.
    /// Applied to the text near the corners, never to the whole region — see the bottom region.
    static let cornerInset: CGFloat = 10

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let tint = Color(hexString: context.state.tint)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.stateLabel).font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: context.state.symbol).foregroundStyle(tint)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownSlot(
                        countdown: context.state.countdown(),
                        font: .caption.monospacedDigit(),
                        maxWidth: 64
                    )
                    .foregroundStyle(tint)
                    .padding(.trailing, Self.cornerInset)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.dry == true {
                        DryReadout(state: context.state, tint: tint)
                    } else {
                        VStack(spacing: 5) {
                            ProgressBar(progress: Double(context.state.progress) / 100, tint: tint)
                            HStack {
                                Text("Layer \(context.state.layer)/\(context.state.totalLayers)")
                                Spacer()
                                Text("\(context.state.progress)%")
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            // Only the TEXT is inset, not the bar. The bar is a rectangle whose ends
                            // read as deliberate against the curve; a glyph half-eaten by it reads as
                            // a bug — "Layer" was arriving as "ayer".
                            .padding(.horizontal, Self.cornerInset)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbol).foregroundStyle(tint)
            } compactTrailing: {
                // Drying cards pin progress to 0, so a percentage says nothing about them — they get
                // the countdown instead. Resolved once so the visibility check and the text that
                // follows it read the same clock.
                let countdown = context.state.countdown()
                if context.state.dry == true, countdown != .hidden {
                    CountdownSlot(
                        countdown: countdown,
                        font: .caption2.monospacedDigit(),
                        maxWidth: 44,
                        compact: true
                    )
                    .foregroundStyle(tint)
                } else {
                    Text("\(context.state.progress)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(tint)
                }
            } minimal: {
                Image(systemName: context.state.symbol).foregroundStyle(tint)
            }
            .keylineTint(tint)
        }
    }
}

/// The one place a countdown is rendered, shared by the lock-screen card, the expanded Dynamic
/// Island and the compact one.
///
/// It exists so no site can reintroduce `Date()...eta`: that range inverts as soon as the ETA passes
/// and `...` traps, taking the widget process — and therefore the whole Live Activity — with it. See
/// `LiveActivityCountdown`.
private struct CountdownSlot: View {
    let countdown: LiveActivityCountdown
    let font: Font
    let maxWidth: CGFloat
    /// The compact island slot is too narrow for the word, so it gets the short label.
    var compact: Bool = false

    var body: some View {
        switch countdown {
        case .ticking(let range):
            text(Text(timerInterval: range, countsDown: true))
        case .overdue:
            text(Text(compact ? LiveActivityCountdown.overdueLabelCompact : LiveActivityCountdown.overdueLabel))
        case .hidden:
            EmptyView()
        }
    }

    private func text(_ label: Text) -> some View {
        label
            .font(font)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: maxWidth)
    }
}

/// The full card on the lock screen.
private struct LockScreenCard: View {
    let state: PrintActivityAttributes.ContentState

    private var tint: Color { Color(hexString: state.tint) }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            leadingVisual

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(state.stateLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                    if !state.printerName.isEmpty {
                        Text(state.printerName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CountdownSlot(
                        countdown: state.countdown(),
                        font: .system(size: 13, weight: .semibold).monospacedDigit(),
                        maxWidth: 70
                    )
                    .foregroundStyle(.primary)
                }

                if !state.name.isEmpty {
                    Text(state.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                if state.dry == true {
                    DryReadout(state: state, tint: tint)
                } else {
                    ProgressBar(progress: Double(state.progress) / 100, tint: tint)
                    HStack(spacing: 10) {
                        Text("\(state.progress)%")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        if state.totalLayers > 0 {
                            Text("Layer \(state.layer)/\(state.totalLayers)")
                                .font(.system(size: 11).monospacedDigit())
                        }
                        Spacer()
                        temps
                    }
                    .foregroundStyle(.secondary)

                    if state.queueCount > 0, !state.nextName.isEmpty {
                        Text("Up next · \(state.nextName)")
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
    }

    /// Plate thumbnail when we have one, else the brand glyph, else the SF Symbol. All three live in
    /// the App Group because the widget is a separate process and cannot reach the app's sandbox.
    @ViewBuilder
    private var leadingVisual: some View {
        if let image = loadImage(state.modelUri) ?? loadImage(state.iconUri) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            Image(systemName: state.symbol)
                .font(.system(size: 24))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
        }
    }

    private var temps: some View {
        HStack(spacing: 8) {
            if state.hasNozzle2 {
                tempPair("L", state.nozzle, state.nozzleTarget, active: state.activeNozzle == 0)
                tempPair("R", state.nozzle2, state.nozzle2Target, active: state.activeNozzle == 1)
            } else {
                tempPair("N", state.nozzle, state.nozzleTarget, active: true)
            }
            tempPair("B", state.bed, state.bedTarget, active: false)
        }
    }

    private func tempPair(_ label: String, _ now: Int, _ target: Int, active: Bool) -> some View {
        Text("\(label) \(now)°")
            .font(.system(size: 10, weight: active ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(active ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
    }

    private func loadImage(_ uri: String) -> UIImage? {
        guard !uri.isEmpty, let url = URL(string: uri), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

/// Drying cards trade progress for the two numbers that actually tell the story: interior
/// temperature climbing and humidity falling. The countdown ticks client-side.
private struct DryReadout: View {
    let state: PrintActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            reading("TEMP", value: "\(state.amsTemp ?? 0)°", target: (state.amsTarget ?? 0) > 0 ? "→ \(state.amsTarget ?? 0)°" : nil)
            reading("HUMIDITY", value: "\(state.humidity ?? 0)%", target: nil)
            Spacer()
        }
    }

    private func reading(_ label: String, value: String, target: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                if let target {
                    Text(target)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct ProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.tertiary)
                Capsule().fill(tint).frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 5)
    }
}

extension Color {
    /// Parses the `#RRGGBB` strings the content state carries. These come off the wire from Trellis,
    /// so an unparseable value falls back to grey rather than crashing the widget.
    init(hexString: String) {
        let hex = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
