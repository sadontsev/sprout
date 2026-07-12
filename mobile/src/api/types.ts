/** A printer registered in Bambuddy (GET /printers/). */
export interface Printer {
  id: number;
  name: string;
  model: string; // "A1" | "H2C" | ...
  nozzle_count: number; // 2 on the H2-series dual-extruder machines
  location?: string | null;
  is_active: boolean;
  serial_number?: string;
  ip_address?: string;
}

/** One HMS (health-management-system) record from the printer. Present even mid-print for
 *  benign notices — presence alone does NOT mean the print failed. */
export interface HmsError {
  code?: string;
  attr?: number;
  module?: number;
  severity?: number;
  full_code?: string; // e.g. "0500050000010007"
  actions?: unknown[];
}

/** The subset of Bambuddy's printer status the app consumes (see docs/phase0-results.md §3). */
export interface PrinterStatus {
  id?: number;
  name?: string;
  connected: boolean;
  state: string; // RUNNING | PAUSE | IDLE | FINISH | FAILED | ...
  progress: number | null; // %
  remaining_time: number | null; // minutes
  layer_num: number | null;
  total_layers: number | null;
  subtask_name: string | null;
  chamber_light: boolean | null;
  temperatures: {
    nozzle?: number;
    nozzle_target?: number;
    nozzle_heating?: boolean;
    /** Second extruder on dual-nozzle machines (H2-series). */
    nozzle_2?: number;
    nozzle_2_target?: number;
    nozzle_2_heating?: boolean;
    bed?: number;
    bed_target?: number;
    bed_heating?: boolean;
    /** Enclosed machines only. */
    chamber?: number;
    chamber_target?: number;
    chamber_heating?: boolean;
  } | null;
  ams?: Array<{
    id: number;
    // NOTE: the WebSocket delivers these as STRINGS ("30.4"); REST sends real numbers. Read via
    // asNum() (src/dashboard/present.ts) before any number method — a raw .toFixed() crashes.
    humidity?: number | string; // %
    temp?: number | string; // °C inside the AMS
    is_ams_ht?: boolean; // AMS-HT dries to 85°C; the AMS 2 Pro tops out at 65°C
    module_type?: string; // e.g. "n3f" (AMS 2 Pro)
    /** Minutes REMAINING in the drying cycle. `> 0` is THE "actively drying" signal — verified live:
     *  dry_status stayed 0 mid-cycle, so it must NOT be used as the active flag. */
    dry_time?: number | string;
    dry_status?: number; // decoded info bits — informational only, NOT a reliable active flag
    dry_sub_status?: number;
    /** Target °C — cached by Bambuddy only for cycles it started itself; null when the cycle was
     *  started elsewhere (printer screen / Bambu Handy). */
    dry_target_temp?: number | string | null;
    dry_filament?: string | null; // filament profile the current cycle was started with, e.g. "PLA"
    /** Why the AMS refuses to dry (codes 0-8) — decode via DRY_BLOCKERS in src/ams/dryer.ts. */
    dry_sf_reason?: Array<number | string>;
    tray: Array<{
      id: number;
      tray_type?: string;
      tray_color?: string;
      remain?: number;
      tray_uuid?: string | null;
      /** Recommended drying temp (°C) / time (hours) from the filament's RFID/preset; 0 = no data. */
      drying_temp?: number | string;
      drying_time?: number | string;
    }>;
  }>;
  /** Active tray index across the AMS (Bambu `tray_now`; 255 = none/external). */
  tray_now?: number;
  hms_errors?: HmsError[];
  print_error?: number;
  /** 1 Silent | 2 Standard | 3 Sport | 4 Ludicrous — the printer's real speed mode. */
  speed_level?: number;
  /** Human-readable sub-stage while printing, e.g. "Changing filament", "Auto bed leveling". */
  stg_cur_name?: string | null;
  /** True after FINISH until the user confirms the plate is clear (gates the queue). */
  awaiting_plate_clear?: boolean;
  door_open?: boolean;
  wifi_signal?: number; // dBm
  active_extruder?: number;
  supports_drying?: boolean;
  supports_drying_while_printing?: boolean;
  supports_chamber_heater?: boolean;
  /** Archive of the current/most recent print — reprint target. */
  current_archive_id?: number | null;
  /** The nozzle(s) mounted on the toolhead now — index 0 = nozzle/left, 1 = nozzle_2/right. */
  nozzles?: Array<{ nozzle_type?: string; nozzle_diameter?: string }>;
  /** H2-series swappable-nozzle store. Empty slots carry serial "N/A" / max_temp 0. Numeric
   *  fields may arrive as strings over the WS — coerce with asNum(). */
  nozzle_rack?: Array<{
    id: number;
    nozzle_type?: string; // "HS01" | "HS00" | ...
    nozzle_diameter?: string | number; // "0.4"
    wear?: number | string;
    max_temp?: number | string;
    serial_number?: string; // "N/A" when the slot is empty
    filament_color?: string; // RGBA hex of the filament last paired to this nozzle
    filament_id?: string;
    filament_type?: string;
  }>;
}

