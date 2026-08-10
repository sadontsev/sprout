import Foundation
import XCTest
@testable import Sprout

// MARK: - Fixtures and helpers

/// Fixed epoch — these tests must not depend on the wall clock.
private let T0 = Date(timeIntervalSince1970: 1_800_000_000)

/// `minutes` after `T0`.
private func at(_ minutes: Double) -> Date { T0.addingTimeInterval(minutes * 60) }

/// Synthesise a Newton cooling curve: the exact physics the fit is supposed to recover.
private func curve(
    start: Double,
    ambient: Double,
    kPerMin: Double,
    minutes: Double,
    step: Double = 1
) -> [BedSample] {
    var out: [BedSample] = []
    var m = 0.0
    while m <= minutes {
        out.append(BedSample(t: at(m), c: ambient + (start - ambient) * exp(-kPerMin * m)))
        m += step
    }
    return out
}

/// A REAL cooldown, recorded from the printer: bed temperature once per minute from the moment the
/// print finished (69°C) until it settled at 33°C, 89 minutes later. It crossed 35°C at minute 72.
///
/// Kept as a fixture because synthetic curves flattered two earlier versions of this model that were
/// badly wrong against real data — the readings are quantized to whole degrees, and the decay is not
/// a single exponential. Room temperature at the time was ~28.5°C (office sensor).
private enum RealCooldown {
    static let celsius: [Double] = [
        69, 67, 65, 64, 63, 61, 60, 59, 58, 57, 56, 56, 55, 54, 53, 53,
        52, 51, 51, 50, 50, 49, 48, 48, 48, 47, 47, 46, 46, 45, 45, 45,
        44, 44, 44, 43, 43, 43, 42, 42, 42, 41, 41, 41, 41, 40, 40, 40,
        40, 39, 39, 39, 39, 39, 38, 38, 38, 38, 38, 37, 37, 37, 37, 37,
        37, 36, 36, 36, 36, 36, 36, 36, 35, 35, 35, 35, 35, 35, 35, 35,
        35, 34, 34, 34, 34, 34, 34, 33, 33, 33,
    ]
    /// Minute at which the real curve crossed the default 35°C threshold.
    static let readyMin = 72
    /// Room temperature during that cooldown, from an independent sensor.
    static let ambientC = 28.5
}

/// The real curve as samples, one per minute, up to and including `minute`.
private func realSamples(through minute: Int) -> [BedSample] {
    (0...minute).map { BedSample(t: at(Double($0)), c: RealCooldown.celsius[$0]) }
}

private func realSamples() -> [BedSample] {
    realSamples(through: RealCooldown.celsius.count - 1)
}

/// Lift plain readings into the nullable shape `estimateAmbient` takes.
private func opt(_ xs: [Double]) -> [Double?] { xs.map { (x: Double) -> Double? in x } }

/// A sensor-history response carrying the given `(recorded_at, value)` points.
private func history(_ points: [(String?, Double?)]) -> SensorHistory {
    SensorHistory(series: [
        SensorSeries(data: points.map { SensorPoint(recordedAt: $0.0, value: LooseNumber($0.1)) })
    ])
}

/// The default cooldown input: not printing, clock pinned to `at(20)`.
private func input(
    printing: Bool = false,
    bedC: Double? = nil,
    nozzleC: Double? = nil,
    thresholdC: Double? = nil,
    samples: [BedSample] = [],
    ambientC: Double? = nil,
    material: String? = nil,
    now: Date = at(20)
) -> CooldownInput {
    CooldownInput(
        printing: printing,
        bedC: bedC,
        nozzleC: nozzleC,
        thresholdC: thresholdC,
        samples: samples,
        ambientC: ambientC,
        material: material,
        now: now
    )
}

// MARK: - clampThreshold

