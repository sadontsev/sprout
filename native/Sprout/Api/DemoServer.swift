import Foundation

/// A Bambuddy that isn't there.
///
/// **Why this exists.** The app is useless without a self-hosted Bambuddy and a printer, and an App
/// Store reviewer has neither. Launch it cold and you hit the config gate — a base URL and an API
/// key you cannot possibly have — which is not something a reviewer can evaluate, and is a
/// rejection. Demo mode is the answer to "show me what this app does".
///
/// **It answers at the transport, not at the view.** `BambuddyClient` funnels every request through
/// one `send(_:path:)`, so replacing that one function is enough. Everything above it stays real:
/// the URL builders, the decoders, the error mapping, the view models, every screen. A demo built by
/// stubbing views would prove the views compile; this one exercises the actual app, which is what
/// the reviewer is being asked to judge — and what makes the mode useful for finding real bugs.
///
/// **Nothing here reaches the network.** No Bambuddy, no printer, no MQTT, no camera. That is a
/// property worth keeping: a demo that quietly needs a server is a demo that fails review at the
/// worst moment.
///
/// The print advances with wall-clock time from `startedAt`, so the dashboard visibly progresses
/// while the reviewer is looking at it rather than sitting frozen — a still screenshot of a print is
/// not evidence the app works.
struct DemoServer: Sendable {
    /// When this demo session began. Progress is derived from it, never stored, so the state is a
    /// pure function of "how long have you been looking" and cannot drift.
    let startedAt: Date

    /// How long the fictional print takes end to end.
    static let printDuration: TimeInterval = 42 * 60

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    // MARK: The clock

    /// 0…1 through the print, looping so a long review session never ends on a dead screen.
    func progress(at now: Date) -> Double {
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed > 0 else { return 0 }
        return (elapsed.truncatingRemainder(dividingBy: Self.printDuration)) / Self.printDuration
    }

    // MARK: Routing

    /// The canned answer for a path, or `nil` when the demo has nothing to say.
    ///
    /// `nil` is deliberately distinct from empty JSON: the caller turns it into a 404 so an
    /// unmodelled endpoint fails like a real one instead of decoding into a silently empty screen.
    /// If a screen looks broken in demo mode, that is a missing route here, and it should look
    /// broken rather than plausible.
    func respond(path: String, method: String, at now: Date = Date()) -> Data? {
        // Compare against the path only; query strings carry tokens and ids that vary per call.
        let route = path.split(separator: "?").first.map(String.init) ?? path

        switch (method, route) {
        case ("GET", "/api/v1/printers/"), ("GET", "/api/v1/printers"):
            return json(Self.printers)
        // Anchored to /printers/ as well as /status. A bare `hasSuffix("/status")` also swallowed
        // `/smart-plugs/{id}/status` — the plug got handed printer JSON, the decode threw, and the
        // Power tab reported "Plug unreachable". A route pattern that answers a NEARBY question,
        // in a switch where the first match wins.
        case ("GET", let p) where p.hasPrefix("/api/v1/printers/") && p.hasSuffix("/status"):
            return json(status(at: now))
        case ("GET", let p) where p.hasPrefix("/api/v1/library/files"):
            // A BARE LIST, not `{files: […]}`. Guessed wrong first time and the Files tab said
            // "Couldn't reach the server" — the route matched and the decode threw. Every shape here
            // is now copied from a real response.
            return json(Self.libraryFiles)
        case ("GET", let p) where p.hasPrefix("/api/v1/queue/"):
            return json(Self.queue)
        case ("GET", let p) where p.hasPrefix("/api/v1/print-log/"):
            return json(Self.history)
        case ("GET", let p) where p.hasPrefix("/api/v1/maintenance/printers/"):
            return json(Self.maintenance)
        case ("GET", "/api/v1/maintenance/summary"):
            return json(Self.maintenanceSummary)
        case ("GET", let p) where p.hasSuffix("/status") && p.hasPrefix("/api/v1/smart-plugs"):
            // Live state is a SEPARATE call from the plug record. Without it the tab rendered the
            // plug and then said "Powered off · Plug unreachable" beside dashes — the device
            // configured, its state unknown, and the screen reporting the unknown as an "off".
            return json(Self.plugStatus)
        case ("GET", let p) where p.hasPrefix("/api/v1/smart-plugs"):
            return json(Self.plug)
        case ("GET", let p) where p.hasPrefix("/api/v1/inventory/"):
            return json([DemoSpool]())
        case ("GET", "/api/v1/makerworld/status"):
            return json(["can_download": true, "signed_in": true] as [String: Bool])
        case ("GET", let p) where p.hasPrefix("/api/v1/makerworld/recent-imports"):
            return json([DemoRecentImport]())
        case ("GET", "/api/v1/cloud/status"):
            return json(["connected": true] as [String: Bool])
        case ("GET", let p) where p.hasPrefix("/api/v1/slicer/presets"):
            return json([DemoPreset]())
        case ("GET", let p) where p.hasPrefix("/api/v1/printer-sensor-history/"):
            return json(["points": []] as [String: [String]])
        case ("GET", "/api/v1/archives/stats"):
            return json(Self.archiveStats)
        case ("POST", let p) where p.contains("/camera/stream-token"):
            return json(["token": "demo"] as [String: String])
        case ("POST", "/api/v1/auth/ws-token"):
            // No socket in demo mode. Refusing here makes PrinterStatusStore fall back to its REST
            // poll, which the demo DOES answer — the same path a real server with a broken socket
            // takes, so the fallback gets exercised rather than bypassed.
            return nil
        default:
            return nil
        }
    }

