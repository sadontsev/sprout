import SwiftUI

struct Shell: View {
    @Environment(\.palette) private var c

    var body: some View {
        ZStack {
            c.bg.ignoresSafeArea()
            Text("Sprout").font(.mono(24)).foregroundStyle(c.accent)
        }
    }
}
