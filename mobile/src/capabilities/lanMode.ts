import type { PrinterStatus } from '@/api/types';

/**
 * Whether the printer will accept COMMANDS at all.
 *
 * Bambuddy reaches the printer over LAN MQTT only. With LAN Developer Mode off, the firmware rejects
 * every message published to `device/{serial}/request` with "mqtt message verify failed" — while
 * status reports keep flowing, so the app looks perfectly healthy. Bambuddy does not check either:
 * it returns success the moment publish() returns, so the API answers 200 and the UI renders a
 * successful pause that never happened. That silent lie is what this exists to end.
 *
 * TRI-STATE ON PURPOSE. 'unknown' is not 'off'. The field is absent until the printer has reported,
 * and a gate that treats absence as "off" greys out the whole UI on every cold start. Only an
 * explicit false disables anything.
 */
export type LanMode = 'on' | 'off' | 'unknown';

export function lanModeFrom(status: Pick<PrinterStatus, 'developer_mode'> | null | undefined): LanMode {
  const v = status?.developer_mode;
  if (v === true) return 'on';
  if (v === false) return 'off';
  return 'unknown';
}

/** Every action the app can invoke that we care about gating. */
export type ActionId =
  | 'pause'
  | 'resume'
  | 'stop'
  | 'light'
  | 'speed'
  | 'dismissHms'
  | 'amsLoad'
  | 'amsUnload'
  | 'dryStart'
  | 'dryStop'
  | 'startPrint'
  | 'plateCleared'
  | 'printAgain'
  | 'plug'
  | 'camera'
  | 'maintenance'
  | 'queueRemove';

/**
 * Actions the printer refuses without Developer Mode. All of them are `print.*` MQTT commands on the
 * one verified topic — the same rejection applies to every one, which is why this is a set and not a
 * per-command investigation.
 */
const BLOCKED: ReadonlySet<ActionId> = new Set<ActionId>([
  'pause',
  'resume',
  'speed',
  'dismissHms',
  'amsLoad',
  'amsUnload',
  'dryStart',
  'dryStop',
  'startPrint',
  'printAgain',
]);

/**
 * Deliberately NOT blocked, each for a specific reason:
 *
 *  stop      THE EMERGENCY CONTROL. A dead grey Stop on a print that is spaghettifying is actively
 *            dangerous. A Stop that might fail is strictly better than one that cannot be pressed.
 *  light     the only control here that is not a `print` command — it publishes system/ledctrl, which
 *            the firmware does not verify the same way.
 *  camera    RTSPS on its own port; verified streaming with Developer Mode off.
 *  plug      a different device entirely, and the real kill switch when commands are refused.
 *  plateCleared, queueRemove, maintenance
 *            Bambuddy-side bookkeeping in its own database; the printer is never asked.
 */
export function isBlocked(action: ActionId, mode: LanMode): boolean {
  return mode === 'off' && BLOCKED.has(action);
}

/** Actions blocked right now — for tests and for anything that wants to enumerate them. */
export function blockedActions(mode: LanMode): ActionId[] {
  return mode === 'off' ? [...BLOCKED] : [];
}

export const LAN_BANNER_TITLE = 'Printer controls are locked';
export const LAN_BANNER_BODY =
  "This printer won't accept commands until LAN Developer Mode is on. Monitoring, the camera and your library still work.";

/** Why a specific control is dead, shown when one is tapped. Short, and says what to do. */
export const LAN_BLOCKED_HINT =
  'Turn on LAN Developer Mode on the printer (Settings → Network), then re-enter its new access code in this app.';

export const LAN_HELP_TITLE = 'Turn on LAN Developer Mode';
export const LAN_HELP_BODY = [
  'Your printer reports status, streams the camera and accepts files, but rejects every command this app sends — pause, resume, speed, AMS, drying and starting a print. Its firmware requires signed commands unless Developer Mode is on.',
  '',
  'On the printer:',
  '1. Settings → Network → LAN Only Mode.',
  '2. Turn on Developer Mode and confirm.',
  '3. The printer shows a NEW access code.',
  '',
  'Then update the access code in Bambuddy, and this app will be able to control the printer again.',
].join('\n');
