#!/usr/bin/env python3
"""Build Wisp's AppIcon.appiconset from design/icon/wisp-icon-source.jpg (a 2000 px render on a flat background).

Cuts out the squircle body (dropping the source's flat background and solid black shadow band), places it on
Apple's macOS icon grid (824 px body on a 1024 canvas) with a soft drop shadow, and writes every required size.
"""
import json, os
from PIL import Image, ImageFilter

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
SRC = os.path.join(ROOT, "design/icon/wisp-icon-source.jpg")
OUT = os.path.join(ROOT, "app/Wisp/Assets.xcassets/AppIcon.appiconset")

im = Image.open(SRC).convert("RGB")
W, H = im.size
# The body is a rounded square from (195, 195) to (1804, 1803) with smooth superellipse corners (radius 490 px,
# exponent 2.5: the largest shape that includes none of the source's black shadow band, found by search). An
# analytic, 2x supersampled mask gives a clean anti-aliased edge; scanning pixels doesn't, because the artwork's
# darkest areas look like the band.
import numpy as np
left, top, right, bottom = 195, 195, 1804, 1803
inset, radius, n, ss = 3, 490.0, 2.5, 2
yy, xx = np.mgrid[0:H * ss, 0:W * ss].astype(np.float32) / ss
x0, y0, x1, y1 = left + inset, top + inset, right - inset, bottom - inset
dx = np.maximum(np.maximum(x0 + radius - xx, xx - (x1 - radius)), 0) / radius
dy = np.maximum(np.maximum(y0 + radius - yy, yy - (y1 - radius)), 0) / radius
inside = (dx ** n + dy ** n <= 1) & (xx >= x0) & (xx <= x1) & (yy >= y0) & (yy <= y1)
m = Image.fromarray((inside * 255).astype(np.uint8)).resize((W, H), Image.LANCZOS)
rgba = im.copy()
rgba.putalpha(m)
body_img = rgba.crop((left, top, right + 1, bottom + 1))

S, B = 1024, 824
body_img = body_img.resize((B, B), Image.LANCZOS)
canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
off = ((S - B) // 2, (S - B) // 2 - 6)
# Soft macOS-style shadow under the body.
alpha = body_img.getchannel("A")
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh = Image.new("RGBA", (B, B), (0, 0, 0, 255))
sh.putalpha(alpha.point(lambda v: int(v * 0.45)))
shadow.paste(sh, (off[0], off[1] + 12), sh)
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
canvas = Image.alpha_composite(canvas, shadow)
canvas.alpha_composite(body_img, off)

os.makedirs(OUT, exist_ok=True)
images = []
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = pt * scale
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        canvas.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
        images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
json.dump({"images": images, "info": {"version": 1, "author": "xcode"}}, open(os.path.join(OUT, "Contents.json"), "w"), indent=2)
json.dump({"info": {"version": 1, "author": "xcode"}}, open(os.path.join(os.path.dirname(OUT), "Contents.json"), "w"), indent=2)
canvas.save(os.path.join(ROOT, "design/icon/AppIcon-1024.png"))
print("wrote", OUT)

# --- Welcome-animation layers (same placement as the app icon): empty squircle, additive glow, and the bubble.
SRCA = np.asarray(im).astype(np.float32)
CX, CY, R = 1000.0, 996.0, 563.0
yy1, xx1 = np.mgrid[0:H, 0:W].astype(np.float32)
dist = np.hypot(xx1 - CX, yy1 - CY)
# Empty body colour per row: the body's own vertical gradient, averaged over pixels well inside the body (away
# from its rim) and outside the glow; rows with no such pixels are interpolated.
from scipy.ndimage import binary_erosion
inner = binary_erosion(np.asarray(m) > 250, iterations=60) & (dist > R * 1.3)
side = np.full((H, 3), np.nan, dtype=np.float32)
for y in range(H):
    xs_ = np.flatnonzero(inner[y])
    if len(xs_) > 20:
        side[y] = SRCA[y, xs_].mean(axis=0)
rows = np.arange(H)
for ch in range(3):
    ok = ~np.isnan(side[:, ch])
    side[:, ch] = np.interp(rows, rows[ok], side[ok, ch])
body = np.repeat(side[:, None, :], W, axis=1)
glow_zone = np.clip((R * 1.3 - dist) / (R * 0.3), 0, 1)[..., None]         # 1 near the bubble, 0 beyond 1.3 r
empty = SRCA * (1 - glow_zone) + body * glow_zone
glow = np.clip(SRCA - body, 0, 255) * glow_zone * (dist >= R - 2)[..., None]
bubble_alpha = np.clip((R + 1.5 - dist) / 3.0, 0, 1)

def place(rgb, alpha_mask, path):
    layer = Image.fromarray(rgb.astype(np.uint8)).convert("RGBA")
    layer.putalpha(Image.fromarray((alpha_mask * 255).astype(np.uint8)))
    layer = layer.crop((left, top, right + 1, bottom + 1)).resize((B, B), Image.LANCZOS)
    c = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    c.alpha_composite(layer, off)
    c.save(path)

WELCOME = os.path.join(ROOT, "app/Packages/WispKit/Sources/WispMac/Resources/Welcome")
os.makedirs(WELCOME, exist_ok=True)
body_alpha = np.asarray(m).astype(np.float32) / 255.0
# Base keeps the shadow so it sits exactly like the app icon.
base_rgba = Image.fromarray(empty.astype(np.uint8)).convert("RGBA")
base_rgba.putalpha(m)
base_body = base_rgba.crop((left, top, right + 1, bottom + 1)).resize((B, B), Image.LANCZOS)
base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
base = Image.alpha_composite(base, shadow)
base.alpha_composite(base_body, off)
# Rim light: the body is darker than the dark welcome window, so a soft edge highlight (brighter along the top,
# like light from above) keeps the tile readable without changing the icon's colours.
from scipy.ndimage import distance_transform_edt
ba = np.asarray(base).astype(np.float32)
solid = ba[..., 3] > 250                                   # the body (the drop shadow is softer than this)
inside = distance_transform_edt(solid)
rim = np.clip(1 - (inside - 1.0) / 9.0, 0, 1) * solid    # 1 at the edge, gone 10 px in (of 1024)
yy = np.arange(S, dtype=np.float32)[:, None] / S
light = (0.30 - 0.20 * yy) * rim                          # top 30 % → bottom 10 % towards white
ba[..., :3] += (255 - ba[..., :3]) * light[..., None]
base = Image.fromarray(np.clip(ba, 0, 255).astype(np.uint8), "RGBA")
base.save(os.path.join(WELCOME, "squircle-empty.png"))
place(glow, body_alpha, os.path.join(WELCOME, "glow.png"))  # composited additively in the app
place(SRCA, bubble_alpha, os.path.join(WELCOME, "bubble.png"))
# Recompose for a visual check: base + glow (add) + bubble should match the app icon.
chk = Image.open(os.path.join(WELCOME, "squircle-empty.png")).convert("RGBA")
g = np.asarray(Image.open(os.path.join(WELCOME, "glow.png")).convert("RGBA")).astype(np.float32)
cb = np.asarray(chk).astype(np.float32)
cb[..., :3] = np.clip(cb[..., :3] + g[..., :3] * (g[..., 3:] / 255.0), 0, 255)
chk = Image.fromarray(cb.astype(np.uint8))
chk.alpha_composite(Image.open(os.path.join(WELCOME, "bubble.png")))
chk.save(os.path.join(ROOT, "tools/out/welcome_recompose.png"))
print("wrote welcome layers to", WELCOME)