final class CoolingClampThresholdTests: XCTestCase {
    func testDefaultsToTheOneNumberBambuPublishes() {
        XCTAssertEqual(Cooling.defaultThresholdC, 35)
        XCTAssertEqual(Cooling.clampThreshold(nil), 35)
        XCTAssertEqual(Cooling.clampThreshold(Double.nan), 35)
        XCTAssertEqual(Cooling.clampThreshold(Double.infinity), 35)
        XCTAssertEqual(Cooling.clampThreshold(-Double.infinity), 35)
        XCTAssertEqual(Cooling.clampThreshold("abc"), 35)
    }

    func testRefusesAThresholdBelowRoomTemperature() {
        // It could never be reached: the plate asymptotes to ambient.
        XCTAssertEqual(Cooling.clampThreshold(25), Cooling.minThresholdC)
        XCTAssertEqual(Cooling.clampThreshold(-5), Cooling.minThresholdC)
    }

    func testRefusesAThresholdHotEnoughToBurn() {
        // You grip the plate to flex it.
        XCTAssertEqual(Cooling.clampThreshold(60), Cooling.maxThresholdC)
        // EN ISO 13732-1: 48°C at 10 min contact on bare metal.
        XCTAssertLessThan(Cooling.maxThresholdC, 48)
    }

    func testPassesThroughSaneValuesIncludingNumericStrings() {
        XCTAssertEqual(Cooling.clampThreshold(40), 40)
        XCTAssertEqual(Cooling.clampThreshold("38"), 38)
        XCTAssertEqual(Cooling.clampThreshold(" 38 "), 38)
    }

    func testUnreadableTextTakesTheDefaultNotTheFloor() {
        // An unset settings value means "use the published number", not "as cold as possible".
        XCTAssertEqual(Cooling.clampThreshold(""), 35)
        XCTAssertEqual(Cooling.clampThreshold("   "), 35)
    }
}

// MARK: - normalizeSamples

final class CoolingNormalizeSamplesTests: XCTestCase {
    func testSortsOutOfOrderPointsAndDropsDuplicatesAndJunk() {
        let s = Cooling.normalizeSamples([
            BedSample(t: at(2), c: 50),
            BedSample(t: at(0), c: 60),
            BedSample(t: at(2), c: 50),
            BedSample(t: at(1), c: .nan),
            BedSample(t: Date(timeIntervalSince1970: .nan), c: 40),
        ])
        XCTAssertEqual(s, [BedSample(t: at(0), c: 60), BedSample(t: at(2), c: 50)])
    }

    func testSurvivesEmptyInput() {
        XCTAssertEqual(Cooling.normalizeSamples([]), [])
    }

    func testKeepsTheFirstOfTwoReadingsSharingATimestamp() {
        // `sorted(by:)` is not stable, so this pins which duplicate wins.
        let s = Cooling.normalizeSamples([
            BedSample(t: at(5), c: 44),
            BedSample(t: at(5), c: 99),
            BedSample(t: at(1), c: 50),
        ])
        XCTAssertEqual(s.map(\.c), [50, 44])
    }

    func testDropsNonFiniteTemperatures() {
        let s = Cooling.normalizeSamples([
            BedSample(t: at(0), c: .infinity),
            BedSample(t: at(1), c: 40),
        ])
        XCTAssertEqual(s.map(\.c), [40])
    }
}

// MARK: - estimateAmbient

final class CoolingEstimateAmbientTests: XCTestCase {
    func testReadsTheRoomOffTheIdleFloorOfALongHistory() throws {
        // Between prints the plate settles to ambient, so the low percentile IS the room.
        // Written out with explicit types rather than as one inferred expression: with `$0` and the
        // ternary's branches both left open, the checker has to weigh every numeric overload of
        // `<`, `-`, `+` and `%` against every `Double.init`, and Xcode 27's frontend gives up on it
        // ("unable to type-check this expression in reasonable time") while 26.3 still manages.
        // Same values either way.
        let week = opt((0..<400).map { (i: Int) -> Double in
            i < 40 ? Double(60 - i) : Double(28 + i % 3)
        })
        let a = try XCTUnwrap(Cooling.estimateAmbient(week))
        XCTAssertGreaterThanOrEqual(a, 28)
        XCTAssertLessThanOrEqual(a, 30)
    }

