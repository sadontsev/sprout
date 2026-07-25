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
  /** Present for 'lookup': Bambu's public HMS page for this code. */
  url?: string;
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
export interface AlertCaps {
  /** The printer is reachable; without this NO control action can succeed. */
  connected: boolean;
  /** Control endpoints accept the app's credentials (Bambuddy's scoped key covers print control). */
  canControl: boolean;
}

// Bambu publishes a lookup page per HMS code; deep-linking it beats us inventing explanations for
// codes we've never seen. Format is the dashed code, lowercase.
const hmsUrl = (dashed: string) => `https://wiki.bambulab.com/en/x1/troubleshooting/hmscode/${dashed.toLowerCase()}`;

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

export function presentAlerts(status: PrinterStatus | null, caps: AlertCaps): AlertVM[] {
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
      detail: status.print_error
        ? `The printer reported error ${status.print_error}. Check the machine before continuing.`
        : 'The printer stopped with an error. Check the machine before continuing.',
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
    if (dashed) actions.push({ id: 'lookup', label: 'What is this?', url: hmsUrl(dashed) });
    // One clear covers every notice, so only offer it on the first row.
    if (canAct && i === 0) actions.push({ id: 'clearHms', label: hms.length > 1 ? `Dismiss all (${hms.length})` : 'Dismiss' });
    out.push({
      id: `hms-${dashed ?? i}`,
      level: sev?.level ?? 'warning',
      title: sev ? `${sev.label} notice` : 'Printer notice',
      detail: dashed
        ? 'The printer raised a health notice. It keeps printing unless it also paused.'
        : 'The printer raised a health notice with no code attached.',
      code: dashed ?? undefined,
      actions,
    });
  });

  return out;
}
