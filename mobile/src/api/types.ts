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
}

export type SpeedMode = 1 | 2 | 3 | 4; // silent | standard | sport | ludicrous
