#!/bin/bash
# Full macOS release pipeline (proven flow):
#   archive → export (developer-id) → build DMG → sign DMG → notarize → staple → verify
# Prerequisites (one-time):
#   - "Developer ID Application: ..." certificate + private key in login keychain
#   - notarytool keychain profile stored: see `xcrun notarytool store-credentials`
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DevOps Assistant"
SCHEME="DevOpsAssistant"
TEAM="LPW4Z3BN69"
NOTARY_PROFILE="devops-assistant-notary"
ARCHIVE="build/DevOpsAssistant.xcarchive"
EXPORT_DIR="build/export"

echo "[1/8] Locating Developer ID Application certificate..."
SIGN_ID=$(security find-identity -v -p codesigning \
  | grep -m1 "Developer ID Application" \
  | sed -E 's/.*"(.*)".*/\1/' || true)
[[ -n "$SIGN_ID" ]] || { echo "✗ No Developer ID Application cert in keychain." >&2; exit 1; }
echo "    using: $SIGN_ID"

echo "[2/8] Archiving (Release, automatic signing)..."
rm -rf "$ARCHIVE" "$EXPORT_DIR" build/derived
xcodebuild archive -project DevOpsAssistant.xcodeproj -scheme "$SCHEME" \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" >/dev/null

echo "[3/8] Exporting as Developer ID..."
cat > build/ExportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>LPW4Z3BN69</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist build/ExportOptions.plist -exportPath "$EXPORT_DIR" >/dev/null
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG="build/release/DevOps-Assistant-$VERSION.dmg"
codesign --verify --strict --verbose=2 "$APP_PATH" 2>&1 | head -1

echo "[4/8] Building DMG..."
STAGE="build/dmg-stage"; rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "[5/8] Signing DMG with Developer ID + timestamp..."
codesign --sign "$SIGN_ID" --timestamp "$DMG"

echo "[6/8] Submitting to notarization (profile: $NOTARY_PROFILE)..."
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "[7/8] Stapling ticket..."
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "[8/8] Gatekeeper check..."
spctl --assess --type install --verbose "$DMG"

echo ""
echo "✅ Done: $DMG"
