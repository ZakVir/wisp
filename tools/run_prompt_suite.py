#!/usr/bin/env python3
"""Run a prompt suite (e.g. tools/prompt_suite_200.json) against a NIM model and write a results table.

Uses the app's exact system prompt and request options (`wisp-bench dump-prompt`), the same user-message format
as PromptBuilder.userText, JPEG 0.85 screenshots, and the same reply rules as the app (TOPIC line, small talk and
questions about Wisp never move the cursor). The API key comes from NVIDIA_API_KEY, or from `wisp-bench get-key`
(kept in memory only). Only synthetic or window-only test screenshots are sent.

Usage: tools/run_prompt_suite.py [suite.json] [model] [--workers=4] [--limit=N]
Writes tools/out/suite/<model>-<time>.{md,csv,json} and prints a summary.
"""
import base64, csv, io, json, os, re, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor
import requests
from PIL import Image

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
BENCH = os.path.join(ROOT, "app/Packages/WispKit/.build/debug/wisp-bench")
URL = "https://integrate.api.nvidia.com/v1/chat/completions"
TAGS = {"TOPIC", "SAY", "POINT", "CIRCLE", "UNDERLINE", "ARROW", "PATH"}

# Mirrors WispCore QuestionIntent (keep in sync).
ABOUT = [r"\bwhat (else )?can you do\b", r"\bwhat do you do( exactly)?\??$", r"\bwho are you\b",
         r"\bwhat are you( exactly| for| called)?\??$", r"\bwhat('s| is) your name\b", r"\bhow do you work\b",
         r"\bwhat are you able to\b", r"\bwhat can i ask you\b", r"\bhow (do|can) i use you\b",
         r"\bare you (an? )?(ai|robot|bot|human)\b", r"\byour (job|purpose|name)\b",
         r"\bare you (claude|siri|chatgpt|gemini|alexa|copilot)\b", r"\bwho (made|built|created) you\b",
         r"\bcan you (remember|see everything|always see)\b", r"\bcan you (click|type) (things|stuff|for me)\b",
         r"\bcan you see (my|the) screen\b", r"\bcan you do (the )?(math|maths|sums|stuff|things)\b",
         r"\bwhat can you help( me)?( with)?\??$", r"\bdo you remember\b"]
DENIES = (r"\b(i (don't|do not|can't|cannot) (see|find)|there('s| is) no (?!need|problem|rush|worries|harm)|there (isn't|aren't)|(isn't|aren't|is not|are not) "
          r"(shown|visible|here|on (this|the|your) (screen|page))|no [a-z ]{1,24} (here|on (this|the) (screen|page)))")


# Identity questions, where the answer should say what Wisp is or does. Other about-questions ("do you remember me",
# "can you do the math") are answered directly and aren't held to that.
IDENTITY = [r"\bwhat (else )?can you do\b", r"\bwhat do you do( exactly)?\??$", r"\bwho are you\b",
            r"\bwhat are you( exactly| for| called)?\??$", r"\bwhat('s| is) your name\b", r"\bhow do you work\b",
            r"\bwhat are you able to\b", r"\bwhat can i ask you\b", r"\bhow (do|can) i use you\b",
            r"\byour (job|purpose)\b", r"\bwho (made|built|created) you\b", r"\bwhat can you help( me)?( with)?\??$"]


def is_about(q):
    ql = q.lower().replace("’", "'")
    return any(re.search(p, ql) for p in ABOUT)


def is_identity(q):
    ql = q.lower().replace("’", "'")
    return any(re.search(p, ql) for p in IDENTITY)
SMALLTALK = (r"^(hey|hi|hello|hello there|hey there|yo|thanks|thank you|thank you so much|thanks a lot|cool|ok|okay|great|nice|"
             r"never ?mind|good (morning|afternoon|evening|night)|test|test test|testing|can you hear me|are you there|um+|uh+|hm+|"
             r"oops|my bad|sorry|sorry,? wrong (button|key|thing)|wrong (button|key))( wisp)?$")


def allows_pointing(q):
    ql = q.lower().replace("’", "'")
    if any(re.search(p, ql) for p in ABOUT):
        return False
    return re.match(SMALLTALK, ql.strip(" .,!?;:'\"")) is None


def label_of(visual):
    """'POINT 12, 34 | Subscribe' -> 'Subscribe'."""
    return visual.split("|", 1)[1].strip() if "|" in visual else ""


