# Wisp

[![Build and test](https://github.com/ZakVir/wisp/actions/workflows/ci.yml/badge.svg)](https://github.com/ZakVir/wisp/actions/workflows/ci.yml)
[![Secret scan](https://github.com/ZakVir/wisp/actions/workflows/secret-scan.yml/badge.svg)](https://github.com/ZakVir/wisp/actions/workflows/secret-scan.yml)

Wisp is a push-to-talk helper for the Mac. Hold **Control + Option**, ask anything out loud, and let go. Wisp answers
in a natural voice with captions. When your question is about what's on your screen, a small companion cursor flies
over to the right button, or circles it. It never clicks or types for you unless you ask it to open an app or a site.

- Ask about your screen: "how do I export this?", "what's that blue button?", "I can't remember my password".
- Or ask anything else: "how do I boil an egg?", "what's fifteen percent of eighty?". Those answers ignore the screen.
- Ask how to do something and Wisp walks you through it step by step: it shows the first step, watches while you do
  it, and tells you the next one when the screen settles ("what now?" works too).
- Light computer use: "open Chess", "open Instagram and search for…" (the cursor does it for you, with Accessibility
  permission). Say "draw a cat" and the cursor draws it on screen.
- Each question stands alone. There's no chat history.

macOS 15 or later, Apple silicon.

## Install

1. Download the newest `Wisp-x.y.z.dmg` from [wisp-updates releases](https://github.com/ZakVir/wisp-updates/releases),
   open it and drag **Wisp** to **Applications**. The first time, macOS may say it can't check Wisp: open
   **System Settings > Privacy & Security** and click **Open Anyway** (builds aren't notarized yet; see
   [docs/RELEASING.md](docs/RELEASING.md)). After that, Wisp updates itself.
2. Open Wisp. The welcome guide walks through:
   - what leaves your Mac;
   - downloading the on-device speech models (about 260 MB, automatic);
   - connecting the AI with a free [NVIDIA API key](https://build.nvidia.com/settings/api-keys);
   - Microphone, Input Monitoring and Screen Recording permissions;
   - choosing and practising the shortcut;
   - asking a first real question (Try it out).

Wisp lives in the menu bar (the cursor icon). Settings are under that menu.

## Privacy

- Your voice is turned into text **on this Mac** (Moonshine) and answers are spoken **on this Mac** (Kokoro).
  Audio never leaves it.
- While you hold the shortcut, Wisp takes a screenshot of the display you're using. If "Include my other displays" is
  on, it also takes your other displays (up to three). The screenshots and your question's text go to the AI provider
  you chose (NVIDIA NIM by default). Wisp doesn't keep them.
- Wisp keeps no analytics. Timing measurements stay on this Mac and contain no content. API keys are stored encrypted
  on this Mac.

## Settings

| Tab | What's there |
|---|---|
| General | Shortcut and hold/toggle mode; Open at login; microphone; voice (12 voices, with Preview); speed and volume; captions and sounds; Replay Welcome |
| Speech | Model downloads (Download / Try Again), Repair, Remove |
| AI | NVIDIA (free: Nemotron 3.5 Super VL answers, Step 5 Preview draws, Nemotron Nano backs up) or Custom (any OpenAI-compatible server: address, optional key, model with Find Models), connection test |
| Companion | Cursor theme, size, outline, keep-on-screen and opacity |
| Permissions / Privacy | Live permission status; what's sent where; "Include my other displays" |
| About | Version, updates, open-source credits |

## Building

```
cd app && xcodegen generate && open Wisp.xcodeproj      # app (scheme Wisp)
cd app/Packages/WispKit && swift test                  # unit tests
tools/run_app.sh                                       # build + relaunch the Debug app
tools/release.sh 0.3.0 4 --publish                     # Release build, checks, DMG, publish to wisp-updates
```

- Code: `app/Wisp` (app target) and `app/Packages/WispKit` (WispCore pure logic, WispMac UI and system,
  `wisp-bench` measurement CLI).
- How everything works and how to customize it: [docs/DEVELOPER-GUIDE.md](docs/DEVELOPER-GUIDE.md).
- Measurements and decisions (model bake-off, latency, prompt tuning) are in [docs/FINDINGS.md](docs/FINDINGS.md).
- Answer-quality test: `tools/run_prompt_suite.py tools/prompt_suite_200.json` (200 realistic questions; writes a
  results table).

## Repository layout

- `app/` holds the Wisp app (`app/Wisp`) and its Swift package (`app/Packages/WispKit`: `WispCore` pure logic with
  tests, `WispMac` UI and system code, `wisp-bench` measurement CLI). `app/project.yml` is the XcodeGen spec.
- `docs/` has the developer guide, findings, releasing notes and a release note for every version.
- `tools/` has build, release, measurement and test scripts.
- `design/` has the icon source and generated assets.
- `.github/` has the CI, secret-scan and dependency-update setup.

## Security

No API keys or signing keys are in this repository (see [SECURITY.md](SECURITY.md)); every push is scanned for
secrets. To run Wisp from source you bring your own free NVIDIA key, entered in the app's Settings and kept in the
macOS Keychain.

## Status and license

This repository is the source of Wisp, kept public as an open backup. It has **no license**: you can read it and fork
it on GitHub, but all other rights are reserved by the author. Pre-built, signed-by-the-developer releases are at
[ZakVir/wisp-updates](https://github.com/ZakVir/wisp-updates/releases).
