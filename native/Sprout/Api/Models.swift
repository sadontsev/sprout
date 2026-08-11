import Foundation

/// A number that may arrive as a JSON number OR a JSON string.
///
/// Bambuddy's WebSocket feed stringifies numerics (`"30.4"`) where REST sends `30.4`. The RN app
/// coerced these at every read site with `asNum()`; doing it in the decoder means the rest of the
/// app only ever sees `Double?` and can't crash on a string.
struct LooseNumber: Codable, Hashable, Sendable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    let value: Double?

    init(_ value: Double?) { self.value = value }
    init(floatLiteral value: Double) { self.value = value }
    init(integerLiteral value: Int) { self.value = Double(value) }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = nil
        } else if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self) {
            value = Double(s)
        } else if let b = try? c.decode(Bool.self) {
            value = b ? 1 : 0
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    var double: Double? { value }

    /// Truncated toward zero (as `Int(_: Double)` is), or nil when there is no value or it isn't
    /// finite.
    ///
    /// `isFinite` alone is not enough: `Int(_: Double)` is a runtime TRAP — not a silent 0 — for any
    /// finite value outside `Int`'s range, and `Double("1e30")` from a stringified WebSocket field is
    /// perfectly finite. Saturating at the ends keeps the promise this type exists to make (the rest
    /// of the app can't crash on a bad number), and matches `Dryer.safeRound` / `Cooling.rounded`.
    var int: Int? {
        guard let value, value.isFinite else { return nil }
        if value >= Double(Int.max) { return .max }
        if value <= Double(Int.min) { return .min }
        return Int(value)
    }
}

/// A printer registered in Bambuddy (GET /printers/).
struct Printer: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var model: String       // "A1" | "H2C" | ...
    var nozzleCount: Int?   // 2 on the H2-series dual-extruder machines
    var location: String?
    var isActive: Bool?
    var serialNumber: String?
    var ipAddress: String?
}

/// One HMS (health-management-system) record from the printer. Present even mid-print for benign
/// notices — presence alone does NOT mean the print failed.
struct HmsError: Codable, Hashable, Sendable {
    var code: String?
    var attr: LooseNumber?
    var module: LooseNumber?
    var severity: LooseNumber?
    var fullCode: String?   // e.g. "0500050000010007"
}

struct Temperatures: Codable, Hashable, Sendable {
    var nozzle: LooseNumber?
    var nozzleTarget: LooseNumber?
    var nozzleHeating: Bool?
    /// Second extruder on dual-nozzle machines (H2-series).
    var nozzle2: LooseNumber?
    var nozzle2Target: LooseNumber?
    var nozzle2Heating: Bool?
    var bed: LooseNumber?
    var bedTarget: LooseNumber?
    var bedHeating: Bool?
    /// Enclosed machines only.
    var chamber: LooseNumber?
    var chamberTarget: LooseNumber?
    var chamberHeating: Bool?
}

struct AmsTray: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    var trayType: String?
    var trayColor: String?
    var remain: LooseNumber?
    var trayUuid: String?
    /// Recommended drying temp (°C) / time (hours) from the filament's RFID/preset; 0 = no data.
    var dryingTemp: LooseNumber?
    var dryingTime: LooseNumber?
}

struct AmsUnitRaw: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    var humidity: LooseNumber?
    var temp: LooseNumber?
    /// AMS-HT dries to 85 °C; the AMS 2 Pro tops out at 65 °C.
    var isAmsHt: Bool?
    var moduleType: String?     // e.g. "n3f" (AMS 2 Pro)
    /// Minutes REMAINING in the drying cycle. `> 0` is THE "actively drying" signal — verified live:
    /// `dryStatus` stayed 0 mid-cycle, so it must NOT be used as the active flag.
    var dryTime: LooseNumber?
    var dryStatus: LooseNumber?
    var drySubStatus: LooseNumber?
    /// Target °C — cached by Bambuddy only for cycles it started itself; nil when the cycle was
    /// started elsewhere (printer screen / Bambu Handy).
    var dryTargetTemp: LooseNumber?
    var dryFilament: String?
    /// Why the AMS refuses to dry (codes 0-8) — decode via `DryBlockers`.
    var drySfReason: [LooseNumber]?
    /// Short serial tail is the only way to tell two identical AMS 2 Pro units apart.
    var serialNumber: String?
    var tray: [AmsTray]?
}