export type SpeedMode = 1 | 2 | 3 | 4; // silent | standard | sport | ludicrous

export interface LibraryFile {
  id: number;
  filename: string;
  file_type: string; // stl | 3mf | gcode.3mf
  file_size?: number;
  thumbnail_path?: string | null;
  sliced_for_model?: string | null;
  print_time_seconds?: number | null;
  filament_used_grams?: number | null;
  print_name?: string | null;
  /** Present on GET /library/files/{id} (detail), not on the list. Slicer-baked stats. */
  metadata?: FileMetadata | null;
}

/** One entry in the printer's onboard storage (SD card) listing. */
export interface PrinterFile {
  name: string;
  is_directory: boolean;
  size: number;
  path: string;
  mtime?: string;
}
export interface PrinterFileList {
  path: string;
  files: PrinterFile[];
}

/** A filament a plate/slot consumes (from /plates or file metadata). */
export interface PlateFilament {
  slot_id: number;
  type?: string | null; // "PLA" | "PETG-CF" | ...
  color?: string | null; // "#RRGGBB"
  used_grams?: number | null;
  used_meters?: number | null;
}

/** One build plate inside a sliced .gcode.3mf (from GET /library/files/{id}/plates). */
export interface PlateInfo {
  index: number; // 1-based
  name?: string | null;
  objects?: string[];
  object_count?: number;
  has_thumbnail?: boolean;
  thumbnail_url?: string | null;
  print_time_seconds?: number | null;
  filament_used_grams?: number | null;
  filaments?: PlateFilament[];
}

export interface PlatesResponse {
  file_id: number;
  filename: string;
  plates: PlateInfo[];
  is_multi_plate: boolean;
  embedded_printer?: string | null;
  embedded_process?: string | null;
}

/** The slicer-baked metadata block on a sliced file's detail (GET /library/files/{id}).metadata. */
export interface FileMetadata {
  total_layers?: number | null;
  layer_height?: number | null;
  nozzle_diameter?: number | null;
  nozzle_temperature?: number | null;
  bed_type?: string | null;
  sliced_for_model?: string | null;
  filament_type?: string | null;
  filament_color?: string | null;
  filament_used_mm?: number | null;
  filament_used_g?: number | null;
  print_time_seconds?: number | null;
  filament_slots?: Array<{ slot_id: number; used_g?: number | null; type?: string | null; color?: string | null }>;
  [k: string]: unknown;
}

export interface QueueItem {
  id: number;
  status: string; // pending | printing | completed | failed | ...
  position?: number;
  printer_id?: number | null;
  printer_name?: string | null;
  library_file_name?: string | null;
  archive_name?: string | null;
  library_file_thumbnail?: string | null;
  archive_thumbnail?: string | null;
  print_time_seconds?: number | null;
}

export interface SmartPlug {
  id: number;
  name?: string;
  printer_id?: number;
  plug_type?: string; // "homeassistant" | "mqtt" | "rest" | ...
  enabled?: boolean;
  last_state?: string; // "ON" | "OFF"
}

export interface PlugEnergy {
  power?: number | null; // live draw, watts
  voltage?: number | null;
  current?: number | null;
  today?: number | null; // kWh consumed today
  yesterday?: number | null;
  total?: number | null;
}

export interface PlugStatus {
  state?: string; // "ON" | "OFF"
  reachable?: boolean;
  device_name?: string;
  energy?: PlugEnergy | null;
  [k: string]: unknown;
}

// ---- Maintenance (GET /maintenance/printers/{id}, /maintenance/summary) ----
export interface MaintenanceItem {
  id: number;
  printer_id: number;
  maintenance_type_name: string;
  maintenance_type_icon: string | null; // Lucide name e.g. "Droplet","Flame"
  enabled: boolean;
  interval_hours: number;
  interval_type?: string;
  current_hours?: number;
  hours_since_maintenance: number;
  hours_until_due: number; // negative when overdue
  days_until_due?: number | null;
  is_due: boolean;
  is_warning: boolean;
  last_performed_at: string | null;
}

export interface MaintenancePrinter {
  printer_id: number;
  printer_name: string;
  printer_model?: string | null;
  total_print_hours: number;
  maintenance_items: MaintenanceItem[];
  due_count: number;
  warning_count: number;
}

export interface MaintenanceSummary {
  total_due: number;
  total_warning: number;
  printers_with_issues: Array<{ printer_id: number; printer_name: string; due_count?: number; warning_count?: number }>;
}

