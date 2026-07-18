import * as SecureStore from 'expo-secure-store';
import type { ThemeName } from '@/theme';

/** App connection config, persisted in the iOS Keychain (this-device-only). */
export type AppConfig = {
  /** e.g. https://bambuddy.example.com */
  baseUrl: string;
  /** Bambuddy scoped API key (bb_...) sent as X-API-Key */
  apiKey: string;
  /** Long-lived camera stream token, minted lazily */
  cameraToken?: string;
  /** UI theme preference (defaults to dark) */
  theme?: ThemeName;
  /** Last-selected printer (restored on launch). */
  printerId?: number;
  printerName?: string;
  /** la-push base URL for Live-Activity APNs push. Blank ⇒ derived from the bambuddy host as
   *  lapush.* (owner convenience); anyone self-hosting with a different host sets it explicitly. */
  pushUrl?: string;
  /** Live-Activity mode. true/undefined ⇒ register with la-push so cards persist after the app is
   *  suspended + status banners fire (needs a reachable la-push). false ⇒ LOCAL only: cards update
   *  while the app runs, no banners, no server. See resolvePushUrl() in config/pushConfig.ts. */
  serverPush?: boolean;
  /** stl-texturize sidecar URL. Blank ⇒ derived from the bambuddy host as texturize.*; set it if the
   *  sidecar runs elsewhere. Only used when `texturize` isn't false AND /health answers. */
  texturizeUrl?: string;
  /** Model-texturizer feature toggle. true/undefined ⇒ enabled (URL derived or explicit, then
   *  health-probed). false ⇒ fully off: no texturize UI, thumbnails stay on the Bambuddy path. */
  texturize?: boolean;
  /** Optional Bambuddy ADMIN login — unlocks admin-gated actions (e.g. maintenance "mark done"),
   *  which categorically refuse API keys. Keychain-only, like the API key. */
  adminUsername?: string;
  adminPassword?: string;
};

const KEY = 'bambu.config';
const OPTS: SecureStore.SecureStoreOptions = {
  keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
};

export async function getConfig(): Promise<AppConfig | null> {
  const raw = await SecureStore.getItemAsync(KEY, OPTS);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as AppConfig;
  } catch {
    return null;
  }
}

export async function setConfig(c: AppConfig): Promise<void> {
  await SecureStore.setItemAsync(KEY, JSON.stringify(c), OPTS);
}

/** Merge a partial update into the stored config (no-op if nothing is stored yet). */
export async function patchConfig(partial: Partial<AppConfig>): Promise<void> {
  const cur = await getConfig();
  if (!cur) return;
  await setConfig({ ...cur, ...partial });
}

export async function clearConfig(): Promise<void> {
  await SecureStore.deleteItemAsync(KEY, OPTS);
}
