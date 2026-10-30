#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the window app as .build/Saur0n.app — a release build of the Saur0nApp target in a hand-made bundle
# with an ad-hoc signature; no Xcode (research/2026-10-16-phase1-topup.md Q1). Installing is the user's drag.
# Also builds the release command-line tool, .build/release/saur0n, so it is as new as the window.
# Usage: bash scripts/make-app.sh   (prints the CLI path, then the bundle path)
# Optional overrides: SAUR0N_BUNDLE_ID (default app.saur0n.monitor), SAUR0N_APP_DIR (default .build/Saur0n.app;
# must be .build/<name>.app), SAUR0N_BUILD_JOBS (passed as swift build --jobs). The warning-safety live check
# builds its own bundle this way, so it never shares settings with the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."

bundle_id=${SAUR0N_BUNDLE_ID:-app.saur0n.monitor}
app=${SAUR0N_APP_DIR:-.build/Saur0n.app}
jobs=()
[[ -z ${SAUR0N_BUILD_JOBS:-} ]] || jobs=(--jobs "$SAUR0N_BUILD_JOBS")
case $app in .build/*.app) ;; *) echo "make-app: SAUR0N_APP_DIR must be .build/<name>.app" >&2; exit 2 ;; esac

swift build "${jobs[@]}" -c release --product Saur0nApp
swift build "${jobs[@]}" -c release --product saur0n
bin=$(swift build -c release --show-bin-path)

# The default is a fixed path; an override is checked above to sit under .build/.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Saur0nApp" "$app/Contents/MacOS/Saur0nApp"
# The icon: the committed iconset that scripts/make-icon.swift draws, packed by iconutil.
iconutil -c icns Resources/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
# The eye without its tile, which the app draws over each Dock step (Phase 6 Step 9).
cp Resources/AppIcon-eye.png "$app/Contents/Resources/AppIcon-eye.png"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>Saur0n</string>
  <key>CFBundleDisplayName</key><string>Saur0n</string>
  <key>CFBundleExecutable</key><string>Saur0nApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null
codesign --force --sign - "$app"
codesign --verify --verbose=2 "$app" 2>/dev/null
# The bundle is rebuilt on every run, but swift build leaves an unchanged binary's time alone; the build above
# just confirmed the CLI current, so mark it as new as the bundle (make's sentinel idiom).
touch "$bin/saur0n"
echo "CLI: $bin/saur0n"
echo "$PWD/$app"
