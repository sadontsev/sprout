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
# Invoke xcodebuild by its ABSOLUTE PATH inside DEVELOPER_DIR, never the bare name. The /usr/bin
# xcodebuild shim resolves the toolchain through xcode-select/xcrun, and in some environments (a
# shell hosted by Xcode-beta, for one) that resolution is forced to the beta regardless of
# DEVELOPER_DIR — which silently produced an iphoneos27 (beta-SDK) archive that App Store Connect
# rejected only after a full upload. The absolute path is the one selector that cannot be overridden.
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
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

"$XCODEBUILD" -project Sprout.xcodeproj -scheme Sprout -configuration Release \
  -destination 'generic/platform=iOS' -archivePath /tmp/SproutNative.xcarchive \
  -allowProvisioningUpdates ${asc_auth[@]+"${asc_auth[@]}"} \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
  ENABLE_USER_SCRIPT_SANDBOXING=NO archive 2>&1 | tail -30 || true

# Trust the artifact, not the exit code: a nested -quiet xcodebuild in a script phase can print
# "error: ... exit code 0 but produced no further output" and fail the action while the archive is
# perfectly good.
test -d /tmp/SproutNative.xcarchive/Products/Applications/Sprout.app \
  || { echo "no app in the archive — the failure was real"; exit 1; }

# …but do check the archive was built with the SDK we selected, not a beta the shim substituted.
# App Store Connect rejects an unsupported/beta SDK, so catch a mismatch in a second here rather
# than after a ten-minute upload. Compare the SDK baked into the app to the one DEVELOPER_DIR
# advertises; if they differ, the wrong xcodebuild ran (see the XCODEBUILD note above).
want_sdk=$("$XCODEBUILD" -showsdks 2>/dev/null | grep -oE 'iphoneos[0-9.]+' | head -1)
got_sdk=$(/usr/libexec/PlistBuddy -c "Print :DTSDKName" \
  /tmp/SproutNative.xcarchive/Products/Applications/Sprout.app/Info.plist 2>/dev/null)
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
rm -rf /tmp/sprout-export
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
    <key>com.mvks5.bambu.LiveActivity</key><string>${DIST_PROFILE_WIDGET}</string>
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

"$XCODEBUILD" -exportArchive -archivePath /tmp/SproutNative.xcarchive \
  -exportOptionsPlist /tmp/sprout-ExportOptions.plist -exportPath /tmp/sprout-export \
  -allowProvisioningUpdates ${asc_auth[@]+"${asc_auth[@]}"}

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