/// Filament Track Switch: routes AMS units to either extruder dynamically, which is why FTS-routed
/// units never appear in `amsExtruderMap`.
struct FilaSwitch: Codable, Hashable, Sendable {
    var installed: Bool?
    /// Per inlet, packed `(ams_id << 8) | slot`, -1 when empty.
    var inSlots: [Int]?
    /// The extruder each outlet feeds (0xE = none).
    var outExtruders: [Int]?
    var stat: LooseNumber?
    var info: LooseNumber?
}

struct NozzleInfo: Codable, Hashable, Sendable {
    var nozzleType: String?
    var nozzleDiameter: String?
}

/// H2-series swappable-nozzle store. Empty slots carry serial "N/A" / maxTemp 0.
struct NozzleRackSlot: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    var nozzleType: String?         // "HS01" | "HS00" | ...
    var nozzleDiameter: LooseNumber?
    var wear: LooseNumber?
    var maxTemp: LooseNumber?
    var serialNumber: String?       // "N/A" when the slot is empty
    var filamentColor: String?      // RGBA hex of the filament last paired to this nozzle
    var filamentId: String?
    var filamentType: String?
}

/// The subset of Bambuddy's printer status the app consumes.
struct PrinterStatus: Codable, Hashable, Sendable {
    var id: Int?
    var name: String?
    var connected: Bool = false
    var state: String = ""          // RUNNING | PAUSE | IDLE | FINISH | FAILED | ...
    var progress: LooseNumber?      // %
    var remainingTime: LooseNumber? // minutes
    var layerNum: LooseNumber?
    var totalLayers: LooseNumber?
    var subtaskName: String?
    var chamberLight: Bool?
    var temperatures: Temperatures?
    var ams: [AmsUnitRaw]?
    /// Active tray index across the AMS (Bambu `tray_now`; 255 = none/external). NOTE: on H2-series
    /// firmware this can degenerate to a LOCAL slot (0-3), which is ambiguous once more than one
    /// 4-slot unit is fitted — see `AmsTopology.routing` before treating it as a global id.
    var trayNow: LooseNumber?
    /// Which extruder each AMS unit feeds, keyed by unit id. Bambuddy derives this from each unit's
    /// `info` bits and SKIPS units reporting 0xE ("no fixed extruder"). It is merge-only and never
    /// pruned, so entries can be stale residue. Do NOT trust it when `filaSwitch.installed`.
    var amsExtruderMap: [String: Int]?
    var filaSwitch: FilaSwitch?
    var amsExists: Bool?
    var amsFilamentBackup: Bool?
    var hmsErrors: [HmsError]?
    var printError: LooseNumber?
    /// 1 Silent | 2 Standard | 3 Sport | 4 Ludicrous — the printer's real speed mode.
    var speedLevel: LooseNumber?
    /// Human-readable sub-stage while printing, e.g. "Changing filament", "Auto bed leveling".
    var stgCurName: String?
    /// True after FINISH until the user confirms the plate is clear (gates the queue).
    var awaitingPlateClear: Bool?
    var doorOpen: Bool?
    /// LAN Developer Mode. false = the firmware REJECTS every command Bambuddy sends (status still
    /// flows, so nothing looks wrong). Absent on the WebSocket feed — fetch via REST, and treat
    /// nil as "not yet known", never as off. See `LanMode`.
    var developerMode: Bool?
    var wifiSignal: LooseNumber?
    var activeExtruder: LooseNumber?
    var supportsDrying: Bool?
    var supportsDryingWhilePrinting: Bool?
    var supportsChamberHeater: Bool?
    /// Archive of the current/most recent print — reprint target.
    var currentArchiveId: Int?
    /// The nozzle(s) mounted on the toolhead now — index 0 = nozzle/left, 1 = nozzle_2/right.
    var nozzles: [NozzleInfo]?
    var nozzleRack: [NozzleRackSlot]?
}

