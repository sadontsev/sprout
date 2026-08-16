import { useEffect, useMemo, useRef, useState } from 'react';
import type { BambuddyClient } from '@/api/bambuddyClient';
import type { PrinterStatus } from '@/api/types';
import { globalTrayId } from '@/ams/units';
import { estimateAmbient, parseBedHistory, presentCooldown, type BedSample, type CooldownVM } from './present';

/** How often to refresh the cooling curve while the plate is actually cooling. */
const CURVE_POLL_MS = 60_000;
/** Hours of curve to pull — long enough to cover a whole cooldown plus the print that preceded it. */
const CURVE_HOURS = 3;
/** Hours used to read room temperature off the idle floor, and how often to redo it. Refreshed
 *  rarely: it is a property of the room, not of the print. */
const AMBIENT_HOURS = 24;
const AMBIENT_REFRESH_MS = 30 * 60_000;

const isPrinting = (state: string | undefined): boolean => ['RUNNING', 'PAUSE', 'PAUSED', 'PREPARE', 'SLICING'].includes((state || '').toUpperCase());

/** Live plate-cooldown state for the dashboard.
 *
 *  Seeds from the server's stored curve rather than only watching live readings, so opening the app
 *  halfway through a cooldown still gets a rate and an ETA instead of starting from nothing. */
export function useCooldown(client: BambuddyClient, printerId: number, status: PrinterStatus | null): CooldownVM {
  const [curve, setCurve] = useState<BedSample[]>([]);
  const [ambientC, setAmbientC] = useState<number | null>(null);
  const printing = isPrinting(status?.state);
  const bedC = status?.temperatures?.bed ?? null;

  // Room temperature: the low percentile of idle bed readings over a long window.
  useEffect(() => {
    let alive = true;
    const load = () =>
      client
        .sensorHistory(printerId, 'bed', AMBIENT_HOURS)
        .then((h) => {
          if (!alive) return;
          const temps = parseBedHistory(h).map((s) => s.c);
          setAmbientC(estimateAmbient(temps));
        })
        .catch(() => {});
    load();
    const t = setInterval(load, AMBIENT_REFRESH_MS);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [client, printerId]);

  // The cooling curve. Only polled while there is a cooldown to track — no point pulling history
  // for a printer that is mid-print or has been cold for hours.
  const active = !printing && typeof bedC === 'number' && bedC > 0;
  useEffect(() => {
    if (!active) {
      setCurve([]);
      return;
    }
    let alive = true;
    const load = () =>
      client
        .sensorHistory(printerId, 'bed', CURVE_HOURS)
        .then((h) => alive && setCurve(parseBedHistory(h)))
        .catch(() => {});
    load();
    const t = setInterval(load, CURVE_POLL_MS);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [client, printerId, active]);

  // The stored curve lags by up to a minute, so fold in the live reading. Without this the plateau
  // detector could see a stale flat tail and call a still-falling plate "settled".
  const liveRef = useRef<BedSample[]>([]);
  useEffect(() => {
    if (!active || typeof bedC !== 'number') {
      liveRef.current = [];
      return;
    }
    const now = Date.now();
    liveRef.current = [...liveRef.current.filter((s) => now - s.t < CURVE_HOURS * 3600_000), { t: now, c: bedC }];
  }, [active, bedC]);

  return useMemo(
    () =>
      presentCooldown({
        printing,
        bedC,
        nozzleC: status?.temperatures?.nozzle ?? null,
        ambientC,
        samples: [...curve, ...liveRef.current],
        material: activeMaterial(status),
      }),
    [printing, bedC, ambientC, curve, status],
  );
}

/** Filament in the tray the printer was last using. Wording only — it never moves the threshold,
 *  which is just as well, because this is absent for an external spool and singular for a
 *  multi-material print. */
function activeMaterial(status: PrinterStatus | null): string | null {
  const now = status?.tray_now;
  if (typeof now !== 'number' || now === 255) return null;
  for (const unit of status?.ams ?? []) {
    for (const tray of unit.tray ?? []) {
      if (globalTrayId(unit.id, tray.id) === now) return tray.tray_type ?? null;
    }
  }
  return null;
}
