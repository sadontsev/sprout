import {
  clampThreshold,
  estimateAmbient,
  etaToThreshold,
  fitDecayRate,
  hasPlateaued,
  materialCaution,
  normalizeSamples,
  parseBedHistory,
  presentCooldown,
  COOLDOWN_DEFAULT_C,
  COOLDOWN_MAX_C,
  COOLDOWN_MIN_C,
  ETA_MAX_LEAD_C,
  type BedSample,
} from '../present';
import { REAL_AMBIENT_C, REAL_COOLDOWN_C, REAL_READY_MIN } from '../fixtures/realCooldown';

const T0 = 1_800_000_000_000; // fixed epoch — these tests must not depend on the wall clock
const min = (n: number) => T0 + n * 60000;

/** Synthesise a Newton cooling curve: the exact physics the fit is supposed to recover. */
const curve = (startC: number, ambientC: number, kPerMin: number, minutes: number, stepMin = 1): BedSample[] => {
  const out: BedSample[] = [];
  for (let m = 0; m <= minutes; m += stepMin) out.push({ t: min(m), c: ambientC + (startC - ambientC) * Math.exp(-kPerMin * m) });
  return out;
};

describe('clampThreshold', () => {
  it('defaults to the one number Bambu actually publishes', () => {
    expect(COOLDOWN_DEFAULT_C).toBe(35);
    for (const bad of [undefined, null, NaN, Infinity, 'abc', {}]) expect(clampThreshold(bad as never)).toBe(35);
  });

  it('refuses a threshold below room temperature — it could never be reached', () => {
    expect(clampThreshold(25)).toBe(COOLDOWN_MIN_C);
    expect(clampThreshold(-5)).toBe(COOLDOWN_MIN_C);
  });

  it('refuses a threshold hot enough to burn — you grip the plate to flex it', () => {
    expect(clampThreshold(60)).toBe(COOLDOWN_MAX_C);
    expect(COOLDOWN_MAX_C).toBeLessThan(48); // EN ISO 13732-1: 48°C at 10 min contact on bare metal
  });

  it('passes through sane values, including numeric strings from the API', () => {
    expect(clampThreshold(40)).toBe(40);
    expect(clampThreshold('38')).toBe(38);
  });
});

describe('normalizeSamples', () => {
  it('coerces string temperatures — the WebSocket sends numbers as strings', () => {
    expect(normalizeSamples([{ t: min(0), c: '52.5' }])).toEqual([{ t: min(0), c: 52.5 }]);
  });

  it('sorts out-of-order points and drops duplicates and junk', () => {
    const s = normalizeSamples([
      { t: min(2), c: 50 },
      { t: min(0), c: 60 },
      { t: min(2), c: 50 },
      { t: min(1), c: null },
      { t: null, c: 40 },
    ]);
    expect(s).toEqual([{ t: min(0), c: 60 }, { t: min(2), c: 50 }]);
  });

  it('survives null/undefined input', () => {
    expect(normalizeSamples(null)).toEqual([]);
    expect(normalizeSamples(undefined)).toEqual([]);
  });
});

describe('estimateAmbient', () => {
  it('reads the room off the idle floor of a long history', () => {
    // Between prints the plate settles to ambient, so the low percentile IS the room.
    const week = [...Array(400)].map((_, i) => (i < 40 ? 60 - i : 28 + (i % 3)));
    expect(estimateAmbient(week)).toBeGreaterThanOrEqual(28);
    expect(estimateAmbient(week)).toBeLessThanOrEqual(30);
  });

  it('is robust to a single spurious cold reading — percentile, not minimum', () => {
    const week = [1, ...Array(200).fill(28)];
    expect(estimateAmbient(week)).toBe(28);
  });

  it('refuses to guess from too little history', () => {
    expect(estimateAmbient([28, 28, 28])).toBeNull();
    expect(estimateAmbient([])).toBeNull();
  });

  it('ignores junk and implausible values', () => {
    expect(estimateAmbient([...Array(200).fill(28), NaN, null, undefined, 0])).toBe(28);
    expect(estimateAmbient(Array(200).fill(90))).toBeNull(); // no room is 90°C
  });

  it('recovers the real room temperature from the real idle floor', () => {
    // The measured curve bottoms out near ambient; pad with settled idle readings as a week of
    // history would contain.
    const hist = [...REAL_COOLDOWN_C, ...Array(200).fill(29), ...Array(50).fill(28)];
    const a = estimateAmbient(hist)!;
    expect(a).toBeGreaterThan(25);
    expect(a).toBeLessThanOrEqual(REAL_AMBIENT_C + 1);
  });
});

