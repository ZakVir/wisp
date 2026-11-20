#!/usr/bin/env python3
"""Add real-app items to the pointing golden set (M8), with exact targets from the Accessibility API.

For each app (chosen to have no personal content), the front window alone is captured with `screencapture -l`
and placed at its real position on a plain full-screen canvas, so the model sees a realistic full display
without anything else that happens to be on screen. Target boxes come from the controls' AX frames.

Appends to eval-data/pointing/golden.json (replacing earlier real-* items).
Usage: tools/make_real_pointing_set.py [per_app]   (needs build/tools/ax_dump; Accessibility + Screen Recording)
"""
import json, os, random, subprocess, sys, tempfile, time
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(__file__), "..")
OUT = os.path.join(ROOT, "eval-data", "pointing")
AX = os.path.join(ROOT, "build", "tools", "ax_dump")
LONG_EDGE = 1456
APPS = [  # bundle id, optional file to open
    ("com.apple.calculator", None),
    ("com.apple.Chess", None),
    ("com.apple.FontBook", None),
    ("com.apple.Dictionary", None),
    ("com.apple.Preview", os.path.join(ROOT, "tools", "out", "themes.png")),
    # Not used: TextEdit (AX frames didn't line up with the captured window), App Store (shows the account name).
    ("com.apple.tips", None),
    ("com.apple.DiskUtility", None),
    ("com.apple.clock", None),
]
SKIP_TITLES = {"", "close", "minimise", "minimize", "zoom", "full screen"}


def question(role, title):
    t = title.strip()
    if role in ("AXCheckBox",):
        return random.choice([f"Where's the {t} checkbox?", f"How do I turn on {t}?"])
    if role in ("AXPopUpButton", "AXMenuButton"):
        return f"Where's the {t} menu?"
    if role in ("AXTab", "AXRadioButton"):
        return random.choice([f"How do I switch to {t}?", f"Where's the {t} tab?"])
    if role in ("AXTextField", "AXSearchField"):
        return "Where do I type to search?" if "search" in t.lower() else f"Where's the {t} field?"
    return random.choice([f"Where's the {t} button?", f"Which button is {t}?"])


def running(bundle):
    out = subprocess.run(["osascript", "-e", f'application id "{bundle}" is running'], capture_output=True, text=True).stdout
    return out.strip() == "true"


def wallpaper(w, h):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        k = y / h
        d.line([(0, y), (w, y)], fill=(int(40 + 60 * k), int(70 + 50 * k), int(120 + 60 * k)))
    d.rectangle([0, 0, w, 24], fill=(236, 236, 238))
    return img


def main():
    per_app = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    random.seed(11)
    golden_path = os.path.join(OUT, "golden.json")
    golden = [g for g in json.load(open(golden_path)) if not g["kind"].startswith("real")] if os.path.exists(golden_path) else []
    tmp = tempfile.mkdtemp()
    blank = os.path.join(tmp, "Untitled.rtf")
    open(blank, "w").write(r"{\rtf1\ansi\deff0 {\fonttbl {\f0 Helvetica;}}\f0\fs24 }")
    added = 0
    for bundle, doc in APPS:
        was_running = running(bundle)
        args = ["open", "-b", bundle] + ([blank if doc == "BLANK" else doc] if doc else [])
        if subprocess.run(args, capture_output=True).returncode != 0:
            print("skip (not installed)", bundle); continue
        time.sleep(3.5)
        subprocess.run(["osascript", "-e", f'tell application id "{bundle}" to activate'], capture_output=True)
        time.sleep(1.0)
        try:
            info = json.loads(subprocess.run([AX, bundle], capture_output=True, text=True, timeout=30).stdout or "{}")
        except Exception as e:
            print("ax failed", bundle, e); info = {}
        if not info.get("windowID") or not info.get("elements"):
            print("no window/elements", bundle)
        else:
            shot = os.path.join(tmp, "w.png")
            subprocess.run(["screencapture", "-x", "-o", "-l", str(info["windowID"]), shot], check=True)
            sw, sh = info["screen"]
            wx, wy, ww, wh = info["window"]
            canvas = wallpaper(int(sw), int(sh))
            win = Image.open(shot).convert("RGB").resize((int(ww), int(wh)), Image.LANCZOS)
            canvas.paste(win, (int(wx), int(wy)))
            k = LONG_EDGE / max(sw, sh)
            canvas = canvas.resize((round(sw * k), round(sh * k)), Image.LANCZOS)
            seen, candidates = set(), []
            for e in info["elements"]:
                t = e["title"].strip()
                if t.lower() in SKIP_TITLES or len(t) > 32 or t in seen:
                    continue
                if sum(1 for o in info["elements"] if o["title"].strip() == t) > 1:
                    continue  # ambiguous: the same label twice
                seen.add(t); candidates.append(e)
            random.shuffle(candidates)
            name = bundle.split(".")[-1].lower()
            for j, e in enumerate(candidates[:per_app]):
                x, y, w, h = e["frame"]
                item_id = f"real-{name}-{j}"
                canvas.save(os.path.join(OUT, item_id + ".png"))
                golden.append({"id": item_id, "image": item_id + ".png", "question": question(e["role"], e["title"]),
                               "label": e["title"], "target": [round(x * k), round(y * k), round((x + w) * k), round((y + h) * k)],
                               "kind": "real", "aspect": "16:10", "app": name, "role": e["role"]})
                added += 1
            print(f"{name}: {min(per_app, len(candidates))} items from {len(info['elements'])} controls")
        if not was_running:
            subprocess.run(["osascript", "-e", f'tell application id "{bundle}" to quit saving no'], capture_output=True)
    json.dump(golden, open(golden_path, "w"), indent=1)
    print(f"added {added} real items; golden set now {len(golden)}")


if __name__ == "__main__":
    main()