    /// Whether a write should be accepted.
    ///
    /// Demo mode accepts nothing that would change a printer, and says so rather than pretending.
    /// A control that appears to work and silently does nothing is this codebase's oldest bug; the
    /// reviewer sees a real refusal with a real reason instead.
    static let writeRefusal = "Not available in the demo. Connect your own Bambuddy server to control a printer."

    // MARK: Fixtures

    private func json(_ value: some Encodable) -> Data? {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return try? e.encode(value)
    }

    private static let printers: [DemoPrinter] = [
        DemoPrinter(id: 1, name: "Studio H2C", serialNumber: "DEMO0000000001", model: "H2C",
                    location: "Workshop", isActive: true, nozzleCount: 2)
    ]

    /// The live print. Every number is derived from `progress`, so the layer count, the percentage
    /// and the time remaining always agree with each other — a demo whose numbers contradict is
    /// worse than no demo.
    private func status(at now: Date) -> DemoStatus {
        let p = progress(at: now)
        let totalLayers = 168
        return DemoStatus(
            id: 1,
            name: "Studio H2C",
            connected: true,
            state: "RUNNING",
            progress: (p * 100).rounded(),
            remainingTime: ((1 - p) * Self.printDuration / 60).rounded(),
            layerNum: max(1, Int((p * Double(totalLayers)).rounded())),
            totalLayers: totalLayers,
            subtaskName: "planter-lattice.gcode.3mf",
            chamberLight: true,
            temperatures: DemoTemps(nozzle: 219 + (p * 2).rounded(), nozzleTarget: 220,
                                    nozzle2: 42, nozzle2Target: 0,
                                    bed: 60, bedTarget: 60, chamber: 31, chamberTarget: 0),
            ams: Self.amsUnits,
            amsExists: true,
            speedLevel: 2,
            printError: 0,
            hmsErrors: []
        )
    }

    private static let amsUnits: [DemoAmsUnit] = [
        DemoAmsUnit(id: 0, humidity: 22, temp: 28.4, isAmsHt: false, serialNumber: "DEMO-0156", tray: [
            DemoTray(id: 0, trayType: "PLA", trayColor: "8E7CC3FF", remain: 55),
            DemoTray(id: 1, trayType: "PETG", trayColor: "1A1A1AFF", remain: 80),
            DemoTray(id: 2, trayType: "PLA", trayColor: "C1440EFF", remain: 30),
            DemoTray(id: 3, trayType: nil, trayColor: nil, remain: nil)
        ]),
        DemoAmsUnit(id: 128, humidity: 8, temp: 30.4, isAmsHt: true, serialNumber: "DEMO-00RS", tray: [
            DemoTray(id: 0, trayType: "PA-CF", trayColor: "4A4A4AFF", remain: 95)
        ])
    ]

    private static let libraryFiles: [DemoFile] = [
        DemoFile(id: 101, filename: "planter-lattice.gcode.3mf", fileType: "gcode.3mf", fileSize: 24_180_000),
        DemoFile(id: 102, filename: "hinge-bracket.3mf", fileType: "3mf", fileSize: 4_020_000),
        DemoFile(id: 103, filename: "cable-clip-v3.3mf", fileType: "3mf", fileSize: 812_000),
        DemoFile(id: 104, filename: "desk-hook.gcode.3mf", fileType: "gcode.3mf", fileSize: 11_400_000),
        DemoFile(id: 105, filename: "vase-spiral.stl", fileType: "stl", fileSize: 2_640_000)
    ]

