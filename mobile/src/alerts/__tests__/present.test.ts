import { presentAlerts, type AlertCaps } from '@/alerts/present';
import type { PrinterStatus } from '@/api/types';

const OK: AlertCaps = { connected: true, canControl: true };
const st = (over: object = {}): PrinterStatus => ({ connected: true, state: 'RUNNING', ...over }) as PrinterStatus;
const ids = (s: PrinterStatus, caps = OK) => presentAlerts(s, caps).map((a) => a.id);
const actionsOf = (s: PrinterStatus, id: string, caps = OK) =>
  presentAlerts(s, caps).find((a) => a.id === id)?.actions.map((x) => x.id) ?? [];

test('a healthy print raises nothing', () => {
  expect(presentAlerts(st(), OK)).toEqual([]);
  expect(presentAlerts(null, OK)).toEqual([]);
});

describe('actions are offered only when the state actually allows them', () => {
  it('Resume appears when paused, and not while printing normally', () => {
    expect(actionsOf(st({ state: 'PAUSE' }), 'paused')).toEqual(['resume', 'stop']);
    expect(ids(st())).not.toContain('paused');
  });

  it('plate confirmation appears only while the queue is actually waiting', () => {
    expect(actionsOf(st({ awaiting_plate_clear: true }), 'plate')).toEqual(['plateCleared']);
    expect(ids(st({ awaiting_plate_clear: false }))).not.toContain('plate');
  });

  it('an OFFLINE printer shows the problem but offers no control it cannot perform', () => {
    const offline = { connected: false, canControl: true };
    expect(actionsOf(st({ state: 'PAUSE' }), 'paused', offline)).toEqual([]);
    expect(ids(st({ state: 'PAUSE' }), offline)).toContain('paused'); // still explains the situation
  });

  it('without control permission, nothing actionable is offered', () => {
    const readOnly = { connected: true, canControl: false };
    expect(actionsOf(st({ awaiting_plate_clear: true }), 'plate', readOnly)).toEqual([]);
  });

  it('Stop is always marked destructive so the UI can confirm it', () => {
    const stop = presentAlerts(st({ state: 'PAUSE' }), OK)[0].actions.find((a) => a.id === 'stop');
    expect(stop?.destructive).toBe(true);
    const resume = presentAlerts(st({ state: 'PAUSE' }), OK)[0].actions.find((a) => a.id === 'resume');
    expect(resume?.destructive).toBeUndefined(); // routine — no confirmation
  });
});

