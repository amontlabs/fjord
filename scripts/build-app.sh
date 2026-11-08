#!/bin/bash
# Builds "build/Fjord.app" (a bundle is required for notifications and launch at login).
# VERSION=1.2.3 sets the bundle version; UNIVERSAL=1 builds for arm64 + x86_64 (used for releases).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.0-dev}"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Fjord
else
  swift build -c release
  BIN=.build/release/Fjord
fi
APP="build/Fjord.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Fjord"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# The layered icon, compiled from the Icon Composer document: light, dark, tinted and clear on macOS 26, its light tile on
# earlier systems (CFBundleIconName picks the catalog over the .icns, which stays for whatever reads the file alone).
ICON_OUT="$(mktemp -d)"
xcrun actool Resources/AppIcon.icon --compile "$ICON_OUT" --app-icon AppIcon --platform macosx \
  --minimum-deployment-target 14.0 --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null
cp "$ICON_OUT/Assets.car" "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/"   # Geist and Geist Mono (OFL), registered at launch by Brand
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.amontlabs.fjord</string>
  <key>CFBundleName</key><string>Fjord</string>
  <key>CFBundleDisplayName</key><string>Fjord</string>
  <key>CFBundleExecutable</key><string>Fjord</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Keep AppKit's text-input policy the same in the bundle and the bare SwiftPM executable.
/usr/libexec/PlistBuddy -c "Merge Resources/AppInfo.plist" "$APP/Contents/Info.plist"
# Ad-hoc signatures change with every build, so macOS forgets Accessibility access each time and the in-app
# updater can't tell a release is really ours. A stable code-signing certificate (default name "Fjord Dev",
# or SIGN_IDENTITY, which is then required) keeps both working across builds.
IDENTITY="${SIGN_IDENTITY:-Fjord Dev}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  SIGNING_IDENTITY="$IDENTITY"
elif [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "Signing identity \"$SIGN_IDENTITY\" not found" >&2
  exit 1
else
  SIGNING_IDENTITY="-"
fi
if [ "$SIGNING_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP ($VERSION)"
