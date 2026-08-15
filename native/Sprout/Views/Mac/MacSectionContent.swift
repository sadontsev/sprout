#if os(macOS)
import SwiftUI

/// Routes the selected section to its content view. Kept separate so `MacWindow` stays a readable
/// outline of the window rather than a switch statement wearing one.
struct MacSectionContent: View {
    let model: AppModel
    let explore: ExploreModel
    let section: TabKey

    var body: some View {
        Group {
            switch section {
            case .printer: MacPrinterSection(model: model)
            case .library: MacFilesSection(model: model)
            case .jobs:    MacJobsSection(model: model)
            case .ams:     MacHardwareSection(model: model)
            case .power:   MacPowerSection(model: model)
            case .explore: MacExploreSection(model: model, explore: explore)
            }
        }
        // Store lifetimes are driven HERE, not by each section.
        //
        // `AppModel` deliberately has no `startStores()` — polling belongs to whoever can see the
        // section — but leaving each section to remember that produced exactly the drift you would
        // expect: Power started and stopped its store, Files started its, Hardware called `reload`
        // without ever starting, and Jobs did nothing at all. Since Jobs' data is also read by the
        // Printer section (UP NEXT, recent prints) and Printer is the section a fresh launch opens
        // on, "nothing at all" meant the default screen sat on "Loading the queue…" forever.
        //
        // One `switch` in one place cannot drift, and it is the honest home for the rule: this view
        // is the only thing in the app that knows which section is on screen. The body above is a
        // ViewBuilder switch, so exactly one section exists at a time — starting a store here and
        // stopping it on the way out is the same lifetime `.task` gives iOS.
        .task(id: section) {
            startStores(for: section)
            // Cancellation is the stop: `.task(id:)` cancels when `section` changes or the window
            // goes away, which is precisely when the section stops being visible.
            defer { stopStores(for: section) }
            try? await Task.sleep(for: .seconds(60 * 60 * 24))
        }
    }

    /// Jobs' queue and archive back BOTH the Jobs section and the Printer section's UP NEXT and
    /// recent-prints cards, so both start it. The two are never on screen together — the switch
    /// above builds one — so neither can stop the other's polling out from under it.
    private func startStores(for section: TabKey) {
        switch section {
        case .printer: model.jobs.start()
        case .library: model.library.start()
        case .jobs:    model.jobs.start()
        case .ams:     model.hardware.start()
        case .power:   model.power.start()
        case .explore: break        // ExploreModel fetches on demand; it has no poll loop.
        }
    }

    private func stopStores(for section: TabKey) {
        switch section {
        case .printer, .jobs: model.jobs.stop()
        case .library:        model.library.stop()
        case .ams:            model.hardware.stop()
        case .power:          model.power.stop()
        case .explore:        break
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
