#!/bin/bash
# Builds Wattline.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

# The macOS 27 SDK in Command Line Tools lacks the SwiftUI macro plugin (@State etc.),
# so build against the 26.5 SDK when no SDK is chosen explicitly.
if [ -z "${SDKROOT:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

if [ "${UNIVERSAL:-0}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BINDIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
  BIN=$BINDIR/Wattline
else
  swift build -c release
  BINDIR=.build/release
  BIN=$BINDIR/Wattline
fi

ICON=Resources/AppIcon.icns
if [ ! -f "$ICON" ]; then
  TMP=$(mktemp -d)
  swift Scripts/make-icon.swift "$TMP/icon.png"
  SET="$TMP/AppIcon.iconset"; mkdir "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$ICON"
  rm -rf "$TMP"
fi

APP=build/Wattline.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wattline"
# Strip symbols to keep the app small.
strip -x "$APP/Contents/MacOS/Wattline"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# The widget extension: desktop and Notification Center.
APPEX="$APP/Contents/PlugIns/WattlineWidget.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BINDIR/WattlineWidget" "$APPEX/Contents/MacOS/WattlineWidget"
strip -x "$APPEX/Contents/MacOS/WattlineWidget"
cp Resources/Widget/Info.plist "$APPEX/Contents/Info.plist"

# Sign with a stable local certificate so macOS permissions (camera, calendars,
# screen recording, automation) survive rebuilds. Falls back to ad-hoc signing.
KC="$(pwd)/signing/wattline.keychain-db"
if [ -f "$KC" ] && [ -f signing/keychain-password.txt ]; then
  security unlock-keychain -p "$(cat signing/keychain-password.txt)" "$KC"
  ID=$(security find-identity "$KC" | awk '/Wattline Local Signing/ {print $2; exit}')
  codesign --force --keychain "$KC" --sign "$ID" --entitlements Resources/Widget/Widget.entitlements -i local.wattline.Wattline.Widget "$APPEX"
  codesign --force --keychain "$KC" --sign "$ID" -i local.wattline.Wattline "$APP"
  echo "Signed with Wattline Local Signing ($ID)"
else
  codesign --force --sign - --entitlements Resources/Widget/Widget.entitlements "$APPEX" >/dev/null 2>&1 || true
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "Warning: ad-hoc signed; permissions will reset on every rebuild (run Scripts/make-signing.sh once)"
fi

echo "Built $(pwd)/$APP"
