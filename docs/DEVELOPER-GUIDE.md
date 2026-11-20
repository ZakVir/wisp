# Wisp developer guide

Everything a person or an AI coding agent needs to understand, change and ship Wisp. Read this before editing code.
Measurements and the reasoning behind choices live in [FINDINGS.md](FINDINGS.md); releasing is in
[RELEASING.md](RELEASING.md).

## 1. What Wisp is

A macOS menu-bar app (macOS 15+, Apple silicon). The user holds a shortcut (Control + Option by default), asks a
question out loud and lets go. Wisp:

1. turns the speech into text **on the Mac** (Moonshine);
2. takes a screenshot of the display being used (optionally the other displays too);
3. sends the screenshot(s) and the question's text to a vision LLM (NVIDIA NIM by default, or any OpenAI-compatible
   server);
4. speaks the answer **on the Mac** (Kokoro) with captions;
5. when the question is about the screen, flies a companion cursor to the right control, or circles, underlines or
   draws an arrow to it. It never clicks or types.

Each question is one-shot: no chat history. Questions not about the screen are answered from general knowledge and
never touch the screen.

## 2. Repository map

| Path | What |
|---|---|
| `app/project.yml` | XcodeGen spec for the app target (version, Info.plist keys, Sparkle, signing). Run `xcodegen generate` after editing. |
| `app/Wisp/` | App target: `WispApp.swift` (entry point), `SparkleUpdater.swift`, `Info.plist`, entitlements, `Assets.xcassets` (app icon). |
| `app/Packages/WispKit/` | Swift package with all the code. |
| `…/Sources/WispCore/` | Pure logic, no AppKit: config, prompt, answer parser, chord state machine, geometry, themes, manifests, policy. Fully unit-tested. |
| `…/Sources/WispMac/` | Everything that touches macOS: audio, hotkey, capture, speech, vision client, overlay, windows, settings. |
| `…/Sources/wisp-bench/` | Command-line test bench (prompt suite, pointing eval, TTS/STT checks, signing). |
| `…/Tests/` | `WispCoreTests`, `WispMacTests` (XCTest). |
| `tools/` | Scripts: `run_app.sh`, `release.sh`, `run_prompt_suite.py`, manifest/icon generators, dev helpers (`axpress`, `chord`, `winshot.sh`…). |
| `docs/` | This guide, findings, releasing, release notes, welcome-animation design. |
| `design/` | Icon source and generated assets. |

## 3. Build, run, test

Toolchain: Xcode with Swift 6 (strict concurrency; developed on Xcode 27), XcodeGen.

```
cd app && xcodegen generate && open Wisp.xcodeproj       # app (scheme Wisp)
tools/run_app.sh                                        # build Debug + relaunch (add --fresh to reset TCC + settings)
cd app/Packages/WispKit && swift build && swift test    # package + unit tests
python3 tools/run_prompt_suite.py tools/prompt_suite_200.json   # answer-quality suite (needs an NVIDIA key)
tools/release.sh 0.3.0 4 --publish                      # Release build, checks, DMG, publish update
```

Debug builds read no update feed (the feed URL is set only in the Release configuration).

## 4. Architecture at a glance

```
WispApp (app target)
  └─ WispAppController            wires everything; owns windows (setup, settings), menu, updater hooks
       ├─ AppState                 observable config (ConfigStore), permissions, live key state, UI callbacks
       ├─ StatusItemController     menu-bar icon + menu (Stop, Settings, Welcome Guide, updates)
       ├─ TurnCoordinator          hold → record → release; earcons; cancellation; Stop
       │    ├─ HotkeyMonitor       CGEvent tap for the chord (ChordStateMachine in WispCore)
       │    └─ AudioRecorder       AVAudioEngine capture at 16 kHz mono
       ├─ TurnPipeline             one question end to end (below)
       │    ├─ SpeechToText        Moonshine (ONNX Runtime) streaming STT
       │    ├─ ScreenCapturer      ScreenCaptureKit screenshot(s) + geometry record
       │    ├─ AssistantEngine     vision request racing/fallback over VisionClient (SSE)
       │    ├─ KokoroSpeechEngine  on-device voice (KokoroChain on Core ML) / SystemSpeechEngine fallback
       │    └─ ContextProvider     optional extra knowledge per question (empty by default)
       ├─ OverlayController        transparent full-screen panels: companion cursor, flights, drawings
       ├─ CaptionController        caption plate beside the pointer
       ├─ RecoveryCardController   permission recovery cards
       └─ ModelManager             downloads, verifies and installs on-device models
```

