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
  /** la-push base URL for Live-Activity APNs push (defaults to the bambuddy host as lapush.*). */
  pushUrl?: string;
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
