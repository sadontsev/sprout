import { useCallback, useEffect, useState } from 'react';
import { AppState } from 'react-native';
import type { BambuddyClient } from '@/api/bambuddyClient';
import { lanModeFrom, type LanMode } from './lanMode';

/** How often to re-check. It only changes when someone toggles a setting on the printer's screen. */
const POLL_MS = 5 * 60_000;

/**
 * Whether the printer accepts commands, fetched OUT-OF-BAND over REST.
 *
 * Deliberately not read from `usePrinterStatus`: that feed is WebSocket-primary, and Bambuddy's
 * WebSocket frame does not carry `developer_mode` at all (printer_manager.printer_state_to_dict
 * omits it). Reading it there would yield undefined on the happy path and a real value only while
 * the socket was down — a gate that flickered exactly when the app was healthiest.
 */
export function useLanMode(client: BambuddyClient, printerId: number): LanMode {
  const [mode, setMode] = useState<LanMode>('unknown');

  const check = useCallback(() => {
    client
      .getStatus(printerId)
      .then((s) => setMode(lanModeFrom(s)))
      // Leave the last known value on a failure. A network blip must not grey out the UI.
      .catch(() => {});
  }, [client, printerId]);

  useEffect(() => {
    check();
    const t = setInterval(check, POLL_MS);
    // Re-check on foreground: the usual fix is to walk to the printer and change the setting.
    const sub = AppState.addEventListener('change', (s) => s === 'active' && check());
    return () => {
      clearInterval(t);
      sub.remove();
    };
  }, [check]);

  return mode;
}
