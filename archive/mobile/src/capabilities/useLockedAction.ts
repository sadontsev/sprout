import { useMemo } from 'react';
import { Alert } from 'react-native';

import { isBlocked, lockedStyle, LAN_BANNER_TITLE, LAN_BLOCKED_HINT, type ActionId, type LanMode } from './lanMode';

/**
 * Single source of truth for how a LAN-gated control behaves, so a button can never look enabled
 * while its handler is blocked (or the reverse). Every gated control pairs `style(a)` with
 * `press(a, run)` — one decision, applied to both the look and the tap.
 */
export function useLockedAction(lanMode: LanMode) {
  return useMemo(
    () => ({
      blocked: (a: ActionId) => isBlocked(a, lanMode),
      style: (a: ActionId) => lockedStyle(isBlocked(a, lanMode)),
      press: (a: ActionId, run: () => void) => () => {
        if (isBlocked(a, lanMode)) {
          Alert.alert(LAN_BANNER_TITLE, LAN_BLOCKED_HINT);
          return;
        }
        run();
      },
    }),
    [lanMode],
  );
}
