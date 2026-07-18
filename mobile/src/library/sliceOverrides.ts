// Pure builders for per-slice parameter overrides. Bambuddy's slice API takes only preset
// REFERENCES — but local presets support `inherits` + a delta of keys (Bambuddy resolves the base;
// the slicer sidecar flattens inheritance too). So "advanced mode" = upsert an ephemeral local
// preset carrying just the user's changed keys, then slice referencing it. Same mechanism the
// "+ Supports" twins use (deploy/bambuddy/ensure-support-profiles.py), generalized.
//
// Key names + value shapes verified against BambuStudio's PrintConfig.cpp: preset JSON values are
// STRINGS ("1"/"0" bools, "15%" percents). Only scalar-safe keys are exposed — per-extruder ARRAY
// keys (speeds: 5-element (extruder,variant) arrays on H2-series) are deliberately excluded until
// the app can read base preset content to rewrite whole arrays.

export interface SliceOverrides {
  /** wall_loops (0–1000; stock ~2) */
  wallLoops?: number;
  /** sparse_infill_density percent 0–100 */
  infillDensity?: number;
  /** sparse_infill_pattern */
  infillPattern?: string;
  /** top_surface_pattern */
  topPattern?: string;
  /** enable_prime_tower */
  primeTower?: boolean;
  /** prime_tower_width mm (min 2) */
  primeTowerWidth?: number;
  /** enable_support — advanced path (supersedes the "+ Supports" twin swap when set) */
  support?: boolean;
  /** support_type: normal(auto) | tree(auto) | normal(manual) | tree(manual) */
  supportType?: string;
  /** support_style: default | grid | snug | tree_slim | tree_strong | tree_hybrid | tree_organic */
  supportStyle?: string;
  /** support_threshold_angle 1–90° */
  supportAngle?: number;
  /** filament_flow_ratio (FILAMENT preset; H2-series carries a 3-element per-variant array) */
  flowRatio?: number;
}

export const INFILL_PATTERNS = ['grid', 'gyroid', 'cubic', 'triangles', 'honeycomb', 'lightning', 'adaptivecubic', 'crosshatch'] as const;
export const TOP_PATTERNS = ['monotonic', 'monotonicline', 'concentric', 'alignedrectilinear'] as const;
export const SUPPORT_TYPES = ['tree(auto)', 'normal(auto)'] as const;
export const SUPPORT_STYLES = ['default', 'snug', 'tree_slim', 'tree_strong', 'tree_hybrid', 'tree_organic'] as const;

const PROCESS_KEYS: (keyof SliceOverrides)[] = ['wallLoops', 'infillDensity', 'infillPattern', 'topPattern', 'primeTower', 'primeTowerWidth', 'support', 'supportType', 'supportStyle', 'supportAngle'];

export function hasProcessOverrides(o: SliceOverrides): boolean {
  return PROCESS_KEYS.some((k) => o[k] !== undefined);
}
export function hasFilamentOverrides(o: SliceOverrides): boolean {
  return o.flowRatio !== undefined;
}

const bool = (b: boolean): string => (b ? '1' : '0');

/**
 * Delta process-preset `setting` JSON inheriting `baseQualityName`, or null when nothing to
 * override. `presetName` is the reusable local-preset row name (one per machine, updated in place).
 */
export function buildProcessDelta(baseQualityName: string, o: SliceOverrides, presetName: string): Record<string, string> | null {
  if (!hasProcessOverrides(o)) return null;
  const s: Record<string, string> = { type: 'process', name: presetName, from: 'User', inherits: baseQualityName };
  if (o.wallLoops !== undefined) s.wall_loops = String(Math.max(0, Math.round(o.wallLoops)));
  if (o.infillDensity !== undefined) s.sparse_infill_density = `${Math.min(100, Math.max(0, Math.round(o.infillDensity)))}%`;
  if (o.infillPattern !== undefined) s.sparse_infill_pattern = o.infillPattern;
  if (o.topPattern !== undefined) s.top_surface_pattern = o.topPattern;
  if (o.primeTower !== undefined) s.enable_prime_tower = bool(o.primeTower);
  if (o.primeTowerWidth !== undefined) s.prime_tower_width = String(Math.max(2, o.primeTowerWidth));
  if (o.support !== undefined) s.enable_support = bool(o.support);
  if (o.supportType !== undefined) s.support_type = o.supportType;
  if (o.supportStyle !== undefined) s.support_style = o.supportStyle;
  if (o.supportAngle !== undefined) s.support_threshold_angle = String(Math.min(90, Math.max(1, Math.round(o.supportAngle))));
  return s;
}

/**
 * Delta filament-preset `setting`, or null. `variants` = the machine's per-(extruder,variant) array
 * length for filament keys (H2-series: 3; single-extruder: 1) — same value replicated across, which
 * is the safe uniform override.
 */
export function buildFilamentDelta(baseFilamentName: string, o: SliceOverrides, presetName: string, variants = 3): Record<string, unknown> | null {
  if (!hasFilamentOverrides(o)) return null;
  const flow = Math.min(2, Math.max(0.5, o.flowRatio!));
  return {
    type: 'filament',
    name: presetName,
    from: 'User',
    inherits: baseFilamentName,
    filament_flow_ratio: Array.from({ length: Math.max(1, variants) }, () => String(flow)),
  };
}

/** Count of active overrides — drives the "n changed" badge on the Advanced accordion. */
export function overrideCount(o: SliceOverrides): number {
  return [...PROCESS_KEYS, 'flowRatio' as const].filter((k) => o[k] !== undefined).length;
}
