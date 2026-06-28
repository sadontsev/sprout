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
  nozzleNow: number;
  nozzleTarget: number;
  nozzleHeating: boolean;
  bedNow: number;
  bedTarget: number;
  bedHeating: boolean;
  isPaused: boolean;
  lightOn: boolean;
  speedLabel: string;
  ams: AmsTrayVM[];
}

const round = (n: number | undefined | null): number => Math.round(n ?? 0);

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

const BASE: DashVM = {
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
  bedNow: 0,
  bedTarget: 0,
  bedHeating: false,
  isPaused: false,
  lightOn: false,
  speedLabel: 'Standard',
  ams: [],
};

/** Pure: map a PrinterStatus into the Dashboard's display values (mirrors the design bindings). */
export function presentDashboard(status: PrinterStatus | null, nowMs = 0): DashVM {
  if (!status) return BASE;
  if (!status.connected) {
    return { ...BASE, kind: 'offline', stateLabel: 'Offline', stateColor: c.idle, heroSub: 'No response from the printer' };
  }

  const state = (status.state || '').toUpperCase();
  const t = status.temperatures ?? {};
  const nozzleNow = round(t.nozzle);
  const nozzleTarget = round(t.nozzle_target);
  const bedNow = round(t.bed);
  const bedTarget = round(t.bed_target);
  const nozzleHeating = nozzleTarget > 0 && nozzleNow < nozzleTarget - 3;
  const bedHeating = bedTarget > 0 && bedNow < bedTarget - 2;

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

  const common: DashVM = {
    ...BASE,
    heroSub: status.subtask_name ?? '',
    progressInt: round(status.progress),
    layer: String(status.layer_num ?? 0),
    totalLayers: String(status.total_layers ?? 0),
    etaText: fmtDuration(status.remaining_time ?? 0),
    doneText: status.remaining_time ? fmtClock(nowMs + status.remaining_time * 60000) : '—',
    nozzleNow,
    nozzleTarget,
    nozzleHeating,
    bedNow,
    bedTarget,
    bedHeating,
    lightOn: status.chamber_light === true,
    ams,
  };

  if ((status.hms_errors?.length ?? 0) > 0 || !!status.print_error) {
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
  const heating = (nozzleHeating || bedHeating) && (status.progress ?? 0) < 2;
  return { ...common, kind: 'live', stateLabel: heating ? 'Heating' : 'Printing', stateColor: heating ? c.heating : c.running };
}
