// Pure input sanitizers for the connection form — kept import-free so they stay unit-testable
// (settings.tsx itself pulls in the reanimated-based anim kit, which jest can't load).

/** Trim whitespace and any stray trailing slash; keep scheme + host. */
export function sanitizeBaseUrl(raw: string): string {
  return raw.trim().replace(/\s+/g, '').replace(/\/+$/, '');
}

/**
 * API keys are `bb_` + a base64url token ([A-Za-z0-9_-]). Pasting often appends a stray trailing
 * char — whitespace, a newline, or a `%` (zsh's no-newline EOL marker / a URL-encode artifact). Trim
 * both ends, then strip leading/trailing chars that aren't valid key characters. Interior characters
 * are never touched. NOTE: the charset MUST match KEY_RE below (and it now includes `-`); an earlier
 * mismatch — sanitize kept `_` but the validator only accepted [A-Za-z0-9] — left Connect greyed out
 * for any key containing `_`/`-`, despite the field being filled.
 */
export function sanitizeApiKey(raw: string): string {
  return raw.trim().replace(/^[^A-Za-z0-9_-]+/, '').replace(/[^A-Za-z0-9_-]+$/, '');
}

/** Whether a raw API-key input is a plausible Bambuddy key once sanitized — drives the Connect
 *  button's enabled state. base64url charset so real keys with `-`/`_` aren't rejected. */
const KEY_RE = /^bb_[A-Za-z0-9_-]{6,}$/;
export function isValidApiKey(raw: string): boolean {
  return KEY_RE.test(sanitizeApiKey(raw));
}
