import type { SensorHistory } from '@/api/types';

/** When is the plate cool enough to take the print off?
 *
 *  The one number any vendor actually publishes is Bambu's own, for the Textured PEI plate:
 *  "we always recommend waiting until it reaches 35℃ or lower", stated for the HEATBED — which is
 *  exactly the sensor we read (PrinterStatus.temperatures.bed). Everything else in circulation is
 *  either a bed SETPOINT (55-80°C, a different quantity entirely) or an unsourced extrapolation.
 *
 *  Two traps this module exists to avoid:
 *
 *  1. A threshold at or below room temperature can NEVER be reached — a passively cooling plate
 *     approaches ambient asymptotically and cannot cross it. Picking a "safely cool" 25°C would mean
 *     the notification silently never fires. This office sits around 28°C, so even 35°C is only a
 *     few degrees of headroom. Hence `stalled`: when the plate has levelled off, or the measured
 *     room is already at the target, we say so instead of waiting forever for a number that will
 *     never arrive.
 *  2. Glass transition is a poor predictor of release (PLA releases ~25°C below Tg, PETG can stay
 *     welded to smooth PEI 45°C below it, and TPU has no Tg above room temperature at all). So there
 *     is no per-material threshold table here on purpose. Material only ever changes the WORDING.
 */

/** Bambu's published figure for the textured PEI plate. */
export const COOLDOWN_DEFAULT_C = 35;
/** Below this the threshold starts colliding with room temperature and may never be reached. */
export const COOLDOWN_MIN_C = 30;
/** Burn ceiling. EN ISO 13732-1 puts the 1-minute contact threshold for bare metal at ~51°C; you
 *  grip the steel plate for several seconds to flex it, so cap well under that. */
export const COOLDOWN_MAX_C = 45;
/** Above this the hotend is worth a warning — it never blocks "ready", since the plate is what you
 *  touch and it cools far slower than the nozzle. */
export const NOZZLE_CAUTION_C = 50;
/** Plateau detector: less than this much fall across the window means it has stopped cooling. */
export const PLATEAU_WINDOW_MIN = 10;
export const PLATEAU_DELTA_C = 1.0;

export type CooldownPhase = 'none' | 'cooling' | 'ready' | 'stalled';

/** One bed-temperature reading. `t` is epoch milliseconds. */
export interface BedSample {
  t: number;
  c: number;
}

export interface CoolingFit {
  /** Room temperature the plate is decaying toward. MEASURED (estimateAmbient), never fitted. */
  ambientC: number;
  /** Newton cooling constant, per minute. */
  kPerMin: number;
}

export interface CooldownVM {
  phase: CooldownPhase;
  bedC: number;
  thresholdC: number;
  /** Minutes until the threshold. null when unknown or unreachable. */
  etaMin: number | null;
  ambientC: number | null;
  label: string;
  detail: string;
  /** 0..1, from the bed's peak down to the threshold. Drives a progress bar. */
  progress: number;
  tone: 'hot' | 'warm' | 'ready';
  /** Material-specific warning, when the material is known. */
  caution: string | null;
}

/** Keep a user-supplied threshold inside the defensible band. Anything outside is either
 *  unreachable (too low) or hot enough to hurt (too high). */
export function clampThreshold(c: unknown): number {
  const n = typeof c === 'string' ? Number(c) : c;
  if (typeof n !== 'number' || !isFinite(n)) return COOLDOWN_DEFAULT_C;
  return Math.min(COOLDOWN_MAX_C, Math.max(COOLDOWN_MIN_C, n));
}

const asC = (v: unknown): number | null => {
  const n = typeof v === 'string' ? Number(v) : v;
  return typeof n === 'number' && isFinite(n) ? n : null;
};

/** Clean, sorted, de-duplicated samples. The WebSocket can deliver numbers as strings, and the
 *  history endpoint can return points out of order after a backfill. */