enum SpeedMode: Int, Codable, CaseIterable, Sendable {
    case silent = 1, standard = 2, sport = 3, ludicrous = 4
}

// MARK: - Library

struct FileMetadata: Codable, Hashable, Sendable {
    var totalLayers: LooseNumber?
    var layerHeight: LooseNumber?
    var nozzleDiameter: LooseNumber?
    var nozzleTemperature: LooseNumber?
    var bedType: String?
    var slicedForModel: String?
    var filamentType: String?
    var filamentColor: String?
    var filamentUsedMm: LooseNumber?
    var filamentUsedG: LooseNumber?
    var printTimeSeconds: LooseNumber?
    var filamentSlots: [FilamentSlot]?

    struct FilamentSlot: Codable, Hashable, Sendable {
        var slotId: Int?
        var usedG: LooseNumber?
        var type: String?
        var color: String?
    }
}

struct LibraryFile: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var filename: String
    var fileType: String?           // stl | 3mf | gcode.3mf
    var fileSize: LooseNumber?
    var thumbnailPath: String?
    var slicedForModel: String?
    var printTimeSeconds: LooseNumber?
    var filamentUsedGrams: LooseNumber?
    var printName: String?
    /// Present on GET /library/files/{id} (detail), not on the list. Slicer-baked stats.
    var metadata: FileMetadata?
}

/// One entry in the printer's onboard storage (SD card) listing.
struct PrinterFile: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var isDirectory: Bool
    var size: LooseNumber?
    var path: String
    var mtime: String?
    var id: String { path }
}

struct PrinterFileList: Codable, Hashable, Sendable {
    var path: String
    var files: [PrinterFile]
}

/// A filament a plate/slot consumes (from /plates or file metadata).
struct PlateFilament: Codable, Hashable, Sendable {
    var slotId: Int?
    var type: String?           // "PLA" | "PETG-CF" | ...
    var color: String?          // "#RRGGBB"
    var usedGrams: LooseNumber?
    var usedMeters: LooseNumber?
}

/// One build plate inside a sliced .gcode.3mf.
struct PlateInfo: Codable, Hashable, Sendable, Identifiable {
    var index: Int              // 1-based
    var name: String?
    var objects: [String]?
    var objectCount: Int?
    var hasThumbnail: Bool?
    var thumbnailUrl: String?
    var printTimeSeconds: LooseNumber?
    var filamentUsedGrams: LooseNumber?
    var filaments: [PlateFilament]?
    var id: Int { index }
}

struct PlatesResponse: Codable, Hashable, Sendable {
    var fileId: Int?
    var filename: String?
    var plates: [PlateInfo]
    var isMultiPlate: Bool?
    var embeddedPrinter: String?
    var embeddedProcess: String?
}

struct PrinterFilePlates: Codable, Hashable, Sendable {
    var printerId: Int?
    var path: String?
    var filename: String?
    var plates: [PlateInfo]
}

// MARK: - Queue

struct QueueItem: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var status: String          // pending | printing | completed | failed | ...
    var position: Int?
    var printerId: Int?
    var printerName: String?
    var libraryFileName: String?
    var archiveName: String?
    var libraryFileThumbnail: String?
    var archiveThumbnail: String?
    var printTimeSeconds: LooseNumber?
}

// MARK: - Sensor history

/// One point from GET /printer-sensor-history. `recordedAt` is NAIVE and in UTC.
struct SensorPoint: Codable, Hashable, Sendable {
    var recordedAt: String?
    var value: LooseNumber?
    var target: LooseNumber?
}