describe('fitDecayRate', () => {
  it('recovers a known rate given the true ambient', () => {
    const k = fitDecayRate(curve(70, 28.5, 0.041, 20), 28.5, min(20));
    expect(k).toBeCloseTo(0.041, 3);
  });

  it('works against whole-degree readings — the printer never reports fractions', () => {
    const quantized = curve(70, 28.5, 0.041, 20).map((s) => ({ ...s, c: Math.round(s.c) }));
    const k = fitDecayRate(quantized, 28.5, min(20))!;
    expect(k).toBeGreaterThan(0.03);
    expect(k).toBeLessThan(0.055);
  });

  it('uses only the trailing window, so it tracks the CURRENT rate', () => {
    // Real cooling slows down: early k is much higher than late k.
    const s = REAL_COOLDOWN_C.map((c, m) => ({ t: min(m), c }));
    const early = fitDecayRate(s.slice(0, 21), REAL_AMBIENT_C, min(20))!;
    const late = fitDecayRate(s, REAL_AMBIENT_C, min(89))!;
    expect(early).toBeGreaterThan(late);
  });

  it('returns null rather than a bogus rate for thin, flat or sub-ambient data', () => {
    expect(fitDecayRate([], 28, min(0))).toBeNull();
    expect(fitDecayRate(curve(70, 28, 0.04, 3), 28, min(3))).toBeNull(); // window too short
    const flat = [0, 3, 6, 9, 12].map((m) => ({ t: min(m), c: 40 }));
    expect(fitDecayRate(flat, 28, min(12))).toBeNull(); // no slope
    const cold = [0, 3, 6, 9, 12].map((m) => ({ t: min(m), c: 28 }));
    expect(fitDecayRate(cold, 28, min(12))).toBeNull(); // at ambient: no information
  });

  it('ignores samples older than the rate window', () => {
    const s = [{ t: min(0), c: 70 }, ...[60, 63, 66, 69, 72].map((m) => ({ t: min(m), c: 40 - (m - 60) * 0.2 }))];
    expect(fitDecayRate(s, 28, min(72))).not.toBeNull();
  });
});