def sentence_names(label, sentence):
    """Mirrors QuestionIntent.sentenceNames: the sentence names the thing the visual points at."""
    name = label.strip(" \t.,;:!?\"'")
    name = re.sub(r"\s*\((button|icon|menu|tab|link|field|option|checkbox)\)$", "", name, flags=re.I)
    name = re.sub(r"\s+(button|icon|menu item|menu|tab|link|field|option|checkbox|toggle)$", "", name, flags=re.I)
    if len(name) < 2 and not (len(name) == 1 and f'"{name}"' in sentence):
        return False
    if name.lower() in ("not visible", "none", "n/a", "nothing", "screen", "the screen", "window", "page", "not shown", "unknown"):
        return False
    return re.search(r"(?<![^\W_])" + re.escape(name) + r"(?![^\W_])", sentence, flags=re.I) is not None


_rescue_cache = {}


def rescued(visual, sentence, screen_path):
    """Mirrors the app: with TOPIC other, a visual survives only if its sentence names its label AND the label is
    written on the screenshot next to the point (checked with the app's own code via `wisp-bench rescue-check`)."""
    label = label_of(visual)
    if not sentence_names(label, sentence) or not visual.startswith("POINT"):
        return False
    nums = re.findall(r"-?\d+(?:\.\d+)?", visual.split("|")[0])
    if len(nums) < 2:
        return False
    key = (screen_path, label.lower(), nums[0], nums[1])
    if key not in _rescue_cache:
        out = subprocess.run([BENCH, "rescue-check", os.path.join(ROOT, screen_path), label, nums[0], nums[1]],
                             capture_output=True, text=True).stdout.strip().splitlines()
        try:
            _rescue_cache[key] = bool(json.loads(out[-1]).get("ok"))
        except (IndexError, ValueError):
            _rescue_cache[key] = False
    return _rescue_cache[key]


HEDGE = (r"^\s*(i (can't|cannot|can not) help with [^,.;]{0,40}|i (don't|do not|can't|cannot) see [^,.;]{0,70}|"
         r"i'm not (sure|able to [^,.;]{0,30})[^,.;]{0,20}),?\s+but\s+")


def without_hedge(sentence):
    """Mirrors QuestionIntent.withoutHedge: the app drops a 'can't help / don't see, but' opener in off-screen answers."""
    s = sentence.replace("’", "'")
    m = re.match(HEDGE, s, flags=re.I)
    if not m:
        return sentence
    rest = s[m.end():].strip()
    return rest[:1].upper() + rest[1:] if len(rest.split()) >= 4 else sentence


def parse(raw):
    """Returns topic, spoken text, visuals (with the sentence each follows), untagged lines."""
    topic, say, visuals, untagged = None, [], [], []
    last_sentence = ""
    for line in raw.splitlines():
        line = line.strip().lstrip("-*•> ").replace("**", "").replace("`", "")
        if not line:
            continue
        tag, _, body = line.partition(":")
        tag = tag.strip().upper()
        if tag not in TAGS:
            untagged.append(line)
            say.append(line)  # the app speaks untagged lines
            continue
        body = body.strip()
        if tag == "TOPIC":
            word = re.sub(r"[^a-z]", "", body.lower())
            word = "you" if word == "wisp" else word
            topic = word if word in ("screen", "you", "other") else ("screen" if word.startswith("screen") else "other")
        elif tag == "SAY":
            text = body.strip('"“” ')
            say.append(text)
            parts = re.split(r"(?<=[.!?])\s+", text)
            last_sentence = parts[-1] if parts else text
        else:
            visuals.append((f"{tag} {body}", last_sentence))
    return topic, " ".join(say), visuals, untagged


def jpeg_b64(path):
    im = Image.open(os.path.join(ROOT, path)).convert("RGB")
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=85)
    return base64.b64encode(buf.getvalue()).decode(), im.size


