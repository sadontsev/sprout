#if os(iOS)
import SwiftUI

/// The filters `select/design2` honours, edited as a draft and applied once on Done so a sheet
/// full of toggles costs one request, not one per tap.
struct ExploreFilterSheet: View {
    @State var draft: MWSearchFilters
    /// The connected printer's MakerWorld code, or nil when MakerWorld has no code for it.
    let printerCode: String?
    let printerModel: String?
    let onApply: (MWSearchFilters) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var c

    private static let times: [(String, Int?)] = [("Any", nil), ("< 1 h", 60), ("< 3 h", 180),
                                                  ("< 8 h", 480), ("< 24 h", 1440)]
    private static let weights: [(String, Int?)] = [("Any", nil), ("< 50 g", 50), ("< 200 g", 200),
                                                    ("< 500 g", 500)]
    private static let licences: [(String, String)] = [
        ("Public domain", "CC0"), ("CC BY", "BY"), ("CC BY-SA", "BY-SA"), ("CC BY-ND", "BY-ND"),
        ("CC BY-NC", "BY-NC"), ("CC BY-NC-SA", "BY-NC-SA"), ("CC BY-NC-ND", "BY-NC-ND"),
    ]

    /// Why the toggle is off, in the user's words. **Three cases, not two.** The old copy read
    /// "MakerWorld has no code for this printer" whenever the code was nil — which is also what nil
    /// means when there is no printer connected at all, so a fresh install was told MakerWorld had
    /// failed to recognise a machine it had never been shown.
    private var printerSubtitle: String {
        guard let printerModel else { return "No printer connected yet" }
        return printerCode == nil
            ? "MakerWorld has no code for \(printerModel)"
            : "Profiles published for the \(printerModel)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Printer") {
                    // Dimmed, never guessed: an unknown model would send no code and claim a
                    // filter it did not apply.
                    Toggle(isOn: Binding(get: { draft.printerCode != nil },
                                         set: { draft.printerCode = $0 ? printerCode : nil })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Made for my printer")
                            Text(verbatim: printerSubtitle)
                                .scaledFont(12).foregroundStyle(c.t3)
                        }
                    }
                    .disabled(printerCode == nil)

                    Picker("Nozzle", selection: $draft.nozzle) {
                        Text("Any").tag(String?.none)
                        ForEach(["0.2", "0.4", "0.6", "0.8"], id: \.self) { Text(verbatim: "\($0) mm").tag(String?.some($0)) }
                    }
                }
                Section("Print") {
                    Picker("Colours", selection: $draft.colours) {
                        Text("Any").tag(MWSearchFilters.Colours.any)
                        Text("Single").tag(MWSearchFilters.Colours.single)
                        Text("Multi").tag(MWSearchFilters.Colours.multi)
                    }
                    .pickerStyle(.segmented)
                    Picker("Print time", selection: $draft.maxMinutes) {
                        ForEach(Self.times, id: \.0) { Text($0.0).tag($0.1) }
                    }
                    Picker("Filament", selection: $draft.maxGrams) {
                        ForEach(Self.weights, id: \.0) { Text($0.0).tag($0.1) }
                    }
                }
                Section("Model") {
                    Picker("Tag", selection: $draft.tag) {
                        Text("Any").tag(MWSearchFilters.Tag.any)
                        Text("Featured").tag(MWSearchFilters.Tag.featured)
                        Text("Exclusive").tag(MWSearchFilters.Tag.exclusive)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Customisable", isOn: $draft.customisable)
                }
                Section("Licence") {
                    ForEach(Self.licences, id: \.1) { label, code in
                        Toggle(label, isOn: Binding(get: { draft.licences.contains(code) },
                                                    set: { on in
                            if on { draft.licences.insert(code) } else { draft.licences.remove(code) }
                        }))
                    }
                }
                Section {
                    Button("Reset all filters", role: .destructive) { draft = MWSearchFilters() }
                        .disabled(draft.isEmpty)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onApply(draft); dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(c.accent)
    }
}
#endif