## 5. One question, step by step

All in `WispMac/Turn/TurnCoordinator.swift` and `TurnPipeline.swift` unless noted.

1. **Key down.** `HotkeyMonitor` (CGEvent tap, needs Input Monitoring) feeds modifier changes to
   `ChordStateMachine` (WispCore). After a short confirmation delay the chord counts as a hold; quick taps and other
   keys cancel it. Hold mode or toggle mode (`Chord.mode`).
2. **Turn begins.** `TurnCoordinator` starts `AudioRecorder` (engine pre-built for low latency), plays the listening
   earcon and calls `pipeline.turnBegan`, which **takes the screenshot now** (what the user looks at while asking)
   and silently warms the voice model.
3. **Listening.** Audio chunks stream into `SpeechToText` (Moonshine streaming). The overlay shows a level meter.
4. **Key up.** The recorder keeps a short tail, stops and hands over the utterance. Silence or a too-short hold →
   a soft sound and the caption "I didn't catch a question…" (never spoken).
5. **Transcript.** `stt.finish()` (10 s timeout). Empty → same soft notice.
6. **Prompt.** `PromptBuilder.systemPrompt(space:)` (WispCore) + `PromptBuilder.userText(TurnFacts)`: screenshot
   sizes, pointer position, frontmost app, optional reference notes from the `ContextProvider`, and a hint when
   the question is about Wisp itself. A black (protected or sleeping) screenshot is flagged so the model knows it
   can't see.
7. **Ask.** `AssistantEngine.ask` streams from `VisionClient` (OpenAI-compatible `/chat/completions`, SSE). The
   primary model is raced against fallbacks after a quick busy/garbled failure (`RaceOwner`: the first lane to
   produce real content wins). In-stream error events and HTTP 429 count as busy.
8. **Parse.** `AssistantResponse` (WispCore) parses tagged lines as they arrive:
   `TOPIC`, `SAY`, `POINT`, `CIRCLE`, `UNDERLINE`, `ARROW`, `PATH`, with optional `| screen N`.
9. **Speak and show.** Each `SAY` sentence goes to the voice immediately (sentence streaming). Visual events wait
   for the sentence they follow, then the overlay flies there as that sentence starts. Guards
   (`QuestionIntent` in WispCore) drop visuals when the topic isn't the screen, the question is small talk or about
   Wisp, or the sentence denies something is there or asks the user back.
10. **Done.** Timing (`TurnTiming`) is logged locally (no content). "Still thinking…" appears after 6 s; Stop or a
    new hold cancels everything (barge-in).

## 6. The answer protocol and the prompt

- System prompt: `WispCore/Assistant/PromptBuilder.swift`. It is **principle-based** (identity; "you" = Wisp;
  decide the topic first; speaking style; when to show; care), not a list of patches for single failures. Keep it
  that way: when a test fails, fix the principle that covers it and anything similar.
- Reply format: the first line is `TOPIC: screen` or `TOPIC: other`, then `SAY:` sentences, and showing lines only
  in screen replies. Coordinates are in the model's native space (`ModelCoordinateSpace`: image pixels, 0–1000, or
  0–1), set per model in `VisionModelCatalog` and converted by `CaptureGeometry`.
- `QuestionIntent` (in `AssistantResponse.swift`): `isAboutAssistant`, `isSmallTalk`, `deniesPresence`,
  `asksBack`, `allowsPointing`. The prompt-suite script mirrors these.
- Testing answers: `tools/run_prompt_suite.py` sends the exact prompt (via `wisp-bench dump-prompt`) for 100/200
  realistic, vague questions and writes a table to `tools/out/suite/`. Re-run it after any prompt change.

## 7. AI providers

- Settings: `VisionSettings` in `WispCore/Config/AppConfig.swift` (`providerID`, `baseURL`, `modelID`,
  `fallbackModelIDs`, `timeoutSeconds`, `imageLongEdge`, `captureAllDisplays`, `customCoordinateSpace`).