export interface Spool {
  id: number;
  material: string; // "PETG-CF", "Support for PLA", "PLA"
  subtype?: string | null;
  color_name: string | null; // "Titan Gray", "Clear"
  rgba: string | null; // "565656FF" — 8-digit hex, alpha last
  brand: string | null; // "Bambu Lab"
  label_weight: number; // grams on the label
  weight_used: number; // grams consumed
  slicer_filament: string | null; // preset code, e.g. "GFG50"
  slicer_filament_name: string | null; // display name, e.g. "Bambu PETG-CF"
  tray_uuid: string | null; // RFID UUID; null for unrecognized spools
  cost_per_kg: number | null;
  nozzle_temp_min?: number | null;
  nozzle_temp_max?: number | null;
  storage_location?: string | null;
  last_used?: string | null;
}

export interface SlotAssignment {
  id: number;
  spool_id: number;
  printer_id: number;
  printer_name: string;
  ams_id: number; // AMS unit id -> status.ams[k].id
  tray_id: number; // tray index -> status.ams[k].tray[i].id
  fingerprint_color?: string | null;
  fingerprint_type?: string | null;
  configured?: boolean;
  pending_config?: boolean;
  ams_label?: string | null;
  spool: Spool; // full embedded spool
}

/** Grams of filament remaining on a spool (never negative). */
export function spoolGramsRemaining(s: Spool): number {
  return Math.max(0, (s.label_weight ?? 0) - (s.weight_used ?? 0));
}

/** Subset of GET /api/v1/settings/ the app reads. Writes are admin-JWT only. */
export interface AppSettings {
  energy_cost_per_kwh: number; // e.g. 0.24
  currency: string; // ISO code, e.g. "GBP" | "USD" | "EUR"
  energy_tracking_mode?: string;
  default_filament_cost?: number;
  [k: string]: unknown;
}

export interface PrintLogEntry {
  id: number;
  archive_id: number | null;
  print_name: string;
  printer_name: string;
  printer_id: number;
  status: 'completed' | 'failed' | 'cancelled' | string;
  started_at: string; // naive local ISO, e.g. "2026-06-28T15:07:35.681213"
  completed_at: string | null;
  duration_seconds: number | null;
  filament_type: string | null; // may be comma-joined: "PETG-CF, PLA"
  filament_color: string | null; // may be comma-joined: "#565656,#000000"
  filament_used_grams: number | null;
  cost: number | null;
  energy_kwh: number | null;
  energy_cost: number | null;
  failure_reason: string | null;
  thumbnail_path: string | null;
  created_at?: string;
}

export interface PrintLogPage {
  items: PrintLogEntry[];
  total: number;
}

export interface ArchiveStats {
  total_prints: number;
  successful_prints: number;
  failed_prints: number;
  cancelled_prints: number;
  total_print_time_hours: number;
  total_filament_grams: number;
  total_cost: number;
  prints_by_filament_type: Record<string, number>;
  prints_by_printer: Record<string, number>;
  total_energy_kwh: number;
  total_energy_cost: number;
  energy_data_warming_up: boolean;
}

// ---------------- MakerWorld ----------------
export interface MakerWorldStatus {
  has_cloud_token: boolean;
  can_download: boolean;
}
export interface MWFilament {
  type?: string | null;
  color?: string | null;
  usedG?: string | null;
}
/** One printable profile/instance. id → instance_id, profileId → profile_id on import. */
export interface MWInstance {
  id: number;
  profileId?: number | null;
  title?: string | null;
  cover?: string | null;
  needAms?: boolean | null;
  prediction?: number | null; // print time, seconds (best-effort)
  weight?: number | null; // grams (best-effort)
  instanceFilaments?: MWFilament[] | null;
  extention?: {
    modelInfo?: { plates?: Array<{ prediction?: number | null; weight?: number | null; filaments?: MWFilament[] | null }> } | null;
  } | null;
}
export interface MWDesign {
  id: number;
  title?: string | null;
  coverUrl?: string | null;
  summary?: string | null;
  downloadCount?: number | null;
  likeCount?: number | null;
  tags?: string[] | null;
  designCreator?: { name?: string | null; handle?: string | null; avatar?: string | null } | null;
}
export interface MakerWorldResolved {
  model_id: number;
  profile_id?: number | null;
  design: MWDesign;
  instances: MWInstance[];
  already_imported_library_ids?: number[];
}
export interface MakerWorldImportRequest {
  model_id: number;
  profile_id?: number | null;
  instance_id?: number | null;
  folder_id?: number | null;
}
export interface MakerWorldImportResponse {
  library_file_id: number;
  filename: string;
  was_existing: boolean;
}

/** A bundled slicer preset reference (from /slicer/presets). */
export interface PresetRef {
  id: string;
  name: string;
  source?: string;
}

export interface SliceResult {
  status: string;
  print_time_seconds?: number | null;
  filament_used_g?: number | null;
  filament_used_mm?: number | null;
  library_file_id?: number | null;
}
