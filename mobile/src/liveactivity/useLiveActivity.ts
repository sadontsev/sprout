import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import { printActivity, type PrintActivityProps } from './PrintActivity';
import { nozzleIconUri } from './nozzleIcon';
import type { LiveActivity } from 'expo-widgets';
import type { PrinterStatus } from '@/api/types';
import type { DashVM } from '@/dashboard/present';

const MIN_UPDATE_MS = 4000; // don't push to ActivityKit more than ~once / 4s
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
export function toContentState(vm: DashVM, status: PrinterStatus, nowMs: number, iconUri = '', extras: LiveActivityExtras = {}): PrintActivityProps {
  const finished = vm.kind === 'complete';
  const remainingMin = status.remaining_time ?? 0;
  const t = status.temperatures;
  return {
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

function meaningfulChange(a: PrintActivityProps | null, b: PrintActivityProps): boolean {
  if (!a) return true;
  return (
    Math.abs(a.progress - b.progress) >= PROGRESS_EPS ||
    a.layer !== b.layer ||
    a.stateLabel !== b.stateLabel ||
    a.name !== b.name ||
    a.modelUri !== b.modelUri ||
    a.queueCount !== b.queueCount ||
    a.nextName !== b.nextName
  );
}

/**
 * Drives an iOS Live Activity from the printer's DashVM.
 * v1: the app pushes updates while running (foreground/background). v2 (not built): ActivityKit APNs
 * push so it survives app-kill — flip enablePushNotifications + wire instance.getPushToken() and have
 * Bambuddy POST to APNs. `offline`/`connecting` are deliberately no-ops so a WS blip doesn't kill the
 * activity mid-print; only complete/error/idle end it.
 */
export function useLiveActivity(vm: DashVM | null, status: PrinterStatus | null, extras: LiveActivityExtras = {}) {
  const instanceRef = useRef<LiveActivity<PrintActivityProps> | null>(null);
  const lastPushRef = useRef(0);
  const lastStateRef = useRef<PrintActivityProps | null>(null);
  const reattachedRef = useRef(false);

  useEffect(() => {
    if (Platform.OS !== 'ios') return;
    if (!vm || !status) return;

    // Re-attach to an activity left running from a previous app launch (once).
    if (!reattachedRef.current) {
      reattachedRef.current = true;
      try {
        const existing = printActivity.getInstances();
        if (existing.length > 0) instanceRef.current = existing[0];
      } catch {
        /* Expo Go / no native module — ignore */
      }
    }

    const now = Date.now();
    const next = toContentState(vm, status, now, nozzleIconUri(), extras);

    // 1) Terminal -> end the activity.
    if (isTerminal(vm)) {
      const inst = instanceRef.current;
      if (inst) {
        inst.end('default', next, new Date(now)).catch(() => {});
        instanceRef.current = null;
        lastStateRef.current = null;
      }
      return;
    }

    // 2) Live, no activity yet -> start one (deep links back into the app).
    if (isLive(vm) && !instanceRef.current) {
      try {
        instanceRef.current = printActivity.start(next, 'bambu://');
        lastStateRef.current = next;
        lastPushRef.current = now;
      } catch {
        instanceRef.current = null; // disabled by user / not a dev build — app UI still works
      }
      return;
    }

    // 3) Live, activity exists -> throttled update on meaningful change.
    if (instanceRef.current) {
      const due = now - lastPushRef.current >= MIN_UPDATE_MS;
      if (due && meaningfulChange(lastStateRef.current, next)) {
        instanceRef.current.update(next).catch(() => {});
        lastStateRef.current = next;
        lastPushRef.current = now;
      }
    }
  }, [vm, status, extras.modelUri, extras.queueCount, extras.nextName]);
}
