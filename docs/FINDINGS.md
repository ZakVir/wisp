# Findings: measured, not estimated

Every number here was measured on real hardware or read from a primary source. Test machine unless
stated otherwise: **MacBook Air M2, 8 GB RAM, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4.**

Legend: **Measured** = timed/observed here. **Primary** = read from the vendor/model card/repo itself.
**Pending** = cannot be measured without the user (noted why).

---

## 1. Vision models on NVIDIA NIM (free endpoints)

### 1.1 Which free endpoints accept images (Primary, build.nvidia.com, 2026-10-01)
39 models carry the "Free Endpoint" badge. Their model cards list image input for:
`moonshotai/kimi-k3`, `deepseek-ai/deepseek-v4.1-flash`, `z-ai/glm-5.3-flash`, `meta/muse-glimmer-30b`,
`google/gemma-4-31b-it`, `google/diffusiongemma-26b-a4b-it`, `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning`,
`nvidia/cosmos3-nano-reasoner`, `nvidia/ising-calibration-1.5-31b` (quantum-calibration plots),
`nvidia/ising-calibration-1-35b-a3b`, `meta/llama-3.2-11b-vision-instruct`, `meta/llama-3.2-90b-vision-instruct`,
`google/paligemma` (different, non-chat API). Safety classifiers that also take images
(`nvidia/nemotron-3.5-content-safety`, `meta/llama-guard-4-12b`) are excluded: they cannot answer questions.
Many other ids listed by `GET /v1/models` return HTTP 404 ("Function not found"): listed but not deployed.

### 1.2 First probe: one synthetic UI image, "where is Export?" (Measured, 2026-10-01)
Synthetic 1456×910 image (no real screen content), streaming, temperature 0, `tools/nim_vision_probe.py`.

| Model | Hit | Time to first content token | Notes |
|---|---|---|---|
| kimi-k3 (default, thinking on) | yes (1290,790) | 8.41 s (reasoning starts 3.18 s) | 565 reasoning chars before answering |
| **kimi-k3, `chat_template_kwargs: {"thinking": false}`** | **yes** | **1.84 s** (2.15 s total) | no reasoning tokens; same answer |
| kimi-k3, `reasoning_effort: low` | yes | 7.05 s | still reasons |
| glm-5.3-flash (default) | yes | 12.5 s | |
| glm-5.3-flash, `reasoning_effort: low` | yes (1231,788) | 13.8 s | thinking flags ignored |
| llama-3.2-11b-vision | no (1456,844) | 0.68 s | fast but wrong |
| llama-3.2-90b-vision | no | 15.4 s | |
| nemotron-3-nano-omni | no | 20.5 s | |
| gemma-4-31b-it | no | 31.6 s | |
| deepseek-v4.1-flash | timeout | > 90 s | timed out in the first probe; re-test in the bake-off |

**Decision input:** Kimi K3 must be called with thinking disabled for interactive use (≈4.5× faster first
token, same answer). The full accuracy/speed bake-off is in section 6 (M8); it supersedes this one-image probe
(Nemotron, Gemma and DeepSeek "missed" here because of coordinate space and queueing, not accuracy).

---

## 2. On-device speech-to-text: Moonshine v2 Small (streaming, English)

Primary sources: github.com/moonshine-ai/moonshine (commit 234f60f, LICENSE), moonshine-swift v0.1.5,
huggingface.co/moonshine-ai/moonshine-voice-assets (commit 0bf2f2e5…).

- **Licence:** MIT for code and for all streaming and English models (LICENSE lines 1–5). Compiled-in third
  party: onnxruntime (MIT), Eigen (MPL-2.0), kaldi-native-fbank (Apache-2.0), kissfft (BSD), nlohmann/json (MIT).
- **Runtime:** `moonshine-swift` 0.1.5 (`MoonshineVoice`), a static xcframework with ONNX Runtime 1.23 compiled in;
  CPU by default. No Core ML conversion of v2 streaming exists. Adds ~29 MB (stripped, arm64) to the app.
- **Files** (`model/small-streaming-en/quantized_26_08_21/`, 8-bit weights), total **142,300,974 bytes (135.7 MiB)**:

