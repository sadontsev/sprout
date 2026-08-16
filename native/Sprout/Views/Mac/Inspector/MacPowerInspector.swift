#if os(macOS)
import SwiftUI

/// The Power inspector (§4): what is drawing right now, and what it is priced at.
///
/// Power has no selection — the socket table is deliberately unselectable — so this column is the
/// "what is LIVE" half of §4's rule: the printer socket's draw, the tariff those numbers are priced
/// with, and who owns that tariff. Nothing here navigates.
///
/// **The prototype's card is titled LAST 24 H; this one is not, and the difference is the point.**
/// Bambuddy exposes a plug's *live* power and a running *today* total (`/smart-plugs/{id}/status`);
/// there is no hourly series anywhere in the API, and `PlugPoller` keeps only what it polls. Drawing
/// 24 bars from that would mean inventing 23 of them. So the chart shows exactly what the app has
/// watched since this inspector was last shown, says so in its own footnote, and the axis is
/// labelled with the span the bars actually cover rather than a day it never saw.
struct MacPowerInspector: View {
    let model: AppModel
    /// Does this instance bring its own `ScrollView`?
    ///
    /// True in the inspector column, which is its own scrolling region. False when the panes fall
    /// back INTO the section (`MacInspectorPlacement`), because the section already scrolls and
    /// nesting one scroll view in another gives an ambiguous height and two scrollbars.
    ///
    /// A parameter rather than a computed `panes` property read from outside, because a SwiftUI
    /// view's `@State` and `@Environment` are only established once it is installed in the
    /// hierarchy — reading `SomeInspector(model:).panes` from another view would evaluate those
    /// wrappers before SwiftUI has set them up.
    var scrolls = true


    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    /// One sample, and when it was taken.
    ///
    /// The time is stored rather than multiplied out from the bar count, because the sampler's clock
    /// is not the poller's (see the `.task` below): a count × cadence label is a claim about elapsed
    /// time that nothing has measured.
    private struct Sample: Equatable {
        let at: Date
        /// `nil` is "no current reading" — a gap, drawn as a gap, never as zero.
        let watts: Double?
    }

    /// The trace.
    ///
    /// View state rather than store state because it is presentation history of a value the store
    /// already publishes: nothing else reads it, and it is honest about dying with the column (see
    /// the footnote it renders). A store-owned ring buffer is the upgrade if this should survive
    /// leaving the section.
    @State private var samples: [Sample] = []

    private var power: PowerStore { model.power }

    /// 24 bars, matching the prototype's chart, sampled at the hero poller's cadence.
    private static let barCount = 24
    /// The prototype's chart height. Metrics names density, not chart geometry.
    private static let chartHeight: CGFloat = 74

    var body: some View {
        MacInspectorScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: m.cardGap) {
                drawCard
                tariffCard
                sourceNote
            }
            .padding(m.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(c.bg)
        // Sampling, not fetching: it reads a value `PlugPoller` has already published, and it is
        // keyed on the SESSION (`MacPowerSessionKey`, shared with the section) so switching machines
        // — or re-Saving onto a different server with the same printer id — starts a clean trace
        // rather than splicing two plugs' draw into one line. `printerId` alone does not change on
        // that second case, which is the whole reason the key exists.
        //
        // **This is its own clock, not the poller's, and the bars say only what that supports.** The
        // loop wakes on the same 5 s cadence, but nothing here observes when a poll actually lands —
        // `Task.sleep` is a floor and each poll adds its own latency — so the two drift, and a bar is
        // "the value the poller had published when the sampler looked": occasionally the same
        // reading twice, occasionally one skipped. It is NOT "one bar per poll", which is what this
        // used to claim. Making that claim true needs a per-poll signal on `PlugPoller`
        // (a `pollCount` this could key `.onChange` on) — noted in the report; a value-equality
        // watch cannot stand in for it, because two identical readings must still advance the trace.
        .task(id: MacPowerSessionKey(model)) {
            samples = []
            while !Task.isCancelled {
                // `liveWatts`: a retained reading from a plug Bambuddy can no longer reach is not a
                // measurement. Drawing it produced a flat line of confident bars and a `peak N W`
                // for a plug that had stopped answering — and made this card's own premise ("nil is
                // a poll that returned no reading") unreachable, since the store never nils `watts`.
                samples.append(Sample(at: Date(), watts: power.hero.liveWatts))
                if samples.count > Self.barCount {
                    samples.removeFirst(samples.count - Self.barCount)
                }
                try? await Task.sleep(for: PowerStore.heroCadence)
            }
        }
    }

