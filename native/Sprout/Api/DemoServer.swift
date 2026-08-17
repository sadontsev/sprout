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
        // Per-file routes come BEFORE the list, because a `switch` matches in order and
        // `hasPrefix("/api/v1/library/files")` swallows every sub-path.
        //
        // It did. `/plates` returned the file LIST, which cannot decode as `PlatesResponse`, so the
        // print sheet reported "Couldn't read this plate's details" against a server that had answered
        // 200 — a demo that lies in exactly the way the real thing is careful not to.
        case ("GET", let p) where p.hasPrefix("/api/v1/library/files/") && p.hasSuffix("/plates"):
            let id = Self.fileId(in: p)
            return json(DemoPlates.plates(
                forFileId: id,
                fileType: Self.libraryFiles.first { $0.id == id }?.fileType
            ))
        case ("GET", let p) where p.hasPrefix("/api/v1/library/files/") && p.contains("/filament-requirements"):
            // A raw mesh has no slots either — same fiction as the plate, and it put a PLA row and a
            // tray picker on a file the sheet had already refused.
            let rid = Self.fileId(in: p)
            let isStl = Self.libraryFiles.first { $0.id == rid }?.fileType == "stl"
            return json(isStl ? FilamentRequirements(filaments: []) : DemoPlates.requirements)
        case ("GET", let p) where p.hasPrefix("/api/v1/library/files/")
            && Self.fileId(in: p) != nil && !p.contains("/"):
            return json(Self.libraryFiles.first { $0.id == Self.fileId(in: p) })
        case ("GET", let p) where p.hasPrefix("/api/v1/library/files"):
            // A BARE LIST, not `{files: […]}`. Guessed wrong first time and the Files tab said
            // "Couldn't reach the server" — the route matched and the decode threw. Every shape here
            // is now copied from a real response.
            return json(Self.libraryFiles)
        // The printer's own storage. Before these, demo mode had no SD route at all: the Printer SD
        // segment rendered "Nothing to show" whatever was built behind it, so the whole half of the
        // Files section was unreviewable — and on a platform whose windows cannot be inspected from
        // the shell, unreviewable means unreviewed. The `/plates` route comes first for the same
        // reason it does on the library side: a `hasPrefix` on the parent swallows every sub-path.
        //
        // Thumbnails are deliberately NOT modelled and cannot be: `CachedThumb` fetches through
        // `ThumbCache`, which never passes through `send(_:path:)` where this server is consulted. So
        // an SD card in demo mode draws the generic missing-image well, exactly as a library card
        // does. That is a limit of the demo, not of the feature — the plate and poster URLs are only
        // exercised against a real Bambuddy.
        case ("GET", let p) where p.hasPrefix("/api/v1/printers/") && p.contains("/files/plates"):
            return json(PrinterFilePlates(printerId: 1, path: Self.query("path", in: path),
                                          filename: nil, plates: [Self.printerPlate]))
        case ("GET", let p) where p.hasPrefix("/api/v1/printers/") && p.contains("/files"):
            let at = Self.query("path", in: path) ?? "/"
            return json(PrinterFileList(path: at, files: Self.printerFiles(at: at)))
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
            // A real `PresetsResponse` OBJECT. This used to answer `[DemoPreset]()` — a JSON array —
            // which `PresetsResponse` cannot decode, so the demo threw on every preset fetch and the
            // slice path could never be looked at without a live Bambuddy. Given that a Mac app's
            // windows cannot be inspected from the shell, "the demo cannot reach this screen" means
            // "nobody can review this screen".
            return json(DemoPresets.response)
        // Slicing. A real job that completes on the second poll, so the progress state is reachable
        // rather than instantaneous — a fixture that finishes immediately hides its own UI.
        case ("POST", let p) where p.hasSuffix("/slice") && p.hasPrefix("/api/v1/library/files/"):
            DemoSliceProgress.shared.restart()
            return json(["job_id": DemoPresets.sliceJobId] as [String: Int])
        case ("GET", let p) where p.hasPrefix("/api/v1/slice-jobs/"):
            return json(DemoPresets.job(poll: DemoSliceProgress.shared.nextPoll()))
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

    /// The library file id in `/api/v1/library/files/<id>/…`, or nil if that segment is not a number.
    static func fileId(in path: String) -> Int? {
        let tail = path.dropFirst("/api/v1/library/files/".count)
        return Int(tail.prefix { $0.isNumber })
    }

    /// One query parameter's decoded value.
    ///
    /// `respond` strips the query before matching a route, because tokens and ids vary per call — but
    /// the SD endpoints carry their whole subject in `?path=`, so those routes have to read it back
    /// out of the unstripped path.
    static func query(_ name: String, in path: String) -> String? {
        guard let queryPart = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for pair in queryPart.split(separator: "&") {
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.first.map(String.init) == name else { continue }
            let raw = halves.dropFirst().first.map(String.init) ?? ""
            return raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        }
        return nil
    }

    // MARK: Fixtures

    /// A small but REPRESENTATIVE SD card: folders at the root, sliced prints in one, and recordings
    /// in the two media folders — because every one of those exercises a different branch of the
    /// section (folder navigation, plate preview, poster + Play, and the plain-file fallback).
    ///
    /// The recordings carry real printer-style timestamps so `mediaLabel` has something to read; a
    /// fixture named `clip1.mp4` would have shown the raw-name fallback and called it working.
    static func printerFiles(at path: String) -> [PrinterFile] {
        switch path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path {
        case "/cache":
            return [
                PrinterFile(name: "planter-lattice.gcode.3mf", isDirectory: false, size: 24_180_000, path: "/cache/planter-lattice.gcode.3mf", mtime: nil),
                PrinterFile(name: "desk-hook.gcode.3mf", isDirectory: false, size: 11_400_000, path: "/cache/desk-hook.gcode.3mf", mtime: nil),
                // A plain project 3MF: sliced-looking to a careless predicate, and refused by the
                // exact one. It is here so the "no layers" branch has a subject.
                PrinterFile(name: "hinge-bracket.3mf", isDirectory: false, size: 4_020_000, path: "/cache/hinge-bracket.3mf", mtime: nil),
                PrinterFile(name: "notes.txt", isDirectory: false, size: 1_200,
                            path: "/cache/notes.txt", mtime: nil),
            ]
        case "/timelapse":
            return [
                PrinterFile(name: "video_2026-07-05_15-16-02.mp4", isDirectory: false, size: 48_300_000, path: "/timelapse/video_2026-07-05_15-16-02.mp4", mtime: nil),
                PrinterFile(name: "video_2026-07-04_09-02-41.mp4", isDirectory: false, size: 39_100_000, path: "/timelapse/video_2026-07-04_09-02-41.mp4", mtime: nil),
                PrinterFile(name: "thumbnail", isDirectory: true, size: nil,
                            path: "/timelapse/thumbnail", mtime: nil),
            ]
        case "/ipcam":
            return [
                PrinterFile(name: "ipcam-record.2026-04-21_22-12-16.0.mp4", isDirectory: false, size: 252_400_000, path: "/ipcam/ipcam-record.2026-04-21_22-12-16.0.mp4", mtime: nil),
                PrinterFile(name: "thumbnail", isDirectory: true, size: nil, path: "/ipcam/thumbnail", mtime: nil),
            ]
        case "/timelapse/thumbnail", "/ipcam/thumbnail":
            return []
        default:
            return [
                PrinterFile(name: "cache", isDirectory: true, size: nil, path: "/cache", mtime: nil),
                PrinterFile(name: "timelapse", isDirectory: true, size: nil, path: "/timelapse", mtime: nil),
                PrinterFile(name: "ipcam", isDirectory: true, size: nil, path: "/ipcam", mtime: nil),
            ]
        }
    }

    /// What `/files/plates` says about a sliced file on the card — time and weight, which is what the
    /// inspector reads. Not filaments: nothing has ever been observed reading one from this endpoint,
    /// and a fixture that invents them would licence a UI that prints them.
    static let printerPlate = PlateInfo(index: 1, name: "Plate 1", objects: nil, objectCount: 2,
                                        hasThumbnail: true, thumbnailUrl: nil,
                                        printTimeSeconds: 7_380, filamentUsedGrams: 46)

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
        DemoFile(id: 105, filename: "vase-spiral.stl", fileType: "stl", fileSize: 2_640_000),
        // The slice OUTPUT (`DemoPresets.slicedFileId`). A real row, because the sheet re-reads its
        // subject the moment slicing completes and a dangling id would 404 there. Deliberately a
        // different id from the 102 it is sliced from: the sheet has to survive its subject changing
        // identity mid-flow, and a fixture that reused the input id would hide the riskiest part.
        DemoFile(id: 106, filename: "hinge-bracket.gcode.3mf", fileType: "gcode.3mf", fileSize: 5_310_000)
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

