#!/usr/bin/env python3
"""Probe NVIDIA NIM chat models for image support and basic pointing ability.

Uses a synthetic UI image (no real screen content). The API key is read from the
login Keychain (service com.zakvirani.wisp.dev, account NVIDIA_API_KEY) or from
the NVIDIA_API_KEY environment variable. Nothing secret is printed.

Usage: tools/nim_vision_probe.py [model ...]   (default: every chat model listed)
Writes a JSON summary to tools/out/nim_probe.json.
"""
import base64, concurrent.futures as cf, io, json, os, re, subprocess, sys, time
import requests
from PIL import Image, ImageDraw, ImageFont

BASE = "https://integrate.api.nvidia.com/v1"
SKIP = re.compile(r"embed|reward|guard|safety|translate|clip|parse|deplot|kosmos|detector|calibration|retriever|starcoder|codellama|code|fuyu|diffusion|llama2|recurrent|gemma-2b|sea-lion|zamba|chatqa|nemoguard", re.I)


def api_key():
    if os.environ.get("NVIDIA_API_KEY"):
        return os.environ["NVIDIA_API_KEY"]
    return subprocess.check_output(["security", "find-generic-password", "-a", "NVIDIA_API_KEY",
                                    "-s", "com.zakvirani.wisp.dev", "-w"], text=True).strip()


def synthetic_ui():
    """A 1456x910 fake app window with labelled buttons; returns (png_bytes, targets)."""
    W, H = 1456, 910
    img = Image.new("RGB", (W, H), (236, 236, 238))
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 22)
    d.rectangle([0, 0, W, 52], fill=(222, 222, 226))
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        d.ellipse([18 + i * 26, 18, 34 + i * 26, 34], fill=c)
    d.text((W // 2 - 60, 14), "Photo Editor", fill=(40, 40, 40), font=font)
    d.rectangle([0, 52, 240, H], fill=(246, 246, 248))
    for i, name in enumerate(["Library", "Albums", "Recents", "Favorites", "Trash"]):
        d.text((28, 90 + i * 48), name, fill=(30, 30, 30), font=font)
    buttons = {"Export": (1180, 760, 1400, 820), "Crop": (300, 90, 420, 140),
               "Adjust": (440, 90, 580, 140), "Share": (1250, 70, 1400, 120)}
    for name, (x0, y0, x1, y1) in buttons.items():
        d.rounded_rectangle([x0, y0, x1, y1], radius=10, fill=(0, 122, 255) if name == "Export" else (255, 255, 255),
                            outline=(190, 190, 195))
        d.text((x0 + 22, y0 + 14), name, fill=(255, 255, 255) if name == "Export" else (20, 20, 20), font=font)
    d.rectangle([300, 170, 1400, 730], fill=(200, 210, 225))
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue(), buttons, (W, H)


PROMPT = ("The image is {w}x{h} pixels. Where is the button labeled 'Export'? "
          "Reply with exactly one line: POINT: x,y  (pixel coordinates of its center), nothing else.")


def probe(model, key, png, targets, size):
    body = {
        "model": model, "max_tokens": 400, "temperature": 0.0, "stream": True,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": PROMPT.format(w=size[0], h=size[1])},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + base64.b64encode(png).decode()}}]}],
    }
    t0 = time.monotonic()
    out = {"model": model}
    try:
        r = requests.post(BASE + "/chat/completions", json=body, stream=True, timeout=90,
                          headers={"Authorization": "Bearer " + key, "Accept": "text/event-stream"})
        out["http"] = r.status_code
        if r.status_code != 200:
            out["error"] = r.text[:300]
            return out
        text, ttft = "", None
        for line in r.iter_lines(decode_unicode=True):
            if not line or not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                delta = json.loads(data)["choices"][0].get("delta", {})
            except (KeyError, IndexError, json.JSONDecodeError):
                continue
            piece = delta.get("content") or ""
            if piece and ttft is None:
                ttft = time.monotonic() - t0
            text += piece
        out.update(ttft_s=round(ttft, 3) if ttft else None, total_s=round(time.monotonic() - t0, 3), reply=text.strip()[:200])
        m = re.search(r"(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)", text)
        if m:
            x, y = float(m.group(1)), float(m.group(2))
            x0, y0, x1, y1 = targets["Export"]
            out["point"] = [x, y]
            out["hit"] = x0 <= x <= x1 and y0 <= y <= y1
    except Exception as e:  # network errors are data for this probe
        out["error"] = type(e).__name__ + ": " + str(e)[:200]
    return out


def main():
    key = api_key()
    models = sys.argv[1:]
    if not models:
        listing = requests.get(BASE + "/models", headers={"Authorization": "Bearer " + key}, timeout=30).json()["data"]
        models = sorted(m["id"] for m in listing if not SKIP.search(m["id"]))
    png, targets, size = synthetic_ui()
    os.makedirs("tools/out", exist_ok=True)
    with open("tools/out/synthetic_ui.png", "wb") as f:
        f.write(png)
    with cf.ThreadPoolExecutor(max_workers=6) as ex:
        results = list(ex.map(lambda m: probe(m, key, png, targets, size), models))
    results.sort(key=lambda r: (not r.get("hit", False), r.get("ttft_s") or 999))
    for r in results:
        print(f"{r['model']:52} http={r.get('http')} hit={r.get('hit')} ttft={r.get('ttft_s')} total={r.get('total_s')} "
              f"reply={(r.get('reply') or r.get('error') or '')[:70]!r}")
    with open("tools/out/nim_probe.json", "w") as f:
        json.dump(results, f, indent=1)


if __name__ == "__main__":
    main()
