#!/usr/bin/env bash
# Archive the native app and export it for TestFlight.
#
#   ./scripts-archive.sh                    archive + export iOS, stop there
#   ./scripts-archive.sh --macos            …the Mac build instead
#   ./scripts-archive.sh --upload           …then validate and upload to TestFlight
#   ./scripts-archive.sh --macos --upload
#
# One app record carries both platforms, so the two ship as separate TestFlight builds of one app
# and share its testers. They are separate uploads and can hold the same build number.
#
# The Mac half used to be done by hand, off a copy of this file's iOS command with the destination
# swapped. Six things differ between the two and every one of them fails at a different stage —
# the destination, the SDK the archive is checked against, whether there is a widget profile to
# name, the exported artifact (.ipa vs .pkg), how the build number is read back out of it, and
# altool's -t. Doing that from memory each time is how a platform ships with an unverified build
# number.
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
platform=ios
for arg in "$@"; do
  case "$arg" in
    --upload) upload=1 ;;
    --macos|--mac) platform=macos ;;
    --ios) platform=ios ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-26.3.0.app/Contents/Developer}
# Invoke xcodebuild by its ABSOLUTE PATH inside DEVELOPER_DIR, never the bare name. The /usr/bin
# xcodebuild shim resolves the toolchain through xcode-select/xcrun, and in some environments (a
# shell hosted by Xcode-beta, for one) that resolution is forced to the beta regardless of
# DEVELOPER_DIR — which silently produced an iphoneos27 (beta-SDK) archive that App Store Connect
# rejected only after a full upload. The absolute path is the one selector that cannot be overridden.
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
cd "$(dirname "$0")"

# Everything that differs between the two platforms, in ONE place. Scattered `if macos` branches
# through the body is how the hand-run Mac archive drifted from this file in the first place.
if [ "$platform" = macos ]; then
  dest='generic/platform=macOS'
  archive=/tmp/SproutNative-macOS.xcarchive
  exportdir=/tmp/sprout-export-macos
  sdk_pattern='macosx[0-9.]+'
  altool_type=macos
  artifact_glob='*.pkg'
  # No widget on macOS: the SproutWidget dependency is `platformFilter: iOS`, so the Mac app embeds
  # no appex and naming a profile for one would fail the export.
  has_widget=0
else
  dest='generic/platform=iOS'
  archive=/tmp/SproutNative.xcarchive
  exportdir=/tmp/sprout-export
  sdk_pattern='iphoneos[0-9.]+'
  altool_type=ios
  artifact_glob='*.ipa'
  has_widget=1
fi
echo "archiving for $platform"

# Your Apple Developer team id. Kept OUT of the repo: put it in native/.env-local (gitignored) as
#   DEVELOPMENT_TEAM=XXXXXXXXXX
# or export it. xcodegen expands ${DEVELOPMENT_TEAM} in project.yml from the environment, so it has
# to be exported before `xcodegen generate` — not just passed to xcodebuild.
# `if`, not `[ … ] && …`: under `set -e` a failing && chain aborts the script, so with no
# .env-local this exited silently before doing anything.
if [ -f .env-local ]; then set -a; . ./.env-local; set +a; fi
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM (see native/.env-local.example)}"
export DEVELOPMENT_TEAM

