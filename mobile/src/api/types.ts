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