| File | Bytes | SHA-256 |
|---|---:|---|
| adapter.ort | 2,870,368 | c665f742364febad597cc9ac1e0b341ffbee0e24a1466e2f3bde95e6e4771762 |
| cross_kv.ort | 5,356,536 | e2d3417144e9514055ebfefe8dcc4c0a55a55adcb8530435844c75c53e352bf6 |
| decoder_kv.ort | 81,878,600 | 1a05465b1dd955858dfcbee039c0020fb5dd982b0f5094c34e61735d518d771b |
| encoder.ort | 44,148,576 | 2d4d973e91e8aca08c51e7e7efa28a46ab265b63d809d5294d18b86bcd85b993 |
| frontend.model.ort | 26,944 | 09b1210ae30dc5f0f3e45f0ebab914c254741323114f53fbbe5ae62cca35058f |
| frontend.weights.ort | 7,769,464 | 7ef97521bd4bad3928f5bb6808586f4fcc6e92bd5990394112eed7d4052ec338 |
| streaming_config.json | 512 | 26f02b6afb22d60871a5efd85c3d38e569cc0ddb6c5eb6e93d3260152ae8a47a |
| tokenizer.bin | 249,974 | 6884b35fd6377d4c4d32336a0bc152f36b64d1e45b6503683cdc238250a8472d |

- **Measured (sample harness, M2):** model load 733–859 ms cold / 90–95 ms warm; end of audio → final text
  43 ms (20 ms chunks) to 100–130 ms (100 ms chunks) after `stop()`; streaming RTF 0.19–0.24; peak memory
  footprint 0.5–0.7 GB (important on 8 GB Macs: unload when idle). Synthetic test sentence transcribed exactly;
  with key terms set, capitalisation of UI terms was exact. Re-measured inside the app in M4/M7.

---

## 3. On-device text-to-speech: Kokoro-82M v1.0, Core ML

**Update 2026-10-02: replaced the INT8 model with FluidInference's seven-stage chain.** The owner heard a grainy
"ehhh" in the voice. I rendered the same phonemes (Wisp's G2P) through hexgrad's PyTorch Kokoro (reference), the
aufklarer INT8 model (what we shipped) and FluidInference's `ANE/` chain (laishere/kokoro-coreml conversion,
maintained in FluidAudio). Spectrograms showed the INT8 vocoder adding a noise floor between the harmonics (the grain),
and its durations ran ~25% faster than the reference (4.93 s vs 6.45 s for the same two sentences). The chain matches
the reference in timing and harmonic structure. FluidInference's single-file fp16 `kokoro_21_5s_v2` was also tried:
right timing but smeared low frequencies and a steady ~250 Hz line, and its `audio_length_samples` is half the real
length. Measured on this Mac (debug build): one short sentence 0.16 s, a 5.7 s sentence 0.47 s (old: ~0.5 s per call
whatever the length); after 10-30 s idle the first call takes ~0.9 s (prewarmed at key-down); first-ever load 16 s
(Neural Engine compile, once), later loads 2.3 s. Files: 82.3 MB (34 files) pinned to commit 006395f. Pipeline code
ported from FluidAudio (Apache-2.0) into `KokoroChain.swift`; Wisp keeps its own G2P, voices and verified downloads.
The rest of this section describes the original INT8 choice.

Primary sources: huggingface.co/hexgrad/Kokoro-82M, aufklarer/Kokoro-82M-CoreML-INT8 (commit 4bc7df47…),
FluidInference/kokoro-82m-coreml (commit 006395f6…).

- **Size question:** v0.19, v1.0 and v1.1-zh all have **81,763,410 parameters** (counted from the official
  checkpoints). Nothing larger exists, so "largest under 200M" = **v1.0** (full English voice set).
- **Licence:** weights Apache-2.0; Core ML conversion and its dictionaries/G2P Apache-2.0. Upstream Kokoro's
  optional espeak-ng fallback is GPL-3; **we do not use it** (dictionary + BART G2P Core ML instead).
  Unknown: what the BART G2P was trained on (undocumented).
- **Runtime:** our own Swift code on Core ML (`.cpuAndNeuralEngine`; `.all` was 5× slower). Observed: the INT8
  graph runs on CPU here, not the Neural Engine, despite the "ANE-optimized" label.
- **Footprint:** ~90.8 MB English runtime (pre-compiled `.mlmodelc`: no on-device compile needed);
  `kokoro_5s.mlmodelc` weight file 81,762,944 bytes (so the reported "~83 MB" is right).
- **Measured (sample harness, M2):** first-ever load ≈2 s; warm process start → first audio 0.86–0.90 s;
  0.39–0.48 s per sentence (≈7–8× faster than real time); peak memory ≈180 MB. Max 126 phonemes / 5 s per call
  (we chunk by sentence). Output sanity: 3.10 s, −23.0 dBFS RMS. Re-measured inside the app in M5/M7.

**Combined on-device model footprint ≈ 233 MB** (limit 700 MB).

---

## 4. Audio capture (M1)

