#if os(macOS)
import SwiftUI

/// Routes the selected section to its content view. Kept separate so `MacWindow` stays a readable
/// outline of the window rather than a switch statement wearing one.
struct MacSectionContent: View {
    let model: AppModel
    let explore: ExploreModel
    let section: TabKey

    var body: some View {
        switch section {
        case .printer: MacPrinterSection(model: model)
        case .library: MacFilesSection(model: model)
        case .jobs:    MacJobsSection(model: model)
        case .ams:     MacHardwareSection(model: model)
        case .power:   MacPowerSection(model: model)
        case .explore: MacExploreSection(model: model, explore: explore)
        }
    }
}

/// Routes the selected section to its inspector.
///
/// One rule governs every case here (§4): **content is the thing, the inspector is what's selected
/// or what's live.** It is never a second navigation surface, and it never holds anything that is
/// not about the current selection. A case that starts wanting its own navigation is a case that
/// belongs in the content column.
struct MacInspectorContent: View {
    let model: AppModel
    let explore: ExploreModel
    let section: TabKey

    var body: some View {
        switch section {
        case .printer: MacPrinterInspector(model: model)
        case .library: MacFilesInspector(model: model)
        case .jobs:    MacJobsInspector(model: model)
        case .ams:     MacHardwareInspector(model: model)
        case .power:   MacPowerInspector(model: model)
        case .explore: MacExploreInspector(model: model, explore: explore)
        }
    }
}

/// `⌘R`. §10: refetches the current section **and nothing else** — so this is a switch, not a
/// "reload everything". A blanket refresh would restart polls the user is not looking at and, on
/// Hardware, refetch the one segment (`Nozzles`) that §4 says is live socket state and must not.
enum MacSectionRefresh {
    @MainActor
    static func run(_ section: TabKey, model: AppModel, explore: ExploreModel) async {
        switch section {
        case .printer: await model.refreshLanMode()
        case .library: await model.library.reload()
        case .jobs:    await model.jobs.refreshAll()
        case .ams:     await model.hardware.reload()
        case .power:   await model.power.reload()
        case .explore:
            // `laPushUrl`, NOT `resolvePushUrl` — collections are plain authenticated HTTP with no
            // APNs involved, so refreshing them must keep working with push switched off.
            explore.refresh(CollectionsClient(
                baseUrl: model.config.flatMap(ConfigRules.laPushUrl),
                apiKey: model.config?.apiKey ?? ""
            ))
        }
    }
}
#endif
