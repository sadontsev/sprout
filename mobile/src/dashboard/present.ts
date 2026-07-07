import { c } from '../theme';
import type { PrinterStatus } from '../api/types';

export type DashKind = 'connecting' | 'offline' | 'idle' | 'live' | 'complete' | 'error';

export interface AmsTrayVM {
  label: string;
  color: string;
  pct: string;
  active: boolean;
  empty: boolean;
}

export interface NozzleVM {
  now: number;
  target: number;
  heating: boolean;
  /** The extruder currently doing the work (always true on single-nozzle machines). */
  active: boolean;
}

export interface DashVM {
  kind: DashKind;
  stateLabel: string;
  stateColor: string;
  heroSub: string;
  progressInt: number;
  layer: string;
  totalLayers: string;
  etaText: string;
  doneText: string;
  /** The ACTIVE nozzle (of 1 or 2) — what the compact views and Live Activity show. */
  nozzleNow: number;
  nozzleTarget: number;
  nozzleHeating: boolean;
  /** All nozzles, in payload order — dual-nozzle machines (H2-series) have 2. */
  nozzles: NozzleVM[];
  bedNow: number;
  bedTarget: number;
  bedHeating: boolean;
  /** Chamber temperature — only on enclosed machines (hasChamber). */
  hasChamber: boolean;
  chamberNow: number;
  chamberTarget: number;
  chamberHeating: boolean;
  isPaused: boolean;
  lightOn: boolean;
  speedIdx: number; // 1..4, from the printer's real speed_level
  speedLabel: string;
  /** Non-blocking HMS notices (the printer keeps printing) — shown as a warning chip, not an error screen. */
  hmsCount: number;
  hmsCode: string | null; // first full_code, dashed for readability
  /** FINISH + plate not confirmed clear — the queue is blocked until the user confirms. */
  awaitingPlateClear: boolean;
  ams: AmsTrayVM[];
}

const round = (n: number | undefined | null): number => Math.round(Number(n ?? 0)) || 0;

/** Coerce a Bambuddy numeric field to a finite number, else null. The WebSocket delivers some
 *  numbers as strings (e.g. AMS `temp` = "30.4") while REST sends real numbers — callers that use
 *  number-only methods (.toFixed) MUST go through this or they crash on the string form. */
export function asNum(x: unknown): number | null {
  if (x == null || x === '') return null;
  const n = typeof x === 'number' ? x : Number(x);
  return Number.isFinite(n) ? n : null;
}

export const SPEED_LABELS = ['', 'Silent', 'Standard', 'Sport', 'Ludicrous'];

export function fmtDuration(min: number): string {
  if (!isFinite(min) || min <= 0) return '—';
  const h = Math.floor(min / 60);
  const m = Math.round(min % 60);
  return h > 0 ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
}

export function fmtClock(ms: number): string {
  const d = new Date(ms);
  let h = d.getHours();
  const m = d.getMinutes();
  const ap = h >= 12 ? 'PM' : 'AM';
  h = h % 12 || 12;
  return `${h}:${String(m).padStart(2, '0')} ${ap}`;
}

/** Bambu tray colors are RGBA hex like "565656FF" / "00000000". Return #RRGGBB or null. */
export function normColor(hex?: string): string | null {
  if (!hex) return null;
  const h = hex.replace('#', '');
  if (h.length >= 6) return '#' + h.slice(0, 6).toUpperCase();
  return null;
}

// ---- Nozzles / hotends (H2-series: a fixed Left toolhead + a swappable Right "vortex") ----
// Inventory view grouped by toolhead. Temperatures live on the dashboard (labelled Left/Right) —
// this view is deliberately spec-only so they aren't duplicated.
export interface RackNozzleVM {
  key: string;
  diameter: string; // "0.4 mm"
  type: string; // "Hardened" | "Stainless"
  colorHex: string | null; // filament currently threaded (=> mounted)
  serial: string; // short tail of the serial, '' if none
  mounted: boolean; // has filament -> currently mounted on the toolhead
}
export interface ToolheadVM {
  side: 'left' | 'right' | 'single';
  label: string; // "Left" | "Right" | "Nozzle"
  active: boolean; // the currently-selected extruder
  swappable: boolean; // has a vortex (more than one nozzle to choose from)
  nozzles: RackNozzleVM[];
}

