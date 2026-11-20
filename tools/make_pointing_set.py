#!/usr/bin/env python3
"""Generate the synthetic part of the pointing golden set (M8).

Each item is a fake but realistic Mac screen with one target whose exact box is known, plus a spoken-style
question. Layouts vary on purpose: screen aspect ratio (16:10, 16:9, ultrawide, portrait), light/dark, dense
toolbars, small icon-only buttons, sidebars, sheets/dialogs, web pages, menus and look-alike distractors.

Output (gitignored): eval-data/pointing/<id>.png and eval-data/pointing/golden.json:
  [{"id", "image", "question", "target": [x0, y0, x1, y1], "kind", "aspect"}]
Usage: tools/make_pointing_set.py [count] [seed]
"""
import json, math, os, random, sys
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(__file__), "..", "eval-data", "pointing")
FONT = "/System/Library/Fonts/SFNS.ttf"
SIZES = {"16:10": (1456, 910), "16:9": (1456, 819), "21:9": (1456, 610), "portrait": (819, 1456), "4:3": (1456, 1092)}

ACTIONS = {  # label -> ways a person might ask for it
    "Export": ["How do I export this?", "Where's the export button?"],
    "Share": ["How do I share this with someone?", "Where do I click to share?"],
    "Save": ["How do I save my changes?", "Where's save?"],
    "Delete": ["How do I delete this?", "Which button deletes it?"],
    "Settings": ["Where are the settings?", "How do I open settings?"],
    "New Folder": ["How do I make a new folder?"],
    "Import": ["How do I import my files?"],
    "Print": ["How do I print this?"],
    "Sign In": ["How do I sign in?", "Where do I log in?"],
    "Download": ["How do I download this?", "Where's the download button?"],
    "Upload": ["How do I upload a file?"],
    "Cancel": ["How do I cancel this?"],
    "Continue": ["How do I go to the next step?", "What do I press to continue?"],
    "Add Account": ["How do I add another account?"],
    "Duplicate": ["How do I make a copy of this?"],
    "Rename": ["How do I rename this?"],
    "Filter": ["How do I filter this list?"],
    "Sort": ["How do I change the sort order?"],
    "Invite": ["How do I invite someone?"],
    "Publish": ["How do I publish this?"],
    "Undo": ["How do I undo that?"],
    "Crop": ["How do I crop the picture?"],
    "Rotate": ["How do I rotate the image?"],
    "Archive": ["How do I archive this?"],
    "Reply": ["How do I reply?"],
    "Compose": ["How do I write a new message?"],
    "Log Out": ["How do I log out?"],
    "Subscribe": ["How do I subscribe?"],
    "Checkout": ["How do I check out?"],
}
ICONS = {  # icon-only buttons: (draw fn name, questions)
    "gear": ["Where's the gear icon for settings?", "How do I open the settings? It's the little gear."],
    "trash": ["Where's the trash can icon?", "Which icon deletes this?"],
    "plus": ["Where's the plus button to add one?", "How do I add a new one?"],
    "search": ["Where's the search icon?", "How do I search?"],
    "bell": ["Where are my notifications?", "Where's the bell icon?"],
    "close": ["How do I close this panel?"],
}
SIDEBAR = ["Library", "Recents", "Favorites", "Shared", "Projects", "Drafts", "Archive", "Trash", "Downloads", "Documents"]
DISTRACT = {"Export": ["Export All", "Exports"], "Save": ["Save As…", "Saved"], "Share": ["Shared", "Share Link"],
            "Delete": ["Delete All"], "Download": ["Downloads"], "Settings": ["Settings Sync"]}


class Theme:
    def __init__(self, dark):
        self.dark = dark
        self.bg = (30, 30, 32) if dark else (236, 236, 238)
        self.chrome = (44, 44, 48) if dark else (222, 222, 226)
        self.side = (38, 38, 42) if dark else (246, 246, 248)
        self.content = (24, 24, 26) if dark else (255, 255, 255)
        self.text = (235, 235, 240) if dark else (30, 30, 32)
        self.dim = (150, 150, 158) if dark else (120, 120, 128)
        self.btn = (70, 70, 76) if dark else (250, 250, 252)
        self.border = (90, 90, 96) if dark else (196, 196, 202)
        self.accent = random.choice([(10, 132, 255), (48, 176, 90), (175, 82, 222), (255, 105, 40)])


def font(px):
    return ImageFont.truetype(FONT, px)


