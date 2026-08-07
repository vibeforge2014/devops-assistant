#!/bin/zsh
# Sign a macOS .app bundle with a Developer ID identity (for distribution
# outside the App Store). Adapted from openclaw's codesign-mac-app.sh,
# simplified to the common path: sign embedded helpers/frameworks first, then
# the outer bundle, with hardened runtime + timestamp.
#
# Env:
#   SIGN_IDENTITY  — override identity (default: first "Developer ID Application")
#   ENTITLEMENTS   — path to an entitlements plist (optional)
#
# Usage: codesign-mac.sh <app-bundle-path>

set -euo pipefail

APP="${1:?app bundle path required}"
ENTITLEMENTS="${ENTITLEMENTS:-}"
IDENTITY="${SIGN_IDENTITY:-}"

# Auto-select a Developer ID Application identity if none given.
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -p codesigning -v | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
  if [[ -z "$IDENTITY" ]]; then
    echo "ERROR: no Developer ID Application identity found in keychain" >&2
    exit 1
  fi
fi

sign_args=(--force --options runtime --timestamp --sign "$IDENTITY")
if [[ -n "$ENTITLEMENTS" && -f "$ENTITLEMENTS" ]]; then
  sign_args+=(--entitlements "$ENTITLEMENTS")
fi

echo "▶ Signing nested code (frameworks/helpers)…"
find "$APP" -type f \( -name "*.dylib" -o -name "*.framework" \) -print0 | while IFS= read -r -d '' f; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$f" 2>/dev/null || true
done

echo "▶ Signing $APP with '$IDENTITY'…"
codesign "${sign_args[@]}" "$APP"

echo "▶ Verifying signature…"
codesign --verify --strict --verbose=2 "$APP"
echo "✓ Signing complete"