describe('HMS notices', () => {
  // The live H2C notice, verbatim.
  const hms = (over: object = {}) => ({ code: '0x10007', module: 5, severity: 5, full_code: '0500050000010007', ...over });

  it('displays the dashed code but links the wiki’s UNDERSCORE path (verified: dashed 404s, underscore 200s)', () => {
    const a = presentAlerts(st({ hms_errors: [hms()] }), OK).find((x) => x.id.startsWith('hms-'))!;
    expect(a.code).toBe('0500-0500-0001-0007');
    const urls = a.actions.find((x) => x.id === 'lookup')!.urls!;
    expect(urls[0].split('/').pop()).toBe('0500_0500_0001_0007'); // separator is what mattered
    expect(urls[urls.length - 1]).toContain('/hms/error-code'); // guaranteed-to-exist last resort
  });

  it('puts THIS machine’s wiki family first — each family has its own code namespace', () => {
    // Verified live: 0C00_0100_0002_0017 is 200 under /h2/ and 404 under /x1/; the reverse for
    // 0300_0D00_0001_0003. So the model decides which page to try first.
    const h2 = presentAlerts(st({ hms_errors: [hms()] }), { ...OK, model: 'H2C' }).find((x) => x.id.startsWith('hms-'))!;
    expect(h2.actions.find((x) => x.id === 'lookup')!.urls![0]).toContain('/en/h2/');
    const x1 = presentAlerts(st({ hms_errors: [hms()] }), { ...OK, model: 'X1C' }).find((x) => x.id.startsWith('hms-'))!;
    expect(x1.actions.find((x) => x.id === 'lookup')!.urls![0]).toContain('/en/x1/');
  });

  it('still offers every other family as a fallback, so a mis-modelled printer still finds the page', () => {
    const urls = presentAlerts(st({ hms_errors: [hms()] }), { ...OK, model: 'H2C' })
      .find((x) => x.id.startsWith('hms-'))!.actions.find((x) => x.id === 'lookup')!.urls!;
    expect(urls.filter((u) => u.includes('/troubleshooting/'))).toHaveLength(4); // h2, x1, p1, a1
    expect(urls[0]).toContain('/en/h2/');
  });

  it('an unrecognised severity stays a neutral notice instead of guessing a level', () => {
    const a = presentAlerts(st({ hms_errors: [hms({ severity: 5 })] }), OK).find((x) => x.id.startsWith('hms-'))!;
    expect(a.title).toBe('Printer notice');
    expect(a.level).toBe('warning');
  });

  it('maps the documented severities', () => {
    const lvl = (severity: number) => presentAlerts(st({ hms_errors: [hms({ severity })] }), OK).find((x) => x.id.startsWith('hms-'))!;
    expect(lvl(1)).toMatchObject({ level: 'error', title: 'Fatal notice' });
    expect(lvl(3)).toMatchObject({ level: 'warning', title: 'Common notice' });
    expect(lvl(4)).toMatchObject({ level: 'info', title: 'Info notice' });
  });

  it('offers ONE dismiss for the whole batch, not one per row', () => {
    const list = presentAlerts(st({ hms_errors: [hms(), hms({ full_code: '0500050000010008' })] }), OK);
    const dismissals = list.flatMap((a) => a.actions).filter((x) => x.id === 'clearHms');
    expect(dismissals).toHaveLength(1);
    expect(dismissals[0].label).toBe('Dismiss all (2)');
  });

  it('a routine notice never claims the print failed — that is reserved for a real error', () => {
    const a = presentAlerts(st({ hms_errors: [hms({ severity: 4 })] }), OK).find((x) => x.id.startsWith('hms-'))!;
    expect(a.detail).toMatch(/keeps going/i);
    expect(ids(st({ hms_errors: [hms()] }))).not.toContain('print-error');
  });

  it('a FATAL notice does NOT reassure that the printer keeps going', () => {
    const a = presentAlerts(st({ hms_errors: [hms({ severity: 1 })] }), OK).find((x) => x.id.startsWith('hms-'))!;
    expect(a.detail).not.toMatch(/keeps going|keeps printing/i);
    expect(a.detail).toMatch(/serious/i);
  });

  it('ids are stable across polls so the list does not churn mid-print', () => {
    const s = st({ hms_errors: [hms()] });
    expect(ids(s)).toEqual(ids(s));
  });
});

test('a real print error leads the list and offers resume or stop', () => {
  const list = presentAlerts(st({ print_error: 84033543, state: 'FAILED', hms_errors: [{ full_code: '0500050000010007' }] }), OK);
  expect(list[0].id).toBe('print-error');
  expect(list[0].level).toBe('error');
  expect(list[0].detail).toContain('84033543');
  expect(list[0].actions.map((a) => a.id)).toEqual(['resume', 'stop']);
});