def ask(key, prompt, case, image):
    b64, (w, h) = image
    hint = "This question is about you, Wisp, not about anything on the screen.\n" if is_about(case["q"]) else ""
    user = f'Screenshot size: {w} x {h} pixels.\n{hint}The user asked: "{case["q"]}"'
    body = {"model": prompt["model"], "stream": True, "max_tokens": 400, "temperature": 0.2,
            "messages": [{"role": "system", "content": prompt["system"]},
                         {"role": "user", "content": [{"type": "text", "text": user},
                                                      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64}}]}]}
    body.update(prompt["extraBody"])
    for attempt, wait in enumerate([0, 3, 8, 20, 40]):
        time.sleep(wait)
        t0 = time.time()
        first, raw, err = None, "", None
        try:
            with requests.post(URL, json=body, stream=True, timeout=(10, 90),
                               headers={"Authorization": f"Bearer {key}", "Accept": "text/event-stream"}) as r:
                if r.status_code != 200:
                    err = f"http_{r.status_code}"
                else:
                    for line in r.iter_lines(decode_unicode=True):
                        if not line or not line.startswith("data:"):
                            continue
                        data = line[5:].strip()
                        if data == "[DONE]":
                            break
                        j = json.loads(data)
                        if "error" in j:
                            msg = j["error"].get("message", "")
                            err = "busy" if re.search("ResourceExhausted|limit|overload", msg) else "stream_error"
                            break
                        delta = (j.get("choices") or [{}])[0].get("delta", {})
                        c = delta.get("content") or ""
                        if c.strip() and first is None:
                            first = time.time() - t0
                        raw += c
        except requests.RequestException as e:
            err = "network"
        if err in ("busy", "http_429") or (err and err.startswith("http_5")):
            continue
        return raw, err, first, time.time() - t0, attempt
    return "", "busy", None, 0, 5


