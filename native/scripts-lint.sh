#!/usr/bin/env bash
# Semantic lint for native/. Files default to whatever the current branch changed.
#
# swift-format's PRETTY-PRINTER is unusable on this codebase and that is not going to change: it
# re-indents SwiftUI modifier chains to its own model, so a clean run emits ~25 000 [Indentation]
# warnings against a house style the project never adopted. Those are the tool disagreeing with the
# codebase, not defects, so they are filtered out and only the semantic rules are reported.
#
#   ./native/scripts-lint.sh                 # what this branch changed vs main
#   ./native/scripts-lint.sh path/to/File.swift ...
set -euo pipefail

SF="${SWIFT_FORMAT:-/Applications/Xcode-26.3.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-format}"
[ -x "$SF" ] || { echo "swift-format not found at $SF (set SWIFT_FORMAT)"; exit 1; }

cd "$(dirname "$0")/.."

if [ $# -gt 0 ]; then
  files=("$@")
else
  mapfile -t files < <(git diff --name-only main...HEAD -- '*.swift'; git diff --name-only -- '*.swift')
  # De-duplicate, and drop anything already deleted.
  mapfile -t files < <(printf '%s\n' "${files[@]}" | sort -u | while read -r f; do [ -f "$f" ] && echo "$f"; done)
fi

[ ${#files[@]} -gt 0 ] || { echo "no Swift files to lint"; exit 0; }

# Formatting-only rules. Everything else is signal.
NOISE='\[(Indentation|AddLines|LineLength|Spacing|RemoveLine|TrailingWhitespace)\]'

out=$("$SF" lint --configuration .swift-format "${files[@]}" 2>&1 | grep -vE "$NOISE" || true)
out=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' || true)

if [ -z "$out" ]; then
  echo "lint clean — ${#files[@]} file(s), semantic rules only"
  exit 0
fi

printf '%s\n' "$out"
printf '\n%s semantic finding(s) across %s file(s)\n' "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "${#files[@]}"