export function normalizeSamples(raw: Array<{ t: unknown; c: unknown }> | null | undefined): BedSample[] {
  const out: BedSample[] = [];
  for (const s of raw ?? []) {
    const t = asC(s?.t);
    const c = asC(s?.c);
    if (t != null && c != null) out.push({ t, c });
  }
  out.sort((a, b) => a.t - b.t);
  return out.filter((s, i) => i === 0 || s.t !== out[i - 1].t);
}

/** Turn a sensor-history response into samples.
 *
 *  Bambuddy timestamps are NAIVE and expressed in UTC ("2026-08-01T11:57:57", no zone marker).
 *  JavaScript parses a bare datetime like that as LOCAL time, which silently shifts the entire
 *  curve by the UTC offset — an hour here — corrupting every rate, ETA and plateau check while
 *  looking perfectly plausible. So the zone is appended explicitly unless one is already present. */
export function parseBedHistory(h: SensorHistory | null | undefined): BedSample[] {
  const pts = h?.series?.[0]?.data ?? [];
  const out: Array<{ t: unknown; c: unknown }> = [];
  for (const p of pts) {
    const raw = p?.recorded_at;
    if (typeof raw !== 'string' || !raw) continue;
    const iso = /([zZ]|[+-]\d\d:?\d\d)$/.test(raw) ? raw : `${raw}Z`;
    out.push({ t: Date.parse(iso), c: p?.value });
  }
  return normalizeSamples(out);
}

/** Trailing window used to measure the CURRENT decay rate. */
export const RATE_WINDOW_MIN = 20;
/** Only offer a time estimate once the bed is within this much of the threshold.
 *
 *  Measured against a real 89-minute cooldown: with a known ambient the estimate lands within ~6
 *  minutes of truth from 45°C down, but runs 27-45% optimistic while the plate is above 50°C.
 *  Real plate cooling is not a single exponential — plate, chamber and room have different time
 *  constants — so an early extrapolation always runs fast. Rather than show a number we know is
 *  wrong by half, we show none until the horizon is short enough to be honest. */
export const ETA_MAX_LEAD_C = 10;

/** Room temperature, MEASURED rather than inferred: between prints the plate always settles to
 *  ambient, so the low percentile of idle bed readings over a long window is the room.
 *
 *  This replaces solving for ambient from the cooling curve itself, which sounds elegant and does
 *  not work. Fitted against the real measured cooldown it returned 39.9°C for a 28.5°C room while
 *  the plate was still at 56°C — which would have declared the plate "as cool as it will get" less
 *  than ten minutes after the print ended. The curve simply does not identify its own asymptote
 *  early on; the idle floor does, directly.
 *
 *  Takes the 5th percentile rather than the minimum so one cold night or one bad reading cannot
 *  drag the estimate down. */
export function estimateAmbient(temps: Array<number | null | undefined>, pct = 0.05): number | null {
  const s = temps.filter((n): n is number => typeof n === 'number' && isFinite(n) && n > 0).sort((a, b) => a - b);
  // A handful of readings cannot establish a floor; this wants hours of history.
  if (s.length < 60) return null;
  const v = s[Math.min(s.length - 1, Math.floor(s.length * pct))];
  return v >= 0 && v <= 45 ? v : null;
}

/** The plate's CURRENT decay rate, given a known ambient. One free parameter instead of two, so it
 *  is well conditioned even against whole-degree readings: regress ln(T − ambient) on time.
 *
 *  Deliberately uses only a trailing window — k is not constant across a real cooldown (it fell
 *  from 0.038 to 0.021 over 89 measured minutes), and what matters for a short extrapolation is how
 *  fast the plate is losing heat NOW. */