- Providers: `VisionProvider` in `WispMac/Support/Keychain.swift`: `nvidia-nim` (key required, model catalog,
  fallbacks) and `openai-compatible` ("Custom": any `…/v1` server, key optional for local servers).
- Model catalog: `VisionModelCatalog` (best first; per-model coordinate space and request extras such as turning
  "thinking" off). Unknown models use `customCoordinateSpace`.
- Keys: `APIKeyStore` keeps them encrypted in Wisp's own storage (never prompts for a Keychain password).
  `APIKeyStore.isConnected(vision)` says whether Wisp can ask.
- UI: `AISettingsView`, `CustomProviderForm` (address, key, Find Models via `ModelListFetcher`, Connect →
  `VisionConnectionTest`, which sends a blank 64×64 image only).

## 8. On-device models

- Manifest: `WispMac/Resources/Models/manifest.json` + `.sig`, generated by `tools/make_manifest.py` and signed
  with `wisp-bench sign-manifest` (Ed25519 key in the login Keychain). Every file is pinned to a Hugging Face
  commit with size and SHA-256.
- `ModelManager`: downloads (resumable, mirrors, offline folder), verifies, installs atomically
  (`<id>/<version>/` + `.installed.json` marker), warms the runtime, retries network failures, Repair/Remove.
- Speech-to-text: Moonshine v2 Small streaming (`SpeechToText.swift`, ONNX Runtime).
- Voice: Kokoro-82M as seven Core ML stages (`KokoroChain.swift`, ported from FluidAudio, Apache-2.0), English G2P
  (`KokoroG2P.swift`), 12 voices (`VoiceCatalog`, voice packs are [510, 256] style tables). `SpeechTextNormalizer`
  spells numbers, symbols and abbreviations. Voice changes run on one serial queue.
- System voice (`SystemSpeechEngine`) is used until Kokoro is ready and for any sentence Kokoro can't voice.

## 9. Companion cursor and themes

- Overlay: `OverlayController` (one transparent panel per display, flights with springs from `WispCore/Motion`,
  drawing traced by the cursor), `OverlayView`, Metal renderer (`CompanionRenderer`, `CompanionShader`).
- Themes: `ThemeCatalog` (11 built-ins) in `WispCore/Companion/CompanionTheme.swift`. A theme is a palette, a fluid
  style and an accent pair; the accent also colours the app's windows (`WispStyle.theme`).
- Custom skins: `CustomSkin` (solid, gradient or photo colours) → `OverlaySettings.resolvedTheme`. Editor:
  `CustomSkinEditor`; photo colours: `PaletteExtractor` (k-means; only colours are kept, up to 50 MB files).
- Settings: `OverlaySettings` (theme, size, keep-on-screen, idle opacity, outline, reduce motion).

## 10. Settings and company control

- `ConfigStore` (WispCore) layers JSON: built-in defaults → user file
  (`~/Library/Application Support/Wisp/settings.json`) → **managed file**
  (`/Library/Application Support/Wisp/managed-config.json`; Debug builds can point elsewhere with `WISP_MANAGED_CONFIG`). Any key in the
  managed file wins and is locked; the UI shows it as managed (`app.isLocked("vision.modelID")`). A broken managed
  file never wipes user settings.
- New settings: add a property with a default to the right struct in `AppConfig.swift`. Old settings files keep
  working because layers merge over the defaults.
- `PolicyGate` (WispCore) decides every network request (`NetworkIntent`: purpose, host, whether it carries user
  content, frontmost app). The personal edition uses `ConsentPolicyGate` (user content only after the privacy
  step). A company build can add an allow-list of hosts or block certain apps.

## 11. Windows and flows