const NOZZLE_TYPE_LABEL: Record<string, string> = {
  HS01: 'Hardened',
  HS00: 'Stainless',
  hardened_steel: 'Hardened',
  stainless_steel: 'Stainless',
};
const nozzleType = (t?: string): string => (t ? NOZZLE_TYPE_LABEL[t] ?? t : '');
const nozzleDia = (d?: string | number): string => {
  const n = asNum(d);
  return n != null ? `${n} mm` : '';
};

/**
 * Pure: nozzles grouped by toolhead. On the H2-series the nozzle_rack `id` encodes the extruder in
 * its high nibble — `id >> 4` is 0 for the LEFT toolhead (a single fixed nozzle) and 1 for the RIGHT
 * (a vortex it swaps between). Verified against active_extruder + ams_extruder_map. Machines with no
 * rack (A1) fall back to their mounted `nozzles` spec. Empty rack slots (serial "N/A") are dropped.
 */
export function presentNozzles(status: PrinterStatus | null): { toolheads: ToolheadVM[]; hasVortex: boolean } {
  if (!status) return { toolheads: [], hasVortex: false };
  const ae = asNum(status.active_extruder);
  const rack = (status.nozzle_rack ?? []).filter((r) => r.serial_number && r.serial_number !== 'N/A' && (asNum(r.max_temp) ?? 0) > 0);

  if (rack.length > 0) {
    const toNozzle = (r: NonNullable<PrinterStatus['nozzle_rack']>[number]): RackNozzleVM => {
      const mounted = !!(r.filament_color && r.filament_color !== '00000000');
      return {
        key: String(r.id),
        diameter: nozzleDia(r.nozzle_diameter),
        type: nozzleType(r.nozzle_type),
        colorHex: mounted ? normColor(r.filament_color) : null,
        serial: r.serial_number ? r.serial_number.slice(-4) : '',
        mounted,
      };
    };
    const byExtruder = new Map<number, RackNozzleVM[]>();
    for (const r of rack) {
      const ext = Math.max(0, r.id) >> 4; // 0 = left, 1 = right
      byExtruder.set(ext, [...(byExtruder.get(ext) ?? []), toNozzle(r)]);
    }
    const exts = [...byExtruder.keys()].sort((a, b) => a - b);
    const dual = exts.length > 1;
    const toolheads: ToolheadVM[] = exts.map((ext) => {
      const nozzles = byExtruder.get(ext)!;
      return {
        side: dual ? (ext === 0 ? 'left' : 'right') : 'single',
        label: dual ? (ext === 0 ? 'Left' : 'Right') : 'Nozzle',
        active: ae === ext,
        swappable: nozzles.length > 1,
        nozzles,
      };
    });
    return { toolheads, hasVortex: toolheads.some((t) => t.swappable) };
  }

  // No rack (A1 etc.): one non-swappable toolhead per mounted nozzle, spec from status.nozzles.
  const vm = presentDashboard(status);
  const info = status.nozzles ?? [];
  const dual = vm.nozzles.length > 1;
  const toolheads: ToolheadVM[] = vm.nozzles
    .map((n, i): ToolheadVM => {
      const diameter = nozzleDia(info[i]?.nozzle_diameter);
      const type = nozzleType(info[i]?.nozzle_type);
      return {
        side: dual ? (i === 0 ? 'left' : 'right') : 'single',
        label: dual ? (i === 0 ? 'Left' : 'Right') : 'Nozzle',
        active: n.active,
        swappable: false,
        nozzles: diameter || type ? [{ key: `m${i}`, diameter, type, colorHex: null, serial: '', mounted: n.active }] : [],
      };
    })
    .filter((t) => t.nozzles.length > 0);
  return { toolheads, hasVortex: false };
}

