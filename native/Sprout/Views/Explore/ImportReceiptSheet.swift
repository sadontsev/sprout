#if os(iOS)
// iOS layout. macOS: Views/Mac/Sections/MacExploreSection.
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI

/// What just happened, and where the file went.
///
/// **The import used to end the browse session without saying anything.** `doImport()` fired a toast
/// and then replaced the whole overlay with the print wizard. The reasoning was sound — there should
/// be one print path — but the effect was that browsing ended in a different screen with no
/// statement of what had been imported or where it landed, and `MakerWorldImportResponse.folderId`
/// was returned by the server and never used.
///
/// So: name the file, name the folder, and offer all three things someone might actually want next.
/// "Keep exploring" is first-class rather than a dismiss, because importing a model is not a
/// commitment to print it right now.
struct ImportReceiptSheet: View {
    let model: AppModel
    let client: BambuddyClient
    let receipt: ImportReceipt

    @Environment(\.palette) private var c
    @Environment(\.dismiss) private var dismiss
    @State private var opening = false

    private var filename: String { receipt.response.filename ?? "The model" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(c.accent)
                Text(receipt.response.wasExisting == true ? "Already in your library" : "Added to your library")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(c.t1)
            }
            .padding(.bottom, 12)

            // The path, so the answer to "where did it go" is on screen rather than inferred.
            Text(verbatim: "Files › MakerWorld › \(filename)")
                .font(.mono(12.5, weight: .medium))
                .foregroundStyle(c.t2)
                .lineLimit(3)
                .padding(.bottom, 20)

            VStack(spacing: 10) {
                action("Slice and print", symbol: "printer.fill", primary: true, busy: opening) {
                    // The SAME wizard, not a second print path: the LAN gate, the wrong-printer
                    // guard, the plate review and the enqueue all already live there. A MakerWorld
                    // import is never printable as-is — measured, the file is a plain 3mf whose
                    // /gcode answers 404 — so the wizard opens at step one and slices.
                    guard !opening else { return }
                    opening = true
                    Task {
                        defer { opening = false }
                        guard let file = try? await client.getFileDetail(receipt.response.libraryFileId)
                        else {
                            model.toast = "Couldn’t open \(filename) — it is in your library."
                            dismiss()
                            return
                        }
                        // Replacing the overlay rather than closing and reopening: going nil →
                        // .wizard in the same turn flashes an empty frame.
                        model.overlay = .wizard(file)
                    }
                }
                action("Open in Files", symbol: "folder") {
                    dismiss()
                    model.overlay = nil
                    model.tab = .library
                }
                action("Keep exploring", symbol: "magnifyingglass") { dismiss() }
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.sheet)
    }

    private func action(_ title: String, symbol: String, primary: Bool = false, busy: Bool = false,
                        run: @escaping () -> Void) -> some View {
        Tap(action: run) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView().tint(primary ? .black : c.t2)
                } else {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                }
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(primary ? .black : c.t1)
            .padding(.horizontal, 15)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(primary ? c.accent : c.s2))
            .contentShape(.rect)
        }
    }
}
#endif