| Metric | Value | How |
|---|---|---|
| `AudioRecorder.start()` returns | 27 ms | file source, bench |
| Key-down → first converted buffer | 61–82 ms | **file source** (simulates a warm mic); real mic **Pending** |
| Tail kept after key-up | 200 ms (setting) | stop() measured 200.7 ms |
| Conversion | 48 kHz stereo → 16 kHz mono Float32 verified in unit test | |
| End-to-end hold → utterance handed on | works (3.15 s utterance from a 3 s hold) | real CGEvent chord + app |

**Pending (needs the user):** real-microphone first-buffer latency and clipped-first-word rate. This session's
host app has no microphone permission and Wisp never answers permission prompts itself. Run
`wisp-bench record 3` from Terminal after granting it the microphone, or hold the shortcut in Wisp.

---

## 4b. Screenshot capture (M2)

`wisp-bench capture 15` on the built-in 1710×1112 pt Retina display (3420×2224 px → sent 1456×946), Measured:

| Mode | capture+resize+JPEG p50 | ScreenCaptureKit p50 | resize p50 | JPEG p50 | JPEG size |
|---|---|---|---|---|---|
| Full-res capture + Lanczos downscale | 84.9 ms | 56.8 ms | 21.1 ms | 6.8 ms | 442 KB |
| **ScreenCaptureKit scales to 1456 px (default)** | **62.2 ms** | 54.9 ms | 0 | 6.2 ms | 360 KB |

P95 includes the first (cold) capture: 498 ms vs 147 ms. Visual text comparison at 2× zoom: nearly identical,
Lanczos marginally sharper. Default = system scaling; revisit with M8 hit rates.
- In-app, capture runs at key-down: 96 ms, finished long before key-up (adds 0 ms after release).
- **Exclusion verified:** Wisp's companion and level meter were on screen during the hold (screencapture) but
  absent from Wisp's own capture (`SCContentFilter` excluding Wisp's app); the system pointer is included.
- Budget (blueprint): capture-to-encode < 150 ms P95 on M1 → met warm on M2; cold first capture is slower,
  so the app prewarms `SCShareableContent` at launch.
- Multi-display/mixed-scale mapping: covered by unit tests (4 layouts incl. negative origins, portrait,
  1.5× scale). Only one physical display was available here (**Pending**: real external display check).

## 4c. Companion renderer

- Metal shader compiled at runtime from source + SDF textures for arrow and hand: renderer ready on first use;
  11 themes × 2 shapes offscreen at 360 px in ~40 ms, at 112 px in ~11 ms (M2, Measured).
- Keep-on-screen idle (Debug build): ~6 % CPU at 30 fps → **~1–1.6 % CPU at 20 fps** (idle/settled frame-rate
  throttle; full rate during flights/turns). Measured with `ps` over 6 s.
- Overlay-only capture (`tools/overlay_frames.sh`) confirms: fly out of the menu bar icon → listening bars →
  thinking dots → resting → fly home into the icon.

## 4d. Model auto-install (M3)

- Fresh launch → both models (233,116,036 bytes, 27 files) downloaded from the pinned Hugging Face URLs,
  SHA-256-verified, atomically installed: **~10 s** on this home Wi-Fi (Measured, 2026-10-01). Spot-checked
  `decoder_kv.ort` and `kokoro_5s…/weight.bin` hashes on disk = manifest.
- **Background URLSession is not usable for a menu-bar app:** nsurlsessiond logged "current discretionary status
  for com.zakvirani.wisp is discretionary" and transfers crawled for 10+ minutes. Switched to an in-process session;
  on quit, running transfers are cancelled with resume data written next to the staging file.
- Quit after 4 s → `decoder_kv.ort.resume` saved; relaunch resumed it and finished both installs in ~7 s; resume
  files and staging folders removed afterwards.
- Failure paths (resume after dropped connection, hash mismatch, 403, 503 retries, disk full, unreachable host,
  policy deny, repair, remove, side-by-side upgrade): 11 automated tests against a fault-injecting local server.

## 4e. End-to-end turns (M4–M6), real hotkey events, spoken question (file source), real screen, NIM

