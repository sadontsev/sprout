import { Platform } from 'react-native';

/** Design tokens from docs/design/Bambu.dc.html (Claude Design). */
export const c = {
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
} as const;

/** Monospaced family for the SF-Mono labels in the design. */
export const mono = Platform.select({ ios: 'Menlo', default: 'monospace' });

export const shadow1 = {
  shadowColor: '#000',
  shadowOpacity: 0.5,
  shadowRadius: 2,
  shadowOffset: { width: 0, height: 1 },
} as const;
