import SwiftUI

/// Keeps the plate-cooldown model fed: the bed curve for the decay fit, and a much longer window
/// whose idle floor is the room temperature.
///
/// Ambient is MEASURED rather than fitted. An earlier version solved for it as a third parameter and
/// got 39.9 °C while the plate was at 56 °C, which would have declared the plate "as cool as it
/// gets" at 56 °C. Measuring the floor and fitting only the rate is what makes the ETA honest.
@MainActor
@Observable
final class CooldownStore {
    private(set) var vm: CooldownVM?

    private let client: BambuddyClient
    private var samples: [BedSample] = []
    private var ambientC: Double?
    private var task: Task<Void, Never>?

    /// The curve window is short because only the recent slope matters; the ambient window is a full
    /// day because the floor only shows up across idle periods.
    private static let curveWindowHours = 3
    private static let ambientWindowHours = 24
    private static let curveRefresh: Duration = .seconds(60)
    /// 30 minutes at a 60 s curve cadence.
    private static let ambientEveryNPasses = 30

    init(client: BambuddyClient) {
        self.client = client
    }

    func start(printerId: Int) {
        task?.cancel()
        samples = []
        ambientC = nil
        task = Task { [weak self] in
            // Seed from server history so opening the app mid-cooldown still produces an ETA
            // instead of waiting 20 minutes to accumulate its own points.
            await self?.refreshAmbient(printerId)
            // `self` is re-acquired on EVERY pass and never held across a sleep. Binding it once
            // outside the loop turns the weak capture into a strong one for the loop's whole life —
            // and since the loop only exits on cancellation, and the task is owned by the very
            // object it pins, nothing could ever release it. Replacing this store then leaked a
            // poller that kept calling the server with a stale client forever.
            var pass = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshCurve(printerId)
                pass += 1
                if pass % Self.ambientEveryNPasses == 0 { await self.refreshAmbient(printerId) }
                try? await Task.sleep(for: Self.curveRefresh)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Recompute from the latest status. Cheap and pure, so it can run on every frame.
    func update(status: PrinterStatus?, vmKind: DashKind, material: String?) {
        guard let status else { vm = nil; return }
        vm = Cooling.present(CooldownInput(
            printing: vmKind == .live,
            bedC: status.temperatures?.bed?.double,
            nozzleC: status.temperatures?.nozzle?.double,
            thresholdC: nil,
            samples: samples,
            ambientC: ambientC,
            material: material
        ))
    }

    private func refreshCurve(_ printerId: Int) async {
        guard let history = await client.sensorHistory(printerId, kind: "bed", hours: Self.curveWindowHours) else { return }
        samples = Cooling.parseBedHistory(history)
    }

    private func refreshAmbient(_ printerId: Int) async {
        guard let history = await client.sensorHistory(printerId, kind: "bed", hours: Self.ambientWindowHours) else { return }
        ambientC = Cooling.estimateAmbient(Cooling.parseBedHistory(history).map(\.c))
    }
}

/// The plate-cooldown readout: how hot the plate is, when it will be safe to handle, and why the app
/// is or isn't willing to predict that.
struct CooldownCard: View {
    let vm: CooldownVM
    @Environment(\.palette) private var c

    private var tint: Color {
        switch vm.tone {
        case .ready: c.running
        case .warm: c.heating
        case .hot: c.error
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: vm.phase == .ready ? "hand.raised.fill" : "thermometer.medium")
                    .font(.system(size: 14))
                    .foregroundStyle(tint)
                Text(vm.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.t1)
                Spacer()
                Text("\(Int(vm.bedC.rounded()))°")
                    .font(.mono(15))
                    .foregroundStyle(tint)
            }

            // The bar runs from the bed's peak down to the threshold, so it fills as the plate cools
            // rather than emptying.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(c.s3)
                    Capsule().fill(tint).frame(width: geo.size.width * min(max(vm.progress, 0), 1))
                }
            }
            .frame(height: 4)
            .animation(Motion.outQuad(0.6), value: vm.progress)

            Text(vm.detail)
                .font(.system(size: 12))
                .foregroundStyle(c.t2)
                .fixedSize(horizontal: false, vertical: true)

            if let caution = vm.caution {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(c.heating)
                    Text(caution)
                        .font(.system(size: 11))
                        .foregroundStyle(c.heating)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(c.line))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }
}
