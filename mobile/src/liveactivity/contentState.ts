// Pure mapping DashVM (+ raw status) -> the flat ContentState the Live Activity renders.
//
// Extracted out of useLiveActivity.ts (and away from PrintActivity.tsx, which imports the native
// expo-widgets / @expo/ui runtime) so this — the logic that decides what the lock screen shows — is
// unit-testable under jest. The widget component consumes the `PrintActivityProps` type from here.
import type { PrinterStatus } from '@/api/types';
import type { DashVM } from '@/dashboard/present';
import { c } from '@/theme';

/** Flat, JSON-serializable ContentState the activity renders. Mirrors what Trellis pushes (app.py). */
export type PrintActivityProps = {
  printerName: string; // "A1" | "H2C" — which machine this card is for (one activity per printer)
  name: string; // subtask/file name
  stateLabel: string; // "Printing" | "Heating" | "Paused" | "Complete" | "Error"
  progress: number; // 0..100
  layer: number;
  totalLayers: number; // 0 if unknown
  etaEpochMs: number; // absolute finish time, ms epoch; 0 if unknown
  finished: boolean;
  symbol: string; // SF Symbol fallback name
  iconUri: string; // file:// URI of the brand nozzle glyph in the App Group ('' -> fall back to symbol)
  tint: string; // hex accent
  // Nozzles are physical: `nozzle` is the left/only head, `nozzle2` the right (H2-series only).
  nozzle: number;
  nozzleTarget: number;
  nozzle2: number;
  nozzle2Target: number;
  hasNozzle2: boolean; // true on dual-nozzle machines -> show both, one labelled active
  activeNozzle: number; // 0 = left/only, 1 = right — which head is currently driven
  bed: number;
  bedTarget: number;
  modelUri: string; // file:// URI of the plate thumbnail in the App Group ('' -> nozzle glyph) — leading visual
  queueCount: number; // prints waiting in the queue (drives the "Up next" banner row)
  nextName: string; // name of the next queued print ('' if none)
  // ---- AMS drying card (second activity per printer; widget branches on `dry`) ----
  dry?: boolean; // true -> this card shows a DRYING cycle, not a print
  amsTemp?: number; // current AMS interior °C
  amsTarget?: number; // drying target °C (0 when unknown)
  humidity?: number; // AMS %RH
};

export type LiveActivityExtras = { modelUri?: string | null; queueCount?: number; nextName?: string | null };

/**
 * FIXED palette for Live Activity content — deliberately NOT the app theme's `c.*`.
 *
 * A card lives on the lock screen, which has no relationship to the in-app theme, and Trellis (which
 * owns cards in server mode) has no idea what theme the phone is on: it always sends these values.
 * Reading `vm.stateColor` meant a light-mode app produced #23B24A while an identical card pushed from
 * the server produced #30D158 — the same print rendering in two different greens depending on which
 * side created the card. These values are the single source of truth and MUST equal Trellis's COLORS.
 */
export const LA_COLORS = {
  running: '#30D158',
  heating: '#FF9F0A',
  paused: '#0A84FF',
  error: '#FF453A',
  idle: '#8E9398',
} as const;

/** Theme-independent tint for a print card. Derived from the VM's semantic state, not its themed
 *  colour, so the same print looks identical whoever built the card and whatever theme is active. */
export function laTint(vm: DashVM): string {
  if (vm.kind === 'error') return LA_COLORS.error;
  if (vm.isPaused) return LA_COLORS.paused;
  if (vm.kind === 'idle' || vm.kind === 'offline' || vm.kind === 'connecting') return LA_COLORS.idle;
  if (vm.kind === 'complete') return LA_COLORS.running;
  // Live: heating / a named sub-stage is amber, steady printing is green — mirrors present.ts and
  // Trellis's classify() by comparing against the THEMED token rather than a hardcoded hex.
  return vm.stateColor === c.heating ? LA_COLORS.heating : LA_COLORS.running;
}

// state label -> SF Symbol shown in the activity.
const SYMBOLS: Record<string, string> = {
  Printing: 'printer.fill',
  Heating: 'thermometer.medium',
  Paused: 'pause.circle.fill',
  Complete: 'checkmark.circle.fill',
  Error: 'exclamationmark.triangle.fill',
};

const PROGRESS_EPS = 1; // push when progress moved >= 1%

/** Pure: DashVM (+raw status) -> the flat ContentState the activity renders. */
export function toContentState(
  vm: DashVM,
  status: PrinterStatus,
  nowMs: number,
  iconUri = '',
  printerName = '',
  extras: LiveActivityExtras = {},
): PrintActivityProps {
  const finished = vm.kind === 'complete';
  const remainingMin = status.remaining_time ?? 0;
  const t = status.temperatures;
  // Physical nozzle mapping (left = nozzle, right = nozzle_2); the active head + dual-ness come from
  // the view-model so the Live Activity and the in-app dashboard always agree on which is driven.
  const dual = vm.nozzles.length > 1;
  const activeNozzle = Math.max(0, vm.nozzles.findIndex((n) => n.active));
  return {
    printerName,
    iconUri,
    modelUri: extras.modelUri ?? '',
    queueCount: extras.queueCount ?? 0,
    nextName: extras.nextName ?? '',
    name: status.subtask_name ?? '',
    stateLabel: vm.stateLabel,
    progress: vm.progressInt,
    layer: status.layer_num ?? 0,
    totalLayers: status.total_layers ?? 0,
    etaEpochMs: !finished && remainingMin > 0 ? nowMs + remainingMin * 60000 : 0,
    finished,
    symbol: SYMBOLS[vm.stateLabel] ?? (vm.kind === 'error' ? SYMBOLS.Error : SYMBOLS.Printing),
    tint: laTint(vm),
    nozzle: Math.round(t?.nozzle ?? 0),
    nozzleTarget: Math.round(t?.nozzle_target ?? 0),
    nozzle2: Math.round(t?.nozzle_2 ?? 0),
    nozzle2Target: Math.round(t?.nozzle_2_target ?? 0),
    hasNozzle2: dual,
    activeNozzle,
    bed: Math.round(t?.bed ?? 0),
    bedTarget: Math.round(t?.bed_target ?? 0),
  };
}