def checks(case, topic, say, shown, untagged, err):
    f, s, q = [], say.lower(), case["q"].lower()
    kind = case.get("kind")
    if err:
        f.append(f"error {err}")
    if not say and not err:
        f.append("no speech")
    if topic is None and not err:
        f.append("no TOPIC line")
    if untagged:
        f.append("untagged line")
    if kind == "offscreen" and topic == "screen":
        f.append("topic=screen for off-screen question")
    if kind == "about" and topic == "screen":
        f.append("topic=screen for question about Wisp")
    # A screen question labelled "other" only matters if it costs the user something: the app still shows a point
    # whose label is confirmed on screen, and a sentence saying the thing isn't there needs no point.
    if kind == "screen" and topic in ("other", "you") and not shown and not re.search(DENIES, s.replace("’", "'")):
        f.append(f"topic={topic} for screen question (no point)")
    for pat, name in [(r"\bchat\b|this conversation|earlier you asked|as i (said|mentioned)", "chat framing"),
                      (r"\b(i('ll| will)|let me|i('ve| have)) (click|type|press|open|tap|scroll|select|stop|start|close|delete|turn|change|do that)\b|\bi can (click|press|cancel|close|open|type|do (that|this|it))\b[^.]{0,40}\bfor you\b", "claims to act"),
                      (r"as an ai|language model|i'm an ai", "AI boilerplate"),
                      (r"[*#`]|\n-", "formatting"),
                      (r"i can (help with|assist with) (coding|writing|many)", "speaks as another assistant"),
                      (r"i can't help with (that|this|[a-z]+ing)\b|i only see (your|the)|i can only (see|help)|i can't see what you", "refuses an off-screen question")]:
        if re.search(pat, s):
            f.append(name)
    if kind == "offscreen" and re.search(r"\b(screen|button|click|window|tab|menu|toolbar|sidebar|page|app|i see|i don't see)\b|\bon (your|the|this) (screen|page|display)\b", s):
        f.append("off-screen answer mentions the screen")
    if kind == "about" and is_identity(case["q"]) and not re.search(r"\bwisp\b|\bscreen\b|\bshortcut\b|\bpoint\b|\bmac\b", s):
        f.append("doesn't describe Wisp")
    # Spoken answers: a couple of sentences. One full sentence of 40-odd words is fine; a paragraph isn't.
    words = len(say.split())
    sentences = len([x for x in re.split(r"[.!?]+", say) if x.strip()])
    if (words > 55 or (words > 40 and sentences > 3)) and not case.get("long"):
        f.append(f"long ({words} words)")
    if case.get("point") is True and not shown:
        f.append("didn't point")
    if case.get("point") is False and shown:
        f.append("pointed")
    return f


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    suite_path = args[0] if args else os.path.join(ROOT, "tools/prompt_suite_200.json")
    model = args[1] if len(args) > 1 else None
    suite = json.load(open(suite_path))
    cases = suite["cases"][: int(opts["limit"])] if "limit" in opts else suite["cases"]
    prompt = json.loads(subprocess.check_output([BENCH, "dump-prompt"] + ([model] if model else []), text=True))
    key = os.environ.get("NVIDIA_API_KEY") or subprocess.run([BENCH, "get-key"], capture_output=True, text=True).stdout.strip()
    if not key:
        sys.exit("no API key")
    images = {name: jpeg_b64(path) for name, path in suite["screens"].items()}
    results, lock, done = [None] * len(cases), threading.Lock(), [0]

    def run(i):
        c = cases[i]
        raw, err, first, total, retries = ask(key, prompt, c, images[c["screen"]])
        topic, say, visuals, untagged = parse(raw)
        if topic == "other":
            say = " ".join(without_hedge(x) for x in re.split(r"(?<=[.!?])\s+", say) if x)
        # Mirrors TurnPipeline: no visuals for questions about Wisp or small talk; none after a sentence that denies
        # or asks back; with TOPIC other, only a visual whose label the sentence itself names (the rescue rule).
        shown = [v for v, sentence in visuals if allows_pointing(c["q"])
                 and (topic in ("screen", None) or rescued(v, sentence, suite["screens"][c["screen"]]))
                 and not re.search(DENIES, sentence.lower().replace("’", "'"))
                 and not sentence.strip(' "”\'').endswith("?")]
        visuals = [v for v, _ in visuals]
        row = {"n": i + 1, "kind": c.get("kind", ""), "screen": c["screen"], "question": c["q"], "topic": topic or "-",
               "say": say, "shown": "; ".join(shown), "hidden": "; ".join(v for v in visuals if v not in shown),
               "raw": raw.strip(), "first_ms": int(first * 1000) if first else None, "total_ms": int(total * 1000),
               "retries": retries, "flags": checks(c, topic, say, shown, untagged, err)}
        with lock:
            results[i] = row
            done[0] += 1
            print(f"{done[0]}/{len(cases)}  #{i + 1} {c['q'][:40]!r} -> {topic} {'FLAG ' + ', '.join(row['flags']) if row['flags'] else 'ok'}", flush=True)

    with ThreadPoolExecutor(int(opts.get("workers", 4))) as pool:
        list(pool.map(run, range(len(cases))))
    # NIM's free tier is sometimes saturated for minutes: retry anything that never got an answer, one at a time.
    for round_ in range(3):
        failed = [i for i, r in enumerate(results) if any(f.startswith("error") for f in r["flags"])]
        if not failed:
            break
        print(f"retry pass {round_ + 1}: {len(failed)} unanswered", flush=True)
        time.sleep(30)
        done[0] -= len(failed)
        for i in failed:
            run(i)

    stamp = time.strftime("%Y%m%d-%H%M%S")
    out_dir = os.path.join(ROOT, "tools/out/suite")
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.join(out_dir, f"{prompt['model'].replace('/', '_')}-{stamp}")
    json.dump({"model": prompt["model"], "suite": suite_path, "system": prompt["system"], "results": results},
              open(base + ".json", "w"), indent=1)
    with open(base + ".csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(results[0].keys()))
        w.writeheader()
        for r in results:
            w.writerow({**r, "flags": ", ".join(r["flags"])})
    esc = lambda t: str(t or "").replace("|", "/").replace("\n", " ⏎ ")
    lines = [f"# {prompt['model']}: {len(results)} questions", "",
             "| # | Kind/Screen | Question | Topic | Answer | Cursor shown | First token ms | Flags | Raw reply |",
             "|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        lines.append(f"| {r['n']} | {r['kind']}/{r['screen']} | {esc(r['question'])} | {r['topic']} | {esc(r['say'])} | "
                     f"{esc(r['shown'])} | {r['first_ms'] or '-'} | {esc(', '.join(r['flags']))} | {esc(r['raw'])} |")
    flagged = [r for r in results if r["flags"]]
    counts = {}
    for r in flagged:
        for f in r["flags"]:
            k = re.sub(r"\(.*\)", "", f).strip()
            counts[k] = counts.get(k, 0) + 1
    firsts = sorted(r["first_ms"] for r in results if r["first_ms"])
    summary = (f"{len(flagged)} of {len(results)} flagged. " + ", ".join(f"{k}: {v}" for k, v in sorted(counts.items(), key=lambda kv: -kv[1]))
               + (f". First token p50 {firsts[len(firsts) // 2]} ms." if firsts else ""))
    lines += ["", summary]
    open(base + ".md", "w").write("\n".join(lines) + "\n")
    print(summary)
    print("table:", base + ".md")


if __name__ == "__main__":
    main()
