# Releasing Wisp

`tools/release.sh [version] [build]` does the whole thing and stops at the first failed check:

1. Archives a Release build (arm64, hardened runtime) with the version you pass.
2. Checks every release: valid signature, hardened runtime, microphone entitlement, not debuggable (no
   `get-task-allow`), none of the `WISP_*` debug hooks in the binary, Sparkle embedded.
3. Notarizes and staples the app, builds a DMG (with an Applications shortcut), signs, notarizes and staples it.
4. Writes a one-item Sparkle `appcast.xml`, with the DMG signed by the update key.

Add `--publish` to also create the GitHub release `v<version>` with the DMG, the appcast and notes listing the
commits since the previous tag (a pre-release until builds are notarized). Bump the version for every release
(`tools/release.sh 0.1.1 3 --publish`).

Output goes to `build/release/<version>/`, with a `release-notes.txt` that lists what was checked.

## One-time setup

| What | How | Status |
|---|---|---|
| Developer ID Application certificate | Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application (needs a paid Apple Developer membership) | **Missing**: builds are signed with Apple Development. They run on any Mac after a one-time "Open Anyway". Switching to Developer ID later makes macOS ask everyone for permissions again, so get it before sharing widely |
| Notarization credentials | `xcrun notarytool store-credentials WISP_NOTARY --apple-id <id> --team-id 373GNFYF7D` (app-specific password) | Not set |
| Update signing key | `wisp-bench update-key` (Ed25519, login Keychain; public key already in `project.yml` as `SUPublicEDKey`) | Done |
| Update feed | `--publish` publishes to the public releases-only repo `ZakVir/wisp-updates` (see below) | Done |

Debug builds have no feed URL, so Sparkle never starts in them. Release builds check daily, download quietly and install
at an idle moment (not mid-question), because a menu-bar app is rarely quit. Both can be switched off in Settings >
About.

## Downloads and automatic updates

- Installers and the update feed live in the **public, releases-only** repo
  [ZakVir/wisp-updates](https://github.com/ZakVir/wisp-updates). The source repo stays private.
- `--publish`:
  - attaches the DMG to release `v<version>` there;
  - adds the version to that repo's `appcast.xml` (newest first; refuses a build number that isn't higher than the
    last one);
  - tags the source commit.
- Wisp reads `https://raw.githubusercontent.com/ZakVir/wisp-updates/main/appcast.xml` (`WISP_APPCAST_URL` in
  `app/project.yml`). It checks daily and installs quietly by default; both can be switched off in Settings > About.
- Share `https://github.com/ZakVir/wisp-updates/releases/latest` with people who want Wisp. Until there's a Developer ID,
  they allow it once in System Settings > Privacy & Security > Open Anyway (the repo README says how).

Checked: signatures made by `wisp-bench sign-update` pass Sparkle's own `sign_update --verify` against the same key,
and a corrupted signature is rejected.

## Keys

- Model manifest signing: login Keychain `com.zakvirani.wisp.manifest-signing` (`wisp-bench sign-manifest`).
- App update signing: login Keychain `com.zakvirani.wisp.update-signing` (`wisp-bench sign-update`).

These are two separate keys: losing or leaking one doesn't affect the other. Neither key is ever committed.

## Release history

`v0.0.1` to `v0.0.9` are source snapshots of the milestone branches (M0 to M7+M8). `v0.1.0` is the first installable
build (DMG attached).

## Back up the update key

`com.zakvirani.wisp.update-signing` in the login Keychain signs every update. If it's lost, already-installed copies
can never update again. Export it somewhere safe (for example, an encrypted note in a password manager):
`security find-generic-password -a update-signing-key-1 -s com.zakvirani.wisp.update-signing -w`
