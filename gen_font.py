#!/usr/bin/env python3
"""Generate a minimal BMFont with characters from all TickTick tasks and lists."""

import json, math, os, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

BASE_DIR = Path(__file__).parent
FONT_TTF = str(BASE_DIR / "widget/resources/fonts/NotoSansTC-Regular.ttf")
OUT_DIR  = str(BASE_DIR / "widget/resources/fonts")
OUT_NAME = "CJKFont"
FONT_SIZE = 22
ATLAS_W  = 512
ATLAS_H  = 512

# ── Fetch characters directly via TickTickClient (no server needed) ────────────
sys.path.insert(0, str(BASE_DIR))
from dotenv import load_dotenv
load_dotenv(BASE_DIR / ".env")

from ticktick import TickTickClient

client_id     = os.environ["TICKTICK_CLIENT_ID"]
client_secret = os.environ["TICKTICK_CLIENT_SECRET"]
redirect_uri  = os.environ.get("REDIRECT_URI", "http://localhost:8765")
client = TickTickClient(client_id, client_secret, redirect_uri)

print("Fetching lists...")
lists = client.get_lists()
list_names = [lst["name"] for lst in lists]
print(f"  {len(list_names)} lists")

print("Fetching all tasks from every list...")
all_titles = []
for lst in lists:
    try:
        tasks = client.get_list_tasks(lst["id"])
        all_titles += [t["title"] for t in tasks]
        print(f"  {lst['name']}: {len(tasks)} tasks")
    except Exception as e:
        print(f"  {lst['name']}: failed ({e})")

print(f"  Total: {len(all_titles)} tasks")

# ── Build character set ────────────────────────────────────────────────────────
chars_needed = set(range(0x0020, 0x007F))  # ASCII
for text in all_titles + list_names:
    for ch in text:
        chars_needed.add(ord(ch))

print(f"  {len(chars_needed)} unique characters needed")

# ── Measure glyphs ─────────────────────────────────────────────────────────────
pil_font = ImageFont.truetype(FONT_TTF, FONT_SIZE)

glyphs = {}
for cp in chars_needed:
    ch = chr(cp)
    try:
        l, t, r, b = pil_font.getbbox(ch)
    except Exception:
        continue
    w, h = r - l, b - t
    if w <= 0 or h <= 0:
        if cp == 0x0020:
            glyphs[cp] = dict(ch=ch, bbox=(0,0,FONT_SIZE//2,FONT_SIZE), w=FONT_SIZE//2, h=FONT_SIZE)
        continue
    glyphs[cp] = dict(ch=ch, bbox=(l, t, r, b), w=w, h=h)

# ── Pack into atlas ─────────────────────────────────────────────────────────────
CELL_W   = FONT_SIZE + 4
CELL_H   = FONT_SIZE + 6
COLS     = ATLAS_W // CELL_W
PER_PAGE = COLS * (ATLAS_H // CELL_H)

sorted_cps = sorted(glyphs)
n_pages    = math.ceil(len(sorted_cps) / PER_PAGE)

pages = [Image.new("L", (ATLAS_W, ATLAS_H), 0) for _ in range(n_pages)]
draws = [ImageDraw.Draw(p) for p in pages]

cp_to_idx = {cp: i for i, cp in enumerate(sorted_cps)}

packed = {}
for idx, cp in enumerate(sorted_cps):
    g      = glyphs[cp]
    page_i = idx // PER_PAGE
    slot   = idx  % PER_PAGE
    col    = slot % COLS
    row    = slot // COLS
    cx     = col * CELL_W
    cy     = row * CELL_H
    if cp != 0x0020:
        ox = cx + (CELL_W - g['w']) // 2 - g['bbox'][0]
        oy = cy + (CELL_H - g['h']) // 2 - g['bbox'][1]
        draws[page_i].text((ox, oy), g['ch'], font=pil_font, fill=255)
    packed[idx] = dict(
        x=cx, y=cy, width=CELL_W, height=CELL_H,
        xoffset=0, yoffset=0, xadvance=CELL_W,
        page=page_i
    )

# ── Save PNGs ──────────────────────────────────────────────────────────────────
for i, img in enumerate(pages):
    path = os.path.join(OUT_DIR, f"{OUT_NAME}_{i}.png")
    img.save(path)
    print(f"  Page {i}: {os.path.getsize(path)//1024} KB")

# ── Write .fnt ─────────────────────────────────────────────────────────────────
fnt_path = os.path.join(OUT_DIR, f"{OUT_NAME}.fnt")
with open(fnt_path, 'w', encoding='utf-8') as f:
    f.write(f'info face="{OUT_NAME}" size={FONT_SIZE} bold=0 italic=0 charset="" unicode=1 stretchH=100 smooth=0 aa=0 padding=1,1,1,1 spacing=1,1 outline=0\n')
    f.write(f'common lineHeight={CELL_H} base={FONT_SIZE} scaleW={ATLAS_W} scaleH={ATLAS_H} pages={n_pages} packed=0\n')
    for i in range(n_pages):
        f.write(f'page id={i} file="{OUT_NAME}_{i}.png"\n')
    f.write(f'chars count={len(packed)}\n')
    for char_id, g in sorted(packed.items()):
        f.write(f'char id={char_id}   x={g["x"]}   y={g["y"]}   width={g["width"]}   height={g["height"]}   xoffset={g["xoffset"]}   yoffset={g["yoffset"]}   xadvance={g["xadvance"]}   page={g["page"]}  chnl=15\n')

charmap = {str(cp): cp_to_idx[cp] for cp in sorted_cps}
map_path = os.path.join(OUT_DIR, "charmap.json")
with open(map_path, 'w', encoding='utf-8') as f:
    json.dump(charmap, f, ensure_ascii=False)
print(f"  charmap.json: {len(charmap)} entries")

print(f"\nDone: {len(packed)} glyphs, {n_pages} page(s)")
