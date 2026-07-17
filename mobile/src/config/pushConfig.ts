import type { AppConfig } from './secureConfig';

/**
 * The effective la-push base URL the app should register with — or null for LOCAL-ONLY mode.
 *
 * Push architecture: each person self-hosts their OWN `la-push` next to their OWN Bambuddy (it polls
 * Bambuddy with their API key and signs with their APNs .p8), so the app must be pointed at it. There
 * are two Live-Activity modes:
 *  - SERVER (this returns a URL): the app registers each card's push token with la-push, so the
 *    lock-screen cards keep updating and status banners fire even after iOS suspends the app.
 *  - LOCAL (this returns null): usePrinterActivities/useStatusNotifications no-op their registration,
 *    so Live Activities only update while the app is running and there are no push banners — but no
 *    server is needed.
 *
 * Resolution: `serverPush === false` forces LOCAL. Otherwise prefer an explicit `pushUrl`; else derive
 * it from a `bambuddy.*` base-URL host by swapping the subdomain to `lapush.` (a naming convenience —
 * anyone whose la-push host differs should just set the explicit URL). null when nothing resolves.
 */
export function resolvePushUrl(cfg: Pick<AppConfig, 'baseUrl' | 'pushUrl' | 'serverPush'>): string | null {
  if (cfg.serverPush === false) return null;
  const trim = (s: string) => s.trim().replace(/\/+$/, '');
  const explicit = cfg.pushUrl?.trim();
  if (explicit) return trim(explicit);
  const base = cfg.baseUrl ?? '';
  if (base.includes('bambuddy.')) return trim(base.replace('bambuddy.', 'lapush.'));
  return null;
}