    func testIsRobustToASingleSpuriousColdReading() {
        // Percentile, not minimum.
        let week = opt([1] + Array(repeating: 28, count: 200))
        XCTAssertEqual(Cooling.estimateAmbient(week), 28)
    }

    func testRefusesToGuessFromTooLittleHistory() {
        XCTAssertNil(Cooling.estimateAmbient(opt([28, 28, 28])))
        XCTAssertNil(Cooling.estimateAmbient(opt([])))
    }

    func testIgnoresJunkAndImplausibleValues() {
        let junk: [Double?] = [Double.nan, nil, nil, 0]
        XCTAssertEqual(Cooling.estimateAmbient(opt(Array(repeating: 28, count: 200)) + junk), 28)
        // No room is 90°C.
        XCTAssertNil(Cooling.estimateAmbient(opt(Array(repeating: 90, count: 200))))
    }

    func testRecoversTheRealRoomTemperatureFromTheRealIdleFloor() throws {
        // The measured curve bottoms out near ambient; pad with settled idle readings as a week of
        // history would contain.
        let hist = opt(
            RealCooldown.celsius
                + Array(repeating: 29, count: 200)
                + Array(repeating: 28, count: 50)
        )
        let a = try XCTUnwrap(Cooling.estimateAmbient(hist))
        XCTAssertGreaterThan(a, 25)
        XCTAssertLessThanOrEqual(a, RealCooldown.ambientC + 1)
    }
}

// MARK: - fitDecayRate

final class CoolingFitDecayRateTests: XCTestCase {
    func testRecoversAKnownRateGivenTheTrueAmbient() throws {
        let k = try XCTUnwrap(
            Cooling.fitDecayRate(
                curve(start: 70, ambient: 28.5, kPerMin: 0.041, minutes: 20),
                ambientC: 28.5,
                now: at(20)
            )
        )
        XCTAssertEqual(k, 0.041, accuracy: 0.0005)
    }

    func testWorksAgainstWholeDegreeReadings() throws {
        // The printer never reports fractions.
        let quantized = curve(start: 70, ambient: 28.5, kPerMin: 0.041, minutes: 20)
            .map { BedSample(t: $0.t, c: $0.c.rounded()) }
        let k = try XCTUnwrap(Cooling.fitDecayRate(quantized, ambientC: 28.5, now: at(20)))
        XCTAssertGreaterThan(k, 0.03)
        XCTAssertLessThan(k, 0.055)
    }

    func testUsesOnlyTheTrailingWindowSoItTracksTheCurrentRate() throws {
        // Real cooling slows down: early k is much higher than late k.
        let early = try XCTUnwrap(
            Cooling.fitDecayRate(realSamples(through: 20), ambientC: RealCooldown.ambientC, now: at(20))
        )
        let late = try XCTUnwrap(
            Cooling.fitDecayRate(realSamples(), ambientC: RealCooldown.ambientC, now: at(89))
        )
        XCTAssertGreaterThan(early, late)
    }

    func testReturnsNilForThinFlatOrSubAmbientData() {
        XCTAssertNil(Cooling.fitDecayRate([], ambientC: 28, now: at(0)))
        // Window too short.
        XCTAssertNil(
            Cooling.fitDecayRate(curve(start: 70, ambient: 28, kPerMin: 0.04, minutes: 3), ambientC: 28, now: at(3))
        )
        let ms: [Double] = [0, 3, 6, 9, 12]
        // No slope.
        XCTAssertNil(Cooling.fitDecayRate(ms.map { BedSample(t: at($0), c: 40) }, ambientC: 28, now: at(12)))
        // At ambient: no information.
        XCTAssertNil(Cooling.fitDecayRate(ms.map { BedSample(t: at($0), c: 28) }, ambientC: 28, now: at(12)))
    }