- Setup (`Onboarding/`): welcome animation (`WelcomeHero.swift`; design in `docs/welcome-animation.md`) → privacy
  → speech models → AI → microphone → shortcut (choose + practise) → screen → Try it out (real question + "Make it
  yours") → done. Progress is saved; Settings > General "Replay Welcome…" restarts it.
- Settings (`MenuBar/SettingsView.swift`): General, Speech, AI, Companion, Permissions, Privacy, About.
- Permissions: `PermissionModel` (WispCore) + `PermissionService`; `RecoveryCardPanel` explains how to re-enable
  one that was turned off.

## 12. Privacy rules (non-negotiable)

- Audio never leaves the Mac. Screenshots and question text go only to the chosen AI provider, only for that
  question, and are not stored.
- No screenshot, audio, transcript or answer content in logs, crash reports or analytics. Logs use
  `privacy: .public` only for content-free values (timings, counts, error codes).
- Keys are stored encrypted on the Mac, never in the repo, never printed. Wisp must never trigger a Keychain
  password prompt.

## 13. Updates and releases

- Sparkle 2 (`app/Wisp/SparkleUpdater.swift`): daily checks, quiet installs at an idle moment. Feed:
  `https://raw.githubusercontent.com/ZakVir/wisp-updates/main/appcast.xml` (Release configuration only). Public
  key in `project.yml` (`SUPublicEDKey`); the private key is in the login Keychain (back it up).
- `tools/release.sh <version> <build> [--publish]`: Release archive (arm64), re-signs Sparkle helpers, checks
  entitlements/feed/debug hooks, makes the DMG, signs the update, publishes a GitHub release and the feed to
  `ZakVir/wisp-updates`, tags the source. Build numbers must increase. Notes come from `docs/release-notes/`.
- Builds are signed with an Apple Development identity and not notarized yet (users choose Open Anyway once).
  Moving to a Developer ID later changes the signature, so users would need to grant permissions again.

## 14. Debug hooks and tools

Debug builds only (stripped from Release; `release.sh` checks):

| Hook | Effect |
|---|---|
| `WISP_HOME=<dir>` | Use a separate settings/models/keys folder (fresh-install testing). |
| `WISP_FAKE_MIC_FILE=<wav>` | Replace the microphone with a file. **Answers are spoken; don't leave it running.** |
| `WISP_FAKE_PERMISSIONS` | Pretend permissions are granted/denied. |
| `WISP_DEMO_SCRIPT`, `WISP_DEMO_TARGET` | Scripted overlay demos. |
| `WISP_MANAGED_CONFIG=<file>` | Use another managed-config file (Debug only, so a launch flag can never drop an admin's locks). |
| `WISP_ONBOARDING_HEIGHT=<pt>` | Taller setup window for screenshots. |
| `--show-onboarding`, `--onboarding-step=N` | Open setup (at page N). |

`wisp-bench` commands include: `prompt-suite`, `dump-prompt`, `ask`, `point-eval`, `probe`, `vision-check`,
`capture`, `record`, `stt-eval`, `stt-record`, `speak`, `tts-render`, `tts-compare`, `phonemes`,
`latency-report`, `themes`, `sign-manifest`, `update-key`, `sign-update`, `set-key`/`get-key` (scripts only).

Tools: `tools/run_app.sh`, `tools/winshot.sh` (screenshot Wisp's windows), `build/tools/axpress` (press a button by
name via Accessibility), `build/tools/chord` (hold the shortcut programmatically), `tools/make_app_icon.py`.

## 15. Customization recipes

| Goal | Where |
|---|---|
| Change how Wisp talks or behaves | `PromptBuilder.systemPrompt` (principles), then run the prompt suite. |
| Change defaults (shortcut, voice, model, theme) | Defaults in `AppConfig.swift`; for a fleet, a managed-config file instead. |
| Add a model to the NVIDIA list | `VisionModelCatalog` (id, display name, coordinate space, extras); measure with `point-eval`. |
| Use another AI service | Settings > AI > Custom, or set `vision.providerID/baseURL/modelID` in managed config. Non-OpenAI APIs need an adapter next to `VisionClient`. |
| Add knowledge (product docs, company how-tos) | Implement `ContextProvider` and pass it to `TurnPipeline(app:context:)` in `WispAppController`. Snippets appear in the prompt as "Reference notes" (up to 5, 600 characters each; raise those limits in `PromptBuilder.userText` if needed). |
| Restrict where data goes | Implement `PolicyGate` (allow-listed hosts, blocked apps) and use it where `ConsentPolicyGate` is created. |
| Add a theme | `ThemeCatalog.all` (palette darkest → brightest, style, accents). |
| Add a voice | `VoiceCatalog` + the voices entry in `tools/make_manifest.py`, regenerate and sign the manifest. |
| Rebrand | Name, bundle ID, icon and feed in `app/project.yml` + `Assets.xcassets`; new update key (`wisp-bench update-key`); new releases repo (`WISP_RELEASES_REPO` for `release.sh`). |

### A company edition (outline)

The code was built with this in mind:

1. **AI**: point Wisp at the company's provider: an OpenAI-compatible endpoint (OpenAI, Azure OpenAI, a gateway,
   or a self-hosted model). Claude's Messages API needs a small adapter, or an OpenAI-compatible gateway in front.
   The model must accept images. Lock the choice in the managed config. The quickest way to write one: set up a
   Mac the way the company wants, use Settings > General > Export Settings… (`ConfigTransfer`; never contains
   keys), trim it to the keys to lock, and deploy it as `/Library/Application Support/Wisp/managed-config.json`.
2. **Knowledge**: a `ContextProvider` that searches the company's help docs (an embeddings index bundled with the
   app or queried from an internal search service), using the question and the frontmost app's bundle ID to pick
   the right product's pages.
