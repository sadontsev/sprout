import type { AppConfig } from './secureConfig';

/**
 * The stl-texturize sidecar base URL — or null when it can't be derived (feature hidden).
 *
 * Mirrors resolvePushUrl's convention: the sidecar runs next to Bambuddy (deploy/stl-texturize/),
 * exposed as `texturize.` on the same host that serves `bambuddy.`. No explicit-override field yet —
 * unlike push (which anyone self-hosting needs), texturize is optional polish; the derivation covers
 * the deploy pattern, and a null simply hides the Texturize action in the library.
 */
export function resolveTexturizeUrl(cfg: Pick<AppConfig, 'baseUrl'>): string | null {
  const base = (cfg.baseUrl ?? '').trim().replace(/\/+$/, '');
  if (!base.includes('bambuddy.')) return null;
  const url = base.replace('bambuddy.', 'texturize.');
  return /^https?:\/\/[^\s]+$/i.test(url) ? url : null;
}
