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
  # A read loop, not `mapfile`: that is a bash 4 builtin and macOS still ships bash 3.2 as
  # /bin/bash, so `#!/usr/bin/env bash` finds a shell without it unless a newer one happens to come
  # first on PATH. It died with "mapfile: command not found" — for the author it worked, because
  # MacPorts' bash was earlier in their PATH than the system one.
  #
  # `sort -u` de-duplicates the two diffs, and the `-f` test drops files the branch deleted. Doing
  # both inside one loop also removes the `printf ... "${files[@]}"` that ran between the two
  # mapfiles, which would itself have failed under `set -u` when nothing had changed.
  files=()
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && files+=("$f")
  done < <({ git diff --name-only main...HEAD -- '*.swift'
             git diff --name-only -- '*.swift'; } | sort -u)
fi

[ ${#files[@]} -gt 0 ] || { echo "no Swift files to lint"; exit 0; }

# Formatting-only rules. Everything else is signal.
# TrailingComma belongs here rather than in `.swift-format`: it is not a toggleable rule, it is
# part of the pretty-printer — which is also why its positions point into the FORMATTED output and
# not the source (it reported WizardView:1000, a blank line, and :1041, a comment). Unfixable as
# reported, and a style preference either way.
NOISE='\[(Indentation|AddLines|LineLength|Spacing|RemoveLine|TrailingWhitespace|TrailingComma|EndOfLineComment)\]'

out=$("$SF" lint --configuration .swift-format "${files[@]}" 2>&1 | grep -vE "$NOISE" || true)
out=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' || true)

if [ -z "$out" ]; then
  echo "lint clean — ${#files[@]} file(s), semantic rules only"
  exit 0
fi

printf '%s\n' "$out"
printf '\n%s semantic finding(s) across %s file(s)\n' "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "${#files[@]}"
