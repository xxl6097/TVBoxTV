#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成竖屏应用截图（1080x1920，9:16），用于华为应用市场手机端素材位。
版式：深色背景 + 顶部品牌/功能标题 + 中间横屏画面 + 底部功能说明。
"""

import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCREEN_DIR = os.path.join(ROOT, "docs", "store", "screenshots")
ICON = os.path.join(ROOT, "docs", "store", "icon_1024.png")
OUT_DIR = os.path.join(SCREEN_DIR, "portrait")

W, H = 1080, 1920
BG_TOP = (0x14, 0x14, 0x14)
BG_BOT = (0x0D, 0x0D, 0x0D)
WHITE = (0xFF, 0xFF, 0xFF)
ACCENT = (0xFF, 0xC1, 0x07)   # 金黄色，呼应选中态强调色
GRAY = (0x9A, 0x9A, 0x9A)

FONT_TITLE = "/System/Library/Fonts/STHeiti Medium.ttc"
FONT_BODY = "/System/Library/Fonts/STHeiti Light.ttc"


def font(path, size, index=0):
    return ImageFont.truetype(path, size, index=index)


def draw_centered_text(draw, cx, top, text, fnt, fill):
    bbox = draw.textbbox((0, 0), text, font=fnt)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    draw.text((cx - tw / 2 - bbox[0], top - bbox[1]), text, font=fnt, fill=fill)
    return th


def rounded_icon(icon_path, size, radius):
    ic = Image.open(icon_path).convert("RGBA")
    ic = ic.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(ic, (0, 0), mask)
    return out


def gradient_bg(w, h):
    bg = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(bg)
    for y in range(h):
        t = y / max(1, h - 1)
        r = int(BG_TOP[0] + (BG_BOT[0] - BG_TOP[0]) * t)
        g = int(BG_TOP[1] + (BG_BOT[1] - BG_TOP[1]) * t)
        b = int(BG_TOP[2] + (BG_BOT[2] - BG_TOP[2]) * t)
        d.line([(0, y), (w, y)], fill=(r, g, b))
    return bg


def make_portrait(src_name, feature_title, desc, out_name):
    src = os.path.join(SCREEN_DIR, src_name)
    shot = Image.open(src).convert("RGB")

    # 横屏画面缩放到 1080 宽，保持 16:9
    frame_h = round(W * shot.height / shot.width)
    shot = shot.resize((W, frame_h), Image.LANCZOS)

    canvas = gradient_bg(W, H)
    draw = ImageDraw.Draw(canvas)

    # 画面垂直居中
    frame_top = (H - frame_h) // 2
    canvas.paste(shot, (0, frame_top))

    top_zone = frame_top          # 顶部留白区高度
    bottom_zone = H - frame_top - frame_h

    # ---- 顶部：图标 + 品牌 + 功能标题 ----
    icon_size = 128
    icon = rounded_icon(ICON, icon_size, radius=30)
    icon_cx = (W - icon_size) // 2
    # 顶部内容整体垂直居中于 top_zone
    brand = "夜帧影视"
    f_brand = font(FONT_TITLE, 60)
    f_feature = font(FONT_BODY, 42)
    bbox_brand = draw.textbbox((0, 0), brand, font=f_brand)
    brand_h = bbox_brand[3] - bbox_brand[1]
    bbox_feature = draw.textbbox((0, 0), feature_title, font=f_feature)
    feat_h = bbox_feature[3] - bbox_feature[1]

    gap1, gap2 = 22, 14
    block_h = icon_size + gap1 + brand_h + gap2 + feat_h
    y = (top_zone - block_h) // 2

    canvas.paste(icon, (icon_cx, y), icon)
    y += icon_size + gap1
    draw_centered_text(draw, W / 2, y, brand, f_brand, WHITE)
    y += brand_h + gap2
    draw_centered_text(draw, W / 2, y, feature_title, f_feature, ACCENT)

    # ---- 底部：功能说明 ----
    f_desc = font(FONT_BODY, 34)
    bbox_desc = draw.textbbox((0, 0), desc, font=f_desc)
    desc_h = bbox_desc[3] - bbox_desc[1]
    desc_top = frame_top + frame_h + (bottom_zone - desc_h) // 2
    draw_centered_text(draw, W / 2, desc_top, desc, f_desc, GRAY)

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, out_name)
    canvas.save(out, "PNG")
    print("saved:", out, canvas.size)


SHOTS = [
    ("07_首页.png", "大屏首页", "点播·直播·直连·搜索·收藏·历史·设置，功能一目了然", "竖版_01_首页.png"),
    ("01_点播分类.png", "点播分类", "电视剧·电影·综艺·动漫，多站聚合一站式浏览", "竖版_02_点播分类.png"),
    ("02_直播分组.png", "直播分组", "央视·卫视·地方·体育，按组找台一屏直达", "竖版_03_直播分组.png"),
    ("11_播放控制条.png", "高清播放", "多码率自适应画质，遥控器全键盘操作", "竖版_04_高清播放.png"),
    ("04_设置.png", "扫码录入", "手机扫码填源地址，告别遥控器逐字输入", "竖版_05_扫码录入.png"),
]

if __name__ == "__main__":
    for s in SHOTS:
        make_portrait(*s)
    print("done,", len(SHOTS), "portrait screenshots")
