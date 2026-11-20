#!/usr/bin/env python3
"""Summarise wisp-bench point-eval results: eval-data/pointing/results/*.json -> table."""
import glob, json, math, os, sys
from collections import defaultdict

def pct(v, p):
    if not v: return "-"
    v = sorted(v); return v[min(len(v) - 1, max(0, math.ceil(p / 100 * len(v)) - 1))]

d = sys.argv[1] if len(sys.argv) > 1 else "eval-data/pointing/results"
for f in sorted(glob.glob(os.path.join(d, "*.json"))):
    r = json.load(open(f)); n = len(r)
    hit = sum(x["hit"] for x in r); pointed = sum(x["pointed"] for x in r)
    errs = defaultdict(int)
    for x in r:
        if x.get("error"): errs[x["error"]] += 1
    kinds = defaultdict(lambda: [0, 0]); aspects = defaultdict(lambda: [0, 0])
    for x in r:
        kinds[x["kind"]][0] += x["hit"]; kinds[x["kind"]][1] += 1
        aspects[x["aspect"]][0] += x["hit"]; aspects[x["aspect"]][1] += 1
    miss = [int(x["errorPixels"]) for x in r if x["pointed"] and not x["hit"]]
    pt = [x["pointMs"] for x in r if x.get("pointMs")]; tot = [x["totalMs"] for x in r]
    ft = [x["firstTokenMs"] for x in r if x.get("firstTokenMs")]
    print(f"== {os.path.basename(f)[:-5]}  (n={n})")
    print(f"   hit {hit}/{n} = {hit / n:.0%}   pointed {pointed}/{n}   errors {dict(errs)}   retried {sum(x['attempts'] > 1 for x in r)}")
    print("   by scene: " + ", ".join(f"{k} {a}/{b}" for k, (a, b) in sorted(kinds.items())))
    print("   by aspect: " + ", ".join(f"{k} {a}/{b}" for k, (a, b) in sorted(aspects.items())))
    print(f"   miss distance px: p50 {pct(miss, 50)}  p95 {pct(miss, 95)}  ({len(miss)} misses)")
    print(f"   first token ms p50 {pct(ft, 50)} p95 {pct(ft, 95)} | time to point p50 {pct(pt, 50)} p95 {pct(pt, 95)} | total p50 {pct(tot, 50)} p95 {pct(tot, 95)}")
