// Pure: printer status -> the list of things demanding attention, each carrying ONLY the actions that
// are actually possible right now.
//
// The guiding rule (the owner's): never offer an action the printer/permissions can't currently take.
// A "Resume" button on a printer that isn't paused, or on one that's offline, is worse than no button
// — it teaches you not to trust the screen. So every action is gated on observed state, and anything
// we can't verify is simply not offered.
import { fmtHmsCode } from '../dashboard/present';
import type { PrinterStatus } from '../api/types';

export type AlertLevel = 'error' | 'warning' | 'info';

export type AlertActionId =
  | 'resume' // continue a paused print (problem fixed / intentional pause)
  | 'stop' // cancel the job
  | 'clearHms' // dismiss the printer's HMS notices
  | 'plateCleared' // confirm the bed is clear so the queue can dispatch
  | 'lookup'; // open Bambu's HMS reference for this exact code

export interface AlertActionVM {
  id: AlertActionId;
  label: string;
  /** Irreversible or job-ending — the UI confirms these first. */
  destructive?: boolean;
  /** Present for 'lookup': ordered candidate pages for this code, most likely first. The LAST entry
   *  is Bambu's searchable index and always resolves, so the caller can open the first that works. */
  urls?: string[];
}

export interface AlertVM {
  /** Stable across polls so the list doesn't churn while a print runs. */
  id: string;
  level: AlertLevel;
  title: string;
  detail: string;
  /** Formatted HMS code, when this alert came from one. */
  code?: string;
  actions: AlertActionVM[];
}

/** What the app is currently allowed/able to do — actions are filtered through this. */
/** Looks up Bambu's own text for a code. Injected so presentAlerts stays pure — see hmsCatalog.ts. */
export interface AlertDescribe {
  hms?: (code: string) => string | null;
  printError?: (err: number | string) => string | null;
}

export interface AlertCaps {
  /** The printer is reachable; without this NO control action can succeed. */
  connected: boolean;
  /** Control endpoints accept the app's credentials (Bambuddy's scoped key covers print control). */
  canControl: boolean;
  /** Machine model ("H2C") — picks the right wiki family for code lookups. */
  model?: string | null;
}

// Bambu's wiki has a page per HMS code, but the path is PER MODEL FAMILY and each family has its own
// code namespace — verified live: 0C00_0100_0002_0017 is 200 under /h2/ and 404 under /x1/, while
// 0300_0D00_0001_0003 is the exact reverse. The path also uses UNDERSCORES, not the dashes the code is
// displayed with (the dashed form 404s everywhere; case is tolerated).
//
// So we can't know the right page from the code alone: build ordered candidates from the machine's
// model, then the other families, and finally the searchable index — which always exists. The caller
// opens the first that resolves.
const FAMILIES = ['h2', 'x1', 'p1', 'a1'] as const;

/** Wiki segment for a Bambuddy model string ("H2C" -> h2, "X1C" -> x1, "A1 mini" -> a1). */
export function wikiFamily(model?: string | null): string {
  const m = (model ?? '').trim().toUpperCase();
  if (m.startsWith('H2')) return 'h2';
  if (m.startsWith('X1')) return 'x1';
  if (m.startsWith('P1')) return 'p1';
  if (m.startsWith('A1')) return 'a1';
  return 'x1'; // the largest/legacy set is the least-bad guess for an unknown machine
}

/** Searchable index of every HMS code — the guaranteed-to-exist last resort. */
export const HMS_INDEX_URL = 'https://wiki.bambulab.com/en/hms/error-code';

function hmsUrls(dashed: string, model?: string | null): string[] {
  const code = dashed.replace(/-/g, '_');
  const first = wikiFamily(model);
  const ordered = [first, ...FAMILIES.filter((f) => f !== first)];
  return [...ordered.map((f) => `https://wiki.bambulab.com/en/${f}/troubleshooting/hmscode/${code}`), HMS_INDEX_URL];
}

/** Bambu's documented severity ladder. Anything outside it stays a neutral "Notice" rather than
 *  guessing a level we can't justify — some firmwares report values outside 1-4. */
const SEVERITY: Record<number, { level: AlertLevel; label: string }> = {
  1: { level: 'error', label: 'Fatal' },
  2: { level: 'error', label: 'Serious' },
  3: { level: 'warning', label: 'Common' },
  4: { level: 'info', label: 'Info' },
};

