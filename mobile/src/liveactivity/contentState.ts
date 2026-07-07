// Pure mapping DashVM (+ raw status) -> the flat ContentState the Live Activity renders.
//
// Extracted out of useLiveActivity.ts (and away from PrintActivity.tsx, which imports the native
// expo-widgets / @expo/ui runtime) so this — the logic that decides what the lock screen shows — is
// unit-testable under jest. The widget component consumes the `PrintActivityProps` type from here.
import type { PrinterStatus } from '@/api/types';
import type { DashVM } from '@/dashboard/present';

/** Flat, JSON-serializable ContentState the activity renders. Mirrors what la-push pushes (app.py). */
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
};

export type LiveActivityExtras = { modelUri?: string | null; queueCount?: number; nextName?: string | null };

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
    tint: vm.stateColor,
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

// Minimal content used only to dismiss an orphaned activity we can't map back to a printer.
export const GENERIC_END: PrintActivityProps = {
  printerName: '', name: '', stateLabel: 'Complete', progress: 100, layer: 0, totalLayers: 0, etaEpochMs: 0,
  finished: true, symbol: 'checkmark.circle.fill', iconUri: '', tint: '#30D158',
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
    Math.abs(a.etaEpochMs - b.etaEpochMs) >= 60_000
  );
}