/** "0500050000010007" -> "0500-0500-0001-0007" (the format Bambu's HMS docs use). */
export function fmtHmsCode(fullCode?: string | null): string | null {
  if (!fullCode) return null;
  const s = String(fullCode);
  return s.length === 16 ? s.replace(/(.{4})(?=.)/g, '$1-') : s;
}

// The base VM is built per call — theme tokens (c.*) are live-mutated on theme switch, so
// capturing their values at module scope would freeze the dark palette forever.
function base(): DashVM {
  return {
    kind: 'connecting',
    stateLabel: 'Connecting',
    stateColor: c.idle,
    heroSub: '',
    progressInt: 0,
    layer: '0',
    totalLayers: '0',
    etaText: '—',
    doneText: '—',
    nozzleNow: 0,
    nozzleTarget: 0,
    nozzleHeating: false,
    nozzles: [],
    bedNow: 0,
    bedTarget: 0,
    bedHeating: false,
    hasChamber: false,
    chamberNow: 0,
    chamberTarget: 0,
    chamberHeating: false,
    isPaused: false,
    lightOn: false,
    speedIdx: 2,
    speedLabel: 'Standard',
    hmsCount: 0,
    hmsCode: null,
    awaitingPlateClear: false,
    ams: [],
  };
}

/** Heating: trust the payload's explicit flag when present, else derive from the temp gap. */
function heating(explicit: boolean | undefined, now: number, target: number, gap: number): boolean {
  if (typeof explicit === 'boolean') return explicit;
  return target > 0 && now < target - gap;
}