struct SensorSeries: Codable, Hashable, Sendable {
    var sensorKind: String?
    var data: [SensorPoint]?
    var minValue: LooseNumber?
    var maxValue: LooseNumber?
    var avgValue: LooseNumber?
}

struct SensorHistory: Codable, Hashable, Sendable {
    var printerId: Int?
    var series: [SensorSeries]?
}

// MARK: - Smart plugs

struct SmartPlug: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String?
    var printerId: Int?
    var plugType: String?       // "homeassistant" | "mqtt" | "rest" | ...
    var enabled: Bool?
    var lastState: String?      // "ON" | "OFF"
    // Server-side automations. These switch the plug with no app involvement, so the app can only
    // ever REPORT them — writes to /smart-plugs/{id} are admin-only and 403 with a scoped API key.
    var autoOn: Bool?
    var autoOff: Bool?
    var autoOffPersistent: Bool?
    var offDelayMode: String?   // "time" | "temperature"
    var offDelayMinutes: LooseNumber?
    var offTempThreshold: LooseNumber?
    var autoOffAfterDrying: Bool?
    var offDelayAfterDryingMinutes: LooseNumber?
    var scheduleEnabled: Bool?
    var scheduleOnTime: String?     // "HH:MM"
    var scheduleOffTime: String?
}

struct PlugEnergy: Codable, Hashable, Sendable {
    var power: LooseNumber?     // live draw, watts
    var voltage: LooseNumber?
    var current: LooseNumber?
    var today: LooseNumber?     // kWh consumed today
    var yesterday: LooseNumber?
    var total: LooseNumber?
}

struct PlugStatus: Codable, Hashable, Sendable {
    var state: String?          // "ON" | "OFF"
    var reachable: Bool?
    var deviceName: String?
    var energy: PlugEnergy?
}

// MARK: - Maintenance

struct MaintenanceItem: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var printerId: Int?
    var maintenanceTypeName: String
    var maintenanceTypeIcon: String?    // Lucide name e.g. "Droplet","Flame"
    var enabled: Bool?
    var intervalHours: LooseNumber?
    var intervalType: String?
    var currentHours: LooseNumber?
    var hoursSinceMaintenance: LooseNumber?
    var hoursUntilDue: LooseNumber?     // negative when overdue
    var daysUntilDue: LooseNumber?
    var isDue: Bool?
    var isWarning: Bool?
    var lastPerformedAt: String?
}

struct MaintenancePrinter: Codable, Hashable, Sendable {
    var printerId: Int?
    var printerName: String?
    var printerModel: String?
    var totalPrintHours: LooseNumber?
    var maintenanceItems: [MaintenanceItem]
    var dueCount: Int?
    var warningCount: Int?
}

struct MaintenanceSummary: Codable, Hashable, Sendable {
    var totalDue: Int?
    var totalWarning: Int?
    var printersWithIssues: [Issue]?

    struct Issue: Codable, Hashable, Sendable {
        var printerId: Int
        var printerName: String?
        var dueCount: Int?
        var warningCount: Int?
    }
}

// MARK: - Inventory

struct Spool: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var material: String            // "PETG-CF", "Support for PLA", "PLA"
    var subtype: String?
    var colorName: String?          // "Titan Gray", "Clear"
    var rgba: String?               // "565656FF" — 8-digit hex, alpha last
    var brand: String?
    var labelWeight: LooseNumber?   // grams on the label
    var weightUsed: LooseNumber?    // grams consumed
    var slicerFilament: String?     // preset code, e.g. "GFG50"
    var slicerFilamentName: String? // display name, e.g. "Bambu PETG-CF"
    var trayUuid: String?           // RFID UUID; nil for unrecognized spools
    var costPerKg: LooseNumber?
    var nozzleTempMin: LooseNumber?
    var nozzleTempMax: LooseNumber?
    var storageLocation: String?
    var lastUsed: String?

    /// Grams of filament remaining on a spool (never negative).
    var gramsRemaining: Double {
        max(0, (labelWeight?.double ?? 0) - (weightUsed?.double ?? 0))
    }
}

