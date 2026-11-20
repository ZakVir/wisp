"""Side-by-side: reference cursor crops (left) vs Wisp's rendered themes (right). Local dev aid only."""
from PIL import Image
refs = Image.open('tools/out/refs.png')
ours = Image.open('tools/out/themes.png')
cell = 360
n = 11
rows = []
for i in range(n):
    gx, gy = (i % 4) * cell * 2, (i // 4) * cell
    pair = ours.crop((gx, gy, gx + cell * 2, gy + cell)).resize((600, 300))
    ref = refs.crop((0, 300 * i, refs.width, 300 * (i + 1)))
    row = Image.new('RGB', (ref.width + 610, 300), (255, 255, 255))
    row.paste(ref, (0, 0)); row.paste(pair, (ref.width + 10, 0))
    rows.append(row)
def sheet(rs, path):
    out = Image.new('RGB', (rs[0].width, 300 * len(rs)), (255, 255, 255))
    for i, r in enumerate(rs): out.paste(r, (0, 300 * i))
    out.save(path)
sheet(rows[:6], 'tools/out/compare_a.png')
sheet(rows[6:], 'tools/out/compare_b.png')
print('ok')
