#!/usr/bin/env python3
"""Builds the DMG window background from the Google Flow art (design/dmg/flow-background-2k.jpg).

Window: 660 x 400 points of content (art is 460 tall); Wisp at (170, 180), Applications at (490, 180), icons 128 pt.
Writes design/dmg/background.png (1x), background@2x.png and background.tiff (both, for Finder).

Finder draws the icon labels black in Light Mode and white in Dark Mode (an installer can't choose), so each icon
sits on a frosted tile whose tone keeps both readable (contrast about 4.5:1 either way).
Needs Pillow:  python3 -m pip install pillow
"""
import os, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, "design/dmg/flow-background-2k.jpg")
OUT = os.path.join(ROOT, "design/dmg")
W, H = 660, 460  # 400 pt visible; 60 pt more art for Finder windows with a bottom bar
ICONS = [(170, 180), (490, 180)]
FONT = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    try:  # SF Pro axes: Width, Optical Size, GRAD, Weight
        f.set_variation_by_axes([100, min(max(size / 2, 17), 96), 400, weight])
    except Exception:
        pass
    return f


def render(scale):
    w, h = W * scale, H * scale
    art = Image.open(SRC).convert("RGB")
    # Centre-crop the 16:9 art to the window's shape, keeping the glowing corners.
    aw, ah = art.size
    cw = int(ah * W / H)
    left = (aw - cw) // 2
    base = art.crop((left, 0, left + cw, ah)).resize((w, h), Image.LANCZOS).convert("RGBA")

    # Frosted tiles behind the two icons and their labels.
    blurred = base.filter(ImageFilter.GaussianBlur(18 * scale))
    tiles = Image.new("L", (w, h), 0)
    td = ImageDraw.Draw(tiles)
    tw, th, r = 176 * scale, 186 * scale, 30 * scale
    for (x, y) in ICONS:
        box = (x * scale - tw // 2, (y - 80) * scale, x * scale + tw // 2, (y - 80) * scale + th)
        td.rounded_rectangle(box, radius=r, fill=255)
    frosted = Image.composite(blurred, base, tiles)
    glass = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    gd = ImageDraw.Draw(glass)
    for (x, y) in ICONS:
        box = (x * scale - tw // 2, (y - 80) * scale, x * scale + tw // 2, (y - 80) * scale + th)
        gd.rounded_rectangle(box, radius=r, fill=(255, 255, 255, 84), outline=(255, 255, 255, 60), width=max(1, scale))
    out = Image.alpha_composite(frosted, glass)

    # Arrow from Wisp to Applications: a soft gradient line (pink → teal, like the orb) with a rounded head.
    ss = 4  # supersample for smooth edges
    arrow = Image.new("RGBA", (w * ss, h * ss), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow)
    x0, x1, y = (ICONS[0][0] + 110) * scale * ss, (ICONS[1][0] - 110) * scale * ss, ICONS[0][1] * scale * ss
    steps = 160
    thick = 5 * scale * ss
    for i in range(steps):
        t = i / (steps - 1)
        c = (int(233 + (64 - 233) * t), int(92 + (214 - 92) * t), int(150 + (200 - 150) * t), 235)
        xa = x0 + (x1 - x0 - 14 * scale * ss) * t
        ad.ellipse((xa - thick / 2, y - thick / 2, xa + thick / 2, y + thick / 2), fill=c)
    head = 16 * scale * ss
    ad.line([(x1 - head, y - head), (x1, y), (x1 - head, y + head)], fill=(64, 214, 200, 240), width=int(thick), joint="curve")
    for (px, py) in [(x1 - head, y - head), (x1, y), (x1 - head, y + head)]:
        ad.ellipse((px - thick / 2, py - thick / 2, px + thick / 2, py + thick / 2), fill=(64, 214, 200, 240))
    arrow = arrow.resize((w, h), Image.LANCZOS)
    out = Image.alpha_composite(out, arrow)

    # Caption.
    d = ImageDraw.Draw(out)
    title = "Drag Wisp to Applications"
    f = font(17 * scale, 600)
    tw_, th_ = d.textbbox((0, 0), title, font=f)[2:]
    d.text(((w - tw_) / 2, 318 * scale), title, font=f, fill=(255, 255, 255, 235))
    sub = "Then open Wisp from your Applications folder."
    f2 = font(12 * scale, 400)
    sw, _ = d.textbbox((0, 0), sub, font=f2)[2:]
    d.text(((w - sw) / 2, 346 * scale), sub, font=f2, fill=(255, 255, 255, 165))
    return out.convert("RGB")


def main():
    one, two = render(1), render(2)
    p1, p2 = os.path.join(OUT, "background.png"), os.path.join(OUT, "background@2x.png")
    one.save(p1)
    two.save(p2)
    tiff = os.path.join(OUT, "background.tiff")
    subprocess.run(["tiffutil", "-cathidpicheck", p1, p2, "-out", tiff], check=True, capture_output=True)
    print(f"wrote {p1}, {p2}, {tiff}")


if __name__ == "__main__":
    sys.exit(main())