    /// A BARE ARRAY: `listQueue()` decodes `[QueueItem]` straight from `/api/v1/queue/`. Wrapping it
    /// in `{items: …}` threw in the decoder, which the Jobs tab reported as "Couldn't reach the
    /// server" — a shape error wearing a network error's clothes.
    private static let queue: [DemoQueueItem] = [
        DemoQueueItem(id: 1, status: "pending", position: 1, printerId: 1,
                      printerName: "Studio H2C", libraryFileName: "hinge-bracket.3mf",
                      printTimeSeconds: 3_120),
        DemoQueueItem(id: 2, status: "pending", position: 2, printerId: 1,
                      printerName: "Studio H2C", libraryFileName: "cable-clip-v3.3mf",
                      printTimeSeconds: 900)
    ]

    private static let history = DemoHistory(items: [
        DemoPrint(id: 9, archiveId: 9, printName: "desk-hook", printerName: "Studio H2C", printerId: 1,
                  status: "completed", startedAt: "2026-08-11T18:04:00Z", completedAt: "2026-08-11T19:40:00Z",
                  durationSeconds: 5760, filamentType: "PLA", filamentColor: "#8E7CC3",
                  filamentUsedGrams: 41, energyKwh: 0.31),
        DemoPrint(id: 8, archiveId: 8, printName: "vase-spiral", printerName: "Studio H2C", printerId: 1,
                  status: "completed", startedAt: "2026-08-10T11:20:00Z", completedAt: "2026-08-10T14:54:00Z",
                  durationSeconds: 12840, filamentType: "PETG", filamentColor: "#1A1A1A",
                  filamentUsedGrams: 118, energyKwh: 0.88),
        DemoPrint(id: 7, archiveId: 7, printName: "test-cube", printerName: "Studio H2C", printerId: 1,
                  status: "failed", startedAt: "2026-08-09T09:02:00Z", completedAt: "2026-08-09T09:14:00Z",
                  durationSeconds: 720, filamentType: "PLA", filamentColor: "#C1440E",
                  filamentUsedGrams: 3, energyKwh: 0.04)
    ], total: 3)

    /// One item deliberately overdue, so the Hardware tab's triage card has something true to say.
    /// A demo where nothing ever needs attention hides the feature that exists to surface it.
    private static let maintenance = DemoMaintenance(
        printerId: 1, printerName: "Studio H2C", printerModel: "H2C", totalPrintHours: 148.6,
        maintenanceItems: [
            DemoMaintenanceItem(id: 1, printerId: 1, maintenanceTypeName: "Nozzle wipe",
                                intervalHours: 50, currentHours: 148.6, hoursSinceMaintenance: 56,
                                hoursUntilDue: -6, isDue: true, isWarning: true, enabled: true),
            DemoMaintenanceItem(id: 2, printerId: 1, maintenanceTypeName: "Lubricate rods",
                                intervalHours: 200, currentHours: 148.6, hoursSinceMaintenance: 120,
                                hoursUntilDue: 80, isDue: false, isWarning: false, enabled: true),
            DemoMaintenanceItem(id: 3, printerId: 1, maintenanceTypeName: "Belt tension",
                                intervalHours: 500, currentHours: 148.6, hoursSinceMaintenance: 148,
                                hoursUntilDue: 352, isDue: false, isWarning: false, enabled: true)
        ])

    private static let maintenanceSummary = DemoMaintSummary(dueCount: 1, warningCount: 1)

    /// `getPlug` decodes `SmartPlug`, whose `id` is non-optional — an object without it throws, and
    /// `getPlug` swallows the error with `try?`, so the Power tab said "No smart plug linked". A
    /// missing field reported as a missing device: the same near-miss, one layer down.
    private static let plug = DemoPlug(id: 1, name: "Studio plug", printerId: 1,
                                       plugType: "homeassistant", enabled: true, lastState: "ON",
                                       autoOn: true, autoOff: true, autoOffPersistent: false,
                                       offDelayMode: "temperature", offDelayMinutes: 15,
                                       offTempThreshold: 45)

    /// Every field the Jobs header reads. Filling only three left it saying "3 lifetime prints ·
    /// 0 done · 0 SUCCESS · 0.0 h" — numbers that contradict the three prints listed underneath.
    private static let plugStatus = DemoPlugStatus(
        state: "ON", reachable: true, deviceName: "Studio plug",
        energy: DemoPlugEnergy(power: 104.8, voltage: 239.4, current: 0.44,
                               today: 1.42, yesterday: 2.05, total: 24.6))

