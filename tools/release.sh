#!/bin/bash
# Build a release of Wisp: archive (Release, hardened runtime) → sign → notarize + staple → DMG → Sparkle appcast.
#
# Usage: tools/release.sh [version] [build] [--publish]
#   version  marketing version, e.g. 0.2.0 (default: from project.yml)
#   build    build number, e.g. 2 (default: from project.yml)
#   --publish  publish to the public releases-only repo (WISP_RELEASES_REPO, default ZakVir/wisp-updates): the DMG as
#              release v<version>, the update feed (appcast.xml, newest first), and a tag on the source repo.
#              Notes come from docs/release-notes/<version>.md if present.
#
# Signing: uses a "Developer ID Application" identity when one is in the login Keychain; otherwise falls back to
# the Apple Development identity and SKIPS notarization. Such a build runs on any Mac, but people must allow it once
# (System Settings > Privacy & Security > Open Anyway).
# Notarization: needs a notarytool profile stored once with
#   xcrun notarytool store-credentials WISP_NOTARY --apple-id <id> --team-id 373GNFYF7D
# (override the profile name with WISP_NOTARY_PROFILE).
# Appcast: DMG links default to the releases repo; the app's feed URL is WISP_APPCAST_URL (Release config) in
# app/project.yml. If publishing fails half-way, delete the release in the releases repo and re-run (a re-run makes
# a new DMG with a new signature, so never hand-merge an old appcast item).
#
# Output: build/release/<version>/Wisp-<version>.dmg, appcast.xml, release-notes.txt (checks performed).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TEAM=373GNFYF7D
PUBLISH=no
ARGS=()
for a in "$@"; do if [ "$a" = "--publish" ]; then PUBLISH=yes; else ARGS+=("$a"); fi; done
set -- "${ARGS[@]+"${ARGS[@]}"}"
VERSION=${1:-$(grep MARKETING_VERSION app/project.yml | sed -n 1p | sed -E 's/.*"(.*)".*/\1/')}
BUILD=${2:-$(grep CURRENT_PROJECT_VERSION app/project.yml | sed -n 1p | sed -E 's/.*"(.*)".*/\1/')}
[[ $BUILD =~ ^[0-9]+$ ]] || { echo "build must be a whole number (got '$BUILD')"; exit 1; }
OUT=$ROOT/build/release/$VERSION
NOTARY=${WISP_NOTARY_PROFILE:-WISP_NOTARY}
# Public, releases-only repo: installers + update feed (the source repo stays private).
RELEASES_REPO=${WISP_RELEASES_REPO:-ZakVir/wisp-updates}
mkdir -p "$OUT"
NOTES=$OUT/release-notes.txt
: > "$NOTES"
note() { echo "$*"; echo "$*" >> "$NOTES"; }

DEVID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$DEVID" ]; then
  note "signing: $DEVID"
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$DEVID" DEVELOPMENT_TEAM=$TEAM OTHER_CODE_SIGN_FLAGS=--timestamp)
else
  note "signing: Apple Development (no Developer ID Application certificate found; notarization will be skipped)"
  SIGN_ARGS=(CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=$TEAM)
fi

# 1. Archive.
(cd app && xcodegen generate -q >/dev/null)
LOG=$OUT/xcodebuild.log
if ! xcodebuild -project app/Wisp.xcodeproj -scheme Wisp -configuration Release -derivedDataPath build/DerivedData-release \
     -destination 'generic/platform=macOS' -archivePath "$OUT/Wisp.xcarchive" archive \
     ARCHS=arm64 MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" "${SIGN_ARGS[@]}" >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20; echo "ARCHIVE FAILED (log: $LOG)"; exit 1
fi
APP=$OUT/Wisp.app
rm -rf "$APP"
ditto "$OUT/Wisp.xcarchive/Products/Applications/Wisp.app" "$APP"
note "archived Wisp $VERSION ($BUILD)"

