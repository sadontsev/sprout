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
    /// Liquid Glass is a transparency effect, so it has to yield when the system asks for less of
    /// it. Without this the bar keeps refracting the page behind it for someone who explicitly
    /// turned that off.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Ties the selected item's glass to a single shape that MORPHS between tabs rather than one
    /// capsule fading out while another fades in. The container is what lets neighbouring glass
    /// blend as it travels; without it the highlight would pop.
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(TabKey.allCases, id: \.self) { key in
                    let on = key == active
                    Tap(scale: 0.9) {
                        // Animated here, not in the caller: the morph belongs to the bar, and the
                        // screen swap has its own (slower) transition.
                        withAnimation(Motion.spring(0.42)) { active = key }
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
                        .padding(.vertical, 7)
                        .padding(.horizontal, 2)
                        .contentShape(.rect)
                        // `.interactive()` is the point of this: the glass responds to the touch
                        // itself — it lifts and gives under a press and a drag, instead of the
                        // material being a static backdrop with a separate scale animation on top.
                        // Only the SELECTED item carries glass; giving every item its own turns the
                        // bar into five competing highlights.
                        .glassEffect(
                            on && !reduceTransparency
                                ? .regular.tint(c.accent.opacity(0.18)).interactive()
                                : .identity,
                            in: .capsule
                        )
                        .glassEffectID(on ? "tab-selection" : "tab-\(key.rawValue)", in: glassNamespace)
                    }
                    .accessibilityLabel(key.label)
                    .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        // Liquid Glass belongs to the floating control layer, not to content: the bar sits above the
        // scrolling page and refracts it, so it reads as chrome rather than another card.
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(c.s1)
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(c.line))
            }
        }
        .glassEffect(reduceTransparency ? .identity : .regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }
}
