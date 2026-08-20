# DevOps Assistant — Agent Notes

Reference-only. Contains **locations and workflow**, never secret values.
All secrets live in the macOS login keychain or `~/.appstore/` (gitignored).

## What this project is
Native macOS app (SwiftUI) — a local release console for indie Apple developers.
- XcodeGen project (`project.yml` → `DevOpsAssistant.xcodeproj`)
- Bundle id: `com.vibeforge.DevOpsAssistant`, team `LPW4Z3BN69`
- Distribution: signed DMG on GitHub Release + landing page on Cloudflare Pages

## Credential locations (do NOT ask the user — read from here)

| Purpose | Where | How to read |
|---|---|---|
| Apple notarization | keychain profile `devops-assistant-notary` | `xcrun notarytool submit X --keychain-profile devops-assistant-notary` |
| ASC API key (.p8) | `~/.appstoreconnect/private_keys/AuthKey_496SRK4K68.p8` | key id `496SRK4K68`, issuer `a307ff7b-774c-4ef6-98c4-8031876fa556` (used to rebuild the `devops-assistant-notary` profile on 2026-08-20) |
| Developer ID signing | login keychain identity `Developer ID Application: Zhen Qian (LPW4Z3BN69)` | `security find-identity -p codesigning \| grep Developer` |
| Cloudflare Pages | wrangler OAuth at `~/.wrangler/config/default.toml` (keychain token `devops-assistant-cloudflare` absent on this Mac — deploy falls back to OAuth) | `./scripts/deploy-pages.sh` |
| Apple app-specific pw | keychain `devops-assistant-apple-app-password` | `security find-generic-password -s devops-assistant-apple-app-password -w` |
| .p12 export password | keychain `devops-assistant-p12-password` | `security find-generic-password -s devops-assistant-p12-password -w` |
| GitLab (Synology) token | keychain `devops-assistant-gitlab-token` + git osxkeychain helper | `security find-generic-password -s devops-assistant-gitlab-token -w` (also stored for host `zqian24.synology.me:8010`) |

These are machine-local (this Mac). If a secret is genuinely missing from the keychain,
*then* surface it — otherwise proceed autonomously.

## Release workflow (one command)

```bash
./scripts/release-sign.sh
```

Flow (already proven end-to-end): archive → export `developer-id` → build DMG →
sign DMG with Developer ID → notarize (profile `devops-assistant-notary`) → staple →
`spctl --assess` must read `source=Notarized Developer ID`.

Gotchas already solved:
- OpenSSL 3.x reports wrong password on macOS-exported `.p12` — use `-legacy` or `security import`.
- The DMG itself must be signed **before** notarizing, or `spctl --type install` fails with `no usable signature`.
- `notarytool submit` prints two `id:` lines — take the first.

## Publishing (after a signed DMG exists)

1. GitHub Release: `gh release upload <tag> build/release/*.dmg --clobber`
   (download URL is hardcoded to `v<VERSION>` in `docs/index.html`).
2. Cloudflare Pages: `./scripts/deploy-pages.sh` (reads token from keychain, non-interactive safe).
3. In-app update: the app self-updates from GitHub `releases/latest` (unauthenticated
   public API), picking the `*.dmg` asset — download → `spctl --assess` (must read
   `source=Notarized Developer ID`) → swap the bundle in (~/)/Applications → relaunch.
   Every release must attach a DMG asset; the release notes body shows in the update sheet.

## Repo notes
- Dual remote: `origin` → GitHub (`git@github.com:vibeforge2014/devops-assistant.git`, SSH);
  `backup` → GitLab on Synology (`https://zqian24.synology.me:8010/root/devops-assistant.git`).
- GitLab auth + self-signed cert are configured globally: osxkeychain credential helper holds
  the token, and `http.<host>.sslVerify=false` is set for the Synology host only.
  So `git push origin` and `git push backup` both work with no extra flags.
- `.gitignore` covers `*.p8 *.p12 .env .zcode/ .wrangler/ build/`.
- Tests: `xcodebuild test -scheme DevOpsAssistant`.
