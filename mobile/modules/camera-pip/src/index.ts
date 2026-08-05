import { requireNativeModule, requireNativeView } from 'expo';
import type * as React from 'react';
import type { ViewProps } from 'react-native';

export interface CameraPiPErrorEvent {
  /** Human message. Native sees what the WebView could not — e.g. a 401 from an expired token. */
  message: string;
  /** False for a terminal failure (bad token, camera disabled); true for a transient one. */
  retryable: boolean;
}

export interface CameraPiPViewProps extends ViewProps {
  /** MJPEG stream URL, token included. Changing it hot-swaps the connection without dropping PiP. */
  url?: string | null;
  /** Pull frames while true. False releases the camera; the printer powers it down ~7s later. */
  active?: boolean;
  onLive?: () => void;
  onError?: (e: { nativeEvent: CameraPiPErrorEvent }) => void;
  onPipStart?: () => void;
  onPipStop?: (e: { nativeEvent: { error?: string } }) => void;
  /** Diagnostic heartbeat: total frames enqueued, and whether PiP is currently active. */
  onStats?: (e: { nativeEvent: { frames: number; pip: boolean } }) => void;
  /** Whether the background keep-alive audio session took. Without it the app suspends when
   *  backgrounded and the PiP window freezes on its last frame. */
  onAudio?: (e: { nativeEvent: { ok: boolean; message?: string } }) => void;
}

export interface CameraPiPViewRef {
  startPiP: () => Promise<void>;
  stopPiP: () => Promise<void>;
}

const NativeModule = requireNativeModule('CameraPiP');

/** Whether this device can do Picture-in-Picture at all — gate the button on it, because a button
 *  that silently does nothing is worse than no button. */
export function isPictureInPictureSupported(): boolean {
  try {
    return NativeModule.isSupported() === true;
  } catch {
    return false; // module missing (Expo Go / a build predating it)
  }
}

export const CameraPiPView = requireNativeView<CameraPiPViewProps & { ref?: React.Ref<CameraPiPViewRef> }>('CameraPiP');