3. **Behaviour**: add principles to the prompt (company terms, tone, which internal tools exist), and an optional
   per-company app-name map so the frontmost app is described well.
4. **Control**: managed config deployed by MDM (locks provider, model, data settings), a `PolicyGate`
   allow-listing only the company endpoints and blocking sensitive apps (e.g. never capture while a password
   manager is in front).
5. **Distribution**: own bundle ID, Developer ID signing and notarization, own update feed.

## 15b. Features added in 0.3.3–2.4 (where they live)

- **Local answers before the AI** (`TurnPipeline.process`, in this order): writing help on the selection or window
  (`WritingHelp`), voice commands (`VoiceCommand`), notes (`Notes`), timers (`TimerCommand`, scheduled in
  `WispAppController`), math/time/Mac facts/spelling (`QuickMath`, `TimeAnswer`, `MacFacts` + `MacFactsReader`,
  `LittleHelpers`), dictionary (`Definition`, macOS `DCSCopyTextDefinition`), magnifier (`QuestionIntent.isMagnify`,
  `MagnifierController`), copy text on screen / read page (`ScreenText.readableText`, `ScreenCapturer.captureWindow`),
  shortcuts card (`UIContextReader.menuShortcuts`, `ShortcutsCardController`), "say that again", read aloud.
  Each intent is a pure WispCore matcher with tests; anything unmatched goes to the model as before.
- **Better answers extras**: selected text and the control under the pointer (`UIContext.selectedText/underPointer`,
  re-read at key-up), greyed-out note (`VisualDecision.greyedOutNote`, mirrored in `wisp-bench correctness-eval`).
- **Typed questions**: double-tap detector (`DoubleTapDetector`, key from settings) → `AskBoxController` (quick
  actions: `QuickAction`) → `TurnCoordinator.begin/submitTypedTurn`; answer card `AnswerCardController`.
- **Guidance**: `GuideSession` + click monitor in `WispAppController`; follow-up steps carry `TurnFacts.guideText`.
- **Windows**: What's New (`WhatsNew` entries, one per version), Check-up (`CheckupView`), History (`History`,
  `HistoryView`; saved only with `privacy.keepHistory`), shortcuts card, magnifier.
- **Privacy**: private apps (`privacy.privateApps`: SCContentFilter exclusion + AX skips), clipboard only when
  mentioned (`QuestionIntent.mentionsClipboard`), notes/history files 0600 in Application Support.
- **Providers**: `VisionClient.Wire` (`.openAIChat`, `.anthropicMessages`), `VisionProvider.anthropic`, Claude models
  in `VisionModelCatalog.claude`; request building and stream parsing are unit-tested (`VisionWireTests`).
- **Releases**: `tools/ship_version.sh` (single version) or the overnight queue pattern: feature commits with
  `docs/release-notes/<ver>.md`, a "Wisp <ver> (build N)" commit after each, `tools/release.sh <ver> <build>
  --publish` per commit, main fast-forwarded to it.

## 16. Conventions for contributors and agents

- Small commits, pushed often; never merge to `main` without the owner's OK. Make a GitHub release per version.
- Swift 6 strict concurrency; WispCore stays free of AppKit and is unit-tested.
- Prompt changes are principle-based and verified with the 200-question suite.
- Plain, friendly wording in the UI and in anything spoken (no "API"/"NIM" jargon in spoken text).
- Don't make Wisp speak on someone's Mac during automated tests; render audio to files instead.
- Respect the privacy rules in section 12 in every change.