def button(d, t, x, y, label, px, primary=False, pad=14):
    f = font(px)
    w = d.textlength(label, font=f) + pad * 2
    h = px + 16
    fill = t.accent if primary else t.btn
    d.rounded_rectangle([x, y, x + w, y + h], radius=h // 3, fill=fill, outline=None if primary else t.border)
    d.text((x + pad, y + 7), label, fill=(255, 255, 255) if primary else t.text, font=f)
    return [x, y, x + w, y + h]


def icon(d, t, kind, cx, cy, r):
    c = t.text
    if kind == "gear":
        for i in range(8):
            a = i * math.pi / 4
            d.line([cx + math.cos(a) * r * 0.5, cy + math.sin(a) * r * 0.5, cx + math.cos(a) * r, cy + math.sin(a) * r], fill=c, width=max(2, r // 3))
        d.ellipse([cx - r * 0.65, cy - r * 0.65, cx + r * 0.65, cy + r * 0.65], outline=c, width=max(2, r // 4))
    elif kind == "trash":
        d.rectangle([cx - r * 0.6, cy - r * 0.5, cx + r * 0.6, cy + r], outline=c, width=2)
        d.line([cx - r * 0.85, cy - r * 0.65, cx + r * 0.85, cy - r * 0.65], fill=c, width=2)
        d.rectangle([cx - r * 0.25, cy - r * 0.9, cx + r * 0.25, cy - r * 0.65], outline=c, width=2)
    elif kind == "plus":
        d.line([cx - r * 0.8, cy, cx + r * 0.8, cy], fill=c, width=3)
        d.line([cx, cy - r * 0.8, cx, cy + r * 0.8], fill=c, width=3)
    elif kind == "search":
        d.ellipse([cx - r * 0.7, cy - r * 0.7, cx + r * 0.3, cy + r * 0.3], outline=c, width=3)
        d.line([cx + r * 0.15, cy + r * 0.15, cx + r * 0.85, cy + r * 0.85], fill=c, width=3)
    elif kind == "bell":
        d.chord([cx - r * 0.7, cy - r * 0.8, cx + r * 0.7, cy + r * 0.9], 180, 360, outline=c, width=2)
        d.line([cx - r * 0.7, cy + r * 0.1, cx - r * 0.7, cy + r * 0.6], fill=c, width=2)
        d.line([cx + r * 0.7, cy + r * 0.1, cx + r * 0.7, cy + r * 0.6], fill=c, width=2)
        d.line([cx - r * 0.9, cy + r * 0.6, cx + r * 0.9, cy + r * 0.6], fill=c, width=2)
        d.ellipse([cx - r * 0.18, cy + r * 0.7, cx + r * 0.18, cy + r * 1.0], fill=c)
    elif kind == "close":
        d.line([cx - r * 0.6, cy - r * 0.6, cx + r * 0.6, cy + r * 0.6], fill=c, width=3)
        d.line([cx - r * 0.6, cy + r * 0.6, cx + r * 0.6, cy - r * 0.6], fill=c, width=3)
    return [cx - r - 4, cy - r - 4, cx + r + 4, cy + r + 4]


def menubar(d, t, W, scale):
    h = int(26 * scale)
    d.rectangle([0, 0, W, h], fill=(20, 20, 22) if t.dark else (246, 246, 248))
    f = font(int(13 * scale))
    x = 40
    for m in ["", "File", "Edit", "View", "Window", "Help"]:
        d.text((x, 5 * scale), m, fill=t.text, font=f)
        x += d.textlength(m, font=f) + 22 * scale
    return h


def lorem(d, t, x0, y0, x1, y1, px):
    words = "the quick report shows totals for each region with notes from the team about next steps and budget".split()
    f = font(px)
    y = y0
    while y < y1 - px:
        line = " ".join(random.choice(words) for _ in range(random.randint(6, 14)))
        while d.textlength(line, font=f) > x1 - x0 and " " in line:
            line = line.rsplit(" ", 1)[0]
        d.text((x0, y), line, fill=t.dim, font=f)
        y += px + 10


def scene_app(W, H, t, target, scale, avoid=()):
    """Window with toolbar, sidebar, content; target is a labelled button somewhere plausible."""
    img = Image.new("RGB", (W, H), t.bg)
    d = ImageDraw.Draw(img)
    top = menubar(d, t, W, scale)
    wx0, wy0 = int(random.uniform(0, 0.06) * W), top + int(random.uniform(0, 0.05) * H)
    wx1, wy1 = W - int(random.uniform(0, 0.06) * W), H - int(random.uniform(0, 0.05) * H)
    d.rectangle([wx0, wy0, wx1, wy1], fill=t.content)
    th = int(52 * scale)
    d.rectangle([wx0, wy0, wx1, wy0 + th], fill=t.chrome)
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        d.ellipse([wx0 + 18 + i * 22 * scale, wy0 + 18 * scale, wx0 + 30 * scale + i * 22 * scale, wy0 + 30 * scale], fill=c)
    side = int(random.uniform(0.14, 0.22) * (wx1 - wx0)) if W > H * 0.8 else 0
    if side:
        d.rectangle([wx0, wy0 + th, wx0 + side, wy1], fill=t.side)
        for i, name in enumerate(random.sample(SIDEBAR, 6)):
            d.text((wx0 + 22, wy0 + th + 24 + i * 38 * scale), name, fill=t.text, font=font(int(15 * scale)))
    px = int(random.choice([12, 13, 14, 16]) * scale)
    # Toolbar buttons (distractors + maybe target)
    pool = [k for k in ACTIONS if k != target and k not in avoid]
    labels = random.sample(pool, random.randint(3, 6))
    labels += DISTRACT.get(target, [])[:random.randint(0, 2)]
    where = random.choice(["toolbar", "bottom-right", "content", "toolbar"])
    if where == "toolbar":
        labels.insert(random.randrange(len(labels) + 1), target)
    x = wx0 + side + 20 + random.randint(0, 120)
    box = None
    for lab in labels:
        b = button(d, t, x, wy0 + (th - px - 16) // 2, lab, px, primary=False)
        if lab == target:
            box = b
        x = b[2] + random.randint(6, 18)
        if x > wx1 - 200:
            break
    cx0, cy0 = wx0 + side + 30, wy0 + th + 30
    d.text((cx0, cy0), random.choice(["Quarterly Report", "Trip Photos", "Untitled Project", "Invoices", "Team Notes"]),
           fill=t.text, font=font(int(26 * scale)))
    lorem(d, t, cx0, cy0 + 50 * scale, wx1 - 40, wy1 - 120 * scale, int(14 * scale))
    if box is None and where == "bottom-right":
        f = font(px)
        w = d.textlength(target, font=f) + 28
        box = button(d, t, wx1 - 30 - w, wy1 - 30 - px - 16, target, px, primary=True)
        other = random.choice([o for o in ["Cancel", "Back", "Close"] if o != target])
        button(d, t, box[0] - d.textlength(other, font=f) - 28 - 12, box[1], other, px)
    if box is None:  # in content, among a row of buttons
        y = int(random.uniform(0.45, 0.8) * (wy1 - wy0)) + wy0
        x = cx0 + random.randint(0, 200)
        row = random.sample(pool, 3)
        row.insert(random.randrange(4), target)
        for lab in row:
            b = button(d, t, x, y, lab, px, primary=lab == target and random.random() < 0.5)
            if lab == target:
                box = b
            x = b[2] + 12
    return img, box


def scene_icon(W, H, t, kind, scale):
    """Toolbar of icon-only buttons; target is one icon."""
    img = Image.new("RGB", (W, H), t.bg)
    d = ImageDraw.Draw(img)
    top = menubar(d, t, W, scale)
    d.rectangle([0, top, W, top + 56 * scale], fill=t.chrome)
    kinds = random.sample(list(ICONS), len(ICONS))
    r = int(random.choice([9, 11, 14]) * scale)
    side = random.choice(["left", "right"])
    xs = [int(30 * scale + i * (r * 2 + 26)) for i in range(len(kinds))]
    if side == "right":
        xs = [W - x for x in xs]
    box = None
    for k, x in zip(kinds, xs):
        b = icon(d, t, k, x, int(top + 28 * scale), r)
        if k == kind:
            box = b
    d.rectangle([40, top + 90 * scale, W - 40, H - 40], fill=t.content)
    lorem(d, t, 70, top + 120 * scale, W - 70, H - 80, int(15 * scale))
    return img, box


def scene_web(W, H, t, target, scale):
    """A browser window with a web page: nav links, hero, cards; target is a link/button."""
    img = Image.new("RGB", (W, H), t.bg)
    d = ImageDraw.Draw(img)
    top = menubar(d, t, W, scale)
    d.rectangle([0, top, W, top + 74 * scale], fill=t.chrome)
    d.rounded_rectangle([W * 0.25, top + 40 * scale, W * 0.75, top + 64 * scale], radius=8, fill=t.btn)
    d.text((W * 0.27, top + 44 * scale), "example-store.com", fill=t.dim, font=font(int(13 * scale)))
    page = top + 74 * scale
    d.rectangle([0, page, W, H], fill=t.content)
    navy = page + 20 * scale
    d.text((40, navy), "Lumen", fill=t.text, font=font(int(22 * scale)))
    links = random.sample(["Products", "Pricing", "Blog", "About", "Support", "Careers"], 4)
    x = W * 0.35
    box = None
    f = font(int(15 * scale))
    for lab in links:
        d.text((x, navy + 4), lab, fill=t.text, font=f)
        x += d.textlength(lab, font=f) + 34 * scale
    if random.random() < 0.5:
        box = button(d, t, W - 40 - d.textlength(target, font=f) - 28, navy, target, int(15 * scale), primary=True)
    d.text((60, page + 120 * scale), "Everything you need, in one place.", fill=t.text, font=font(int(34 * scale)))
    lorem(d, t, 60, page + 180 * scale, W * 0.6, page + 260 * scale, int(15 * scale))
    cy = page + 300 * scale
    cw = (W - 120 - 40) / 3
    for i in range(3):
        x0 = 60 + i * (cw + 20)
        if cy + 220 * scale < H:
            d.rounded_rectangle([x0, cy, x0 + cw, cy + 200 * scale], radius=12, outline=t.border, fill=t.content)
            d.text((x0 + 20, cy + 20), random.choice(["Starter", "Pro", "Team", "Basic"]), fill=t.text, font=font(int(18 * scale)))
            lab = target if (box is None and i == random.randrange(3) and target) else random.choice(["Learn more", "Details", "Buy"])
            b = button(d, t, x0 + 20, cy + 140 * scale, lab, int(14 * scale), primary=lab == target)
            if lab == target and box is None:
                box = b
    if box is None:
        box = button(d, t, 60, page + 270 * scale - 50, target, int(16 * scale), primary=True)
    return img, box


def scene_dialog(W, H, t, target, scale):
    """App window dimmed with a centred sheet; target is a dialog button or a checkbox label."""
    img, _ = scene_app(W, H, t, random.choice([k for k in ACTIONS if k != target]), scale, avoid=(target,))
    over = Image.new("RGBA", (W, H), (0, 0, 0, 90))
    img = Image.alpha_composite(img.convert("RGBA"), over).convert("RGB")
    d = ImageDraw.Draw(img)
    dw, dh = int(min(W * 0.5, 520 * scale)), int(260 * scale)
    x0, y0 = (W - dw) // 2, int(H * 0.3)
    d.rounded_rectangle([x0, y0, x0 + dw, y0 + dh], radius=14, fill=t.content, outline=t.border)
    d.text((x0 + 24, y0 + 24), random.choice(["Save changes before closing?", "Export settings", "Confirm"]),
           fill=t.text, font=font(int(17 * scale)))
    lorem(d, t, x0 + 24, y0 + 60 * scale, x0 + dw - 24, y0 + 140 * scale, int(13 * scale))
    px = int(13 * scale)
    f = font(px)
    others = random.sample([o for o in ["Cancel", "Don't Save", "Back", "Later"] if o != target], 2)
    labs = others + [target]
    x = x0 + dw - 24
    box = None
    for lab in reversed(labs):
        w = d.textlength(lab, font=f) + 28
        b = button(d, t, x - w, y0 + dh - 24 - px - 16, lab, px, primary=lab == target)
        if lab == target:
            box = b
        x = b[0] - 10
    return img, box


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 48
    random.seed(int(sys.argv[2]) if len(sys.argv) > 2 else 7)
    os.makedirs(OUT, exist_ok=True)
    golden = []
    scenes = ["app", "app", "icon", "web", "dialog"]
    for i in range(count):
        aspect = list(SIZES)[i % len(SIZES)]
        W, H = SIZES[aspect]
        t = Theme(dark=random.random() < 0.35)
        scale = random.choice([0.8, 1.0, 1.0, 1.2])
        scene = scenes[i % len(scenes)]
        if scene == "icon":
            kind = random.choice(list(ICONS))
            img, box = scene_icon(W, H, t, kind, scale)
            question, label = random.choice(ICONS[kind]), kind
        else:
            label = random.choice(list(ACTIONS))
            img, box = {"app": scene_app, "web": scene_web, "dialog": scene_dialog}[scene](W, H, t, label, scale)
            question = random.choice(ACTIONS[label])
        if box is None:
            continue
        item_id = f"syn-{i:03d}"
        img.save(os.path.join(OUT, item_id + ".png"))
        golden.append({"id": item_id, "image": item_id + ".png", "question": question, "label": label,
                       "target": [round(v) for v in box], "kind": scene, "aspect": aspect, "dark": t.dark})
    with open(os.path.join(OUT, "golden.json"), "w") as f:
        json.dump(golden, f, indent=1)
    print(f"wrote {len(golden)} items to {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