const num = (v: unknown): number | null => {
  const n = typeof v === 'number' ? v : Number(v ?? NaN);
  return Number.isFinite(n) ? n : null;
};

/** One-line rollup for the dashboard: how many, and how bad the worst one is. `null` = all clear,
 *  so the dashboard renders nothing at all rather than a reassuring-but-noisy "no alerts" row. */
export function alertSummary(alerts: AlertVM[]): { count: number; level: AlertLevel; label: string } | null {
  if (!alerts.length) return null;
  const level: AlertLevel = alerts.some((a) => a.level === 'error')
    ? 'error'
    : alerts.some((a) => a.level === 'warning')
      ? 'warning'
      : 'info';
  const actionable = alerts.filter((a) => a.actions.some((x) => x.id !== 'lookup')).length;
  const noun = alerts.length === 1 ? 'alert' : 'alerts';
  return {
    count: alerts.length,
    level,
    label: actionable > 0 ? `${alerts.length} ${noun} · ${actionable} actionable` : `${alerts.length} ${noun}`,
  };
}

export function presentAlerts(status: PrinterStatus | null, caps: AlertCaps, describe: AlertDescribe = {}): AlertVM[] {
  if (!status) return [];
  const out: AlertVM[] = [];
  const state = (status.state || '').toUpperCase();
  const paused = state === 'PAUSE' || state === 'PAUSED';
  // Control actions are pointless (and will just error) when the printer isn't reachable.
  const canAct = caps.connected && caps.canControl;

  // 1. A hard print failure. This is the one that ends a job, so it leads the list.
  if (status.print_error || state === 'FAILED' || state === 'ERROR') {
    out.push({
      id: 'print-error',
      level: 'error',
      title: 'Print error',
      detail:
        (status.print_error ? describe.printError?.(status.print_error) : null) ??
        (status.print_error
          ? `The printer reported error ${status.print_error}. Check the machine before continuing.`
          : 'The printer stopped with an error. Check the machine before continuing.'),
      actions: canAct
        ? [
            { id: 'resume', label: 'Resume' },
            { id: 'stop', label: 'Stop print', destructive: true },
          ]
        : [],
    });
  }

  // 2. Paused — the classic "I fixed it, carry on". Only offered when genuinely paused.
  if (paused) {
    out.push({
      id: 'paused',
      level: 'warning',
      title: 'Print paused',
      detail: 'Resume once the problem is fixed, or stop the job entirely.',
      actions: canAct
        ? [
            { id: 'resume', label: 'Resume print' },
            { id: 'stop', label: 'Stop print', destructive: true },
          ]
        : [],
    });
  }

  // 3. Queue blocked on a physical confirmation only the human can give.
  if (status.awaiting_plate_clear === true) {
    out.push({
      id: 'plate',
      level: 'info',
      title: 'Waiting for the plate',
      detail: 'The finished print has to come off the bed before the next job can start.',
      actions: canAct ? [{ id: 'plateCleared', label: 'Plate is clear' }] : [],
    });
  }

  // 4. HMS notices. These are NOT failures — the H2C emits benign ones mid-print — so they never
  //    claim the print is broken; they carry the code and a way to look it up.
  const hms = status.hms_errors ?? [];
  hms.forEach((h, i) => {
    const dashed = fmtHmsCode(h.full_code ?? h.code);
    const sev = SEVERITY[num(h.severity) ?? -1];
    const actions: AlertActionVM[] = [];
    if (dashed) actions.push({ id: 'lookup', label: 'What is this?', urls: hmsUrls(dashed, caps.model) });
    // One clear covers every notice, so only offer it on the first row.
    if (canAct && i === 0) actions.push({ id: 'clearHms', label: hms.length > 1 ? `Dismiss all (${hms.length})` : 'Dismiss' });
    out.push({
      id: `hms-${dashed ?? i}`,
      level: sev?.level ?? 'warning',
      title: sev ? `${sev.label} notice` : 'Printer notice',
      // Bambu's own words when we have them — "Threaded rods need lubrication now." beats any
      // sentence we could write. Falls back to severity-appropriate generic copy.
      detail:
        (dashed ? describe.hms?.(dashed) : null) ??
        (!dashed
          ? 'The printer raised a health notice with no code attached.'
          : sev?.level === 'error'
            ? 'The printer flagged a serious condition. Check the machine — look up the code for what it means.'
            : 'A health notice. The printer keeps going unless it also paused.'),
      code: dashed ?? undefined,
      actions,
    });
  });

  return out;
}