struct SlotAssignment: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var spoolId: Int?
    var printerId: Int?
    var printerName: String?
    var amsId: Int          // AMS unit id -> status.ams[k].id
    var trayId: Int         // tray index -> status.ams[k].tray[i].id
    var fingerprintColor: String?
    var fingerprintType: String?
    var configured: Bool?
    var pendingConfig: Bool?
    var amsLabel: String?
    var spool: Spool        // full embedded spool
}

// MARK: - Settings & history

/// Subset of GET /api/v1/settings/ the app reads. Writes are admin-JWT only.
struct AppSettings: Codable, Hashable, Sendable {
    var energyCostPerKwh: LooseNumber?  // e.g. 0.24
    var currency: String?               // ISO code, e.g. "GBP" | "USD" | "EUR"
    var energyTrackingMode: String?
    var defaultFilamentCost: LooseNumber?
}

struct PrintLogEntry: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var archiveId: Int?
    var printName: String?
    var printerName: String?
    var printerId: Int?
    var status: String                  // completed | failed | cancelled | ...
    var startedAt: String?              // naive local ISO, e.g. "2026-06-28T15:07:35.681213"
    var completedAt: String?
    var durationSeconds: LooseNumber?
    var filamentType: String?           // may be comma-joined: "PETG-CF, PLA"
    var filamentColor: String?          // may be comma-joined: "#565656,#000000"
    var filamentUsedGrams: LooseNumber?
    var cost: LooseNumber?
    var energyKwh: LooseNumber?
    var energyCost: LooseNumber?
    var failureReason: String?
    var thumbnailPath: String?
    var createdAt: String?
}

struct PrintLogPage: Codable, Hashable, Sendable {
    var items: [PrintLogEntry]
    var total: Int?
}

struct ArchiveStats: Codable, Hashable, Sendable {
    var totalPrints: Int?
    var successfulPrints: Int?
    var failedPrints: Int?
    var cancelledPrints: Int?
    var totalPrintTimeHours: LooseNumber?
    var totalFilamentGrams: LooseNumber?
    var totalCost: LooseNumber?
    var printsByFilamentType: [String: Int]?
    var printsByPrinter: [String: Int]?
    var totalEnergyKwh: LooseNumber?
    var totalEnergyCost: LooseNumber?
    var energyDataWarmingUp: Bool?
}

// MARK: - MakerWorld

struct MakerWorldStatus: Codable, Hashable, Sendable {
    var hasCloudToken: Bool?
    var canDownload: Bool?
}

struct MWFilament: Codable, Hashable, Sendable {
    var type: String?
    var color: String?
    var usedG: String?
}