| Turn | STT final after key-up | Request after key-up | Kimi first token | First sentence after key-up | First audio after key-up | Voice |
|---|---|---|---|---|---|---|
| 1 | 207 ms | 229 ms | 2.06 s | – | 3.29 s | system |
| 2 | 214 ms | 253 ms | 16.90 s | 18.57 s | 20.01 s | Kokoro |
| 3 | 204 ms | 220 ms | 9.43 s | 10.56 s | 11.89 s | Kokoro |
| 4 | 243 ms | 274 ms | 1.40 s | 2.18 s | 2.84 s | Kokoro |
| 5 | 206 ms | 219 ms | 2.48 s | 3.22 s | 3.89 s | Kokoro |
| 6 | 252 ms | 269 ms | 2.36 s | 3.15 s | 3.61 s | Kokoro |
| 7 | 218 ms | 255 ms | 1.19 s | 2.05 s | 2.54 s | Kokoro |

- On-device stages are fast and stable: STT final ~0.2 s after key-up; Kokoro first audio 0.4–0.7 s after the first
  sentence. **NIM free-tier time-to-first-token dominates and varies 1.2–17 s** (M7 quantifies P50/P95).
- Kokoro: fixed 128-token input window → ~0.4 s per call regardless of text length (splitting sentences to start
  sooner does not help; measured). Bench first audio 420–456 ms.
- Pointing (M6): Kimi K3 POINT on the synthetic "Photo Editor" window landed inside the Export button on screen
  (ring centre ≈ (1390, 910) pt; button (1266–1492, 873–934) pt). Mapping covered by unit tests incl. a 1.5×
  display at negative origin.

## 5. Platform behaviour observed

- Listen-only `CGEventTap` creation can succeed even when events will not be delivered; macOS then sends
  `tapDisabledByUserInput`. Wisp re-enables and resyncs modifier state (seen in logs, 2026-10-01).
- `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` gives a tri-state for Input Monitoring; Screen Recording has
  only a boolean preflight, so "not asked" vs "denied" is tracked by Wisp itself.
- The macOS microphone prompt shows Wisp's `NSMicrophoneUsageDescription` verbatim (screenshot verified).

---

## 6. Pointing bake-off (M8) (Measured, 2026-10-01)

### 6.1 Which free NIM models really read images
`wisp-bench vision-check` sent a half-red/half-blue image to every chat model `GET /v1/models` lists and asked for the
left colour. **10 answered "red"**: kimi-k3, glm-5.3-flash, deepseek-v4.1-flash, gemma-4-31b-it, diffusiongemma-26b-a4b-it,
muse-glimmer-30b, ising-calibration-1.5-31b, nemotron-3-nano-omni-30b-a3b-reasoning, llama-3.2-90b-vision,
llama-3.2-11b-vision. Excluded: glm-5.3 (empty answers to images after ~55 s), nemotron-3-super/ultra/3.5-lightning and
laguna-xs (server says "multimodal processing is not enabled"), cosmos3-nano(-reasoner) and phi-3-vision (404, not
deployed), ising-calibration-1-35b (410, retired), paligemma (non-chat API), gpt-oss-20b (text only).
build.nvidia.com's "image" filter is not reliable (it also lists speech and TTS models), so the API check is the source.