describe('etaToThreshold', () => {
  const fit = { ambientC: 28.5, kPerMin: 0.041 };

  it('is zero once the bed is already at or below the threshold', () => {
    expect(etaToThreshold(fit, 35, 35)).toBe(0);
    expect(etaToThreshold(fit, 30, 35)).toBe(0);
    expect(etaToThreshold(null, 20, 35)).toBe(0);
  });

  it('returns null — never a number — when the room is warmer than the threshold', () => {
    // A plate asymptotes to ambient and cannot cross it.
    expect(etaToThreshold({ ambientC: 36, kPerMin: 0.04 }, 44, 35)).toBeNull();
    expect(etaToThreshold({ ambientC: 35, kPerMin: 0.04 }, 44, 35)).toBeNull();
  });

  it('refuses to extrapolate from far away, where it would be ~40% optimistic', () => {
    expect(etaToThreshold(fit, 35 + ETA_MAX_LEAD_C + 1, 35)).toBeNull();
    expect(etaToThreshold(fit, 60, 35)).toBeNull();
    expect(etaToThreshold(fit, 35 + ETA_MAX_LEAD_C, 35)).not.toBeNull();
  });

  it('returns null when there is no rate to extrapolate with', () => {
    expect(etaToThreshold(null, 40, 35)).toBeNull();
  });

  it('shrinks monotonically as the plate cools', () => {
    const a = etaToThreshold(fit, 44, 35)!;
    const b = etaToThreshold(fit, 40, 35)!;
    const c = etaToThreshold(fit, 37, 35)!;
    expect(a).toBeGreaterThan(b);
    expect(b).toBeGreaterThan(c);
  });

  it('caps absurd extrapolations instead of promising a 40-hour wait', () => {
    expect(etaToThreshold({ ambientC: 34.9, kPerMin: 0.0001 }, 40, 35)).toBe(600);
  });

  it('ACCURACY against the real curve: within 8 minutes, every minute it speaks', () => {
    // Absolute error is the honest measure here. Relative error explodes near the end purely
    // because the denominator does (1 minute left), and the residual sawtooth is whole-degree
    // quantization: at bed=36°C the estimate cannot tell 36.0 from 36.9.
    const s = REAL_COOLDOWN_C.map((c, m) => ({ t: min(m), c }));
    let spoke = 0;
    let worst = 0;
    for (let t = 10; t < REAL_READY_MIN; t++) {
      const k = fitDecayRate(s.slice(0, t + 1), REAL_AMBIENT_C, min(t));
      const eta = etaToThreshold(k ? { ambientC: REAL_AMBIENT_C, kPerMin: k } : null, REAL_COOLDOWN_C[t], 35);
      if (eta == null) continue;
      spoke++;
      const truth = REAL_READY_MIN - t;
      worst = Math.max(worst, Math.abs(eta - truth));
      expect(Math.abs(eta - truth)).toBeLessThanOrEqual(8);
      // Over the longer waits, where a percentage is meaningful, it is well inside 25%.
      if (truth >= 15) expect(Math.abs(eta - truth) / truth).toBeLessThan(0.25);
    }
    expect(spoke).toBeGreaterThan(30); // and it speaks for most of the wait, not just the last minute
    expect(worst).toBeLessThanOrEqual(8);
  });

  it('stays silent until it can be accurate — no estimate above threshold + lead', () => {
    const s = REAL_COOLDOWN_C.map((c, m) => ({ t: min(m), c }));
    for (let t = 0; t < 25; t++) {
      const k = fitDecayRate(s.slice(0, t + 1), REAL_AMBIENT_C, min(t));
      expect(etaToThreshold(k ? { ambientC: REAL_AMBIENT_C, kPerMin: k } : null, REAL_COOLDOWN_C[t], 35)).toBeNull();
    }
  });
});

describe('hasPlateaued', () => {
  it('is true when the bed has barely moved across the whole window', () => {
    const flat: BedSample[] = [0, 3, 6, 9, 12].map((m) => ({ t: min(m), c: 37 - m * 0.02 }));
    expect(hasPlateaued(flat, min(12))).toBe(true);
  });

  it('is false while the bed is still falling meaningfully', () => {
    expect(hasPlateaued(curve(70, 28.5, 0.041, 12), min(12))).toBe(false);
  });

  it('needs the window actually spanned — three readings seconds apart prove nothing', () => {
    const burst: BedSample[] = [0, 0.1, 0.2].map((m) => ({ t: min(m), c: 37 }));
    expect(hasPlateaued(burst, min(0.2))).toBe(false);
  });

  it('ignores samples older than the window', () => {
    // Hot an hour ago, flat for the last 12 min -> still plateaued.
    const s: BedSample[] = [{ t: min(0), c: 70 }, ...[48, 51, 54, 57, 60].map((m) => ({ t: min(m), c: 37 }))];
    expect(hasPlateaued(s, min(60))).toBe(true);
  });

  it('is false with no samples', () => {
    expect(hasPlateaued([], min(10))).toBe(false);
  });
});

describe('materialCaution', () => {
  it('warns that TPU has no thermal release at all', () => {
    expect(materialCaution('TPU 95A')).toContain('isopropyl');
    expect(materialCaution('tpu')).toContain('isopropyl');
  });

  it('warns about warping for the enclosure materials, matching CF variants too', () => {
    for (const m of ['ABS', 'ASA', 'ABS-GF', 'PC', 'PA6-CF', 'PAHT-CF', 'Nylon'])
      expect(materialCaution(m)).toContain('warp');
  });

  it('warns about PETG bonding to smooth PEI', () => {
    expect(materialCaution('PETG-CF')).toContain('smooth PEI');
    expect(materialCaution('PETG HF')).toContain('smooth PEI');
  });

  it('says nothing for PLA or an unknown/absent material', () => {
    for (const m of ['PLA', 'PLA-CF', 'PLA Matte', '', null, undefined, 'MysteryBrand'])
      expect(materialCaution(m)).toBeNull();
  });
});

