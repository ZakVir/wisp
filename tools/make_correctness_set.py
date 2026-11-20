#!/usr/bin/env python3
"""Captures real apps for the answer-correctness test: the front window alone, placed at its real position on a
plain full-screen canvas (no personal content), plus what Wisp's own UIContextReader reads from it (controls,
states, menu commands). Writes eval-data/correctness/<app>.png and <app>.json.

The questions and expected answers live in eval-data/correctness/cases.json (written by hand after looking at
each capture). Usage: tools/make_correctness_set.py [app ...]   (Accessibility + Screen Recording for the terminal)
"""
import json, os, subprocess, sys, tempfile, time
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "eval-data", "correctness")
BENCH = os.path.join(ROOT, "app/Packages/WispKit/.build/debug/wisp-bench")
LONG_EDGE = 1456
APPS = {  # name: (bundle id, file to open or None)
    "calculator": ("com.apple.calculator", None),
    "preview": ("com.apple.Preview", os.path.join(ROOT, "tools", "out", "themes.png")),
    "diskutility": ("com.apple.DiskUtility", None),
    "fontbook": ("com.apple.FontBook", None),
    "dictionary": ("com.apple.Dictionary", None),
    "chess": ("com.apple.Chess", None),
    "clock": ("com.apple.clock", None),
    "tips": ("com.apple.tips", None),
}


def wallpaper(w, h):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        k = y / h
        d.line([(0, y), (w, y)], fill=(int(40 + 60 * k), int(70 + 50 * k), int(120 + 60 * k)))
    d.rectangle([0, 0, w, 24], fill=(236, 236, 238))
    return img


def running(bundle):
    out = subprocess.run(["osascript", "-e", f'application id "{bundle}" is running'], capture_output=True, text=True).stdout
    return out.strip() == "true"


def capture(name, bundle, doc):
    was_running = running(bundle)
    if subprocess.run(["open", "-b", bundle] + ([doc] if doc else []), capture_output=True).returncode != 0:
        print("skip (not installed)", name); return
    time.sleep(3.0)
    subprocess.run(["osascript", "-e", f'tell application id "{bundle}" to activate'], capture_output=True)
    time.sleep(1.0)
    info = json.loads(subprocess.run([BENCH, "ui-context", bundle], capture_output=True, text=True, timeout=30).stdout or "{}")
    if not info.get("windowID"):
        print("no window", name); return
    tmp = tempfile.mkdtemp()
    shot = os.path.join(tmp, "w.png")
    subprocess.run(["screencapture", "-x", "-o", "-l", str(info["windowID"]), shot], check=True)
    sw, sh = info["screen"]
    wx, wy, ww, wh = info["window"]
    canvas = wallpaper(int(sw), int(sh))
    win = Image.open(shot).convert("RGB").resize((int(ww), int(wh)), Image.LANCZOS)
    canvas.paste(win, (int(wx), int(wy)))
    k = LONG_EDGE / max(sw, sh)
    canvas = canvas.resize((round(sw * k), round(sh * k)), Image.LANCZOS)
    canvas.save(os.path.join(OUT, name + ".png"))
    record = {"app": name, "bundle": bundle, "image": name + ".png", "screen": [sw, sh],
              "sentPixels": [canvas.width, canvas.height], "readMs": info["readMs"], "context": info["context"]}
    json.dump(record, open(os.path.join(OUT, name + ".json"), "w"), indent=1)
    c = info["context"]
    print(f"{name}: {len(c['elements'])} controls, {len(c['menus'])} menu items, read in {info['readMs']} ms")
    if not was_running:
        subprocess.run(["osascript", "-e", f'tell application id "{bundle}" to quit saving no'], capture_output=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in (sys.argv[1:] or APPS):
        capture(name, *APPS[name])


if __name__ == "__main__":
    main()
