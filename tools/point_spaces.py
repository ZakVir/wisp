#!/usr/bin/env python3
"""Re-score point-eval results as if each model answered in pixels, 0-1000, or 0-1 (finds a model's native space)."""
import json, glob, os, sys
from PIL import Image
golden = sys.argv[1] if len(sys.argv) > 1 else "eval-data/pointing/golden-synthetic.json"
results = sys.argv[2] if len(sys.argv) > 2 else "eval-data/pointing/results"
g = {x["id"]: x for x in json.load(open(golden))}
for f in sorted(glob.glob(os.path.join(results, "*.json"))):
    r = json.load(open(f)); hits = {"px": 0, "n1000": 0, "unit": 0}; n = 0
    for x in r:
        if not x.get("aim") or x["id"] not in g: continue
        it = g[x["id"]]; W, H = Image.open(os.path.join(os.path.dirname(golden), it["image"])).size
        t = it["target"]; ax, ay = x["aim"]; n += 1
        inside = lambda px, py, tol=6: t[0] - tol <= px <= t[2] + tol and t[1] - tol <= py <= t[3] + tol
        hits["px"] += inside(ax, ay); hits["n1000"] += inside(ax / 1000 * W, ay / 1000 * H); hits["unit"] += inside(ax * W, ay * H)
    print(os.path.basename(f)[:-5].ljust(48), f"pointed {n}/{len(r)}", hits)