// MARK: - Demo slicing fixtures

/// How far along the demo's slice job is.
///
/// `DemoServer` is a `struct` and its responder is non-mutating, so the poll count cannot live there.
/// A locked box rather than an actor because the responder is synchronous: an `await` here would
/// change every call site to serve a fixture.
final class DemoSliceProgress: @unchecked Sendable {
    static let shared = DemoSliceProgress()

    private let lock = NSLock()
    private var polls = 0

    /// Called by the POST that starts a slice, so the demo can be sliced more than once per session.
    func restart() {
        lock.lock(); defer { lock.unlock() }
        polls = 0
    }

    func nextPoll() -> Int {
        lock.lock(); defer { lock.unlock() }
        polls += 1
        return polls
    }
}

/// The slicer presets and slice job the demo answers with.
///
/// Named for a real H2C so `PresetSelect` and `SlicePresets.build` do their actual matching rather
/// than being handed something that trivially fits: the printer preset carries the `0.4 nozzle`
/// suffix the picker looks for, the qualities carry the `@BBL H2C` token, and one quality has a
/// `+ Supports` twin so the supports toggle has something to switch to.
enum DemoPresets {

    static let sliceJobId = 4001

    /// The file the completed job points at — `hinge-bracket.3mf` sliced. It is a DIFFERENT id from
    /// every file in the demo library on purpose: the sheet has to survive its subject changing
    /// identity mid-flow, which is the riskiest part of slicing, and a fixture that returned the
    /// input id would hide exactly that.
    static let slicedFileId = 106

