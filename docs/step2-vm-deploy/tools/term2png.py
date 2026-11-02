#!/usr/bin/python3
# 사용: term2png.py <입력.txt> <출력.png> [제목]
# 터미널 창 모양으로 텍스트를 PNG로 그린다 (프롬프트 줄은 초록색)
import sys
from PIL import Image, ImageDraw, ImageFont

src, dst = sys.argv[1], sys.argv[2]
title = sys.argv[3] if len(sys.argv) > 3 else "lab@s07"
FONT = "/usr/share/fonts/truetype/nanum/NanumGothicCoding.ttf"
BOLD = "/usr/share/fonts/truetype/nanum/NanumGothicCodingBold.ttf"
SIZE, PAD, BAR, MAXW = 16, 18, 34, 150

font, bold = ImageFont.truetype(FONT, SIZE), ImageFont.truetype(BOLD, SIZE)
small = ImageFont.truetype(FONT, 13)

lines = []
for raw in open(src, encoding="utf-8", errors="replace").read().rstrip("\n").expandtabs(8).split("\n"):
    while len(raw) > MAXW:
        lines.append(raw[:MAXW]); raw = raw[MAXW:]
    lines.append(raw)

lh = SIZE + 6
width = max([int(font.getlength(l)) for l in lines] + [700]) + PAD * 2
height = BAR + PAD * 2 + lh * len(lines)
img = Image.new("RGB", (width, height), "#1e1e1e")
d = ImageDraw.Draw(img)
d.rectangle([0, 0, width, BAR], fill="#323233")
for i, c in enumerate(["#ff5f56", "#ffbd2e", "#27c93f"]):
    d.ellipse([12 + i * 20, 11, 24 + i * 20, 23], fill=c)
d.text((80, 9), title, font=small, fill="#cccccc")

y = BAR + PAD
for l in lines:
    if l.startswith("lab@s07:"):
        head, _, cmd = l.partition("$ ")
        d.text((PAD, y), head + "$ ", font=bold, fill="#4ec9b0")
        d.text((PAD + font.getlength(head + "$ "), y), cmd, font=bold, fill="#ffffff")
    else:
        d.text((PAD, y), l, font=font, fill="#d4d4d4")
    y += lh
img.save(dst)
