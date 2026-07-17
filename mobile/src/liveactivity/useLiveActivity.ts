import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import { printActivity } from './PrintActivity';
import { toContentState, meaningfulChange, GENERIC_END, type PrintActivityProps, type LiveActivityExtras } from './contentState';
import { nozzleIconUri } from './nozzleIcon';
import type { LiveActivity } from 'expo-widgets';
import type { PrinterStatus } from '@/api/types';
import type { DashVM } from '@/dashboard/present';

const MIN_UPDATE_MS = 4000; // don't push to ActivityKit more than ~once / 4s per printer

const isLive = (vm: DashVM) => vm.kind === 'live'; // Printing | Heating | Paused
const isTerminal = (vm: DashVM) => vm.kind === 'complete' || vm.kind === 'error' || vm.kind === 'idle';

/** One printer's slice of the fleet, fed into usePrinterActivities. */
export type ActivityEntry = {
  printerId: number;
  printerName: string;
  vm: DashVM;
  status: PrinterStatus | null;
  extras?: LiveActivityExtras;
};

/** Register a card's APNs push token with the la-push service (keyed by printer) so it keeps updating
 *  when the app is closed. Fire-and-forget — push is a bonus; foreground updates work regardless. */
function registerPushToken(pushUrl: string, apiKey: string, printerId: number, printerName: string, pushToken: string): void {
  if (!pushToken) return;
  // X-API-Key gates la-push registration to holders of the Bambuddy key, so a stranger who knows the
  // URL can't register their token and receive this printer's notifications.
  fetch(`${pushUrl.replace(/\/+$/, '')}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'X-API-Key': apiKey },
    body: JSON.stringify({ printer_id: printerId, push_token: pushToken, printer_name: printerName, icon_uri: nozzleIconUri() }),
  }).catch(() => {});
}

/**
 * Drives ONE iOS Live Activity per printer that's actively printing — so both machines show as
 * separate cards on the lock screen. v1 pushes updates while the app is running (foreground /
 * briefly background). v2 (in progress): ActivityKit APNs push so each card keeps tracking with the
 * app closed — the app registers each activity's push token and a <your-server>-side service pushes updates.
 * offline/connecting are deliberately no-ops so a WS blip doesn't kill a card mid-print; only
 * complete/error/idle end it.
 */
export function usePrinterActivities(entries: ActivityEntry[], pushUrl?: string | null, apiKey?: string) {
  const instances = useRef(new Map<number, LiveActivity<PrintActivityProps>>());
  const lastPush = useRef(new Map<number, number>());
  const lastState = useRef(new Map<number, PrintActivityProps>());
  const subs = useRef(new Map<number, { remove: () => void }>());
  const adopted = useRef(false);

  // Grab the card's APNs push token (now + on rotation) and register it with la-push.
  const wirePush = (printerId: number, printerName: string, inst: LiveActivity<PrintActivityProps>) => {
    if (!pushUrl || !apiKey || subs.current.has(printerId)) return;
    try {
      inst.getPushToken().then((tok) => tok && registerPushToken(pushUrl, apiKey, printerId, printerName, tok)).catch(() => {});
      const sub = inst.addPushTokenListener((ev) => registerPushToken(pushUrl, apiKey, printerId, printerName, ev.pushToken));
      subs.current.set(printerId, sub);
    } catch {
      /* older expo-widgets / push disabled — foreground updates still work */
    }
  };

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
          if (pool[i]) {
            instances.current.set(e.printerId, pool[i]);
            wirePush(e.printerId, e.printerName, pool[i]);
          }
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
          subs.current.get(e.printerId)?.remove();
          subs.current.delete(e.printerId);
        }
        continue;
      }

      // Live, no card yet -> start one for this printer (deep links back into the app).
      if (isLive(e.vm) && !inst) {
        try {
          const ni = printActivity.start(next, 'bambu://');
          instances.current.set(e.printerId, ni);
          lastState.current.set(e.printerId, next);
          lastPush.current.set(e.printerId, now);
          wirePush(e.printerId, e.printerName, ni);
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entries, pushUrl, apiKey]);
}
