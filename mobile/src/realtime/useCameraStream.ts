import { useCallback, useEffect, useRef, useState } from 'react';
import type { BambuddyClient } from '@/api/bambuddyClient';

const TOKEN_TTL_MS = 55 * 60 * 1000; // backend camera token TTL is 60 min; refresh a little early.

/**
 * Mints + auto-refreshes a camera stream token and exposes the MJPEG stream URL.
 * `enabled` should be true only while the camera view is mounted, so we don't hold a token/stream
 * needlessly. Tokens are minted per session (not persisted) — the camera scope is short-lived.
 */
export function useCameraStream(client: BambuddyClient, printerId: number, enabled: boolean, fps = 10) {
  const [token, setToken] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const mintedAt = useRef(0);

  const mint = useCallback(async () => {
    try {
      const t = await client.mintCameraToken();
      mintedAt.current = Date.now();
      setToken(t);
      setError(null);
    } catch (e) {
      setError(String(e));
    }
  }, [client]);

  // Mint on enable; clear on disable.
  useEffect(() => {
    if (!enabled) {
      setToken(null);
      return;
    }
    if (!token || Date.now() - mintedAt.current > TOKEN_TTL_MS) void mint();
  }, [enabled, token, mint]);

  // Periodic refresh while enabled.
  useEffect(() => {
    if (!enabled) return;
    const id = setInterval(() => {
      if (Date.now() - mintedAt.current > TOKEN_TTL_MS) void mint();
    }, 60_000);
    return () => clearInterval(id);
  }, [enabled, mint]);

  const streamUrl = enabled && token ? client.streamUrl(printerId, token, fps) : null;
  return { token, streamUrl, error, remint: mint };
}
