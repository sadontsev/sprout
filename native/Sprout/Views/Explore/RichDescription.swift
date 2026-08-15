#if os(iOS)
// iOS layout. macOS: Views/Mac/Sections/MacExploreSection.
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI

/// An uploader's description, with its formatting intact.
///
/// The HTML is turned into Markdown by `MakerWorldSearch.markdown(fromHTML:)` and parsed here, so
/// headings, bold, emphasis, numbered steps and links all survive. Everything visual is inherited
/// from the call site — the converter emits no fonts and no colours, which is the point of going via
/// Markdown rather than `NSAttributedString(html:)`.
struct RichDescription: View {
    let description: MakerWorldSearch.Description?
    var font: Font = .system(size: 13.5)
    var lineLimit: Int?

    @Environment(\.palette) private var c

    private var html: String? { description?.html }

    var body: some View {
        if let text = attributed {
            VStack(alignment: .leading, spacing: 7) {
            if description?.isTranslated == true {
                // Says whose words these are. A machine translation presented as the author's own
                // writing is a small lie, and it matters here: these descriptions carry print
                // settings and compatibility claims someone is about to act on.
                HStack(spacing: 5) {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Translated by MakerWorld")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(c.t3)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(c.s2))
            }
            Text(text)
                .font(font)
                .foregroundStyle(c.t2)
                .tint(c.accent)                 // links, in the app's colour rather than systemBlue
                .lineSpacing(3)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)        // these carry dimensions and settings worth copying
            }
        }
    }

    /// `nil` when there is nothing to show, so the caller can omit the whole section.
    var isEmpty: Bool { attributed == nil }

    private var attributed: AttributedString? {
        guard let markdown = MakerWorldSearch.markdown(fromHTML: html) else { return nil }
        // `.inlineOnlyPreservingWhitespace`: the converter has already turned block structure into
        // literal bullets and line breaks, and full markdown parsing would swallow those newlines
        // into paragraph runs that `Text` renders as one long line.
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        // A parse failure falls back to the plain text rather than showing nothing: a description
        // with unusable markup is still worth reading.
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return MakerWorldSearch.plainText(html).map { AttributedString($0) }
        }
        return parsed
    }
}
#endif