export function fitDecayRate(samples: BedSample[], ambientC: number, nowMs: number): number | null {
  const win = samples.filter((s) => nowMs - s.t <= RATE_WINDOW_MIN * 60000);
  if (win.length < 5) return null;
  const spanMin = (win[win.length - 1].t - win[0].t) / 60000;
  if (!(spanMin >= 5)) return null;

  const t0 = win[0].t;
  let sx = 0;
  let sy = 0;
  let sxx = 0;
  let sxy = 0;
  for (const s of win) {
    // Readings at or below ambient carry no rate information and break the logarithm.
    if (s.c - ambientC <= 0.5) return null;
    const x = (s.t - t0) / 60000;
    const y = Math.log(s.c - ambientC);
    sx += x;
    sy += y;
    sxx += x * x;
    sxy += x * y;
  }
  const n = win.length;
  const denom = n * sxx - sx * sx;
  if (Math.abs(denom) < 1e-9) return null;
  const slope = (n * sxy - sx * sy) / denom;
  const k = -slope;
  return isFinite(k) && k > 0 ? k : null;
}

/** Minutes until the bed reaches `thresholdC`. null whenever we cannot say honestly. */
export function etaToThreshold(fit: CoolingFit | null, bedC: number, thresholdC: number): number | null {
  if (bedC <= thresholdC) return 0;
  if (!fit) return null;
  // A plate approaches ambient asymptotically and cannot cross it: if the room is warmer than the
  // threshold, no amount of waiting gets there.
  if (fit.ambientC >= thresholdC) return null;
  // Too far out to extrapolate honestly — see ETA_MAX_LEAD_C.
  if (bedC > thresholdC + ETA_MAX_LEAD_C) return null;
  const mins = Math.log((bedC - fit.ambientC) / (thresholdC - fit.ambientC)) / fit.kPerMin;
  if (!isFinite(mins) || mins < 0) return null;
  return Math.min(600, mins);
}

/** Has the plate stopped falling? Looks only at the trailing window. */
export function hasPlateaued(samples: BedSample[], nowMs: number): boolean {
  const win = samples.filter((s) => nowMs - s.t <= PLATEAU_WINDOW_MIN * 60000);
  if (win.length < 3) return false;
  // The window must actually span the period — three samples in ten seconds prove nothing.
  if ((win[win.length - 1].t - win[0].t) / 60000 < PLATEAU_WINDOW_MIN * 0.8) return false;
  const temps = win.map((s) => s.c);
  return Math.max(...temps) - Math.min(...temps) < PLATEAU_DELTA_C;
}

/** Material-specific caution. Never changes the threshold — only what we say about it.
 *  Matches on a substring so "PLA-CF", "PETG HF" and "Bambu ABS" all land correctly. */
export function materialCaution(material: string | null | undefined): string | null {
  const m = (material || '').toUpperCase();
  if (!m) return null;
  if (m.includes('TPU')) return 'TPU never pops off on its own — lift a corner and let isopropyl wick underneath.';
  if (m.includes('ABS') || m.includes('ASA') || m.includes('PC') || m.startsWith('PA') || m.includes('NYLON'))
    return 'Keep the door shut until the chamber cools too, or the part can warp as it contracts.';
  if (m.includes('PETG')) return 'PETG can bond hard to smooth PEI — on a smooth plate, ease it off rather than forcing it.';
  return null;
}

/** Rounded to 5-minute steps above 10 minutes: measured against a real cooldown the estimate is
 *  good to about ±6 min, so "about 35 min" is honest where "34 min" would be false precision. */
const fmtMin = (m: number): string => {
  let r = Math.round(m);
  if (r >= 10) r = Math.round(r / 5) * 5;
  if (r <= 1) return 'under a minute';
  if (r < 60) return `about ${r} min`;
  const h = Math.floor(r / 60);
  const rem = r % 60;
  return rem ? `about ${h} h ${rem} min` : `about ${h} h`;
};

