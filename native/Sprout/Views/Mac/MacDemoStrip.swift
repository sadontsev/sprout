#if os(macOS)
import SwiftUI

/// The demo banner, on every screen (§1).
///
/// Same reasoning as `Shell.demoBanner` on iOS, and deliberately the same visual language: CHROME,
/// not an alert. A demo that cannot be told from a live connection is a trap — for a reviewer
/// deciding what the app does, and for the owner wondering why their printer is not responding.
struct MacDemoStrip: View {
    let model: AppModel
    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(c.accent).frame(width: 5, height: 5)
            Text("DEMO · sample data")
                .font(.mono(m.monoLabel, weight: .bold))
                .foregroundStyle(c.t3)
            Spacer(minLength: 0)
            Button("Exit demo") { Task { await model.exitDemo() } }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, m.gutter)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(c.s2)
        .overlay(alignment: .bottom) { Rectangle().fill(c.line2).frame(height: 0.5) }
    }
}
#endif
