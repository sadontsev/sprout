// Human descriptions for HMS / print-error codes, from Bambu's own public feed.
//
// Bambuddy does NOT carry this text (its HMSErrorResponse is just code/attr/module/severity/actions),
// and the wiki has no page for every code — the H2C's 0C00-0100-0002-0017 404s. But Bambu publishes
// the same table their own software uses: ~4,900 HMS entries + ~650 print-error entries, keyed by the
// exact codes the printer reports. Fetched once and cached, that turns "HMS 0501-0400-0003-0002" into
// "Threaded rods need lubrication now."
//
// It is fetched rather than bundled: the parsed map is ~535 KB, which would bloat every OTA for text
// that changes independently of the app.
import { File, Paths } from 'expo-file-system';

const FEED_URL = 'https://e.bambulab.com/query.php?lang=en';
const CACHE_FILE = 'hms-catalog.json';
const MAX_AGE_MS = 14 * 24 * 60 * 60 * 1000;

export interface HmsCatalog {
  /** 16-hex full_code (uppercase) -> description. */
  hms: Record<string, string>;
  /** decimal print_error -> description. */
  err: Record<string, string>;
  fetchedAt: number;
}

export const EMPTY_CATALOG: HmsCatalog = { hms: {}, err: {}, fetchedAt: 0 };

/** Pure: Bambu's feed shape -> the two lookup maps. Tolerates missing sections and odd casing. */
export function parseHmsFeed(raw: unknown): Omit<HmsCatalog, 'fetchedAt'> {
  const data = (raw as { data?: Record<string, { en?: { ecode?: unknown; intro?: unknown }[] }> })?.data ?? {};
  const take = (section?: { en?: { ecode?: unknown; intro?: unknown }[] }, upper = false): Record<string, string> => {
    const out: Record<string, string> = {};
    for (const e of section?.en ?? []) {
      const code = String(e?.ecode ?? '').trim();
      const intro = String(e?.intro ?? '').trim();
      if (code && intro) out[upper ? code.toUpperCase() : code] = intro;
    }
    return out;
  };
  return { hms: take(data.device_hms, true), err: take(data.device_error) };
}

/** Pure: description for a printer-reported HMS code. Accepts the dashed display form or raw hex. */
export function describeHms(cat: HmsCatalog, code: string | null | undefined): string | null {
  if (!code) return null;
  return cat.hms[code.replace(/[-_\s]/g, '').toUpperCase()] ?? null;
}

/** Pure: description for a print_error value (Bambuddy reports it as a number). */
export function describePrintError(cat: HmsCatalog, err: number | string | null | undefined): string | null {
  if (err == null || err === '') return null;
  return cat.err[String(err)] ?? null;
}

let memo: HmsCatalog | null = null;
let inflight: Promise<HmsCatalog> | null = null;

/**
 * Memory -> disk -> network. Never throws and never blocks a render: callers get EMPTY_CATALOG until
 * it resolves, and the UI simply shows the code without prose in the meantime.
 */
export function loadHmsCatalog(): Promise<HmsCatalog> {
  if (memo && Date.now() - memo.fetchedAt < MAX_AGE_MS) return Promise.resolve(memo);
  if (inflight) return inflight;

  inflight = (async () => {
    const cache = new File(Paths.cache, CACHE_FILE);
    try {
      if (cache.exists) {
        const disk = JSON.parse(cache.textSync()) as HmsCatalog;
        if (disk?.hms && Date.now() - (disk.fetchedAt ?? 0) < MAX_AGE_MS) {
          memo = disk;
          return disk;
        }
      }
    } catch {
      /* corrupt cache — refetch */
    }
    try {
      const res = await fetch(FEED_URL);
      if (!res.ok) throw new Error(String(res.status));
      const parsed = parseHmsFeed(await res.json());
      const cat: HmsCatalog = { ...parsed, fetchedAt: Date.now() };
      memo = cat;
      try {
        if (cache.exists) cache.delete();
        cache.write(JSON.stringify(cat));
      } catch {
        /* cache write is best-effort */
      }
      return cat;
    } catch {
      return memo ?? EMPTY_CATALOG; // offline: codes still render, just without prose
    } finally {
      inflight = null;
    }
  })();
  return inflight;
}
