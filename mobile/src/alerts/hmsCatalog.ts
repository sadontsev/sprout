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

/** Pure: pull the description out of a Bambu wiki HMS page.
 *  The page's og:title is `HMS_0C00-0100-0002-0017: Nozzle camera lens is dirty, …` — the code's own
 *  prefix is stripped so the caller gets just the sentence. */
export function parseWikiTitle(html: string): string | null {
  const m =
    /<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']/i.exec(html) ??
    /<title>([^<]+)<\/title>/i.exec(html);
  if (!m) return null;
  const text = m[1].replace(/\s*\|\s*Bambu Lab Wiki\s*$/i, '').trim();
  const body = /^HMS_[0-9A-F_-]+:\s*(.+)$/i.exec(text);
  const out = (body ? body[1] : text).trim();
  return out.length > 3 ? out : null;
}

export interface HmsCatalog {
  /** 16-hex full_code (uppercase) -> description. */
  hms: Record<string, string>;
  /** decimal print_error -> description. */
  err: Record<string, string>;
  /** Descriptions scraped from the wiki for codes the feed doesn't carry (e.g. every H2-family code
   *  — verified: 0C00010000020017 is absent from the feed but documented on the wiki). Persisted, so
   *  a given code costs one request ever. */
  learned: Record<string, string>;
  fetchedAt: number;
}

export const EMPTY_CATALOG: HmsCatalog = { hms: {}, err: {}, learned: {}, fetchedAt: 0 };

/** Pure: Bambu's feed shape -> the two lookup maps. Tolerates missing sections and odd casing. */
export function parseHmsFeed(raw: unknown): Omit<HmsCatalog, 'fetchedAt' | 'learned'> {
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
  const key = code.replace(/[-_\s]/g, '').toUpperCase();
  // Optional-chain both: a catalog cached by an earlier build has no `learned` map, and reading it
  // straight would crash the alerts screen on upgrade.
  return cat.hms?.[key] ?? cat.learned?.[key] ?? null;
}

/** Pure: description for a print_error value (Bambuddy reports it as a number). */
export function describePrintError(cat: HmsCatalog, err: number | string | null | undefined): string | null {
  if (err == null || err === '') return null;
  return cat.err?.[String(err)] ?? null;
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
          memo = { ...disk, learned: disk.learned ?? {} }; // older caches predate `learned`
          return memo;
        }
      }
    } catch {
      /* corrupt cache — refetch */
    }
    try {
      const res = await fetch(FEED_URL);
      if (!res.ok) throw new Error(String(res.status));
      const parsed = parseHmsFeed(await res.json());
      const cat: HmsCatalog = { ...parsed, learned: memo?.learned ?? {}, fetchedAt: Date.now() };
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

/**
 * Resolve codes the feed doesn't cover by reading Bambu's wiki page for them, and remember the answer.
 *
 * Every H2-family code is missing from the public feed, including the one that turned out to say
 * "Nozzle camera lens is dirty…" — precisely the message worth surfacing. Candidate URLs come from the
 * alert itself (model family first), and the first page that yields a title wins.
 */
export async function learnCodes(codes: { code: string; urls: string[] }[]): Promise<HmsCatalog> {
  const cat = await loadHmsCatalog();
  let changed = false;
  for (const { code, urls } of codes) {
    const key = code.replace(/[-_\s]/g, '').toUpperCase();
    if (cat.hms?.[key] || cat.learned?.[key]) continue;
    for (const url of urls) {
      if (url.includes('/hms/error-code')) continue; // the index page describes nothing specific
      try {
        const res = await fetch(url);
        if (!res.ok) continue;
        const desc = parseWikiTitle(await res.text());
        if (desc) {
          cat.learned = { ...(cat.learned ?? {}), [key]: desc };
          changed = true;
          break;
        }
      } catch {
        break; // offline — try again next launch
      }
    }
  }
  if (changed) {
    memo = { ...cat };
    try {
      const cache = new File(Paths.cache, CACHE_FILE);
      if (cache.exists) cache.delete();
      cache.write(JSON.stringify(memo));
    } catch {
      /* best effort */
    }
  }
  return memo ?? cat;
}