    func testIgnoresSamplesOlderThanTheRateWindow() {
        let recent: [Double] = [60, 63, 66, 69, 72]
        let s = [BedSample(t: at(0), c: 70)]
            + recent.map { BedSample(t: at($0), c: 40 - ($0 - 60) * 0.2) }
        XCTAssertNotNil(Cooling.fitDecayRate(s, ambientC: 28, now: at(72)))
    }
}

// MARK: - etaToThreshold

final class CoolingEtaTests: XCTestCase {
    private let fit = CoolingFit(ambientC: 28.5, kPerMin: 0.041)

    func testIsZeroOnceTheBedIsAtOrBelowTheThreshold() {
        XCTAssertEqual(Cooling.etaToThreshold(fit, bedC: 35, thresholdC: 35), 0)
        XCTAssertEqual(Cooling.etaToThreshold(fit, bedC: 30, thresholdC: 35), 0)
        XCTAssertEqual(Cooling.etaToThreshold(nil, bedC: 20, thresholdC: 35), 0)
    }

    func testReturnsNilWhenTheRoomIsWarmerThanTheThreshold() {
        // Never a number: a plate asymptotes to ambient and cannot cross it.
        XCTAssertNil(Cooling.etaToThreshold(CoolingFit(ambientC: 36, kPerMin: 0.04), bedC: 44, thresholdC: 35))
        XCTAssertNil(Cooling.etaToThreshold(CoolingFit(ambientC: 35, kPerMin: 0.04), bedC: 44, thresholdC: 35))
    }

    func testRefusesToExtrapolateFromFarAway() {
        // Where it would be ~40% optimistic.
        XCTAssertNil(Cooling.etaToThreshold(fit, bedC: 35 + Cooling.etaMaxLeadC + 1, thresholdC: 35))
        XCTAssertNil(Cooling.etaToThreshold(fit, bedC: 60, thresholdC: 35))
        XCTAssertNotNil(Cooling.etaToThreshold(fit, bedC: 35 + Cooling.etaMaxLeadC, thresholdC: 35))
    }

    func testReturnsNilWhenThereIsNoRateToExtrapolateWith() {
        XCTAssertNil(Cooling.etaToThreshold(nil, bedC: 40, thresholdC: 35))
    }

    func testShrinksMonotonicallyAsThePlateCools() throws {
        let a = try XCTUnwrap(Cooling.etaToThreshold(fit, bedC: 44, thresholdC: 35))
        let b = try XCTUnwrap(Cooling.etaToThreshold(fit, bedC: 40, thresholdC: 35))
        let c = try XCTUnwrap(Cooling.etaToThreshold(fit, bedC: 37, thresholdC: 35))
        XCTAssertGreaterThan(a, b)
        XCTAssertGreaterThan(b, c)
    }

    func testCapsAbsurdExtrapolationsInsteadOfPromisingAFortyHourWait() {
        let creeping = CoolingFit(ambientC: 34.9, kPerMin: 0.0001)
        XCTAssertEqual(Cooling.etaToThreshold(creeping, bedC: 40, thresholdC: 35), 600)
    }