### 6.2 Method
Golden set (gitignored `eval-data/pointing/`): **50 synthetic screens** (`tools/make_pointing_set.py`: app windows,
icon-only toolbars, web pages, dialogs; light and dark; 16:10, 16:9, 21:9, 4:3 and portrait) and **28 real-app screens**
(`tools/make_real_pointing_set.py`: Calculator, Font Book, Dictionary, Preview, Disk Utility, Clock; target boxes from
Accessibility frames; only the app's own window is captured, on a plain canvas, so no personal content is sent).
`wisp-bench point-eval` runs each item through `AssistantEngine` with Wisp's real prompt (JPEG 0.85, ≤ 1456 px).
A **hit** = the spot the companion would fly to is inside the target box (±6 px). "Time to point" = request sent →
first POINT/CIRCLE line parsed (what the user waits for). One run per item; free-tier 429s retried with back-off.

**Coordinate space matters.** Gemma 4, DiffusionGemma, Muse Glimmer and Nemotron Omni answer in 0-1000 coordinates
whatever the prompt says: asked for pixels, Gemma 4 scored 0/50, but read as 0-1000 the same answers scored 40/43. Each
model is now prompted in its native space (`VisionModelInfo.coordinateSpace`); the table uses that.

### 6.3 Results

| Model | Synthetic hit (50) | Real-app hit (28) | Combined | Time to point p50 / p95 |
|---|---|---|---|---|
| **nemotron-3-nano-omni** (0-1000, thinking off) | **49 (98%)** | **21 (75%)**¹ | **90%** | **1.2 s / 2.6 s** |
| kimi-k3 (thinking off) | 47 (94%) | 21 (75%) | 87% | 2.9 s / 6.3 s |
| glm-5.3-flash | 46 (92%) | 19 (68%) | 83% | 10.9 s / 34.4 s |
| gemma-4-31b-it (0-1000) | 39 (78%) | 19 (68%) | 74% | 14.9 s / 50.2 s |
| muse-glimmer-30b (0-1000) | 43 (86%) | 13 (46%) | 72% | 8.5 s / 27.8 s |
| diffusiongemma-26b (0-1000) | 39 (78%) | 14 (50%) | 68% | 0.6 s / 1.1 s |
| deepseek-v4.1-flash (thinking off) | 39 (78%)² | not run | | 124 s / 147 s² |
| ising-calibration-1.5-31b | 3 (6%) | not run | | 2.1 s / 5.1 s |
| llama-3.2-90b-vision | 3 (6%) | not run | | 33 s / 55 s |
| llama-3.2-11b-vision | 2 (4%) | not run | | 1.8 s / 9.0 s |

¹ Nemotron's 3 real-app failures were free-tier rate limits, not wrong answers (21 of 25 answers hit; Kimi 21 of 25).
² DeepSeek was right on 39 of the 42 answers it gave, but NIM queued every request 69-147 s before sending a byte
(`wisp-bench probe`: headers at 69-106 s, then the whole answer in ~0.3 s). It is accurate but unusable live on the free tier.

Misses on real apps are mostly tiny icon-only toolbar buttons (Preview, Font Book), where the models land on the
neighbouring icon about 15 px away; two "Search" misses were the model pointing at the search field instead of its
magnifier glyph (arguably fine for the user).

**Decision:** default model is now **Nemotron 3 Nano Omni** (most accurate and about 2.4× faster than Kimi K3), with
Kimi K3 as the automatic fallback. In-app check: Export button hit live; first spoken sentence 1.4 s after key-up
(Kimi: 2.7-3.2 s).

### 6.4 Reliability notes
- Kimi K3's "!!!!" glitch appeared in 1 of 4 back-to-back requests on a real screenshot; the engine now retries the same
  model once when garbling shows up early, then falls back.
- NIM reports overload *inside* a 200 stream (`{"error": {"message": "ResourceExhausted: Worker local total request
  limit reached (16/16)"}}`). Wisp previously treated that as a garbled answer; it now counts as busy (429) and falls back.
- With 10 models queried at once, Nemotron Omni hit that limit on 35 of 50 requests; one model at a time, 0 of 50.
- Caveats: one run per item; free-tier load varied during the runs; the real-app set is small (28 items, 6 apps).

## 7. Latency vs budget (M7) (Measured, 2026-10-01)

Method: the real app, real hotkey events (`build/tools/chord`), a spoken question replayed as the microphone
(`WISP_FAKE_MIC_FILE`, 4 different questions from `say`), the synthetic UI open in Preview, live NIM, Kokoro voice.
20 turns per run, one every 13-15 s. Timings come from `timings.jsonl` (content-free) via `wisp-bench latency-report`.
Default model Nemotron 3 Nano Omni, fallback Kimi K3. M2 MacBook Air, 8 GB.

| Stage (ms) | Budget p50 / p95 | Run 1 p50 / p95 | Run 3 p50 / p95 |
|---|---|---|---|
| Screenshot ready after key-down | 120 / 150 | 418 / 471 | **131 / 440** |
| STT final after key-up | 400 / - | 211 / 218 | 210 / 224 |
| Request sent after key-up | 460 / - | 225 / 248 | 225 / 252 |
| First answer token after request | 900 / - | 900 / 3948 | **810** / 3672 |
| First sentence parsed after key-up | - | 1459 / 4908 | 1370 / 4867 |
| **First audio after key-up** | **1500 / 3000** | 2024 / 5334 | **1897 / 5582** |
| Barge-in: key-down → speaker quiet | 150 / - (our target) | - | **2 / 14** (13 interrupts) |

Run 1 = screenshot when the hold was confirmed (250 ms), fallback after a failure. Run 3 = screenshot at key-down
(dropped on a tap or cancel) and hedged retries (§6.4). Turns answered by the fallback: 9 of 20 in run 1, 2 of 18 in run 3.

What the numbers say:
- **Within budget:** speech-to-text (210 ms), request (225 ms), median first token (810 ms), barge-in (2 ms; the
  stop call plus the output device's latency).
- **Screenshot:** moving it to key-down took it from 418 to 131 ms median. The capture itself takes ~126 ms in the app
  (62 ms in `wisp-bench capture`); the p95 is the first turn after launch. It finishes during the hold, so it is never
  on the critical path (the request goes out 225 ms after key-up, waiting only for STT).
- **First audio misses the budget (1.9 s vs 1.5 s median; 5.6 s vs 3.0 s p95).** Breakdown of the median: 225 ms to
  send, ~810 ms to the first token, ~330 ms for the rest of the first sentence, ~450 ms for Kokoro to make the first
  audio (fixed cost per call, §3). The p95 tail is NIM: when Nemotron is busy (it answered "busy" to 9 of 20 direct
  probes on the evening of 2026-10-01), the hedge to Kimi costs 1.5-3 s more. Paid or self-hosted endpoints would remove most of it.
- Barge-in measured from the key event's timestamp to `AVAudioPlayerNode.stop()` plus `outputNode.presentationLatency`
  (software-side; not a microphone loopback).

## 8. Prompt tuning with 200 realistic questions (Measured, 2026-10-01/02)

Method: `tools/run_prompt_suite.py` sends `tools/prompt_suite_200.json` (200 different, mostly vague, casual questions
over 18 synthetic or window-only screens) to Nemotron 3 Nano Omni. It uses the app's exact system prompt
(`wisp-bench dump-prompt`) and the same reply rules, and writes a table with each raw reply. Automatic flags cover
chat framing, speaking as an on-screen app, claiming to act, off-screen answers that mention the screen,
unnecessary cursor moves, wrong TOPIC, length and formatting. Every answer was also read by hand.

| Round | Prompt | Flagged | Main issues found (root cause) |
|---|---|---|---|
| 1 | v3: short principles, no examples | 70 / 200 | Pointed on 66 answers that needed none (no explicit "is this about the screen?" step) |
| 2 | v4: TOPIC line first (screen / you / other); only `screen` moves the cursor | 37 (10 were NIM errors) | Off-screen questions refused or answered "not on your screen" (Wisp thought its knowledge came from the screen); "you" confused with on-screen apps |
| 3 | v5: answers from its own knowledge; "you" = Wisp, "this" = the screen | 21 (0 errors) | 3 refusals ("I'm a Mac helper": scope read as the Mac); a few screen questions classed as other |
| 4 | v6: a wrong button is worse than none; the way out = the cancelling control; scope not limited to the computer | 15 (0 errors) | Dialog "close this" fixed (Don't Save, not Print). Still: "I don't see X" followed by a point anyway; "what can you help with" over an assistant's window described that assistant |
| 5 | Code guards: no pointing after a sentence denying presence; recognised self-questions get "this is about you, Wisp" in the request | 14 (0 errors) | Guards removed every "I don't see X" + point; self-description fixed over an assistant's window. New: `TOPIC: you` read as "the user", dropping correct points |
| 6 | `TOPIC: wisp` instead of `you`; apologies are small talk | 12 (0 errors) | Model still wrote `TOPIC: wisp` for screen questions (with the right POINT) |
| 7 | Binary TOPIC (screen / other); questions about Wisp recognised in code | 19, of which 11 were the old "about Wisp → you" expectation | Screen questions labelled correctly again ("I can't remember my password" points at Forgot password) |
| 8 | Guard: no pointing after a question back; "can you do the math" is about Wisp | **7** (0 errors) | 3 are fine answers the check is strict about, 1 is a legitimately long read-aloud. Real: 1 garbled reply, 1 off-screen answer mentioning the screen, 1 stray point, 1 overclaim. One-offs, no pattern |
| 9 | Checker made fairer (identity check only for identity questions; length = over 55 words or a 4-sentence paragraph); a broader "use the screenshot" topic test was tried | 10 | The broader wording backfired: off-screen answers started relating to the screen ("I'm a timer app…", points on unrelated text). Reverted |
| 10 | Code: an `other` answer keeps a point only if its own sentence names the label **and** on-device text recognition (Vision) finds that label next to the point; leaked `<think>` text and wordless lines are never spoken | 10 | Rescued "what's First Aid" / "what's APFS" (correct points the model had labelled `other`); stray points on off-screen answers ("llama", "Atom") now dropped because the label isn't on screen |
| 11 | Prompt: being on their Mac is where Wisp is, not a limit on what it knows; every question gets a real answer | **3** | Remaining: an "I can't…" opener before a correct answer, 1 refusal, 1 "can't see" on a shop page |
| 12 | Confirmation run (3 again, all with correct content) + code: an off-screen answer's "can't help / don't see …, but" opener is dropped when a real answer follows | **1** | A correct answer ("south pole" in an article) without a point |

Point-eval with the text check (78 golden items, Nemotron): moving a point onto its label's text **fixed 0 and broke 3**
(icon buttons whose name sits beside them: Search, Hide Sidebar), so the text is used only to *confirm* rescued points,
never to move them. Hit rate without snapping: 72/78 (92%).

Rejected idea (measured first): dropping points whose label shares no word with the spoken sentence. On round 7 it would
have hidden dozens of correct points (sidebar lists, zoom, bell, timers), because people describe controls differently
from their labels. Too strict.

Where it ends up: 70 → 7 flagged of 200, first token about 0.56 s. What's left is the small model's accuracy on
real apps (sometimes the nearest-sounding button, for example "make a copy" → Rename), not the prompt.

Kimi K3 on the same 200 (round 6 prompt): smarter on hard cases (noticed a nearly full disk for "my computer is
slow"; knew there was no back button and suggested Command + left arrow), but 35 of 200 replies were its "!!!!" glitch
(the app hedges these; the script doesn't) and the median first token was 32 s on the free tier that night (Nemotron:
0.58 s). Nemotron stays the default; Kimi is the fallback.

What worked: making the model **classify the question before answering** (TOPIC line, enforced in code) took
unwanted cursor moves from 66 to 4. Stating **why** (a cursor flying somewhere unrelated is confusing; a wrong button
is worse than none) generalised better than lists of don'ts. **Example answers were copied word for word** by the small
model (including example coordinates), so the prompt has none. Questions about Wisp and small talk are also caught in
code (`QuestionIntent`) so they never point.

## 9. Answer correctness on real apps (Measured, 2026-10-03)

`wisp-bench correctness-eval eval-data/correctness/cases.json`: 58 questions over 7 real apps (Calculator, Preview,
Disk Utility, Font Book, Dictionary, Chess, Clock), each with expected phrases, forbidden phrases and where the point
should land (a control, "none" for menu commands and facts, or "any"). Captures are the front window alone on a plain
canvas plus what `UIContextReader` reads from it (`tools/make_correctness_set.py`). The pointing rules are the app's
own (`VisualDecision`), so what is measured is what ships. Concurrency 2, busy answers retried.

| Model | App details (controls) | Correct | Answer right | Pointing right | First sentence p50 / p90 |
|---|---|---|---|---|---|
| Nemotron 3 Nano Omni | no | 68% / 70% (2 runs) | 74% / 75% | 94% / 93% | 1.25 s / 1.71 s |
| Nemotron 3 Nano Omni | **yes** | **86% / 84%** (2 runs) | 86% / 84% | **100% / 100%** | 1.28 s / 1.96 s |
| Kimi K3 | yes | 81% | 82% | 91% | 2.48 s / 4.56 s (7 busy errors) |
| Gemma 4 31B | yes | 75% | 77% | 98% | 2.34 s / 9.26 s |
| Muse Glimmer 30B | yes | 70% | 72% | 93% | 10.7 s / 20.4 s (11 busy errors) |
| DeepSeek V4.1 Flash | yes | 0% | | | (every request failed or timed out: the free tier queued requests past the 25 s limit) |
| Nemotron + thinking (earlier run) | yes | 81% | | | 8.7 s p50 |

Decision: **Nemotron stays the default**, with app details on. Reading the app's controls is worth about +16 points
of correctness and makes every point land on the right control, at no extra latency (the read runs while the key
is held). Bigger free models are not more accurate here and are 2–5× slower to start talking. Thinking mode is
too slow for a spoken helper.

What's left: the model sometimes ignores a control's state (offers "click Pause" when the timer is already paused,
"click Back" when Back is greyed out) and names a nearby button for menu-only commands.

Follow-ups (same day):
- **Greyed-out note (kept):** when a shown point lands on a control macOS reports as greyed out and the answer
  doesn't say so, Wisp adds "… is greyed out right now". Re-run: 86% (50/58), and "go back" with nothing to go back
  to now passes every time.
- **Menu commands matching the question's words (rejected):** listing the 4 menu commands whose names share words
  with the question dropped correctness to 81%. Word overlap misleads a small model ("make a copy" → Edit > Copy
  instead of File > Duplicate; "details of this image" → "Show Image Background").
- **Listing Wisp's new local features in its self-description (rejected):** 200-question suite went from 2 to 4
  flags; the model started claiming actions it can't take ("stop it" → "I'll stop the timer for you"). Local
  features are handled before the model sees the question, so the model doesn't need to know about them. Kept: the
  short self-description. 200-suite with tonight's other prompt changes (app details, language, pointer units):
  2 of 200 flagged, first token p50 0.60 s.
- **Final run on 2.5.7 code** (greyed-out note, pointer in model units, all prompt changes kept): **87% correct
  (51/58), pointing 100%**, first sentence p50 1.28 s / p90 1.82 s, 0 errors.
- **Drawing (2.6.0):** asked to draw with screen coordinates, Nemotron drew a straight line and Kimi K3 glitched
  ("!!!!"). Asked for a sketch in a 100 x 100 box with no screenshot, Kimi K3 drew a recognisable cat and a house
  with a tree (12-14 strokes, about 12 s); Nemotron's were scribbles. So free drawings use Kimi K3 in that format,
  drawn stroke by stroke as they stream in; common shapes (star, heart, smiley…) are generated on the Mac.
- **Smart routing (2.6.0, owner's choice):** short how-to/where questions → Nemotron first; everything else →
  Kimi K3 first (each the other's fallback; Kimi's glitches trigger the existing hedge). On the real-app test Kimi
  scored 81% vs Nemotron 86% and starts talking later (about 2.5 s), so routing trades some speed for Kimi's
  stronger general answers.

## 10. New NIM models, and Kimi K3's retirement (Measured, 2026-10-17)

Kimi K3 (`moonshotai/kimi-k3`) now answers **HTTP 410 Gone** ("end of life") on NIM, so every question routed to it
fell back to Nemotron. Same real-app test as §9 (58 questions, app details on, concurrency 2):

| Model | Correct | Pointing right | First sentence p50 / p90 | No answer |
|---|---|---|---|---|
| Nemotron 3 Nano Omni (fast model, unchanged) | 86% | 100% | 1.15 s / 1.60 s | 0 |
| **Nemotron 3.5 Super VL**, thinking off | **94%** | **98%** | **2.00 s** / 13.5 s | 0 |
| Nemotron 3.5 Super VL, thinking on (default) | 86% | 95% | 4.19 s / 14.9 s | 1 |
| Step 5 Preview, `reasoning_effort: low` (2 runs) | 94% / 89% | 97% | 4.25 s / 6.04 s p50 | 2 / 3 |
| Step 5 Preview, default (thinks at length first) | 86% | 97% | 5.64 s / 16.0 s | 6 |
| Nemotron 3.5 Lightning | text only (rejects images); a text question took 149 s and spent it all thinking | | | |
| DeepSeek V4.1 Flash | no reply within 200 s (text or image), as on 2026-10-03 | | | |

Drawings (Wisp's sketch prompt, "a cat", "a house with a tree", "a bicycle"): Step 5 Preview drew a recognisable
cat and a clean house with a tree (20-50 s; nothing for the bicycle); Super VL and Nano drew scribbles or timed out.

Decision: **Nemotron 3.5 Super VL replaces Kimi K3** as the strong model (equal best accuracy, 2-3× faster than
Step 5, no errors); **Step 5 Preview draws** (Super VL as its fallback); Nemotron Nano stays the fast model for
quick how-to questions. Saved settings naming Kimi K3 are mapped to Super VL (`VisionModelCatalog.retired`).
Step 5 needs `reasoning_effort: "low"` (top level): without it the reasoning lands in the answer text.

## 11. Walkthroughs (Measured, 2026-10-17)

How-to questions now carry an instruction to end the reply with `STEPS: more|done` (`GuideSession.firstStepText`,
mirrored in `correctness-eval`). Real-app test: Nemotron 3.5 Super VL 96% (56/58, was 94%), Nemotron Nano 82%
(48/58, was 86%: one wording slip, and "how do I make a copy" now points at the File menu as the first step, which
the case scores as "should not point"). Every how-to answer (41/41, both models) gave a STEPS line. Next-step
requests with an unchanged screen: Super VL repeats the step and points again; Nano once pointed without a sentence
(the app now says "Here: <label>." when a reply only points).

## 12. Answering from the screen: Claude full screen (Measured, 2026-10-17)

Owner's report: "how do I start a new session" in Claude (full screen) → "New Session in the File menu", pointing at
the hidden menu bar, with "+ New" visible in the sidebar. Causes: (1) Claude (Electron) reported nothing inside its
window to Accessibility, so the app details were only menu titles and 61 menu commands; setting
`AXManualAccessibility` on the app makes it build the list (142 controls, including "New") after a short delay;
(2) quick how-to questions were routed to Nano, which answered from habit. On a capture of that screen
(`cases-claude.json`, 12 cases, with and without the window's controls): **Nano 4/12, Super VL 12/12**. Decision:
Super VL first for every question; Electron apps asked to expose their controls when they come to the front;
unreadable windows and full screen are stated in the app details. A reply of only `STEPS: done` used to count as a
failed lane ("degenerate") and fall through to the other model; it now counts as an answer.
