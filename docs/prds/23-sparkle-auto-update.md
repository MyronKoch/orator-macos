# PRD 23: One-click auto-update via Sparkle + GitHub Releases

## Decision & context
Orator is a **direct-download, Developer ID-signed, NON-sandboxed** Mac app (needs Accessibility;
not on the Mac App Store). That is exactly Sparkle's target case. Ship in-app one-click updates
with **Sparkle 2**, appcast + archives hosted on **GitHub Releases**. Myron already runs Sparkle
in other apps, so reuse that muscle memory and (if practical) the same EdDSA tooling conventions.

**Sequencing:** land this in the release *after* v1.3.0 (a user on 1.3.0 + Sparkle is the first who
can be offered 1.4.0). So: ship v1.3.0 without Sparkle, then this becomes part of v1.4.0.

## Privacy posture (non-negotiable — Orator's identity)
An update check is a network request, but it sends only app/OS version in a User-Agent and fetches
an XML file — **never reading content or user data.** This does NOT break "100% local synthesis."
Requirements:
- **Ask on first launch** ("Automatically check for updates?") and honor it. Manual "Check for
  Updates…" menu item always available.
- **System profiling OFF** (`SUEnableSystemProfiling` = false / omit — it's opt-in anyway).
- Be transparent in the UI copy that only a version check leaves the Mac. No telemetry beyond that.

## The big integration landmine: custom build script, not Xcode archive
Orator is assembled + signed by `scripts/build-app.sh` (Xcode builds the binary; the script
assembles the .app and signs), NOT Xcode's archive/export. Sparkle's normal "Xcode signs my
framework for me" path does **not** apply. After copying `Sparkle.framework` into
`Contents/Frameworks`, the script MUST manually re-sign every Sparkle component with the Developer
ID identity and hardened runtime (`-o runtime`), **inside-out, and NEVER with `--deep`**:

```
codesign -f -s "$SIGN" -o runtime Sparkle.framework/Versions/B/XPCServices/Installer.xpc
codesign -f -s "$SIGN" -o runtime --preserve-metadata=entitlements Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
codesign -f -s "$SIGN" -o runtime Sparkle.framework/Versions/B/Autoupdate
codesign -f -s "$SIGN" -o runtime Sparkle.framework/Versions/B/Updater.app
codesign -f -s "$SIGN" -o runtime Sparkle.framework
```
Then sign the app outer bundle as today. Because the app is non-sandboxed, we can also **strip the
Downloader.xpc** (a Build/assemble step) to slim the bundle, re-signing the framework after removal.
Notarization then covers the whole app including the bundled framework (existing `make-dmg.sh
--notarize notarytool` path is unchanged in shape).

## Setup steps
1. **Add Sparkle 2 via SPM** (`https://github.com/sparkle-project/Sparkle`). This is a real framework
   dependency — the one justified exception to the "no deps" convention. Adds a few MB (trivial vs the
   320 MB Kokoro payload). `build-app.sh` must copy `Sparkle.framework` into `Contents/Frameworks`
   and re-sign per above.
2. **Keys:** run Sparkle's `generate_keys` → an **EdDSA (Ed25519) keypair**. Public key → Info.plist
   `SUPublicEDKey`. Private key stays in the **developer login keychain** (or Myron's existing Sparkle
   key store). **This is a build-time developer SIGNING key, NOT a user credential or cloud API key —
   it does NOT violate the "no cloud keys / no Keychain" rule (that rule is about network-TTS secrets).**
3. **Info.plist:** `SUFeedURL` → the appcast on a **PERMANENT host**. Use a **GitHub-hosted URL**
   (release asset or `raw.githubusercontent.com/MyronKoch/orator-macos/.../appcast.xml`). **NEVER point
   it at `orator.peaksummitlabs.com` or any lapsable domain** — the URL is baked into every shipped
   binary forever; a lapsed domain = every install stops updating or gets hijacked. Also set
   `SUPublicEDKey`; leave automatic-check keys to the first-launch prompt.
4. **Wire the updater:** add `SPUStandardUpdaterController` (standard UI) and a "Check for Updates…"
   menu item bound to it. (Verify exact API against current Sparkle docs at implementation.)
5. **Appcast in the release pipeline:** integrate `generate_appcast /path/to/updates_folder/` into
   `scripts/make-dmg.sh` — it writes/updates `appcast.xml`, computes **delta updates**, and signs each
   enclosure with the EdDSA key. Upload `appcast.xml` + the archive + deltas to the GitHub release.

## Delta updates are mandatory here (the 320 MB problem)
Without deltas, every update re-downloads the full ~320 MB (Kokoro weights + MLX). With deltas, a
code-only release is a tiny patch since the weights don't change. `generate_appcast` produces deltas
automatically when it sees multiple versions in the updates folder — **keep prior `.app` archives
around so it can diff.** Distribute an **`.app` zip** for Sparkle (best delta support); keep the
`.dmg` as the website/first-download artifact.

## Landmines — DO NOT
- Do NOT sign Sparkle with `codesign --deep` (breaks nested signatures). Sign inside-out explicitly.
- Do NOT point `SUFeedURL` at a domain that can lapse — GitHub only.
- Do NOT enable system profiling; do NOT send anything but a version check. Preserve the privacy story.
- Do NOT ship Sparkle in v1.3.0 — it belongs in v1.4.0 (first updatable-from release is 1.3.0).
- Do NOT confuse the EdDSA signing key with the rejected cloud/API-key rule — different thing, allowed.
- Do NOT skip notarization of the bundled framework — the whole app must notarize + staple.

## Who builds what
- **Maintainer (guarded):** SPM add + `build-app.sh` framework copy/strip/re-sign; keys; Info.plist;
  `make-dmg.sh` appcast+delta generation; notarize. Build-verify + a real update dry-run.
- **Codex (optional):** the in-app "Check for Updates…" menu item + first-launch opt-in prompt UI.

## Verification
- Build, sign (Developer ID), notarize, staple — confirm `spctl -a -t exec` and `stapler validate` pass
  WITH the bundled Sparkle framework (re-sign correctness is the #1 failure point).
- **Real update dry-run:** publish a throwaway higher version to a test appcast, run the installed app,
  confirm it detects, downloads, verifies the EdDSA signature, and swaps atomically. Confirm a **delta**
  update (not a full 320 MB) is offered when prior archives exist.
- Confirm first-launch prompt appears once and the choice persists; confirm manual "Check for Updates…"
  works; confirm no network traffic beyond the appcast fetch.

## Acceptance criteria
1. Installed app offers a one-click in-app update from GitHub-hosted appcast, EdDSA-verified.
2. Update checks are opt-in (first-launch prompt) + a manual menu item; no telemetry beyond version check.
3. Delta updates work — a code-only release downloads a small patch, not the full app.
4. App (incl. Sparkle framework) signs, notarizes, staples, and passes Gatekeeper.
5. `SUFeedURL` points at a permanent GitHub URL; nothing points at a lapsable domain.
