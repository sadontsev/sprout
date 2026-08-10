import SwiftUI

enum TabKey: String, CaseIterable, Hashable, Sendable {
    case printer, library, jobs, ams, power

    var label: String {
        switch self {
        case .printer: "Printer"
        case .library: "Files"
        case .jobs: "Jobs"        // queue + history merged into one print timeline
        case .ams: "Hardware"
        case .power: "Power"
        }
    }

    /// SF Symbol closest to the Feather glyph the RN build used.
    var symbol: String {
        switch self {
        case .printer: "cpu"      // replaced by NozzleIcon — kept for completeness
        case .library: "folder"
        case .jobs: "list.bullet"
        case .ams: "shippingbox"
        case .power: "power"
        }
    }
}

/// The floating bottom bar. Sits above the content (the dashboard reserves 120 pt of bottom
/// padding for it) and paints `s1`, not the `tabbar` token — that one is unused here.
struct TabBar: View {
    @Binding var active: TabKey
    @Environment(\.palette) private var c

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TabKey.allCases, id: \.self) { key in
                let on = key == active
                Tap(scale: 0.9) {
                    active = key
                } content: {
                    VStack(spacing: 4) {
                        if key == .printer {
                            NozzleIcon(color: on ? c.accent : c.t3, size: 22)
                        } else {
                            Image(systemName: key.symbol)
                                .font(.system(size: 19, weight: .regular))
                                .frame(height: 22)
                                .foregroundStyle(on ? c.accent : c.t3)
                        }
                        Text(key.label)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(on ? c.accent : c.t3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 2)
                    .contentShape(.rect)
                }
                .accessibilityLabel(key.label)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        // Liquid Glass belongs to the floating control layer, not to content: the bar sits above the
        // scrolling page and refracts it, so it reads as chrome rather than another card.
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }
}
