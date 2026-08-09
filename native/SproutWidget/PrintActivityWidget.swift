import ActivityKit
import SwiftUI
import WidgetKit

struct PrintActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text(context.attributes.jobName).font(.headline)
                ProgressView(value: context.state.progress)
                Text(context.state.stateLabel).font(.caption)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(context.state.stateLabel) }
                DynamicIslandExpandedRegion(.trailing) { Text(context.state.etaText) }
                DynamicIslandExpandedRegion(.bottom) { ProgressView(value: context.state.progress) }
            } compactLeading: {
                Text("\(Int(context.state.progress * 100))%")
            } compactTrailing: {
                Text(context.state.etaText)
            } minimal: {
                Text("\(Int(context.state.progress * 100))")
            }
        }
    }
}