/** Pure: map a PrinterStatus into the Dashboard's display values (mirrors the design bindings). */
export function presentDashboard(status: PrinterStatus | null, nowMs = 0): DashVM {
  if (!status) return base();
  if (!status.connected) {
    return { ...base(), kind: 'offline', stateLabel: 'Offline', stateColor: c.idle, heroSub: 'No response from the printer' };
  }

  const state = (status.state || '').toUpperCase();
  const t = status.temperatures ?? {};

  // Nozzles: single machines report `nozzle`; dual (H2-series) add `nozzle_2`. The "active" one is
  // whichever is being driven (has a target), falling back to the hotter one — the payload's
  // active_extruder index doesn't map reliably onto the nozzle/nozzle_2 keys.
  const n1: NozzleVM = {
    now: round(t.nozzle),
    target: round(t.nozzle_target),
    heating: heating(t.nozzle_heating, round(t.nozzle), round(t.nozzle_target), 3),
    active: true,
  };
  const nozzles: NozzleVM[] = [n1];
  if (t.nozzle_2 != null) {
    nozzles.push({
      now: round(t.nozzle_2),
      target: round(t.nozzle_2_target),
      heating: heating(t.nozzle_2_heating, round(t.nozzle_2), round(t.nozzle_2_target), 3),
      active: false,
    });
  }
  // Which extruder is doing the work (0=left, 1=right). The reliable signal is the DRIVEN nozzle —
  // exactly one has a target set; the idle one reads 0. (A just-deactivated head can still be hotter
  // than a just-activated one, so a temperature compare alone picks the wrong head mid tool-change.)
  // Fall back to the hotter one only when both or neither is driven. status.active_extruder is
  // deliberately NOT used: on the live H2C it reports the wrong index (observed 1 while the driven
  // head was nozzle idx 0 at 245/245 and active_extruder disagreed with ams_extruder_map too), so
  // trusting it re-introduces the "shows the idle nozzle" bug this exists to fix.
  let activeIdx = 0;
  if (nozzles.length > 1) {
    const driven0 = nozzles[0].target > 0;
    const driven1 = nozzles[1].target > 0;
    activeIdx = driven0 !== driven1 ? (driven1 ? 1 : 0) : nozzles[1].now > nozzles[0].now ? 1 : 0;
  }
  nozzles.forEach((n, i) => (n.active = i === activeIdx));
  const active = nozzles[activeIdx] ?? n1;

  const bedNow = round(t.bed);
  const bedTarget = round(t.bed_target);
  const bedHeating = heating(t.bed_heating, bedNow, bedTarget, 2);

  const hasChamber = t.chamber != null;
  const chamberNow = round(t.chamber);
  const chamberTarget = round(t.chamber_target);
  const chamberHeating = hasChamber && heating(t.chamber_heating, chamberNow, chamberTarget, 2);

  const ams: AmsTrayVM[] = (status.ams?.[0]?.tray ?? []).slice(0, 4).map((tray, i) => {
    const empty = !tray.tray_type;
    return {
      label: empty ? 'Empty' : tray.tray_type ?? '',
      color: empty ? 'transparent' : normColor(tray.tray_color) ?? c.s4,
      pct: empty ? '—' : `${round(tray.remain)}%`,
      active: !empty && status.tray_now === i,
      empty,
    };
  });

  const speedIdx = status.speed_level && status.speed_level >= 1 && status.speed_level <= 4 ? status.speed_level : 2;
  const hmsCount = status.hms_errors?.length ?? 0;
  const hmsCode = fmtHmsCode(status.hms_errors?.[0]?.full_code ?? status.hms_errors?.[0]?.code);

  const common: DashVM = {
    ...base(),
    heroSub: status.subtask_name ?? '',
    progressInt: round(status.progress),
    layer: String(status.layer_num ?? 0),
    totalLayers: String(status.total_layers ?? 0),
    etaText: fmtDuration(status.remaining_time ?? 0),
    doneText: status.remaining_time ? fmtClock(nowMs + status.remaining_time * 60000) : '—',
    nozzleNow: active.now,
    nozzleTarget: active.target,
    nozzleHeating: active.heating,
    nozzles,
    bedNow,
    bedTarget,
    bedHeating,
    hasChamber,
    chamberNow,
    chamberTarget,
    chamberHeating,
    lightOn: status.chamber_light === true,
    speedIdx,
    speedLabel: SPEED_LABELS[speedIdx],
    hmsCount,
    hmsCode,
    awaitingPlateClear: status.awaiting_plate_clear === true,
    ams,
  };

  // A real failure: the backend's print_error, or an explicit failed state. An hms_errors entry
  // alone is NOT an error — the H2C emits benign notices mid-print; they surface via hmsCount.
  if (!!status.print_error || state === 'FAILED' || state === 'ERROR') {
    return { ...common, kind: 'error', stateLabel: 'Error', stateColor: c.error };
  }
  if (state === 'PAUSE' || state === 'PAUSED') {
    return { ...common, kind: 'live', isPaused: true, stateLabel: 'Paused', stateColor: c.paused };
  }
  if (state === 'FINISH' || state === 'FINISHED' || state === 'FINISHING') {
    return { ...common, kind: 'complete', stateLabel: 'Complete', stateColor: c.running };
  }
  if (state === 'IDLE' || state === '' || state === 'UNKNOWN') {
    return { ...common, kind: 'idle', stateLabel: 'Idle', stateColor: c.idle, heroSub: 'No active job' };
  }
  // Live. Prefer the printer's own sub-stage name ("Changing filament", "Auto bed leveling"…);
  // fall back to the heating heuristic.
  const stage = (status.stg_cur_name ?? '').trim();
  const inStage = stage.length > 0 && stage.toLowerCase() !== 'printing';
  const heatingUp = (active.heating || bedHeating) && (status.progress ?? 0) < 2;
  const stateLabel = inStage ? stage : heatingUp ? 'Heating' : 'Printing';
  return { ...common, kind: 'live', stateLabel, stateColor: inStage || heatingUp ? c.heating : c.running };
}
