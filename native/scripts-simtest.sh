#!/usr/bin/env bash
# Build the native app for the simulator, install it, and launch it.
#
# Uses the BETA Xcode so the app is compiled against the iOS 27 SDK and run on an iOS 27 runtime —
# that is the point of the simulator pass. Shipping is a different toolchain (see scripts-archive.sh).
set -euo pipefail

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
cd "$(dirname "$0")"

# Pinned to the iOS 27.0 runtime's iPhone 17 Pro by UDID — by name alone simctl may pick the
# iOS 26.3 device of the same name, which defeats the point of this pass.
DEVICE=${1:-3E955880-80DA-4789-8786-D7F0BC424BFE}
BUNDLE=com.mvks5.bambu

xcodegen generate --spec project.yml >/dev/null

xcodebuild -project Sprout.xcodeproj -scheme Sprout -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath /tmp/sprout-sim build 2>&1 | grep -E "error:|warning: unused|BUILD" || true

APP=/tmp/sprout-sim/Build/Products/Debug-iphonesimulator/Sprout.app
test -d "$APP" || { echo "no .app produced"; exit 1; }

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --console-pty "$DEVICE" "$BUNDLE" &
echo "launched $BUNDLE on $DEVICE"