    private static let archiveStats = DemoArchiveStats(
        totalPrints: 3, successfulPrints: 2, failedPrints: 1, cancelledPrints: 0,
        totalPrintTimeHours: 5.4, totalFilamentGrams: 162, totalCost: 3.24,
        totalEnergyKwh: 1.23, totalEnergyCost: 0.37)
}

// MARK: - Wire shapes
//
// Deliberately their own types rather than the app's models. Encoding the app's own decoded types
// back to JSON would make the fixtures agree with the decoders by construction, and a demo that can
// only produce what the app already parses proves nothing about either.

private struct DemoPrinter: Encodable {
    var id: Int; var name: String; var serialNumber: String; var model: String
    var location: String; var isActive: Bool; var nozzleCount: Int
}

private struct DemoTemps: Encodable {
    var nozzle: Double; var nozzleTarget: Double
    var nozzle2: Double; var nozzle2Target: Double
    var bed: Double; var bedTarget: Double
    var chamber: Double; var chamberTarget: Double
}

private struct DemoTray: Encodable {
    var id: Int; var trayType: String?; var trayColor: String?; var remain: Double?
}

private struct DemoAmsUnit: Encodable {
    var id: Int; var humidity: Double; var temp: Double; var isAmsHt: Bool
    var serialNumber: String; var tray: [DemoTray]
}

private struct DemoStatus: Encodable {
    var id: Int; var name: String; var connected: Bool; var state: String
    var progress: Double; var remainingTime: Double; var layerNum: Int; var totalLayers: Int
    var subtaskName: String; var chamberLight: Bool
    var temperatures: DemoTemps; var ams: [DemoAmsUnit]; var amsExists: Bool
    var speedLevel: Int; var printError: Int; var hmsErrors: [String]
}

/// `/library/files` returns a BARE LIST of these.
private struct DemoFile: Encodable {
    var id: Int; var folderId: Int? = nil; var isExternal = false
    var filename: String; var fileType: String; var fileSize: Int
    var thumbnailPath: String? = nil
}

private struct DemoQueueItem: Encodable {
    var id: Int; var status: String; var position: Int; var printerId: Int
    var printerName: String; var libraryFileName: String; var printTimeSeconds: Int
}

private struct DemoPrint: Encodable {
    var id: Int; var archiveId: Int; var printName: String; var printerName: String; var printerId: Int
    var status: String; var startedAt: String; var completedAt: String; var durationSeconds: Int
    var filamentType: String; var filamentColor: String; var filamentUsedGrams: Double
    var energyKwh: Double
}
private struct DemoHistory: Encodable { var items: [DemoPrint]; var total: Int }

private struct DemoMaintenanceItem: Encodable {
    var id: Int; var printerId: Int; var maintenanceTypeName: String
    var intervalHours: Double; var currentHours: Double; var hoursSinceMaintenance: Double
    var hoursUntilDue: Double; var isDue: Bool; var isWarning: Bool; var enabled: Bool
}
private struct DemoMaintenance: Encodable {
    var printerId: Int; var printerName: String; var printerModel: String
    var totalPrintHours: Double; var maintenanceItems: [DemoMaintenanceItem]
}
private struct DemoMaintSummary: Encodable { var dueCount: Int; var warningCount: Int }

private struct DemoPlug: Encodable {
    var id: Int; var name: String; var printerId: Int; var plugType: String
    var enabled: Bool; var lastState: String
    var autoOn: Bool; var autoOff: Bool; var autoOffPersistent: Bool
    var offDelayMode: String; var offDelayMinutes: Int; var offTempThreshold: Int
}

private struct DemoPlugEnergy: Encodable {
    var power: Double; var voltage: Double; var current: Double
    var today: Double; var yesterday: Double; var total: Double
}
private struct DemoPlugStatus: Encodable {
    var state: String; var reachable: Bool; var deviceName: String; var energy: DemoPlugEnergy
}

private struct DemoArchiveStats: Encodable {
    var totalPrints: Int; var successfulPrints: Int; var failedPrints: Int; var cancelledPrints: Int
    var totalPrintTimeHours: Double; var totalFilamentGrams: Double; var totalCost: Double
    var totalEnergyKwh: Double; var totalEnergyCost: Double
}

private struct DemoSpool: Encodable { var id: Int }
private struct DemoRecentImport: Encodable { var libraryFileId: Int }
private struct DemoPreset: Encodable { var name: String }
