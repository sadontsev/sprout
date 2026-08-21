import SwiftUI

/// The one failure card used wherever an upload or import can fail.
///
/// Unguarded: it is plain SwiftUI with no platform API in it, and the macOS import path reports
/// failures the same way. Only the metrics differ, and those come from the environment.
struct UploadErrorCard: View {
    let text: String
    @Environment(\.palette) private var c

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "xmark.circle")
                .scaledFont(16, weight: .medium)
                .foregroundStyle(c.error)
            Text(text)
                .scaledFont(12.5, weight: .medium)
                .lineSpacing(3)
                .foregroundStyle(c.t2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.errorDim))
    }
}