    func testAccuracyAgainstTheRealCurveIsWithinEightMinutesEveryMinuteItSpeaks() {
        // Absolute error is the honest measure here. Relative error explodes near the end purely
        // because the denominator does (1 minute left), and the residual sawtooth is whole-degree
        // quantization: at bed=36°C the estimate cannot tell 36.0 from 36.9.
        let s = realSamples()
        var spoke = 0
        var worst = 0.0
        for t in 10..<RealCooldown.readyMin {
            let k = Cooling.fitDecayRate(Array(s[0...t]), ambientC: RealCooldown.ambientC, now: at(Double(t)))
            let f = k.map { CoolingFit(ambientC: RealCooldown.ambientC, kPerMin: $0) }
            guard let eta = Cooling.etaToThreshold(f, bedC: RealCooldown.celsius[t], thresholdC: 35) else { continue }
            spoke += 1
            let truth = Double(RealCooldown.readyMin - t)
            let err = abs(eta - truth)
            worst = max(worst, err)
            XCTAssertLessThanOrEqual(err, 8, "minute \(t)")
            // Over the longer waits, where a percentage is meaningful, it is well inside 25%.
            if truth >= 15 { XCTAssertLessThan(err / truth, 0.25, "minute \(t)") }
        }
        // And it speaks for most of the wait, not just the last minute.
        XCTAssertGreaterThan(spoke, 30)
        XCTAssertLessThanOrEqual(worst, 8)
    }

    func testStaysSilentUntilItCanBeAccurate() {
        // No estimate above threshold + lead.
        let s = realSamples()
        for t in 0..<25 {
            let k = Cooling.fitDecayRate(Array(s[0...t]), ambientC: RealCooldown.ambientC, now: at(Double(t)))
            let f = k.map { CoolingFit(ambientC: RealCooldown.ambientC, kPerMin: $0) }
            XCTAssertNil(
                Cooling.etaToThreshold(f, bedC: RealCooldown.celsius[t], thresholdC: 35),
                "minute \(t)"
            )
        }
    }
}

// MARK: - hasPlateaued

final class CoolingPlateauTests: XCTestCase {
    func testIsTrueWhenTheBedHasBarelyMovedAcrossTheWholeWindow() {
        let ms: [Double] = [0, 3, 6, 9, 12]
        let flat = ms.map { BedSample(t: at($0), c: 37 - $0 * 0.02) }
        XCTAssertTrue(Cooling.hasPlateaued(flat, now: at(12)))
    }

    func testIsFalseWhileTheBedIsStillFallingMeaningfully() {
        XCTAssertFalse(
            Cooling.hasPlateaued(curve(start: 70, ambient: 28.5, kPerMin: 0.041, minutes: 12), now: at(12))
        )
    }

    func testNeedsTheWindowActuallySpanned() {
        // Three readings seconds apart prove nothing.
        let ms: [Double] = [0, 0.1, 0.2]
        let burst = ms.map { BedSample(t: at($0), c: 37) }
        XCTAssertFalse(Cooling.hasPlateaued(burst, now: at(0.2)))
    }

    func testIgnoresSamplesOlderThanTheWindow() {
        // Hot an hour ago, flat for the last 12 min -> still plateaued.
        let ms: [Double] = [48, 51, 54, 57, 60]
        let s = [BedSample(t: at(0), c: 70)] + ms.map { BedSample(t: at($0), c: 37) }
        XCTAssertTrue(Cooling.hasPlateaued(s, now: at(60)))
    }

    func testIsFalseWithNoSamples() {
        XCTAssertFalse(Cooling.hasPlateaued([], now: at(10)))
    }
}

// MARK: - materialCaution

final class CoolingMaterialCautionTests: XCTestCase {
    func testWarnsThatTpuHasNoThermalReleaseAtAll() {
        XCTAssertTrue(Cooling.materialCaution("TPU 95A")?.contains("isopropyl") == true)
        XCTAssertTrue(Cooling.materialCaution("tpu")?.contains("isopropyl") == true)
    }

    func testWarnsAboutWarpingForTheEnclosureMaterialsMatchingCfVariantsToo() {
        for m in ["ABS", "ASA", "ABS-GF", "PC", "PA6-CF", "PAHT-CF", "Nylon"] {
            XCTAssertTrue(Cooling.materialCaution(m)?.contains("warp") == true, m)
        }
    }

    func testWarnsAboutPetgBondingToSmoothPei() {
        XCTAssertTrue(Cooling.materialCaution("PETG-CF")?.contains("smooth PEI") == true)
        XCTAssertTrue(Cooling.materialCaution("PETG HF")?.contains("smooth PEI") == true)
    }