    // MARK: - Draw

    private var drawCard: some View {
        let peak = samples.compactMap(\.watts).max()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                monoLabel("LIVE DRAW")
                Spacer(minLength: 6)
                // The bars are scaled to the peak, so without this the chart has no y-axis at all
                // and a tall bar could mean 12 W or 1200 W.
                Text(peakLabel(peak))
                    .font(.mono(m.monoLabel, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(c.t3)
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    bar(at: index, peak: peak ?? 0)
                }
            }
            .frame(height: Self.chartHeight)
            .padding(.top, 12)

            HStack(spacing: 0) {
                Text(spanLabel)
                Spacer(minLength: 6)
                Text(verbatim: "NOW")
            }
            .font(.mono(m.monoLabel, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(c.t3)
            .padding(.top, 8)

            // "since Power opened" was wrong: `samples` is `@State` on a view that
            // `.inspector(isPresented:)` mounts, so collapsing the inspector (⌥⌘I, or the toolbar
            // button) destroys the trace while Power stays open. The sentence now names the lifetime
            // it actually has.
            Text("Bambuddy reports live draw and today's total, not an hourly series — this is what the app has watched since this inspector was last shown.")
                .font(.system(size: m.body))
                .lineSpacing(3)
                .foregroundStyle(c.t3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(m.cardPadding)
        .powerInspectorCard(c, radius: m.cardRadius)
    }

    /// Bars fill from the right, so the newest reading is always in the same place and the trace does
    /// not slide sideways as history accumulates.
    private func bar(at index: Int, peak: Double) -> some View {
        let lead = Self.barCount - samples.count
        let value: Double? = index >= lead ? samples[index - lead].watts : nil
        let isLatest = index == Self.barCount - 1 && !samples.isEmpty
        // Deliberately OFF the card/control/chip scale: this is a data mark in a sparkline, not a
        // piece of chrome, and it is 2 pt tall at its floor. Any token radius would round a 2 pt bar
        // into a dot and a 40 pt one into a lozenge — the mark has to stay a bar at every height.
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(value == nil ? c.s3 : (isLatest ? c.accent : c.accent.opacity(0.55)))
            .frame(maxWidth: .infinity)
            .frame(height: barHeight(value, peak: peak))
    }

    /// A gap and a zero both draw as the 2 pt floor — a bar of no height would read as "nothing
    /// here" for a plug that is genuinely idle at 0 W.
    private func barHeight(_ value: Double?, peak: Double) -> CGFloat {
        guard let value, peak > 0 else { return 2 }
        let fraction = min(1, max(0, value / peak))
        return max(2, Self.chartHeight * CGFloat(fraction))
    }

    /// The y-axis, or — when there is no axis — why there isn't one.
    ///
    /// "no reading yet" was said for all four empty cases, and three of them are not waiting for
    /// anything: a printer with no plug bound has nothing to measure it, and a plug the server
    /// cannot reach is not about to report. Same rule as the section's stat captions: name the
    /// capability that is absent, never a promise the app cannot keep.
    private func peakLabel(_ peak: Double?) -> String {
        if let peak { return "peak \(Int(peak.rounded())) W" }
        switch power.plug {
        case .loading: return "checking for a plug"
        case .unlinked: return "no plug linked"
        case .linked: return power.hero.reachable ? "no reading yet" : "plug unreachable"
        }
    }

    /// The span actually covered, MEASURED from the oldest bar on screen.
    ///
    /// It used to be `(count − 1) × cadence`, which understated its own axis and could never print
    /// the value the card was described by: 23 gaps × 5 s is 115 s, and integer division rendered
    /// that "−1 min", hiding 55 s. Truncating the cadence to whole seconds made it worse — a
    /// sub-second cadence collapsed the whole label to "−0 s". And multiplying out a count is a
    /// claim about elapsed time in a loop that drifts (see the sampler), so the timestamp the sample
    /// already carries is both simpler and the only honest source.
    private var spanLabel: String {
        guard samples.count > 1, let oldest = samples.first else { return "just now" }
        return "−" + Self.elapsedLabel(Date().timeIntervalSince(oldest.at))
    }

    /// Whole minutes AND the remaining seconds, so nothing is hidden by rounding.
    private static func elapsedLabel(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        guard seconds >= 60 else { return "\(seconds) s" }
        let minutes = seconds / 60
        let rest = seconds % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    // MARK: - Tariff

    private var tariffCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            monoLabel("TARIFF")
            VStack(alignment: .leading, spacing: 9) {
                factRow("Rate", rateText, power.price == nil ? .unknown : .value)
                // Bambuddy has no standing-charge field at all (`AppSettings` carries a unit rate and
                // a currency), so this is a statement of fact rather than a value that failed to
                // load: every cost in this section is unit rate × kWh and nothing else. It said so
                // in this comment and then rendered `.unknown`, which is the encoding for "we could
                // not get this" — the words and the colour disagreed, and the colour is louder.
                factRow("Standing charge", "not counted", .note)
                factRow("Meter", meterText, power.plug.value == nil ? .unknown : .value, mono: false)
                if let tracking = trackingText {
                    factRow("Tracking", tracking, mono: false)
                }
            }
            .padding(.top, 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(m.cardPadding)
        .powerInspectorCard(c, radius: m.cardRadius)
    }

    private var rateText: String {
        guard let price = power.price else { return "not set" }
        // Deliberately NOT `PowerStore.money`, which is fixed at two decimals so a column of COSTS
        // lines up. A unit rate is not a cost: 0.257 rounded to £0.26 is a number the server never
        // said, and this section's rule is that the app reports prices rather than producing them.
        return "\(power.symbol)\(price.formatted(.number.precision(.fractionLength(2...4)))) / kWh"
    }

    /// What is actually measuring, since every figure in this section comes from that device.
    private var meterText: String {
        guard let plug = power.plug.value else {
            return power.plug == .loading ? "checking…" : "no plug linked"
        }
        let name = Power.plugLabel(plug)
        guard let via = integrationName(plug.plugType) else { return name }
        return "\(name) · \(via)"
    }

    private func integrationName(_ raw: String?) -> String? {
        switch (raw ?? "").lowercased() {
        case "": return nil
        case "homeassistant", "home_assistant": return "Home Assistant"
        case "mqtt": return "MQTT"
        case "rest": return "REST"
        // The server's own word, unrecognised. Printing it beats inventing a friendlier one.
        default: return raw
        }
    }

    /// Only when the server states one — an absent tracking mode is not "estimated".
    ///
    /// And never the raw token. `integrationName` two rows above exists precisely because a wire
    /// value is not a label; this row was printing `smart_plug` verbatim directly beneath it. Known
    /// tokens get their own words; anything else has its punctuation tidied and nothing else — the
    /// server's own word survives, because inventing a friendlier meaning for a token we have not
    /// seen is how a UI ends up asserting something the backend never said.
    private var trackingText: String? {
        let raw = (power.settings?.energyTrackingMode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "smart_plug", "smartplug": return "Smart plug"
        default: return Self.tidyToken(raw)
        }
    }

    /// `some_mode` → "Some mode". Separators become spaces and the first letter is capitalised; no
    /// word is translated, dropped or added.
    private static func tidyToken(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// How a fact row's value should READ — which is a different question from what it says.
    ///
    /// Two encodings could not carry three meanings: `missing: true` greyed "not counted" (a true
    /// statement about how this section prices things) identically to "not set" (a tariff the server
    /// never gave us), so a fact looked like a failed load.
    private enum Fact {
        /// A real value the server gave us.
        case value
        /// The server has none. Dimmed, because something is genuinely absent.
        case unknown
        /// A statement of fact about the app, not a value at all. Neither full strength (which would
        /// read as a figure) nor dimmed (which would read as missing).
        case note
    }

    private func factRow(_ label: String, _ value: String, _ fact: Fact = .value, mono: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: m.body, weight: .medium))
                .foregroundStyle(c.t3)
            Spacer(minLength: 6)
            Text(value)
                .font(mono ? .mono(m.body, weight: .medium) : .system(size: m.body, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(factColor(fact))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func factColor(_ fact: Fact) -> Color {
        switch fact {
        case .value: return c.t1
        case .unknown: return c.t3
        case .note: return c.t2
        }
    }

    // MARK: - Where the money comes from

    private var sourceNote: some View {
        Text("Costs come from Bambuddy, which owns the tariff. The app never estimates a price it wasn't given.")
            .font(.system(size: m.body))
            .lineSpacing(3)
            .foregroundStyle(c.t3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(m.cardPadding)
            .powerInspectorCard(c, radius: m.cardRadius)
    }

    private func monoLabel(_ text: String) -> some View {
        Text(text)
            .font(.mono(m.monoLabel, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(c.t3)
    }
}

private extension View {
    /// The inspector's one card treatment, matching the section's.
    func powerInspectorCard(_ c: Palette, radius: CGFloat) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(c.s1))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(c.line)
            )
    }
}
#endif
