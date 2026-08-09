#!/bin/zsh
# Notarize a macOS artifact and staple the ticket. Adapted from openclaw's
# notarize-mac-artifact.sh — the assistant invokes this so notarytool usage
# stays in one audited place.
#
# Auth (either is sufficient):
#   NOTARYTOOL_PROFILE       — a keychain profile stored via `xcrun notarytool store-credentials`
#   NOTARYTOOL_KEY/KEY_ID/ISSUER — ASC API key path, key id, issuer id
#
# Usage: notarize.sh <artifact-path> [staple-app-path]

set -euo pipefail

ARTIFACT="${1:?artifact path required}"
STAPLE_APP_PATH="${2:-}"

auth_args=()
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  auth_args+=(--keychain-profile "$NOTARYTOOL_PROFILE")
elif [[ -n "${NOTARYTOOL_KEY:-}" && -n "${NOTARYTOOL_KEY_ID:-}" && -n "${NOTARYTOOL_ISSUER:-}" ]]; then
  auth_args+=(--key "$NOTARYTOOL_KEY" --key-id "$NOTARYTOOL_KEY_ID" --issuer "$NOTARYTOOL_ISSUER")
else
  echo "ERROR: set NOTARYTOOL_PROFILE or NOTARYTOOL_KEY/KEY_ID/ISSUER" >&2
  exit 1
fi

echo "▶ Submitting $ARTIFACT for notarization…"
xcrun notarytool submit "$ARTIFACT" "${auth_args[@]}" --wait

# Staple when the artifact is a dmg/pkg, or when an app path is given. ZIP files
# cannot carry a ticket themselves; their enclosed app is the staple target.
VALIDATE_TARGET=""
case "$ARTIFACT" in
  *.dmg|*.pkg)
    echo "▶ Stapling $ARTIFACT…"
    xcrun stapler staple "$ARTIFACT"
    VALIDATE_TARGET="$ARTIFACT"
    ;;
esac
if [[ -n "$STAPLE_APP_PATH" && -d "$STAPLE_APP_PATH" ]]; then
  echo "▶ Stapling app at $STAPLE_APP_PATH…"
  xcrun stapler staple "$STAPLE_APP_PATH"
  VALIDATE_TARGET="$STAPLE_APP_PATH"
fi

if [[ -z "$VALIDATE_TARGET" ]]; then
  echo "ERROR: no staple target for artifact '$ARTIFACT'" >&2
  exit 1
fi

echo "▶ Validating $VALIDATE_TARGET…"
xcrun stapler validate "$VALIDATE_TARGET"
echo "✓ Notarization complete"
