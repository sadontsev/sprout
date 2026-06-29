// Pure input sanitizers for the connection form — kept import-free so they stay unit-testable
// (settings.tsx itself pulls in the reanimated-based anim kit, which jest can't load).

/** Trim whitespace and any stray trailing slash; keep scheme + host. */
export function sanitizeBaseUrl(raw: string): string {
  return raw.trim().replace(/\s+/g, '').replace(/\/+$/, '');
}

/**
 * API keys are `bb_` + base62 ([A-Za-z0-9]). Pasting often appends a stray trailing char —
 * whitespace, a newline, or a `%` (zsh's no-newline EOL marker / a URL-encode artifact). Trim both
 * ends, then strip any leading/trailing chars that aren't valid key characters (keep `_` for the
 * `bb_` prefix). Interior characters are never touched, so a legitimate key can't be corrupted.
 */
export function sanitizeApiKey(raw: string): string {
  return raw.trim().replace(/^[^A-Za-z0-9_]+/, '').replace(/[^A-Za-z0-9_]+$/, '');
}