# 1b. Sign Sparkle's helpers with our identity, one piece at a time (Sparkle: never --deep). `xcodebuild archive` leaves
#     them ad-hoc signed, which notarization rejects. XPC services are only for sandboxed apps; Wisp isn't sandboxed.
ID=${DEVID:-$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' | sed -n 1p)}
[ -n "$ID" ] || { echo "can't tell which identity signed the app"; exit 1; }
TS=--timestamp; [ -n "$DEVID" ] || TS=--timestamp=none
SPK="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPK/XPCServices" "$SPK/Versions/B/XPCServices"
codesign -f -s "$ID" -o runtime $TS "$SPK/Versions/B/Autoupdate"
codesign -f -s "$ID" -o runtime $TS "$SPK/Versions/B/Updater.app"
codesign -f -s "$ID" -o runtime $TS "$SPK"
codesign -f -s "$ID" -o runtime $TS --preserve-metadata=entitlements,requirements "$APP"
for part in "$SPK/Versions/B/Autoupdate" "$SPK/Versions/B/Updater.app" "$SPK" "$APP"; do
  INFO=$(codesign -dv "$part" 2>&1)
  grep -q "TeamIdentifier=$TEAM" <<<"$INFO" || { echo "$part isn't signed by team $TEAM"; exit 1; }
done
note "signed Sparkle helpers and app as: $ID"

# 2. Checks that must hold for every release.
codesign --verify --deep --strict "$APP"
FLAGS=$(codesign -d --verbose=2 "$APP" 2>&1 | grep -o 'flags=0x[0-9a-f]*([^)]*)' || true)
echo "$FLAGS" | grep -q runtime || { echo "hardened runtime missing"; exit 1; }
codesign -d --entitlements - --xml "$APP" > "$OUT/ents.plist" 2>/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$OUT/ents.plist" 2>/dev/null)" = true ] \
  || { echo "audio-input entitlement missing"; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$OUT/ents.plist" 2>/dev/null || echo false)" = true ] \
  && { echo "get-task-allow is true (debuggable build)"; exit 1; }
