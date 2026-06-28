import { Platform } from 'react-native';
import { File } from 'expo-file-system';
import { widgetsDirectory } from 'expo-widgets';
import type { BambuddyClient } from '@/api/bambuddyClient';

/**
 * Downloads a library file's thumbnail into expo-widgets' App Group container so the Live Activity
 * widget (a separate process) can show it via `uiImage`. Returns the file:// URI or null.
 * The thumbnail endpoint is gated by the camera stream token (?token=), which fileThumbUrl embeds.
 */
export async function writeModelThumb(client: BambuddyClient, fileId: number, token: string | null): Promise<string | null> {
  if (Platform.OS !== 'ios' || !token) return null;
  const dir = widgetsDirectory; // "file:///.../ExpoWidgets/"
  if (!dir) return null;
  const url = client.fileThumbUrl(fileId, token); // authed via ?token=
  if (!url) return null;
  const dest = new File(dir.endsWith('/') ? `${dir}model.png` : `${dir}/model.png`);
  try {
    await File.downloadFileAsync(url, dest, { idempotent: true });
    return dest.uri;
  } catch {
    return null;
  }
}