# Locate the App Store Connect key once, if configured. It has two jobs: provisioning updates during
# archive/export (passed as -authenticationKey*, so signing works with no Apple ID in the GUI login
# keychain — the headless "No Accounts" case), and the altool upload. altool searches these four
# directories itself, so we look in the same set. Found up front, before the archive, so a missing
# key is an error at second one rather than after minutes of building.
asc_auth=()
if [ -n "${ASC_KEY_ID:-}" ]; then
  for d in ./private_keys "$HOME/private_keys" "$HOME/.private_keys" "$HOME/.appstoreconnect/private_keys"; do
    if [ -f "$d/AuthKey_${ASC_KEY_ID}.p8" ]; then asc_key_path="$d/AuthKey_${ASC_KEY_ID}.p8"; break; fi
  done
  if [ -n "${asc_key_path:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    asc_auth=(-authenticationKeyPath "$asc_key_path" -authenticationKeyID "$ASC_KEY_ID" \
              -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  fi
fi

# Everything --upload needs is checked HERE, before the archive, not after it.
if [ "$upload" = 1 ]; then
  : "${ASC_KEY_ID:?--upload needs ASC_KEY_ID (see native/.env-local.example)}"
  : "${ASC_ISSUER_ID:?--upload needs ASC_ISSUER_ID (see native/.env-local.example)}"
  if [ -z "${asc_key_path:-}" ]; then
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
# App Attest is an iOS-only entitlement here — the Mac profile grants none, deliberately (see
# MacNotificationController). So this whole check is iOS's, and running it for macOS would print a
# warning about a capability that build never asks for.
profiles=~/Library/Developer/Xcode/UserData/Provisioning\ Profiles
have_profile=$([ "$platform" = macos ] && echo 1 || echo 0)
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

"$XCODEBUILD" -project Sprout.xcodeproj -scheme Sprout -configuration Release \
  -destination "$dest" -archivePath "$archive" \
  -allowProvisioningUpdates ${asc_auth[@]+"${asc_auth[@]}"} \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
  ENABLE_USER_SCRIPT_SANDBOXING=NO archive 2>&1 | tail -30 || true

# Trust the artifact, not the exit code: a nested -quiet xcodebuild in a script phase can print
# "error: ... exit code 0 but produced no further output" and fail the action while the archive is
# perfectly good.
test -d "$archive/Products/Applications/Sprout.app" \
  || { echo "no app in the archive — the failure was real"; exit 1; }

# …but do check the archive was built with the SDK we selected, not a beta the shim substituted.
# App Store Connect rejects an unsupported/beta SDK, so catch a mismatch in a second here rather
# than after a ten-minute upload. Compare the SDK baked into the app to the one DEVELOPER_DIR
# advertises; if they differ, the wrong xcodebuild ran (see the XCODEBUILD note above).
want_sdk=$("$XCODEBUILD" -showsdks 2>/dev/null | grep -oE "$sdk_pattern" | head -1)
got_sdk=$(/usr/libexec/PlistBuddy -c "Print :DTSDKName" \
  "$archive/Products/Applications/Sprout.app/Info.plist" 2>/dev/null)
if [ -n "$want_sdk" ] && [ "$want_sdk" != "$got_sdk" ]; then
  echo "archive was built with '$got_sdk' but $DEVELOPER_DIR advertises '$want_sdk' — the wrong" >&2
  echo "xcodebuild ran (a beta shim override). App Store Connect rejects a beta SDK, so not" >&2
  echo "exporting. Ensure DEVELOPER_DIR points at a RELEASE Xcode." >&2
  exit 1
fi

# Signing style for the export. Automatic needs the Apple ID's CLOUD-managed distribution
# certificate; a key or account that lacks that access fails with "Cloud signing permission error".
# When .env-local names an explicit distribution cert + profiles, export MANUALLY against them
# instead. Those profiles must already carry every entitlement the app requests (App Attest
# included) — regenerating them after adding a capability is a prerequisite of this script, not a
# step it performs; a stale profile fails here with "doesn't include the … entitlement".
widget_profile_line=""
if [ "$has_widget" = 1 ]; then
  widget_profile_line="    <key>com.mvks5.bambu.LiveActivity</key><string>${DIST_PROFILE_WIDGET:-}</string>"
fi

rm -rf "$exportdir"
if [ -n "${DIST_CERT:-}" ] && [ -n "${DIST_PROFILE_APP:-}" ] && [ -n "${DIST_PROFILE_WIDGET:-}" ]; then
  cat > /tmp/sprout-ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>${DEVELOPMENT_TEAM}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>${DIST_CERT}</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.mvks5.bambu</key><string>${DIST_PROFILE_APP}</string>
${widget_profile_line}
  </dict>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
  <!-- Keep the build number exactly as archived. Left at its default of true, -exportArchive
       queries App Store Connect (it can, now that we pass the ASC key) and SILENTLY increments
       CFBundleVersion past the highest uploaded build — so a 17 archive exports as 18. That is the
       "build 13 shipped as another 12" surprise in reverse: the shipped number stops matching
       CURRENT_PROJECT_VERSION. Bumping the build is a deliberate edit to project.yml, not a thing
       the exporter guesses. -->
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
else
  # xcodebuild does NOT expand variables inside an export plist, so render the committed automatic
  # template here rather than committing one with a team id in it.
  sed "s|\${DEVELOPMENT_TEAM}|$DEVELOPMENT_TEAM|" ExportOptions.template.plist > /tmp/sprout-ExportOptions.plist
fi

"$XCODEBUILD" -exportArchive -archivePath "$archive" \
  -exportOptionsPlist /tmp/sprout-ExportOptions.plist -exportPath "$exportdir" \
  -allowProvisioningUpdates ${asc_auth[@]+"${asc_auth[@]}"}

ipa=$(ls $exportdir/$artifact_glob)
echo "exported: $ipa"

# Read the version back out of the .ipa rather than from project.yml. Build 13 was archived with a
# bump that silently did nothing and shipped as another 12 — the only thing that would have caught
# it is asking the artifact what it actually says.
rm -rf /tmp/sprout-ipa-check && mkdir -p /tmp/sprout-ipa-check
if [ "$platform" = macos ]; then
  # A Mac app-store export is a .pkg — an installer archive, not a zip, so `unzip` does not read it
  # and the iOS `Payload/*.app` path does not exist. Expanding it is the only way to ask the thing
  # that will actually be uploaded what build it says it is, which is the entire point of this check.
  pkgutil --expand-full "$ipa" /tmp/sprout-ipa-check/pkg >/dev/null
  app=$(find /tmp/sprout-ipa-check/pkg -maxdepth 4 -name 'Sprout.app' -type d | head -1)
  plist="$app/Contents/Info.plist"
else
  (cd /tmp/sprout-ipa-check && unzip -q "$ipa")
  app=$(ls -d /tmp/sprout-ipa-check/Payload/*.app)
  plist="$app/Info.plist"
fi
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
echo "contains: $version ($build)"

if [ "$upload" = 0 ]; then
  echo "not uploaded. Pass --upload to send this to TestFlight."
  exit 0
fi

# Validate first: it catches the beta-SDK rejection and most signing problems in seconds, where the
# upload would surface the same error only after transferring the whole build.
echo "validating $platform $version ($build)…"
xcrun altool --validate-app -f "$ipa" -t "$altool_type" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "uploading $platform $version ($build)…"
xcrun altool --upload-app -f "$ipa" -t "$altool_type" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "uploaded $platform $version ($build). App Store Connect takes a few minutes to process it."