    static var response: PresetsResponse {
        PresetsResponse(standard: PresetsResponse.Group(
            printer: [
                Preset(id: "p1", name: "Bambu Lab H2C 0.4 nozzle", source: "system"),
                Preset(id: "p2", name: "Bambu Lab H2C 0.6 nozzle", source: "system"),
            ],
            process: [
                Preset(id: "q1", name: "0.20mm Standard @BBL H2C", source: "system"),
                Preset(id: "q2", name: "0.20mm Standard + Supports @BBL H2C", source: "system"),
                Preset(id: "q3", name: "0.16mm Optimal @BBL H2C", source: "system"),
                Preset(id: "q4", name: "0.28mm Draft @BBL H2C", source: "system"),
            ],
            filament: [
                Preset(id: "f1", name: "Bambu PLA Basic @BBL H2C", source: "system"),
                Preset(id: "f2", name: "Bambu PETG HF @BBL H2C", source: "system"),
                Preset(id: "f3", name: "Bambu PA-CF @BBL H2C", source: "system"),
                Preset(id: "f4", name: "Bambu Support For PLA @BBL H2C", source: "system"),
            ]
        ))
    }

    /// The job, which finishes on the THIRD poll rather than the first.
    ///
    /// A fixture that completes immediately hides its own progress UI, and the progress state is the
    /// part nobody can otherwise look at — the sheet is only in it for a couple of seconds against a
    /// real server. Three polls at 1.5 s is about four seconds of visible slicing.
    static func job(poll: Int) -> SliceJob {
        guard poll >= 3 else {
            return SliceJob(id: sliceJobId, status: "running", progress: LooseNumber(Double(poll) * 30))
        }
        return SliceJob(
            id: sliceJobId,
            status: "completed",
            progress: LooseNumber(100),
            result: SliceJob.Result(
                status: "success",
                libraryFileId: LooseNumber(Double(slicedFileId)),
                printTimeSeconds: LooseNumber(3_120),
                filamentUsedG: LooseNumber(18.4)
            )
        )
    }
}

/// Plates and per-plate filament requirements for the demo library.
///
/// One plate, one filament, so the sheet's auto-fill has something to bind and the mapping row shows a
/// real spool instead of "No tray chosen" — which is what it showed while these routes were shadowed.
enum DemoPlates {

    /// PLA, because the demo AMS has Purple PLA in slot 1 and auto-fill matches on material. A
    /// requirement the inventory cannot satisfy would leave the sheet permanently refusing, which is a
    /// state worth being able to reach deliberately but a poor default.
    static let requirements = FilamentRequirements(filaments: [
        FilamentRequirements.Requirement(
            slotId: 1, type: "PLA", color: "#8E7CC3",
            usedGrams: LooseNumber(18.4), usedInPlate: true
        )
    ])

    /// A raw mesh has NO plates, and the demo must not invent one.
    ///
    /// The first version of this fixture returned the same plate for every id, which gave
    /// `vase-spiral.stl` a plate, a filament requirement and a "52 min · 18 g" estimate — a print
    /// estimate for a file with nothing to estimate. A demo that lies is worse than a demo that
    /// refuses, because the refusals are exactly what needs reviewing.
    static func plates(forFileId id: Int?, fileType: String?) -> PlatesResponse {
        guard let id, fileType != "stl" else {
            return PlatesResponse(fileId: id, plates: [], isMultiPlate: false)
        }
        return PlatesResponse(
            fileId: id,
            plates: [
                PlateInfo(
                    index: 1,
                    name: "Plate 1",
                    objectCount: 1,
                    hasThumbnail: false,
                    printTimeSeconds: LooseNumber(3_120),
                    filamentUsedGrams: LooseNumber(18.4),
                    filaments: [PlateFilament(slotId: 1, type: "PLA", color: "#8E7CC3",
                                              usedGrams: LooseNumber(18.4))]
                )
            ],
            isMultiPlate: false,
            // The machine the file claims. Matching the demo printer keeps `printerMismatch` false —
            // a fixture naming another printer would park the sheet on a terminal refusal.
            embeddedPrinter: "H2C",
            embeddedProcess: "0.20mm Standard @BBL H2C"
        )
    }
}
