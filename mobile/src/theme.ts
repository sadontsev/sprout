import { Platform } from 'react-native';
import { useSyncExternalStore } from 'react';

/** Design tokens from docs/design/Bambu.dc.html (Claude Design) — dark + light variants. */
export type ThemeName = 'dark' | 'light';
export type Palette = typeof dark;

const dark = {
  bg: '#0A0B0C',
  s1: '#131517',
  s2: '#191C1F',
  s3: '#23272B',
  s4: '#2D3237',
  line: 'rgba(255,255,255,0.07)',
  line2: 'rgba(255,255,255,0.12)',
  t1: '#F3F5F7',
  t2: '#A4ABB2',
  t3: '#6B7177',
  accent: '#2BD4C0',
  accentInk: '#04201D',
  accentDim: 'rgba(43,212,192,0.15)',
  running: '#30D158',
  runningDim: 'rgba(48,209,88,0.15)',
  heating: '#FF9F0A',
  heatingDim: 'rgba(255,159,10,0.15)',
  paused: '#0A84FF',
  pausedDim: 'rgba(10,132,255,0.15)',
  error: '#FF453A',
  errorDim: 'rgba(255,69,58,0.15)',
  idle: '#8E9398',
  idleDim: 'rgba(142,147,152,0.14)',
  sheet: '#16181B',
  tabbar: 'rgba(13,14,16,0.72)',
  /** Neutral well behind thumbnails/camera tiles. */
  thumb: '#0e1113',
  /** Supports accent (amber) — matches the layer-view support color. */
  supports: '#E8A23D',
};

const light: typeof dark = {
  bg: '#EFF1F3',
  s1: '#FFFFFF',
  s2: '#F5F6F8',
  s3: '#EAECEF',
  s4: '#DEE1E5',
  line: 'rgba(0,0,0,0.08)',
  line2: 'rgba(0,0,0,0.13)',
  t1: '#0D1012',
  t2: '#585E64',
  t3: '#878D94',
  accent: '#0EAE9C',
  accentInk: '#FFFFFF',
  accentDim: 'rgba(14,174,156,0.14)',
  running: '#23B24A',
  runningDim: 'rgba(35,178,74,0.14)',
  heating: '#E0860A',
  heatingDim: 'rgba(224,134,10,0.14)',
  paused: '#0A84FF',
  pausedDim: 'rgba(10,132,255,0.12)',
  error: '#E5392E',
  errorDim: 'rgba(229,57,46,0.12)',
  idle: '#9AA0A6',
  idleDim: 'rgba(154,160,166,0.14)',
  sheet: '#FFFFFF',
  tabbar: 'rgba(244,246,248,0.8)',
  thumb: '#E4E7EA',
  supports: '#C77E14',
};

export const themes: Record<ThemeName, Palette> = { dark, light };

/**
 * Live token object. Components read `c.<token>` INLINE at render, so reassigning its properties and
 * notifying subscribers re-themes the whole tree without a context or per-component refactor. Call
 * `useTheme()` at the app root(s) so they re-render when `setTheme()` fires.
 */
export const c: Palette = { ...dark };

let _name: ThemeName = 'dark';
const listeners = new Set<() => void>();

export function setTheme(name: ThemeName): void {
  _name = name;
  Object.assign(c, themes[name]);
  listeners.forEach((l) => l());
}

export function getThemeName(): ThemeName {
  return _name;
}

function subscribe(l: () => void): () => void {
  listeners.add(l);
  return () => {
    listeners.delete(l);
  };
}

/** Subscribe (typically the app root) so the subtree re-renders on theme change. */
export function useTheme(): ThemeName {
  return useSyncExternalStore(subscribe, getThemeName, getThemeName);
}

/** Monospaced family for the SF-Mono labels in the design. */
export const mono = Platform.select({ ios: 'Menlo', default: 'monospace' });

export const shadow1 = {
  shadowColor: '#000',
  shadowOpacity: 0.5,
  shadowRadius: 2,
  shadowOffset: { width: 0, height: 1 },
} as const;
