#if os(macOS)
import SwiftUI

/// The sidebar (§2): five sections, a `BROWSE` group holding Explore, and a footer card that says
/// what the app is connected to.
///
/// Explore is a peer here and a push from the Files `+` on iOS. It sits under its own header rather
/// than as a sixth flat row because it browses *someone else's catalogue* — every row above it is
/// about this printer, and flattening the two would make the sidebar mean two different things.
///
/// Printers are deliberately NOT in here. The toolbar popup is the only printer switcher on Mac
/// (§3), so the sidebar never mixes machines with sections.
struct MacSidebar: View {
    let model: AppModel
    @Binding var section: TabKey

    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        List(selection: $section) {
            Section {
                ForEach(TabKey.macPrimary, id: \.self) { row($0) }
            }
            Section {
                ForEach(TabKey.macBrowse, id: \.self) { row($0) }
            } header: {
                Text("BROWSE")
                    .font(.mono(m.monoLabel, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(c.t3)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { connectionCard }
    }

    private func row(_ key: TabKey) -> some View {
        HStack(spacing: 9) {
            icon(key)
                .frame(width: 15, height: 15)
                .foregroundStyle(section == key ? c.accent : c.t2)
            Text(key.label)
                .font(.system(size: m.cardTitle, weight: .semibold))
            Spacer(minLength: 6)
            if let digit = key.commandDigit {
                // Drawn in the row, as the prototype does. The shortcut is also registered as a real
                // `.keyboardShortcut` in MacCommands — this is the affordance, not the mechanism, so
                // the two must not drift: both read `TabKey.commandDigit`.
                Text(verbatim: "⌘\(digit)")
                    .font(.mono(m.monoLabel, weight: .medium))
                    .foregroundStyle(c.t3)
            }
        }
        .frame(height: m.rowHeight)          // 28 pt on Mac (§8)
        .tag(key)
    }

    @ViewBuilder
    private func icon(_ key: TabKey) -> some View {
        if let symbol = key.systemImage {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
        } else {
            // The brand nozzle mark — an asset-catalog template image, not an SF Symbol. Same asset
            // the iOS tab bar uses.
            Image("TabNozzle").renderingMode(.template).resizable().scaledToFit()
        }
    }

    /// What the app is talking to, permanently visible.
    ///
    /// On iOS this lives only in Settings; §2 puts it here because a Mac window has the room, and
    /// "which server am I looking at" is the first question when something looks wrong.
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
                Text("BAMBUDDY")
                    .font(.mono(m.monoLabel, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(c.t2)
            }
            Text(host)
                .font(.system(size: 11))
                .foregroundStyle(c.t3)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(lanLine)
                .font(.system(size: 11))
                .foregroundStyle(c.t3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(c.line))
        .padding(8)
    }

    /// Reflects the CONNECTION, not the print. A printer that is off is not a server that is down,
    /// and this card answers the second question.
    private var connectionColor: Color {
        model.client == nil ? c.idle : (model.vm.kind == .offline ? c.heating : c.running)
    }

    private var host: String {
        guard let raw = model.config?.baseUrl, !raw.isEmpty else { return "Not configured" }
        guard let url = URL(string: raw), let h = url.host() else { return raw }
        return url.port.map { "\(h):\($0)" } ?? h
    }

    private var lanLine: String {
        switch model.lanMode {
        case .on: "LAN mode on · direct"
        case .off: "LAN mode off · cloud relay"
        case .unknown: model.isDemo ? "Demo · no server" : "LAN mode unknown"
        }
    }
}
#endif