const dnum = (v: unknown): number => {
  const n = typeof v === 'number' ? v : Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
};

/** Ids of the units with an ACTIVE drying cycle, in payload order.
 *
 *  `dry_time` (minutes remaining) > 0 is THE active signal — dry_status stayed 0 mid-cycle on the
 *  live H2C, and the WebSocket can deliver these as strings. Three drying-capable units are now
 *  fitted, so concurrent cycles are ordinary rather than theoretical. */
export function dryingUnitIds(status: PrinterStatus | null): number[] {
  return (status?.ams ?? []).filter((u) => dnum(u.dry_time) > 0).map((u) => dnum(u.id));
}

/** Pure: one unit's drying status -> a drying-card ContentState, or null when that unit is idle.
 *  The countdown renders client-side from etaEpochMs (ActivityKit timer), so pushes are only needed
 *  for temp/humidity drift and the end.
 *
 *  `amsId` selects the unit. Omitted, it falls back to the first unit currently drying — kept so a
 *  caller that only cares "is anything drying" still works. */
export function toDryContentState(status: PrinterStatus, nowMs: number, iconUri = '', printerName = '', amsId?: number): PrintActivityProps | null {
  // Scan EVERY unit, not ams[0]: the H2C runs two AMS 2 Pro plus an AMS HT, and a cycle on the HT
  // produced no card at all. The card names its unit so it is unambiguous which one is drying.
  const units = status.ams ?? [];
  const num = dnum;
  const ams = amsId != null ? units.find((u) => num(u.id) === amsId) : units.find((u) => num(u.dry_time) > 0) ?? units[0];
  if (!ams) return null;
  const unitId = num(ams.id);
  const isHt = ams.is_ams_ht === true || unitId >= 128;
  const unitLabel = units.length > 1 ? (isHt ? 'AMS HT' : `AMS ${unitId + 1}`) : '';
  const mins = num(ams.dry_time);
  if (mins <= 0) return null;
  const target = Math.round(num(ams.dry_target_temp));
  const fil = ams.dry_filament || 'Filament';
  return {
    ...GENERIC_END,
    printerName,
    iconUri,
    dry: true,
    stateLabel: 'Drying',
    name: [unitLabel, target > 0 ? `${fil} @ ${target}°` : fil].filter(Boolean).join(' · '),
    tint: '#FFB86C', // drying amber — fixed, matches Trellis's dry_state
    symbol: 'humidity.fill',
    finished: false,
    progress: 0,
    etaEpochMs: nowMs + mins * 60000,
    amsTemp: Math.round(num(ams.temp)),
    amsTarget: target,
    humidity: Math.round(num(ams.humidity)),
  };
}

// Minimal content used only to dismiss an orphaned activity we can't map back to a printer.
export const GENERIC_END: PrintActivityProps = {
  printerName: '', name: '', stateLabel: 'Complete', progress: 100, layer: 0, totalLayers: 0, etaEpochMs: 0,
  finished: true, symbol: 'checkmark.circle.fill', iconUri: '', tint: LA_COLORS.running,
  nozzle: 0, nozzleTarget: 0, nozzle2: 0, nozzle2Target: 0, hasNozzle2: false, activeNozzle: 0,
  bed: 0, bedTarget: 0, modelUri: '', queueCount: 0, nextName: '',
};

export function meaningfulChange(a: PrintActivityProps | null, b: PrintActivityProps): boolean {
  if (!a) return true;
  return (
    Math.abs(a.progress - b.progress) >= PROGRESS_EPS ||
    a.layer !== b.layer ||
    a.stateLabel !== b.stateLabel ||
    a.name !== b.name ||
    a.printerName !== b.printerName ||
    a.modelUri !== b.modelUri ||
    a.queueCount !== b.queueCount ||
    a.nextName !== b.nextName ||
    // Temps + ETA are rendered on the lock screen — without these, a heat-up that doesn't
    // advance progress/layer never pushes and the activity shows cold temps for minutes. Both
    // nozzles + the active head matter now that dual machines show them side by side.
    Math.abs(a.nozzle - b.nozzle) >= 2 ||
    Math.abs(a.nozzle2 - b.nozzle2) >= 2 ||
    a.nozzleTarget !== b.nozzleTarget ||
    a.nozzle2Target !== b.nozzle2Target ||
    a.activeNozzle !== b.activeNozzle ||
    Math.abs(a.bed - b.bed) >= 2 ||
    a.bedTarget !== b.bedTarget ||
    Math.abs(a.etaEpochMs - b.etaEpochMs) >= 60_000 ||
    // Drying cards: temp climb + humidity fall are the whole story; the countdown ticks client-side.
    (a.dry ?? false) !== (b.dry ?? false) ||
    Math.abs((a.amsTemp ?? 0) - (b.amsTemp ?? 0)) >= 1 ||
    (a.amsTarget ?? 0) !== (b.amsTarget ?? 0) ||
    Math.abs((a.humidity ?? 0) - (b.humidity ?? 0)) >= 2
  );
}