export interface CooldownInput {
  /** True while the printer is actually printing — cooling is meaningless then. */
  printing: boolean;
  bedC: number | null | undefined;
  nozzleC?: number | null;
  thresholdC?: number;
  samples?: BedSample[];
  /** Room temperature, MEASURED (see estimateAmbient). Without it there is no ETA — but every
   *  other part of the readout still works, because they rely on observation, not prediction. */
  ambientC?: number | null;
  /** Active filament, for wording only. */
  material?: string | null;
  nowMs?: number;
}

/** The single source of truth for "is the plate cool enough yet". Pure: same inputs, same answer. */
export function presentCooldown(input: CooldownInput): CooldownVM {
  const thresholdC = clampThreshold(input.thresholdC);
  const bedC = asC(input.bedC);
  const nowMs = input.nowMs ?? Date.now();
  const samples = normalizeSamples(input.samples);
  const caution = materialCaution(input.material);

  const none = (): CooldownVM => ({
    phase: 'none',
    bedC: bedC ?? 0,
    thresholdC,
    etaMin: null,
    ambientC: null,
    label: '',
    detail: '',
    progress: 0,
    tone: 'hot',
    caution: null,
  });

  // A bed reading of 0 means "no data" far more often than "the plate is frozen" — temperatures is
  // nullable and missing fields round to 0 upstream.
  if (input.printing || bedC == null || bedC <= 0) return none();

  const ambientC = asC(input.ambientC);
  const kPerMin = ambientC != null ? fitDecayRate(samples, ambientC, nowMs) : null;
  const fit: CoolingFit | null = ambientC != null && kPerMin != null ? { ambientC, kPerMin } : null;
  const etaMin = etaToThreshold(fit, bedC, thresholdC);
  const peak = samples.length ? Math.max(bedC, ...samples.map((s) => s.c)) : bedC;
  const progress = peak > thresholdC ? Math.min(1, Math.max(0, (peak - bedC) / (peak - thresholdC))) : 1;

  const nozzleC = asC(input.nozzleC);
  const hotNozzle = nozzleC != null && nozzleC > NOZZLE_CAUTION_C;
  const nozzleNote = hotNozzle ? ` The nozzle is still at ${Math.round(nozzleC as number)}°C.` : '';

  if (bedC <= thresholdC) {
    return {
      phase: 'ready',
      bedC,
      thresholdC,
      etaMin: 0,
      ambientC,
      label: 'Plate is cool',
      // Deliberately "safe to flex", not "it has popped off" — plenty of prints stay stuck at room
      // temperature, and over-promising invites someone to force it and tear the PEI coating.
      detail: `Bed at ${Math.round(bedC)}°C — safe to flex the plate and lift the print off.${nozzleNote}`,
      progress: 1,
      tone: 'ready',
      caution,
    };
  }

  // Stalled: it stopped falling, or the MEASURED room is already at/above the target so it never
  // can. Both are observations — nothing here is extrapolated.
  const stalled = hasPlateaued(samples, nowMs) || (ambientC != null && ambientC >= thresholdC);
  if (stalled) {
    const room = ambientC != null ? ` The room is around ${Math.round(ambientC)}°C.` : '';
    return {
      phase: 'stalled',
      bedC,
      thresholdC,
      etaMin: null,
      ambientC,
      label: 'As cool as it will get',
      detail: `Bed has settled at ${Math.round(bedC)}°C and is no longer dropping.${room} Go ahead and flex the plate.${nozzleNote}`,
      progress,
      tone: 'warm',
      caution,
    };
  }

  return {
    phase: 'cooling',
    bedC,
    thresholdC,
    etaMin,
    ambientC,
    label: 'Plate cooling',
    detail:
      etaMin == null
        ? `Bed at ${Math.round(bedC)}°C, heading for ${thresholdC}°C.`
        : `Bed at ${Math.round(bedC)}°C — ${fmtMin(etaMin)} until it is easy to remove.`,
    progress,
    tone: bedC > thresholdC + 15 ? 'hot' : 'warm',
    caution,
  };
}
