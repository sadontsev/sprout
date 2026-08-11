#!/usr/bin/env bash
# Archive the native app and export an .ipa for TestFlight.
#
#   ./scripts-archive.sh              archive + export, stop there
#   ./scripts-archive.sh --upload     …then validate and upload to TestFlight
#
# Uploading is opt-in because it is the irreversible half: a build number, once accepted by App
# Store Connect, is spent forever — re-uploading the same one is rejected, so a stray upload costs
# a version bump. Archiving is free to repeat.
#
# Uses the RELEASE Xcode deliberately: App Store Connect rejects anything built with a beta SDK
# ("Unsupported SDK or Xcode version"). The beta toolchain is only for installing to an iOS 27
# device, which is a different job.
set -euo pipefail

upload=0
for arg in "$@"; do
  case "$arg" in
    --upload) upload=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

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

# Everything --upload needs is checked HERE, before the archive, not after it. Discovering a missing
# key at the end means the archive ran for minutes to earn an error that was knowable at second one
# — the same "gate the affordance on the exact capability" rule the app itself follows.
if [ "$upload" = 1 ]; then
  : "${ASC_KEY_ID:?--upload needs ASC_KEY_ID (see native/.env-local.example)}"
  : "${ASC_ISSUER_ID:?--upload needs ASC_ISSUER_ID (see native/.env-local.example)}"
  # altool searches all four of these, so checking only one would refuse a working setup.
  key_found=0
  for d in ./private_keys "$HOME/private_keys" "$HOME/.private_keys" "$HOME/.appstoreconnect/private_keys"; do
    if [ -f "$d/AuthKey_${ASC_KEY_ID}.p8" ]; then key_found=1; break; fi
  done
  if [ "$key_found" = 0 ]; then
    echo "no AuthKey_${ASC_KEY_ID}.p8 in any directory altool searches." >&2
    echo "Apple lets you download a .p8 exactly once — if it is lost, create a new key in" >&2
    echo "App Store Connect → Users and Access → Integrations and update ASC_KEY_ID." >&2
    exit 1
  fi
fi

# Warn — do NOT block — when no distribution profile carries the App Attest entitlement.
#
# Exporting then needs Apple to regenerate the profile, which requires provisioning rights: either
# an Apple ID signed into Xcode, or an App Store Connect key with the App Manager / Admin role
# passed as -authenticationKey*. Without either, the archive SUCCEEDS and the export fails with
# "No Accounts" (or "Cloud signing permission error") followed by two messages about the profile —
# three errors that describe the symptom and none of which name the cause.
#
# This was briefly a hard failure gated on `defaults read com.apple.dt.Xcode
# DVTDeveloperAccountManagerAppleIDLists`. That key answers "what did some Xcode version cache in
# this plist", not "can this machine sign", and it read empty on a machine that was signed in — so
# it blocked a legitimate build. The same near-synonym predicate this project keeps writing. A
# warning states the risk without pretending to know the answer.
profiles=~/Library/Developer/Xcode/UserData/Provisioning\ Profiles
have_profile=0
if compgen -G "$profiles/*.mobileprovision" > /dev/null 2>&1; then
  for p in "$profiles"/*.mobileprovision; do
    plist=$(security cms -D -i "$p" 2>/dev/null) || continue
    case "$plist" in
      *appattest-environment*)
        case "$plist" in *'<key>ProvisionedDevices</key>'*) ;; *) have_profile=1 ;; esac ;;
    esac
  done
fi
if [ "$have_profile" = 0 ]; then
  echo "note: no distribution profile here carries the App Attest entitlement, so the export will" >&2
  echo "      ask Apple to regenerate one. That needs provisioning rights — an Apple ID signed" >&2
  echo "      into Xcode (Settings → Accounts), or ASC_KEY_ID holding the App Manager role." >&2
  echo "      If the export fails, that is why; the archive itself is unaffected." >&2
fi

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

ipa=$(ls /tmp/sprout-export/*.ipa)
echo "exported: $ipa"

# Read the version back out of the .ipa rather than from project.yml. Build 13 was archived with a
# bump that silently did nothing and shipped as another 12 — the only thing that would have caught
# it is asking the artifact what it actually says.
rm -rf /tmp/sprout-ipa-check && mkdir -p /tmp/sprout-ipa-check
(cd /tmp/sprout-ipa-check && unzip -q "$ipa")
app=$(ls -d /tmp/sprout-ipa-check/Payload/*.app)
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Info.plist")
echo "contains: $version ($build)"

if [ "$upload" = 0 ]; then
  echo "not uploaded. Pass --upload to send this to TestFlight."
  exit 0
fi

# Validate first: it catches the beta-SDK rejection and most signing problems in seconds, where the
# upload would surface the same error only after transferring the whole build.
echo "validating $version ($build)…"
xcrun altool --validate-app -f "$ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "uploading $version ($build)…"
xcrun altool --upload-app -f "$ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "uploaded $version ($build). App Store Connect takes a few minutes to process it."