describe('presentCooldown', () => {
  const base = { printing: false, nowMs: min(20) };

  it('is inert while a print is running', () => {
    expect(presentCooldown({ ...base, printing: true, bedC: 70 }).phase).toBe('none');
  });

  it('is inert with no bed reading — 0 means "no data", not "frozen plate"', () => {
    expect(presentCooldown({ ...base, bedC: null }).phase).toBe('none');
    expect(presentCooldown({ ...base, bedC: 0 }).phase).toBe('none');
    expect(presentCooldown({ ...base, bedC: undefined }).phase).toBe('none');
  });

  it('reports READY at or below the threshold', () => {
    const vm = presentCooldown({ ...base, bedC: 34 });
    expect(vm.phase).toBe('ready');
    expect(vm.tone).toBe('ready');
    expect(vm.progress).toBe(1);
    expect(vm.etaMin).toBe(0);
    expect(vm.detail).toContain('34°C');
  });

  it('says "safe to flex", never "your print popped off" — prints do stay stuck when cold', () => {
    const d = presentCooldown({ ...base, bedC: 30 }).detail;
    expect(d).toMatch(/safe to flex/i);
    expect(d).not.toMatch(/popped|released itself|fell off/i);
  });

  it('reports COOLING with an ETA once close enough to predict honestly', () => {
    const s = REAL_COOLDOWN_C.slice(0, 46).map((c, m) => ({ t: min(m), c }));
    const vm = presentCooldown({ ...base, bedC: 40, ambientC: REAL_AMBIENT_C, samples: s, nowMs: min(45) });
    expect(vm.phase).toBe('cooling');
    expect(vm.etaMin).toBeGreaterThan(0);
    expect(vm.ambientC).toBe(REAL_AMBIENT_C);
    expect(vm.detail).toMatch(/min until/);
  });

  it('reports COOLING with NO time estimate while the plate is still far off', () => {
    const s = REAL_COOLDOWN_C.slice(0, 21).map((c, m) => ({ t: min(m), c }));
    const vm = presentCooldown({ ...base, bedC: 50, ambientC: REAL_AMBIENT_C, samples: s, nowMs: min(20) });
    expect(vm.phase).toBe('cooling');
    expect(vm.etaMin).toBeNull(); // would have been ~35% optimistic — say nothing instead
    expect(vm.detail).toContain('50°C');
    expect(vm.detail).not.toMatch(/min until/);
  });

  it('reports STALLED — not a fake ETA — when the MEASURED room is warmer than the threshold', () => {
    const vm = presentCooldown({ ...base, bedC: 40, ambientC: 38, samples: curve(70, 38, 0.04, 25), nowMs: min(25) });
    expect(vm.phase).toBe('stalled');
    expect(vm.etaMin).toBeNull();
    expect(vm.detail).toContain('38°C'); // tells the user WHY
    expect(vm.detail).toMatch(/flex the plate/);
  });

  it('reports STALLED from a measured plateau even with no usable fit', () => {
    const flat: BedSample[] = [0, 3, 6, 9, 12].map((m) => ({ t: min(m), c: 37 }));
    const vm = presentCooldown({ ...base, bedC: 37, samples: flat, nowMs: min(12) });
    expect(vm.phase).toBe('stalled');
  });

  it('never claims STALLED just because the plate is still hot early on', () => {
    // Regression: an earlier version fitted ambient from the curve, got 39.9°C for a 28.5°C room,
    // and declared "as cool as it will get" while the plate was at 56°C, ten minutes in.
    const s = REAL_COOLDOWN_C.slice(0, 11).map((c, m) => ({ t: min(m), c }));
    const vm = presentCooldown({ ...base, bedC: 56, ambientC: REAL_AMBIENT_C, samples: s, nowMs: min(10) });
    expect(vm.phase).toBe('cooling');
  });

  it('degrades to a plain cooling message when there is no history to fit', () => {
    const vm = presentCooldown({ ...base, bedC: 55 });
    expect(vm.phase).toBe('cooling');
    expect(vm.etaMin).toBeNull();
    expect(vm.detail).toContain('55°C');
    expect(vm.detail).not.toMatch(/min until/);
  });

  it('tracks progress from the peak down to the threshold', () => {
    const s = curve(70, 28.5, 0.041, 14);
    expect(presentCooldown({ ...base, bedC: 70, samples: s }).progress).toBeCloseTo(0, 2);
    expect(presentCooldown({ ...base, bedC: 35, samples: s }).progress).toBe(1);
    const mid = presentCooldown({ ...base, bedC: 52.5, samples: s }).progress;
    expect(mid).toBeGreaterThan(0.4);
    expect(mid).toBeLessThan(0.6);
  });

  it('mentions a still-hot nozzle without ever blocking readiness', () => {
    const vm = presentCooldown({ ...base, bedC: 33, nozzleC: 210 });
    expect(vm.phase).toBe('ready'); // the plate is what you touch
    expect(vm.detail).toContain('210°C');
    expect(presentCooldown({ ...base, bedC: 33, nozzleC: 30 }).detail).not.toContain('nozzle');
  });

  it('attaches the material caution without changing the threshold', () => {
    const tpu = presentCooldown({ ...base, bedC: 34, material: 'TPU 95A' });
    const pla = presentCooldown({ ...base, bedC: 34, material: 'PLA' });
    expect(tpu.caution).toContain('isopropyl');
    expect(pla.caution).toBeNull();
    expect(tpu.thresholdC).toBe(pla.thresholdC); // material NEVER moves the number
  });

  it('honours a custom threshold, clamped', () => {
    expect(presentCooldown({ ...base, bedC: 38, thresholdC: 40 }).phase).toBe('ready');
    expect(presentCooldown({ ...base, bedC: 38, thresholdC: 25 }).thresholdC).toBe(COOLDOWN_MIN_C);
  });

  it('is pure — identical inputs give identical output', () => {
    const i = { ...base, bedC: 51, samples: curve(69, 28.5, 0.041, 14), material: 'PLA' };
    expect(presentCooldown(i)).toEqual(presentCooldown(i));
  });
});