    func testSaysNothingForPlaOrAnUnknownOrAbsentMaterial() {
        for m in ["PLA", "PLA-CF", "PLA Matte", "", "MysteryBrand"] {
            XCTAssertNil(Cooling.materialCaution(m), m)
        }
        XCTAssertNil(Cooling.materialCaution(nil))
    }
}

// MARK: - present

final class CoolingPresentTests: XCTestCase {
    func testIsInertWhileAPrintIsRunning() {
        XCTAssertEqual(Cooling.present(input(printing: true, bedC: 70)).phase, .none)
    }

    func testIsInertWithNoBedReading() {
        // 0 means "no data", not "frozen plate".
        XCTAssertEqual(Cooling.present(input(bedC: nil)).phase, .none)
        XCTAssertEqual(Cooling.present(input(bedC: 0)).phase, .none)
        XCTAssertEqual(Cooling.present(input(bedC: -5)).phase, .none)
        XCTAssertEqual(Cooling.present(input(bedC: Double.infinity)).phase, .none)
    }

    func testReportsReadyAtOrBelowTheThreshold() {
        let vm = Cooling.present(input(bedC: 34))
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.tone, .ready)
        XCTAssertEqual(vm.progress, 1)
        XCTAssertEqual(vm.etaMin, 0)
        XCTAssertTrue(vm.detail.contains("34°C"))
    }

    func testSaysSafeToFlexNeverThatThePrintPoppedOff() {
        // Prints do stay stuck when cold.
        let d = Cooling.present(input(bedC: 30)).detail.lowercased()
        XCTAssertTrue(d.contains("safe to flex"))
        for lie in ["popped", "released itself", "fell off"] {
            XCTAssertFalse(d.contains(lie), lie)
        }
    }

    func testReportsCoolingWithAnEtaOnceCloseEnoughToPredictHonestly() throws {
        let vm = Cooling.present(input(
            bedC: 40,
            samples: realSamples(through: 45),
            ambientC: RealCooldown.ambientC,
            now: at(45)
        ))
        XCTAssertEqual(vm.phase, .cooling)
        XCTAssertGreaterThan(try XCTUnwrap(vm.etaMin), 0)
        XCTAssertEqual(vm.ambientC, RealCooldown.ambientC)
        XCTAssertTrue(vm.detail.contains("min until"), vm.detail)
    }

    func testReportsCoolingWithNoTimeEstimateWhileThePlateIsStillFarOff() {
        let vm = Cooling.present(input(
            bedC: 50,
            samples: realSamples(through: 20),
            ambientC: RealCooldown.ambientC,
            now: at(20)
        ))
        XCTAssertEqual(vm.phase, .cooling)
        // Would have been ~35% optimistic — say nothing instead.
        XCTAssertNil(vm.etaMin)
        XCTAssertTrue(vm.detail.contains("50°C"))
        XCTAssertFalse(vm.detail.contains("min until"))
    }

    func testReportsStalledWhenTheMeasuredRoomIsWarmerThanTheThreshold() {
        let vm = Cooling.present(input(
            bedC: 40,
            samples: curve(start: 70, ambient: 38, kPerMin: 0.04, minutes: 25),
            ambientC: 38,
            now: at(25)
        ))
        XCTAssertEqual(vm.phase, .stalled)
        XCTAssertNil(vm.etaMin)
        // Tells the user WHY.
        XCTAssertTrue(vm.detail.contains("38°C"), vm.detail)
        XCTAssertTrue(vm.detail.contains("flex the plate"), vm.detail)
    }

    func testReportsStalledFromAMeasuredPlateauEvenWithNoUsableFit() {
        let ms: [Double] = [0, 3, 6, 9, 12]
        let flat = ms.map { BedSample(t: at($0), c: 37) }
        XCTAssertEqual(Cooling.present(input(bedC: 37, samples: flat, now: at(12))).phase, .stalled)
    }

    func testNeverClaimsStalledJustBecauseThePlateIsStillHotEarlyOn() {
        // Regression: an earlier version fitted ambient from the curve, got 39.9°C for a 28.5°C
        // room, and declared "as cool as it will get" while the plate was at 56°C, ten minutes in.
        let vm = Cooling.present(input(
            bedC: 56,
            samples: realSamples(through: 10),
            ambientC: RealCooldown.ambientC,
            now: at(10)
        ))
        XCTAssertEqual(vm.phase, .cooling)
    }

    func testDegradesToAPlainCoolingMessageWhenThereIsNoHistoryToFit() {
        let vm = Cooling.present(input(bedC: 55))
        XCTAssertEqual(vm.phase, .cooling)
        XCTAssertNil(vm.etaMin)
        XCTAssertTrue(vm.detail.contains("55°C"))
        XCTAssertFalse(vm.detail.contains("min until"))
    }

    func testTracksProgressFromThePeakDownToTheThreshold() {
        let s = curve(start: 70, ambient: 28.5, kPerMin: 0.041, minutes: 14)
        XCTAssertEqual(Cooling.present(input(bedC: 70, samples: s)).progress, 0, accuracy: 0.005)
        XCTAssertEqual(Cooling.present(input(bedC: 35, samples: s)).progress, 1)
        let mid = Cooling.present(input(bedC: 52.5, samples: s)).progress
        XCTAssertGreaterThan(mid, 0.4)
        XCTAssertLessThan(mid, 0.6)
    }

    func testMentionsAStillHotNozzleWithoutEverBlockingReadiness() {
        let vm = Cooling.present(input(bedC: 33, nozzleC: 210))
        // The plate is what you touch.
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertTrue(vm.detail.contains("210°C"), vm.detail)
        XCTAssertFalse(Cooling.present(input(bedC: 33, nozzleC: 30)).detail.contains("nozzle"))
    }

    func testAttachesTheMaterialCautionWithoutChangingTheThreshold() {
        let tpu = Cooling.present(input(bedC: 34, material: "TPU 95A"))
        let pla = Cooling.present(input(bedC: 34, material: "PLA"))
        XCTAssertTrue(tpu.caution?.contains("isopropyl") == true)
        XCTAssertNil(pla.caution)
        // Material NEVER moves the number.
        XCTAssertEqual(tpu.thresholdC, pla.thresholdC)
    }

    func testHonoursACustomThresholdClamped() {
        XCTAssertEqual(Cooling.present(input(bedC: 38, thresholdC: 40)).phase, .ready)
        XCTAssertEqual(Cooling.present(input(bedC: 38, thresholdC: 25)).thresholdC, Cooling.minThresholdC)
    }

    func testIsPureIdenticalInputsGiveIdenticalOutput() {
        let i = input(bedC: 51, samples: curve(start: 69, ambient: 28.5, kPerMin: 0.041, minutes: 14), material: "PLA")
        XCTAssertEqual(Cooling.present(i), Cooling.present(i))
    }

    func testWritesAWholeDegreeThresholdWithoutATrailingDecimal() {
        // Swift would render 37.0 as "37.0"; the readout must say "37°C".
        XCTAssertTrue(Cooling.present(input(bedC: 55, thresholdC: 37)).detail.contains("heading for 37°C"))
    }

    func testSurvivesAnAbsurdBedReadingWithoutTrapping() {
        // `Int(_:)` traps outside Int's range, and a garbage sensor value is not worth a crash.
        let vm = Cooling.present(input(bedC: 1e300))
        XCTAssertEqual(vm.phase, .cooling)
        XCTAssertEqual(vm.tone, .hot)
    }
}

