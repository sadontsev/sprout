import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import { printActivity, type PrintActivityProps } from './PrintActivity';
import { nozzleIconUri } from './nozzleIcon';
import type { LiveActivity } from 'expo-widgets';
import type { PrinterStatus } from '@/api/types';
import type { DashVM } from '@/dashboard/present';

const MIN_UPDATE_MS = 4000; // don't push to ActivityKit more than ~once / 4s per printer
const PROGRESS_EPS = 1; // ...unless progress moved >= 1%

// state label -> SF Symbol shown in the activity.
const SYMBOLS: Record<string, string> = {
  Printing: 'printer.fill',
  Heating: 'thermometer.medium',
  Paused: 'pause.circle.fill',
  Complete: 'checkmark.circle.fill',
  Error: 'exclamationmark.triangle.fill',
};

export type LiveActivityExtras = { modelUri?: string | null; queueCount?: number; nextName?: string | null };

/** Pure: DashVM (+raw status) -> the flat ContentState the activity renders. */
export function toContentState(vm: DashVM, status: PrinterStatus, nowMs: number, iconUri = '', printerName = '', extras: LiveActivityExtras = {}): PrintActivityProps {
  const finished = vm.kind === 'complete';
  const remainingMin = status.remaining_time ?? 0;
  const t = status.temperatures;
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
    bed: Math.round(t?.bed ?? 0),
    bedTarget: Math.round(t?.bed_target ?? 0),
  };
}

const isLive = (vm: DashVM) => vm.kind === 'live'; // Printing | Heating | Paused
const isTerminal = (vm: DashVM) => vm.kind === 'complete' || vm.kind === 'error' || vm.kind === 'idle';

// Minimal content used only to dismiss an orphaned activity we can't map back to a printer.
const GENERIC_END: PrintActivityProps = {
  printerName: '', name: '', stateLabel: 'Complete', progress: 100, layer: 0, totalLayers: 0, etaEpochMs: 0,
  finished: true, symbol: 'checkmark.circle.fill', iconUri: '', tint: '#30D158', nozzle: 0, nozzleTarget: 0, bed: 0, bedTarget: 0,
  modelUri: '', queueCount: 0, nextName: '',
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
    // advance progress/layer never pushes and the activity shows cold temps for minutes.
    Math.abs(a.nozzle - b.nozzle) >= 2 ||
    Math.abs(a.bed - b.bed) >= 2 ||
    a.nozzleTarget !== b.nozzleTarget ||
    a.bedTarget !== b.bedTarget ||
    Math.abs(a.etaEpochMs - b.etaEpochMs) >= 60_000
  );
}

/** One printer's slice of the fleet, fed into usePrinterActivities. */
export type ActivityEntry = {
  printerId: number;
  printerName: string;
  vm: DashVM;
  status: PrinterStatus | null;
  extras?: LiveActivityExtras;
};

/**
 * Drives ONE iOS Live Activity per printer that's actively printing — so both machines show as
 * separate cards on the lock screen. v1 pushes updates while the app is running (foreground /
 * briefly background). v2 (in progress): ActivityKit APNs push so each card keeps tracking with the
 * app closed — the app registers each activity's push token and a homeserver-side service pushes updates.
 * offline/connecting are deliberately no-ops so a WS blip doesn't kill a card mid-print; only
 * complete/error/idle end it.
 */
export function usePrinterActivities(entries: ActivityEntry[]) {
  const instances = useRef(new Map<number, LiveActivity<PrintActivityProps>>());
  const lastPush = useRef(new Map<number, number>());
  const lastState = useRef(new Map<number, PrintActivityProps>());
  const adopted = useRef(false);

  useEffect(() => {
    if (Platform.OS !== 'ios') return;

    // Adopt activities left over from a previous launch (once). We can't map an orphan back to its
    // printer, but a card's identity is just its content — so we hand each orphan to a currently-live
    // printer and let the update loop below rewrite it with the right data. Surplus orphans are ended.
    if (!adopted.current) {
      adopted.current = true;
      try {
        const pool = printActivity.getInstances();
        const live = entries.filter((e) => isLive(e.vm) && e.status);
        live.forEach((e, i) => {
          if (pool[i]) instances.current.set(e.printerId, pool[i]);
        });
        pool.slice(live.length).forEach((inst) => inst.end('default', GENERIC_END, new Date()).catch(() => {}));
      } catch {
        /* Expo Go / no native module — ignore */
      }
    }

    const now = Date.now();
    for (const e of entries) {
      if (!e.status) continue;
      const next = toContentState(e.vm, e.status, now, nozzleIconUri(), e.printerName, e.extras ?? {});
      const inst = instances.current.get(e.printerId);

      // Terminal -> end this printer's card.
      if (isTerminal(e.vm)) {
        if (inst) {
          inst.end('default', next, new Date(now)).catch(() => {});
          instances.current.delete(e.printerId);
          lastState.current.delete(e.printerId);
          lastPush.current.delete(e.printerId);
        }
        continue;
      }

      // Live, no card yet -> start one for this printer (deep links back into the app).
      if (isLive(e.vm) && !inst) {
        try {
          instances.current.set(e.printerId, printActivity.start(next, 'bambu://'));
          lastState.current.set(e.printerId, next);
          lastPush.current.set(e.printerId, now);
        } catch {
          /* disabled by user / not a dev build — app UI still works */
        }
        continue;
      }

      // Live, card exists -> throttled update on meaningful change.
      if (inst) {
        const due = now - (lastPush.current.get(e.printerId) ?? 0) >= MIN_UPDATE_MS;
        if (due && meaningfulChange(lastState.current.get(e.printerId) ?? null, next)) {
          inst.update(next).catch(() => {});
          lastState.current.set(e.printerId, next);
          lastPush.current.set(e.printerId, now);
        }
      }
    }
  }, [entries]);
}