describe('alertSummary — the single dashboard row', () => {
  const { alertSummary } = require('@/alerts/present');
  it('is null when all is well, so the dashboard shows nothing at all', () => {
    expect(alertSummary([])).toBeNull();
  });
  it('reports the WORST level present', () => {
    const list = presentAlerts(st({ state: 'PAUSE', hms_errors: [{ full_code: '0500050000010007', severity: 4 }] }), OK);
    expect(alertSummary(list)!.level).toBe('warning'); // paused outranks an info notice
    const fatal = presentAlerts(st({ print_error: 1 }), OK);
    expect(alertSummary(fatal)!.level).toBe('error');
  });
  it('counts how many are actionable, ignoring lookup-only rows', () => {
    const list = presentAlerts(st({ hms_errors: [{ full_code: '0500050000010007', severity: 4 }] }), OK);
    // one notice: it has lookup + the batch dismiss -> actionable
    expect(alertSummary(list)!.label).toBe('1 alert · 1 actionable');
    const offline = presentAlerts(st({ connected: false, hms_errors: [{ full_code: '0500050000010007', severity: 4 }] }), { connected: false, canControl: true });
    expect(alertSummary(offline)!.label).toBe('1 alert'); // nothing actionable while offline
  });
});

describe('local HMS descriptions (Bambu’s own feed)', () => {
  const { parseHmsFeed, describeHms, describePrintError } = require('@/alerts/hmsCatalog');
  // Verbatim shape of https://e.bambulab.com/query.php?lang=en (4,882 hms + 654 error entries live).
  const feed = {
    data: {
      device_hms: { ver: 1, en: [{ ecode: '0501040000030002', intro: 'Threaded rods need lubrication now.' }] },
      device_error: { ver: 1, en: [{ ecode: '18048012', intro: 'Failed to get AMS mapping table; please select "Resume" to retry.' }] },
    },
  };
  const cat = { ...parseHmsFeed(feed), fetchedAt: Date.now() };

  it('parses both sections into lookup maps', () => {
    expect(Object.keys(cat.hms)).toHaveLength(1);
    expect(Object.keys(cat.err)).toHaveLength(1);
  });

  it('looks up by the DASHED display code as well as raw hex', () => {
    expect(describeHms(cat, '0501-0400-0003-0002')).toBe('Threaded rods need lubrication now.');
    expect(describeHms(cat, '0501040000030002')).toBe('Threaded rods need lubrication now.');
    expect(describeHms(cat, '0501_0400_0003_0002')).toBe('Threaded rods need lubrication now.');
  });

  it('returns null for a code the feed does not cover (the H2C fatal is one)', () => {
    expect(describeHms(cat, '0C00-0100-0002-0017')).toBeNull();
    expect(describeHms(cat, null)).toBeNull();
  });

  it('resolves print_error numbers too', () => {
    expect(describePrintError(cat, 18048012)).toMatch(/AMS mapping table/);
    expect(describePrintError(cat, 999)).toBeNull();
  });

  it('presentAlerts shows Bambu’s wording when available, generic copy when not', () => {
    const describe = { hms: (c: string) => describeHms(cat, c) };
    const withText = presentAlerts(st({ hms_errors: [{ full_code: '0501040000030002', severity: 4 }] }), OK, describe);
    expect(withText[0].detail).toBe('Threaded rods need lubrication now.');
    const without = presentAlerts(st({ hms_errors: [{ full_code: '0C00010000020017', severity: 1 }] }), OK, describe);
    expect(without[0].detail).toMatch(/serious condition/i);
  });

  it('a malformed feed yields empty maps rather than throwing', () => {
    expect(parseHmsFeed({})).toEqual({ hms: {}, err: {} });
    expect(parseHmsFeed(null)).toEqual({ hms: {}, err: {} });
  });
});


describe('wikiFamily', () => {
  const { wikiFamily } = require('@/alerts/present');
  it('maps each Bambu model line', () => {
    expect(wikiFamily('H2C')).toBe('h2');
    expect(wikiFamily('H2D')).toBe('h2');
    expect(wikiFamily('X1C')).toBe('x1');
    expect(wikiFamily('P1S')).toBe('p1');
    expect(wikiFamily('A1 mini')).toBe('a1');
  });
  it('falls back to the largest/legacy set for an unknown or missing model', () => {
    expect(wikiFamily('SomeNewPrinter')).toBe('x1');
    expect(wikiFamily(null)).toBe('x1');
  });
});
