#!/bin/bash
# Deploy docs/ to Cloudflare Pages, non-interactive safe.
# Reads the API token from the keychain (see AGENTS.md).
set -euo pipefail
cd "$(dirname "$0")/.."

TOKEN=$(security find-generic-password -s "devops-assistant-cloudflare" -w 2>/dev/null) || {
  echo "✗ Cloudflare token not in keychain (service 'devops-assistant-cloud')." >&2
  exit 1
}
export CLOUDFLARE_API_TOKEN="$TOKEN"

echo "Deploying docs/ to Cloudflare Pages (project: devops-assistant)..."
exec npx --yes wrangler@latest pages deploy ./docs \
  --project-name=devops-assistant --branch=main --commit-dirty=true