/// One printable profile/instance. `id` → instance_id, `profileId` → profile_id on import.
///
/// The same type decodes BOTH lists a resolve returns, because they carry the same field names — but
/// not the same fields. The `/instances` hits have `id`/`profileId`/`title`/`cover` and, measured
/// across 95 of them on two models, **none** of `prediction`, `weight`, `needAms`,
/// `instanceFilaments` or `extention`; those live only on `design.instances[]`. `MakerWorld.rows`
/// joins the two, so decoding every substantive field as optional here is load-bearing, not defensive
/// habit.
struct MWInstance: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var profileId: Int?
    var title: String?
    var cover: String?
    var needAms: Bool?
    var prediction: LooseNumber?    // print time, seconds
    var weight: LooseNumber?        // grams
    var materialCnt: Int?           // distinct materials
    var materialColorCnt: Int?      // distinct colours
    var isDefault: Bool?            // false on every record of every model probed — see MakerWorld.preselect
    var appCanPrint: Bool?
    var instanceFilaments: [MWFilament]?
    /// The profile's own blurb, as HTML — see `MakerWorldSearch.markdown(fromHTML:)`.
    var summary: String?
    /// MakerWorld's translation of it. Empty string when absent, like the design's.
    var summaryTranslated: String?
    /// Extra photos the uploader attached to this profile, beyond `cover`.
    var pictures: [Picture]?
    var extention: Extention?

    struct Picture: Codable, Hashable, Sendable, Identifiable {
        var name: String?
        var url: String?
        var id: String { url ?? name ?? "" }
    }

    init(id: Int, profileId: Int? = nil, title: String? = nil, cover: String? = nil,
         needAms: Bool? = nil, prediction: LooseNumber? = nil, weight: LooseNumber? = nil,
         materialCnt: Int? = nil, materialColorCnt: Int? = nil, isDefault: Bool? = nil,
         appCanPrint: Bool? = nil, instanceFilaments: [MWFilament]? = nil, summary: String? = nil,
         summaryTranslated: String? = nil, pictures: [Picture]? = nil, extention: Extention? = nil) {
        self.id = id
        self.profileId = profileId
        self.title = title
        self.cover = cover
        self.needAms = needAms
        self.prediction = prediction
        self.weight = weight
        self.materialCnt = materialCnt
        self.materialColorCnt = materialColorCnt
        self.isDefault = isDefault
        self.appCanPrint = appCanPrint
        self.instanceFilaments = instanceFilaments
        self.summary = summary
        self.summaryTranslated = summaryTranslated
        self.pictures = pictures
        self.extention = extention
    }

    struct Extention: Codable, Hashable, Sendable {
        var modelInfo: ModelInfo?
        struct ModelInfo: Codable, Hashable, Sendable {
            var plates: [Plate]?
            var compatibility: Compat?
            var otherCompatibility: [Compat]?
            var projectSettings: ProjectSettings?

            struct Compat: Codable, Hashable, Sendable {
                var devModelName: String?      // "O1C2"
                var devProductName: String?    // "H2C"
                var nozzleDiameter: LooseNumber?
            }
            struct ProjectSettings: Codable, Hashable, Sendable {
                var layerHeight: String?
                var wallLoops: String?
                var sparseInfillDensity: String?
            }
            struct Plate: Codable, Hashable, Sendable {
                var index: Int?
                var prediction: LooseNumber?
                var weight: LooseNumber?
                var filaments: [MWFilament]?
                var thumbnail: Thumb?

                struct Thumb: Codable, Hashable, Sendable { var url: String? }
            }
        }
    }
}

struct MWDesign: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var title: String?
    var coverUrl: String?
    var summary: String?
    /// MakerWorld's own translation of `summary`.
    ///
    /// **An EMPTY STRING when there is no translation, not null** — measured. Treating "" as a
    /// present value shows an empty description; treating a missing key as "no translation" is the
    /// same mistake in the other direction. See `MakerWorldSearch.description`.
    var summaryTranslated: String?
    var downloadCount: Int?
    var likeCount: Int?
    var tags: [String]?
    var designCreator: Creator?
    /// The metadata sidecar for the `/instances` hits — see `MWInstance` and `MakerWorld.rows`.
    var instances: [MWInstance]?
    /// MakerWorld's own pre-selection. An **instance id**, matching `instances[].id`.
    var defaultInstanceId: Int?
    var license: String?
    var licenseDescriptionInfo: LicenseInfo?
    var originals: [Original]?
    var paidSetting: PaidSetting?
    var isPointRedeemable: Bool?
    var isExclusive: Bool?

    struct Creator: Codable, Hashable, Sendable {
        var name: String?
        var handle: String?
        var avatar: String?
    }
    /// MakerWorld's own licence prose. Rendered verbatim rather than paraphrased.
    struct LicenseInfo: Codable, Hashable, Sendable {
        var title: String?
        var content: String?
    }
    /// Upstream attribution when the model is a remix.
    struct Original: Codable, Hashable, Sendable {
        var title: String?
        var author: String?
        var link: String?
        var license: String?
    }
    struct PaidSetting: Codable, Hashable, Sendable {
        var isPaid: Bool?
    }
}

