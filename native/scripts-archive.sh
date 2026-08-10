#!/usr/bin/env bash
# Archive the native app and export an .ipa for TestFlight.
#
# Uses the RELEASE Xcode deliberately: App Store Connect rejects anything built with a beta SDK
# ("Unsupported SDK or Xcode version"). The beta toolchain is only for installing to an iOS 27
# device, which is a different job.
set -euo pipefail

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-26.3.0.app/Contents/Developer}
cd "$(dirname "$0")"

# Your Apple Developer team id. Kept OUT of the repo: put it in native/.env-local (gitignored) as
#   DEVELOPMENT_TEAM=XXXXXXXXXX
# or export it. xcodegen expands ${DEVELOPMENT_TEAM} in project.yml from the environment, so it has
# to be exported before `xcodegen generate` — not just passed to xcodebuild.
# `if`, not `[ … ] && …`: under `set -e` a failing && chain aborts the script, so with no
# .env-local this exited silently before doing anything.
if [ -f .env-local ]; then set -a; . ./.env-local; set +a; fi
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM (see native/.env-local.example)}"
export DEVELOPMENT_TEAM

xcodegen generate --spec project.yml

xcodebuild -project Sprout.xcodeproj -scheme Sprout -configuration Release \
  -destination 'generic/platform=iOS' -archivePath /tmp/SproutNative.xcarchive \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
  ENABLE_USER_SCRIPT_SANDBOXING=NO archive 2>&1 | tail -30 || true

# Trust the artifact, not the exit code: a nested -quiet xcodebuild in a script phase can print
# "error: ... exit code 0 but produced no further output" and fail the action while the archive is
# perfectly good.
test -d /tmp/SproutNative.xcarchive/Products/Applications/Sprout.app \
  || { echo "no app in the archive — the failure was real"; exit 1; }

# xcodebuild does NOT expand variables inside an export plist, so render it here rather than
# committing one with a team id in it.
sed "s|\${DEVELOPMENT_TEAM}|$DEVELOPMENT_TEAM|" ExportOptions.template.plist > /tmp/sprout-ExportOptions.plist

rm -rf /tmp/sprout-export
xcodebuild -exportArchive -archivePath /tmp/SproutNative.xcarchive \
  -exportOptionsPlist /tmp/sprout-ExportOptions.plist -exportPath /tmp/sprout-export -allowProvisioningUpdates

echo "exported: $(ls /tmp/sprout-export/*.ipa)"
