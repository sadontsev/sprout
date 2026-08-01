import { useEffect, useRef } from 'react';
import { addPushToStartTokenListener } from 'expo-widgets';
import { Platform } from 'react-native';
import { printActivity } from './PrintActivity';
import { toContentState, toDryContentState, dryingUnitIds, meaningfulChange, GENERIC_END, type PrintActivityProps, type LiveActivityExtras } from './contentState';
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
function registerPushToken(pushUrl: string, apiKey: string, printerId: number, printerName: string, pushToken: string, kind: 'print' | 'dry' = 'print', amsId?: number): void {
  if (!pushToken) return;
  // X-API-Key gates la-push registration to holders of the Bambuddy key, so a stranger who knows the
  // URL can't register their token and receive this printer's notifications.
  fetch(`${pushUrl.replace(/\/+$/, '')}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'X-API-Key': apiKey },
    // ams_id keys the drying card per UNIT server-side (dry:<pid>:<amsId>); omitted for print cards.
    body: JSON.stringify({ printer_id: printerId, push_token: pushToken, printer_name: printerName, icon_uri: nozzleIconUri(), kind, ...(amsId != null ? { ams_id: amsId } : {}) }),
  }).catch(() => {});
}

/**
 * Live Activities, with EXACTLY ONE OWNER of every card.
 *
 * The old design had two independent producers — this hook started cards locally AND la-push
 * push-to-started them — with nothing able to reconcile the two, because expo-widgets exposes no id
 * and no content on an adopted activity (see getInstances(): you get an opaque handle). That produced
 * all three reported failures at once: duplicate cards for one print, cards frozen at 0% that nobody
 * owned, and local-vs-remote cards rendering different colours/icons.
 *
 * Ownership is now decided by MODE, so a conflict cannot arise:
 *
 *   SERVER mode (a la-push URL is configured) — la-push owns every card: it starts them (push-to-
 *   start), updates them, and ends them. This hook NEVER calls start(). Its only jobs are to hand
 *   over the device's push-to-start token and to RECONCILE: enumerate the live activities, read each
 *   one's push token (the only identity an adopted card exposes), and offer it to la-push. la-push
 *   either recognises it, binds it to the card it just remote-started (this is what un-freezes a
 *   stuck card), or disowns it — and a disowned card is ended here. Cards therefore converge to
 *   exactly the set la-push believes in.
 *
 *   LOCAL mode (no la-push) — this hook owns every card, exactly as before: start on live, throttled
 *   updates, end on terminal. No server, no push, no reconciliation needed.
 *
 * Tradeoff, deliberately taken: in server mode a card appears on la-push's next poll (<=5s) rather
 * than instantly, and if la-push is down there is no card at all. Predictable beats partially-working
 * — the previous "both try" behaviour is precisely what produced duplicates and zombies.
 *
 * offline/connecting remain no-ops so a WS blip never kills a card mid-print; only complete/error/idle
 * ends one.
 */
export function usePrinterActivities(entries: ActivityEntry[], pushUrl?: string | null, apiKey?: string) {
  const instances = useRef(new Map<number, LiveActivity<PrintActivityProps>>());
  const lastPush = useRef(new Map<number, number>());
  const lastState = useRef(new Map<number, PrintActivityProps>());
  // Keyed by STRING so print ('<pid>') and drying ('<pid>:<amsId>') cards share one shape.
  const subs = useRef(new Map<string, { remove: () => void }>());
  const adopted = useRef(false);
  // Drying cards: one per DRYING UNIT, on top of the print card (they run simultaneously). Keyed
  // "<printerId>:<amsId>" — three drying-capable units are fitted, so two concurrent cycles are
  // ordinary, and a per-printer key showed only the first while the second silently never appeared.
  const dryInstances = useRef(new Map<string, LiveActivity<PrintActivityProps>>());
  const dryLastPush = useRef(new Map<string, number>());
  const dryLastState = useRef(new Map<string, PrintActivityProps>());
  const drySubs = useRef(new Map<string, { remove: () => void }>());

  // Grab the card's APNs push token (now + on rotation) and register it with la-push.
  const wirePush = (printerId: number, printerName: string, inst: LiveActivity<PrintActivityProps>, kind: 'print' | 'dry' = 'print', amsId?: number) => {
    const sm = kind === 'dry' ? drySubs : subs;
    const key = kind === 'dry' ? `${printerId}:${amsId}` : String(printerId);
    if (!pushUrl || !apiKey || sm.current.has(key)) return;
    try {
      inst.getPushToken().then((tok) => tok && registerPushToken(pushUrl, apiKey, printerId, printerName, tok, kind, amsId)).catch(() => {});
      const sub = inst.addPushTokenListener((ev) => registerPushToken(pushUrl, apiKey, printerId, printerName, ev.pushToken, kind, amsId));
      sm.current.set(key, sub);
    } catch {
      /* older expo-widgets / push disabled — foreground updates still work */
    }
  };

  const serverMode = !!(pushUrl && apiKey);

  /**
   * Tell la-push exactly which cards exist, and act on what it can't account for.
   *
   * This has to be the FULL set, not one token at a time: APNs answers 200 for a card the user has
   * swiped away, so la-push cannot detect a dismissal on its own — it kept believing it owned a card
   * that was gone, and refused to start a replacement. The app is the only party that can see the
   * truth, so it reports all of it and the server converges: forget vanished cards, bind an unknown
   * token to a card it just remote-started (what makes a frozen card updatable), and hand back
   * anything nothing accounts for, which we end here.
   */
  const reconcile = async () => {
    if (!serverMode) return;
    let list: LiveActivity<PrintActivityProps>[] = [];
    try {
      list = printActivity.getInstances();
    } catch {
      return; // Expo Go / no native module
    }
    const byToken = new Map<string, LiveActivity<PrintActivityProps>>();
    for (const inst of list) {
      try {
        const tok = await inst.getPushToken();
        if (tok) byToken.set(tok, inst); // no token yet -> next pass picks it up
      } catch {
        /* one bad instance must not abort the sweep */
      }
    }
    try {
      const res = await fetch(`${pushUrl!.replace(/\/+$/, '')}/sync`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'X-API-Key': apiKey! },
        body: JSON.stringify({ tokens: [...byToken.keys()], icon_uri: nozzleIconUri() }),
      });
      if (!res.ok) return; // la-push unreachable -> leave every card alone; never destroy on doubt
      const { end = [] } = (await res.json()) as { end?: string[] };
      for (const tok of end) await byToken.get(tok)?.end('immediate', GENERIC_END, new Date()).catch(() => {});
    } catch {
      /* offline -> try again on the next pass */
    }
  };

  // Re-reconcile periodically while the app is open: a card la-push starts while we're running only
  // becomes updatable once we hand over its token, and tokens can rotate.
  useEffect(() => {
    if (!serverMode) return;
    const id = setInterval(() => void reconcile(), 45_000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverMode, pushUrl, apiKey]);

  // Push-to-start: register the DEVICE's start token so la-push can CREATE cards with the app
  // closed — a print or drying cycle started from Studio / the printer screen / the queue raises a
  // lock-screen card without the app ever being opened (iOS 17.2+). The native module emits the
  // current token as soon as the listener attaches, then again on rotation.
  useEffect(() => {
    if (Platform.OS !== 'ios' || !pushUrl || !apiKey) return;
    let sub: { remove: () => void } | undefined;
    try {
      sub = addPushToStartTokenListener((ev) => {
        const tok = ev.activityPushToStartToken;
        if (!tok) return;
        fetch(`${pushUrl.replace(/\/+$/, '')}/register-start`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', 'X-API-Key': apiKey },
          // Hand over the App-Group glyph path too: la-push has no way to know it, so without this
          // remotely-started cards render the SF-symbol fallback while app-started ones show the
          // brand nozzle — the visual tell that gave this whole bug away.
          body: JSON.stringify({ push_token: tok, icon_uri: nozzleIconUri() }),
        }).catch(() => {});
      });
    } catch {
      /* older native module — remote start unavailable; everything else still works */
    }
    return () => sub?.remove();
  }, [pushUrl, apiKey]);

  useEffect(() => {
    if (Platform.OS !== 'ios') return;

    // SERVER mode: la-push owns every card. Reconcile instead of starting anything.
    if (serverMode) {
      if (!adopted.current) {
        adopted.current = true;
        void reconcile();
      }
      return;
    }

    // LOCAL mode: this hook owns every card. Sweep anything left from a previous launch (it can't be
    // identified, and nothing else will ever end it), then rebuild below from live state.
    if (!adopted.current) {
      adopted.current = true;
      try {
        printActivity.getInstances().forEach((inst) => inst.end('immediate', GENERIC_END, new Date()).catch(() => {}));
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
          subs.current.get(String(e.printerId))?.remove();
          subs.current.delete(String(e.printerId));
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

    // ---- Drying cards: one per unit, lifecycle driven by that unit's ams.dry_time (>0 = active). ----
    const liveDryKeys = new Set<string>();
    for (const e of entries) {
      if (!e.status) continue;
      for (const amsId of dryingUnitIds(e.status)) {
        const key = `${e.printerId}:${amsId}`;
        liveDryKeys.add(key);
        const dcs = toDryContentState(e.status, now, nozzleIconUri(), e.printerName, amsId);
        if (!dcs) continue;
        const dinst = dryInstances.current.get(key);
        if (!dinst) {
          try {
            const ni = printActivity.start(dcs, 'bambu://');
            dryInstances.current.set(key, ni);
            dryLastState.current.set(key, dcs);
            dryLastPush.current.set(key, now);
            wirePush(e.printerId, e.printerName, ni, 'dry', amsId);
          } catch {
            /* disabled by user / not a dev build */
          }
          continue;
        }
        const due = now - (dryLastPush.current.get(key) ?? 0) >= MIN_UPDATE_MS;
        if (due && meaningfulChange(dryLastState.current.get(key) ?? null, dcs)) {
          dinst.update(dcs).catch(() => {});
          dryLastState.current.set(key, dcs);
          dryLastPush.current.set(key, now);
        }
      }
    }
    // Any card whose unit is no longer drying -> end it with a Done face. Driven by set difference
    // rather than per-entry, so a unit that vanishes from the payload entirely is still cleaned up.
    for (const key of [...dryInstances.current.keys()]) {
      if (liveDryKeys.has(key)) continue;
      const inst = dryInstances.current.get(key)!;
      inst.end('default', { ...(dryLastState.current.get(key) ?? GENERIC_END), dry: true, stateLabel: 'Done', finished: true, etaEpochMs: 0 }, new Date(now)).catch(() => {});
      dryInstances.current.delete(key);
      dryLastState.current.delete(key);
      dryLastPush.current.delete(key);
      drySubs.current.get(key)?.remove();
      drySubs.current.delete(key);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entries, pushUrl, apiKey]);
}