struct MakerWorldResolved: Codable, Hashable, Sendable {
    var modelId: Int
    var profileId: Int?
    var design: MWDesign
    var instances: [MWInstance]
    var alreadyImportedLibraryIds: [Int]?
}

struct MakerWorldImportRequest: Codable, Hashable, Sendable {
    var modelId: Int
    var profileId: Int?
    var instanceId: Int?
    var folderId: Int?
}

struct MakerWorldImportResponse: Codable, Hashable, Sendable {
    var libraryFileId: Int
    var filename: String?
    var wasExisting: Bool?
    /// The auto-created `MakerWorld` folder, so the Files tab can be opened where the file landed.
    var folderId: Int?
    /// Echoes the profile that was pulled, so the response can be matched back to the picked row.
    var profileId: Int?
}

/// `GET /api/v1/library/files/{id}/filament-requirements`.
///
/// One entry per filament slot the sliced file asks for — the join key between what the file needs
/// and what is in the trays. `nozzleId` is the extruder the slicer assigned the slot to, and exists
/// only after a slice: a raw project 3MF reports no `tray_info_idx` and no `nozzle_id`.
struct FilamentRequirements: Codable, Hashable, Sendable {
    var filaments: [Requirement]?

    struct Requirement: Codable, Hashable, Sendable, Identifiable {
        var slotId: Int?
        var type: String?
        var color: String?
        var usedGrams: LooseNumber?
        var trayInfoIdx: String?
        var usedInPlate: Bool?
        var nozzleId: Int?

        var id: Int { slotId ?? 0 }
    }

    /// The entries the chosen plate actually consumes. A four-plate file lists filaments no single
    /// plate needs, so the unfiltered list answers a different question.
    ///
    /// A missing `used_in_plate` means "no per-plate information", not "unused" — treating it as
    /// unused would under-report a print's needs, which is the direction that matters.
    var usedSlots: [Requirement] { (filaments ?? []).filter { $0.usedInPlate ?? true } }

    /// How many filament slots this print consumes.
    var usedSlotCount: Int { max(usedSlots.count, 1) }

    /// The 1-based filament slots this print consumes, ascending and deduped.
    ///
    /// The list `ams_mapping` is built from. A missing `slot_id` falls back to the entry's POSITION,
    /// not to `1` — two entries that both omit it describe two filaments, and collapsing them to
    /// `[1, 1]` would map one tray and silently drop the other.
    var usedSlotIds: [Int] {
        var ids: [Int] = []
        for (i, r) in usedSlots.enumerated() {
            let id = max(r.slotId ?? (i + 1), 1)
            if !ids.contains(id) { ids.append(id) }
        }
        return ids.sorted()
    }

    /// The 1-based filament slot this print uses, when it uses exactly one — `nil` otherwise.
    ///
    /// **Not the same question as `usedSlotCount == 1`.** `ams_mapping` is indexed by the 3MF's
    /// filament slot, so a one-element array addresses slot 1 and only slot 1. A plate whose lone
    /// filament is slot 3 needs `[-1, -1, tray]`; sending `[tray]` for it binds the chosen tray to a
    /// filament the plate never asks for and leaves the real one for the firmware to guess.
    /// Measured: plate 2 of the seed tray uses slot 2, plate 4 uses slot 3.
    var soleUsedSlot: Int? {
        let used = usedSlots
        guard used.count == 1 else { return nil }
        return max(used[0].slotId ?? 1, 1)
    }
}

/// `GET /api/v1/cloud/status`. A `403` means the API key has no cloud scope — a different condition
/// from "not signed in", with a different remedy. See `MakerWorldAccess`.
struct CloudStatus: Codable, Hashable, Sendable {
    var isAuthenticated: Bool?
    var email: String?
    var region: String?
}

