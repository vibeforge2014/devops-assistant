#!/bin/bash
# Deploy docs/ to Cloudflare Pages, non-interactive safe.
# Auth: API token from the keychain when present, else wrangler's local
# OAuth login (~/.wrangler/config/default.toml) — both verified working.
set -euo pipefail
cd "$(dirname "$0")/.."

# Optional: keychain token takes precedence over wrangler OAuth.
TOKEN=$(security find-generic-password -s "devops-assistant-cloudflare" -w 2>/dev/null || true)
[[ -n "$TOKEN" ]] && export CLOUDFLARE_API_TOKEN="$TOKEN"

echo "Deploying docs/ to Cloudflare Pages (project: devops-assistant)..."
# Pin the version: `wrangler@latest` npx installs can break at startup when
# workerd's optional platform binary is missing from the cache (observed
# 2026-08-20); 4.123.0 is the known-good cached build.
exec npx --yes wrangler@4.123.0 pages deploy ./docs \
  --project-name=devops-assistant --branch=main --commit-dirty=true
