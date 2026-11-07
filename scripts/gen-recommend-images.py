#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成智慧屏应用「推荐图片」前两张（华为 AppGallery 素材位）：
  - 推荐图_01: 396 x 223（横向）
  - 推荐图_02: 414 x 573（竖向）
格式：PNG/JPG/JPEG ≤2MB 或 WEBP ≤100KB，用 PNG 输出。
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, "docs", "store", "icon_1024.png")
OUT_DIR = os.path.join(ROOT, "docs", "store", "recommend")

BG_TOP = (0x1A, 0x18, 0x20)
BG_BOT = (0x0D, 0x0D, 0x0D)
WHITE = (0xFF, 0xFF, 0xFF)
ACCENT = (0xFF, 0xC1, 0x07)
GRAY = (0xB8, 0xB6, 0xC0)

F_TITLE = "/System/Library/Fonts/STHeiti Medium.ttc"
F_BODY = "/System/Library/Fonts/STHeiti Light.ttc"


def font(path, size):
    return ImageFont.truetype(path, size, index=0)


def gradient(w, h):
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / max(1, h - 1)
        r = int(BG_TOP[0] + (BG_BOT[0] - BG_TOP[0]) * t)
        g = int(BG_TOP[1] + (BG_BOT[1] - BG_TOP[1]) * t)
        b = int(BG_TOP[2] + (BG_BOT[2] - BG_TOP[2]) * t)
        d.line([(0, y), (w, y)], fill=(r, g, b))
    return im


def rounded_icon(size, radius):
    ic = Image.open(ICON).convert("RGBA").resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(ic, (0, 0), mask)
    return out


def center_text(draw, cx, top, text, fnt, fill):
    bb = draw.textbbox((0, 0), text, font=fnt)
    draw.text((cx - (bb[2] - bb[0]) / 2 - bb[0], top - bb[1]), text, font=fnt, fill=fill)
    return bb[3] - bb[1]


# ---- 图1：396 x 223 横向 ----
W1, H1 = 396, 223
img1 = gradient(W1, H1)
d1 = ImageDraw.Draw(img1)

icon1 = rounded_icon(80, 18)
icon_x = 26
icon_y = (H1 - 80) // 2
img1.paste(icon1, (icon_x, icon_y), icon1)

title = "夜帧影视"
sub = "直播 · 点播 · 直连"
f_t1 = font(F_TITLE, 42)
f_s1 = font(F_BODY, 21)

bb_t = d1.textbbox((0, 0), title, font=f_t1)
bb_s = d1.textbbox((0, 0), sub, font=f_s1)
th1 = bb_t[3] - bb_t[1]
sh1 = bb_s[3] - bb_s[1]
gap = 10
block = th1 + gap + sh1
text_x = icon_x + 80 + 22
ty = (H1 - block) // 2

d1.text((text_x, ty - bb_t[1]), title, font=f_t1, fill=WHITE)
d1.text((text_x, ty + th1 + gap - bb_s[1]), sub, font=f_s1, fill=ACCENT)

os.makedirs(OUT_DIR, exist_ok=True)
out1 = os.path.join(OUT_DIR, "推荐图_01_396x223.png")
img1.save(out1, "PNG")
print("saved:", out1, img1.size)

# ---- 图2：414 x 573 竖向 ----
W2, H2 = 414, 573
img2 = gradient(W2, H2)
d2 = ImageDraw.Draw(img2)

icon2 = rounded_icon(150, 34)
ic_y = 88
img2.paste(icon2, ((W2 - 150) // 2, ic_y), icon2)

f_t2 = font(F_TITLE, 62)
f_a2 = font(F_BODY, 34)
f_d2 = font(F_BODY, 25)

y = ic_y + 150 + 34
center_text(d2, W2 / 2, y, "夜帧影视", f_t2, WHITE)
y += 62 * 1.25 + 18
center_text(d2, W2 / 2, y, "直播 · 点播 · 直连", f_a2, ACCENT)
y += 34 * 1.25 + 14
center_text(d2, W2 / 2, y, "原生鸿蒙大屏影音播放器", f_d2, GRAY)

out2 = os.path.join(OUT_DIR, "推荐图_02_414x573.png")
img2.save(out2, "PNG")
print("saved:", out2, img2.size)
print("done")