FEED_URL=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null || true)
if [ "$PUBLISH" = yes ] && [[ $FEED_URL != https://* ]]; then echo "SUFeedURL is empty: this build could never update itself"; exit 1; fi
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")
# Capture the strings first: `strings | grep -q` can die of SIGPIPE under pipefail and wrongly pass.
BIN_STRINGS=$(strings -a "$APP/Contents/MacOS/Wisp")
for hook in WISP_FAKE_MIC_FILE WISP_FAKE_PERMISSIONS WISP_DEMO_SCRIPT WISP_DEMO_TARGET WISP_MANAGED_CONFIG; do
  if grep -q "$hook" <<<"$BIN_STRINGS"; then echo "debug hook $hook present in release binary"; exit 1; fi
done
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || { echo "Sparkle.framework not embedded"; exit 1; }
note "checks: signature valid, hardened runtime ($FLAGS), audio-input entitlement, no get-task-allow, no debug hooks, Sparkle embedded"

# 3. Notarize and staple the app (Developer ID only).
NOTARIZED=no
if [ -n "$DEVID" ]; then
  if xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1; then
    ditto -c -k --keepParent "$APP" "$OUT/Wisp-notarize.zip"
    xcrun notarytool submit "$OUT/Wisp-notarize.zip" --keychain-profile "$NOTARY" --wait | tee -a "$NOTES"
    xcrun stapler staple "$APP"
    rm -f "$OUT/Wisp-notarize.zip"
    NOTARIZED=yes
  else
    note "notarization skipped: no notarytool profile '$NOTARY' (see header of this script)"
  fi
fi

# 4. DMG: designed window (design/dmg, tools/dmg_settings.py) with Wisp, an Applications shortcut and the drag hint.
DMG=$OUT/Wisp-$VERSION.dmg
rm -f "$DMG"
if command -v uvx >/dev/null 2>&1 && [ -f design/dmg/background.tiff ]; then
  uvx --from dmgbuild dmgbuild -s tools/dmg_settings.py -D app="$APP" "Wisp $VERSION" "$DMG" >/dev/null 2>&1 \
    || { echo "dmgbuild failed"; exit 1; }
  note "dmg window: designed background (dmgbuild)"
else
  # Fallback without uv: plain window with an Applications shortcut.
  STAGE=$(mktemp -d)
  ditto "$APP" "$STAGE/Wisp.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "Wisp $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO "$DMG"
  rm -rf "$STAGE"
  note "dmg window: plain (install uv for the designed installer window)"
fi
if [ -n "$DEVID" ]; then
  codesign --sign "$DEVID" --timestamp "$DMG"
  if [ "$NOTARIZED" = yes ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY" --wait | tee -a "$NOTES"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | tee -a "$NOTES"
    spctl --assess --type execute -v "$APP" 2>&1 | tee -a "$NOTES"
  fi
fi
note "dmg: $DMG ($(du -h "$DMG" | cut -f1))"

# 5. Sparkle appcast entry, signed with the update key (wisp-bench update-key).
BENCH=app/Packages/WispKit/.build/debug/wisp-bench
(cd app/Packages/WispKit && swift build --product wisp-bench >/dev/null)   # never sign with a stale tool
SIG=$("$BENCH" sign-update "$DMG")
# Installers are attached to each GitHub release, so that's where the feed points by default.
BASE=${WISP_DOWNLOAD_BASE:-https://github.com/$RELEASES_REPO/releases/download/v$VERSION/}
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Wisp</title>
    <item>
      <title>Wisp $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="${BASE}Wisp-$VERSION.dmg" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
XML
# The item on its own, for merging into the running feed (step 7).
sed -n '/<item>/,/<\/item>/p' "$OUT/appcast.xml" > "$OUT/appcast-item.xml"
note "appcast: $OUT/appcast.xml (download base: $BASE)"
[ "$NOTARIZED" = yes ] && note "READY TO SHIP" || note "NOT notarized: works on any Mac, but people allow it once in Privacy & Security"

# 6. Publish (optional): installer + notes as a release in the public releases repo, the update feed in that repo's
#    main branch (newest first), and a tag on the private source repo for traceability.
if [ "$PUBLISH" = yes ]; then
  gh auth status >/dev/null 2>&1 || { echo "gh is not logged in (gh auth login)"; exit 1; }
  if gh release view "v$VERSION" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
    echo "v$VERSION is already published in $RELEASES_REPO; bump the version"; exit 1
  fi
  FEED=$(mktemp -d)
  git clone -q --depth 1 "https://github.com/$RELEASES_REPO.git" "$FEED"
  # Builds must only go up, or Sparkle won't offer the update.
  LAST_BUILD=$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$FEED/appcast.xml" | grep -o '[0-9]*' | sort -n | tail -n 1 || true)
  if [ -n "$LAST_BUILD" ] && [ "$BUILD" -le "$LAST_BUILD" ]; then
    echo "build $BUILD is not newer than the published build $LAST_BUILD"; exit 1
  fi
  {
    echo "**Wisp $VERSION**"
    echo
    echo "Install: download **Wisp-$VERSION.dmg** below, open it and drag Wisp to Applications. Already using Wisp? It updates itself."
    [ "$NOTARIZED" = yes ] || echo "First open on a new Mac: if macOS says it can't check Wisp, open System Settings > Privacy & Security and click **Open Anyway**."
    echo
    if [ -f "$ROOT/docs/release-notes/$VERSION.md" ]; then cat "$ROOT/docs/release-notes/$VERSION.md"; fi
    # The getting-started guide travels with every release (the source repo is private).
    if [ -f "$ROOT/docs/CLIENT-GUIDE.md" ]; then echo; echo "---"; echo; sed 's/^# /## /' "$ROOT/docs/CLIENT-GUIDE.md"; fi
  } > "$OUT/github-notes.md"
  python3 - "$FEED/appcast.xml" "$OUT/appcast-item.xml" "$BUILD" <<'PY'
import os, re, sys
feed_path, item_path, build = sys.argv[1], sys.argv[2], sys.argv[3]
item = open(item_path).read().strip()
head = ('<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        '  <channel>\n    <title>Wisp</title>\n')
items = re.findall(r"\s*<item>.*?</item>", open(feed_path).read(), re.S) if os.path.exists(feed_path) else []
items = [i for i in items if f"<sparkle:version>{build}</sparkle:version>" not in i]
open(feed_path, "w").write(head + "    " + item + "".join(items) + "\n  </channel>\n</rss>\n")
print(f"feed now lists {len(items) + 1} release(s)")
PY
  # Installer first, then the feed that points at it (so the feed never links to a missing file).
  gh release create "v$VERSION" --repo "$RELEASES_REPO" --latest --title "Wisp $VERSION" \
     --notes-file "$OUT/github-notes.md" "$DMG"
  (cd "$FEED" && git add appcast.xml && git commit -qm "Wisp $VERSION ($BUILD)" && git push -q origin HEAD:main)
  rm -rf "$FEED"
  if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    note "source tag v$VERSION already exists; left as is"
  else
    git tag "v$VERSION" && git push -q origin "v$VERSION"
  fi
  note "published Wisp $VERSION to https://github.com/$RELEASES_REPO/releases/tag/v$VERSION (feed updated)"
fi

# Only the DMG is kept: the archive and the unpacked app would otherwise each show up as another copy of Wisp
# (Spotlight, the Apps launcher, Storage settings), one more per release.
rm -rf "$OUT/Wisp.xcarchive" "$APP"
note "kept: $DMG (the build's app copies were removed)"
