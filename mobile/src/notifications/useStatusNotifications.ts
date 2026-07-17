import { useEffect } from 'react';
import { Platform } from 'react-native';
import * as Notifications from 'expo-notifications';

// Show the banner (and play a sound) even if a status alert arrives while the app is foregrounded.
Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowBanner: true,
    shouldShowList: true,
    shouldPlaySound: true,
    shouldSetBadge: false,
  }),
});

/**
 * Requests notification permission, gets the raw APNs *device* token, and registers it with la-push
 * so the server can send print-done / error banners (separate from the per-card Live-Activity tokens).
 * No-op without a pushUrl or on non-iOS; failures are swallowed — the app works regardless.
 */
export function useStatusNotifications(pushUrl?: string | null, apiKey?: string): void {
  useEffect(() => {
    if (Platform.OS !== 'ios' || !pushUrl || !apiKey) return;
    let cancelled = false;
    (async () => {
      try {
        const perm = await Notifications.getPermissionsAsync();
        const granted = perm.granted || (perm.canAskAgain && (await Notifications.requestPermissionsAsync()).granted);
        if (!granted || cancelled) return;
        const token = await Notifications.getDevicePushTokenAsync(); // iOS -> { type: 'ios', data: '<hex>' }
        if (cancelled || token.type !== 'ios' || typeof token.data !== 'string') return;
        // X-API-Key gates la-push registration (see useLiveActivity) — without it a stranger who knows
        // the URL could register their device and receive this printer's status banners.
        await fetch(`${pushUrl.replace(/\/+$/, '')}/register-device`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', 'X-API-Key': apiKey },
          body: JSON.stringify({ device_token: token.data }),
        }).catch(() => {});
      } catch {
        /* notifications denied / unavailable — fine */
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [pushUrl, apiKey]);
}