describe('parseBedHistory', () => {
  it('reads Bambuddy naive timestamps as UTC, not local', () => {
    // The trap: `new Date("2026-08-01T11:57:57")` is LOCAL time in JS. Getting this wrong shifts
    // the whole curve by the UTC offset and quietly corrupts every rate and ETA.
    const s = parseBedHistory({ series: [{ data: [{ recorded_at: '2026-08-01T11:57:57', value: 51 }] }] });
    expect(s).toHaveLength(1);
    expect(s[0].t).toBe(Date.UTC(2026, 7, 1, 11, 57, 57));
  });

  it('respects an explicit zone when one is present', () => {
    const z = parseBedHistory({ series: [{ data: [{ recorded_at: '2026-08-01T11:57:57Z', value: 51 }] }] });
    const off = parseBedHistory({ series: [{ data: [{ recorded_at: '2026-08-01T13:57:57+02:00', value: 51 }] }] });
    expect(z[0].t).toBe(Date.UTC(2026, 7, 1, 11, 57, 57));
    expect(off[0].t).toBe(z[0].t);
  });

  it('sorts, dedupes and drops unusable points', () => {
    const s = parseBedHistory({
      series: [
        {
          data: [
            { recorded_at: '2026-08-01T11:59:00', value: 49 },
            { recorded_at: '2026-08-01T11:57:00', value: 51 },
            { recorded_at: '2026-08-01T11:58:00', value: null },
            { recorded_at: '', value: 40 },
            { value: 40 },
          ],
        },
      ],
    });
    expect(s.map((x) => x.c)).toEqual([51, 49]);
  });

  it('returns [] for an empty, missing or malformed response', () => {
    expect(parseBedHistory(null)).toEqual([]);
    expect(parseBedHistory(undefined)).toEqual([]);
    expect(parseBedHistory({})).toEqual([]);
    expect(parseBedHistory({ series: [] })).toEqual([]);
    expect(parseBedHistory({ series: [{}] })).toEqual([]);
  });
});
