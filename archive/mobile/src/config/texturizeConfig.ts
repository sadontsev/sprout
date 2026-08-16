import type { AppConfig } from './secureConfig';

/**
 * The stl-texturize sidecar base URL — or null when the feature is off / nothing resolves.
 * Mirrors resolvePushUrl exactly: `texturize === false` forces OFF; an explicit `texturizeUrl`
 * wins; else derive `texturize.` from a `bambuddy.` host. The Shell additionally health-probes the
 * resolved URL before enabling anything, so a configured-but-absent sidecar degrades to plain mode
 * instead of dead buttons and broken thumbnails.
 */
export function resolveTexturizeUrl(cfg: Pick<AppConfig, 'baseUrl' | 'texturizeUrl' | 'texturize'>): string | null {
  if (cfg.texturize === false) return null;
  const trim = (s: string) => s.trim().replace(/\/+$/, '');
  const httpUrl = (s: string): string | null => (/^https?:\/\/[^\s]+$/i.test(s) ? s : null);
  const explicit = cfg.texturizeUrl?.trim();
  if (explicit) return httpUrl(trim(explicit));
  const base = (cfg.baseUrl ?? '').trim().replace(/\/+$/, '');
  if (base.includes('bambuddy.')) return httpUrl(base.replace('bambuddy.', 'texturize.'));
  return null;
}