/// One row of `GET /api/v1/makerworld/recent-imports`.
struct MakerWorldRecentImport: Codable, Identifiable, Hashable, Sendable {
    var libraryFileId: Int
    var filename: String?
    var folderId: Int?
    var thumbnailPath: String?
    var sourceUrl: String?
    var createdAt: String?

    var id: Int { libraryFileId }
}

// MARK: - Slicing

/// One poll of `GET /api/v1/slice-jobs/{job_id}`.
///
/// A finished slice reports its outputs NESTED under `result` — validated against the live server and
/// recorded in `docs/phase0-results.md` as `result.{library_file_id, print_time_seconds,
/// filament_used_g, filament_used_mm}`; the RN client read `j.result` for the same reason. Reading
/// those names off the root decoded nil every time, so the wizard enqueued the original (unsliced)
/// file instead of the .gcode.3mf just produced.
///
/// The root-level twins are kept as a FALLBACK, not as the primary shape: the server has not been
/// re-verified since, so a build that flattens the job must still decode. Consumers read the computed
/// accessors below, which prefer the nested object and fall back to the root.
struct SliceJob: Codable, Hashable, Sendable {
    /// The `result` object a completed job carries.
    struct Result: Codable, Hashable, Sendable {
        var status: String?
        var error: String?
        /// The NEW library file the slice produced — this is what actually gets enqueued.
        var libraryFileId: LooseNumber?
        var printTimeSeconds: LooseNumber?
        var filamentUsedG: LooseNumber?
        var filamentUsedMm: LooseNumber?
    }

    var id: Int?
    var status: String?
    var progress: LooseNumber?
    var result: Result?

    // Root-level fallbacks. Prefixed `root` so the accessors below can own the plain names the app
    // reads; `CodingKeys` restores the wire spelling (matched AFTER the decoder's snake_case
    // conversion, hence camelCase).
    var rootError: String?
    var rootErrorMessage: String?
    var rootLibraryFileId: LooseNumber?
    var rootPrintTimeSeconds: LooseNumber?
    var rootFilamentUsedG: LooseNumber?
    var rootFilamentUsedMm: LooseNumber?

    enum CodingKeys: String, CodingKey {
        case id, status, progress, result
        case rootError = "error"
        case rootErrorMessage = "errorMessage"
        case rootLibraryFileId = "libraryFileId"
        case rootPrintTimeSeconds = "printTimeSeconds"
        case rootFilamentUsedG = "filamentUsedG"
        case rootFilamentUsedMm = "filamentUsedMm"
    }

    /// Ids are `LooseNumber` on the wire side so a stringified `"42"` can't fail the whole job
    /// payload the way a strict `Int?` would.
    var libraryFileId: Int? { result?.libraryFileId?.int ?? rootLibraryFileId?.int }
    var printTimeSeconds: LooseNumber? { result?.printTimeSeconds ?? rootPrintTimeSeconds }
    var filamentUsedG: LooseNumber? { result?.filamentUsedG ?? rootFilamentUsedG }
    var filamentUsedMm: LooseNumber? { result?.filamentUsedMm ?? rootFilamentUsedMm }

    /// Why a slice failed. The server names this field `error` (the RN client threw `j.error`);
    /// `error_message` is only a fallback, and a blank string is treated as absent so the caller's
    /// own "Slice failed" default wins instead of an empty alert body.
    var errorMessage: String? {
        for candidate in [rootError, result?.error, rootErrorMessage] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

struct CameraDiagnosis: Codable, Hashable, Sendable {
    var proto: String?
    var port: Int?
    var overallStatus: String?
    var summaryCode: String?
    var stages: [Stage]?

    struct Stage: Codable, Hashable, Sendable {
        var name: String
        var status: String
        var code: String?
    }

    // NOTE: keys here are matched AFTER the decoder's snake_case conversion, so they stay camelCase.
    // Only `protocol` needs remapping, because it is a Swift keyword.
    enum CodingKeys: String, CodingKey {
        case proto = "protocol"
        case port, overallStatus, summaryCode, stages
    }
}
