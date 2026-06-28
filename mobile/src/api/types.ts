/** The subset of Bambuddy's printer status the app consumes (see docs/phase0-results.md §3). */
export interface PrinterStatus {
  connected: boolean;
  state: string; // RUNNING | PAUSE | IDLE | FINISH | ...
  progress: number | null; // %
  remaining_time: number | null; // minutes
  layer_num: number | null;
  total_layers: number | null;
  subtask_name: string | null;
  chamber_light: boolean | null;
  temperatures: {
    nozzle?: number;
    nozzle_target?: number;
    bed?: number;
    bed_target?: number;
  } | null;
  ams?: Array<{
    id: number;
    tray: Array<{ id: number; tray_type?: string; tray_color?: string; remain?: number }>;
  }>;
  /** Active tray index across the AMS (Bambu `tray_now`). */
  tray_now?: number;
  hms_errors?: Array<{ code?: string; attr?: string; module?: string; severity?: string }>;
  print_error?: number;
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
}

export interface QueueItem {
  id: number;
  status: string; // pending | printing | completed | failed | ...
  position?: number;
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