// MARK: - parseBedHistory

/// 2026-08-01T11:57:57Z as epoch seconds, derived by hand so the expectation does not lean on the
/// same calendar arithmetic the parser uses: 20,666 days (56 years, of which 14 are leap, plus 212
/// days into 2026) = 1,785,542,400 s, plus 11:57:57 = 43,077 s.
private let stampUTC = Date(timeIntervalSince1970: 1_785_585_477)

final class CoolingParseBedHistoryTests: XCTestCase {
    func testReadsBambuddyNaiveTimestampsAsUtcNotLocal() {
        // The trap: a bare "2026-08-01T11:57:57" read in the device's zone shifts the whole curve by
        // the UTC offset and quietly corrupts every rate and ETA.
        let s = Cooling.parseBedHistory(history([("2026-08-01T11:57:57", 51)]))
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.t, stampUTC)
    }

    func testRespectsAnExplicitZoneWhenOneIsPresent() {
        let z = Cooling.parseBedHistory(history([("2026-08-01T11:57:57Z", 51)]))
        let colon = Cooling.parseBedHistory(history([("2026-08-01T13:57:57+02:00", 51)]))
        let compact = Cooling.parseBedHistory(history([("2026-08-01T13:57:57+0200", 51)]))
        let behind = Cooling.parseBedHistory(history([("2026-08-01T06:57:57-05:00", 51)]))
        XCTAssertEqual(z.first?.t, stampUTC)
        XCTAssertEqual(colon.first?.t, stampUTC)
        XCTAssertEqual(compact.first?.t, stampUTC)
        XCTAssertEqual(behind.first?.t, stampUTC)
    }

    func testIsIndependentOfTheDeviceTimeZone() {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        // +05:30: a half-hour offset, so a local-time parse cannot accidentally land on the right
        // answer even on a machine whose clock happens to be set to UTC.
        NSTimeZone.default = TimeZone(identifier: "Asia/Kolkata")!
        let s = Cooling.parseBedHistory(history([("2026-08-01T11:57:57", 51)]))
        XCTAssertEqual(s.first?.t, stampUTC)
    }

    func testAcceptsFractionalSeconds() {
        let s = Cooling.parseBedHistory(history([("2026-08-01T11:57:57.500", 51)]))
        XCTAssertEqual(s.first?.t, stampUTC.addingTimeInterval(0.5))
    }

    func testSortsDedupesAndDropsUnusablePoints() {
        let s = Cooling.parseBedHistory(history([
            ("2026-08-01T11:59:00", 49),
            ("2026-08-01T11:57:00", 51),
            ("2026-08-01T11:58:00", nil),
            ("", 40),
            (nil, 40),
            ("2026-08-01T11:57:00", 99),
        ]))
        XCTAssertEqual(s.map(\.c), [51, 49])
    }

    func testRejectsGarbageTimestamps() {
        for bad in ["not a date", "2026-08-01", "2026-13-01T00:00:00", "20260801T115757", "2026-08-01T25:00:00"] {
            XCTAssertEqual(Cooling.parseBedHistory(history([(bad, 40)])).count, 0, bad)
        }
    }

    func testCoercesStringTemperatures() throws {
        // The WebSocket sends numbers as strings; `LooseNumber` absorbs that at the decoder.
        let json = Data("""
        {"series":[{"data":[{"recorded_at":"2026-08-01T11:57:57","value":"52.5"}]}]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let h = try decoder.decode(SensorHistory.self, from: json)
        XCTAssertEqual(Cooling.parseBedHistory(h).map(\.c), [52.5])
    }

    func testReturnsEmptyForAnEmptyMissingOrMalformedResponse() {
        XCTAssertEqual(Cooling.parseBedHistory(nil), [])
        XCTAssertEqual(Cooling.parseBedHistory(SensorHistory()), [])
        XCTAssertEqual(Cooling.parseBedHistory(SensorHistory(series: [])), [])
        XCTAssertEqual(Cooling.parseBedHistory(SensorHistory(series: [SensorSeries()])), [])
    }
}
