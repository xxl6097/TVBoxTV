#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把图标源图里的 "HarmonyTV" 换成「夜帧影视」，产出新源图 docs/store/icon_source.png。

为什么要“擦除 + 重绘”而不是重画整张图：
  源图是用户提供的美术稿（白底 + 绿色圆盘 + 顶部圆角条 + 播放三角 + 喇叭 +
  一行浅绿色品牌字），除这行字之外的部分都要原样保留。所以只处理文字带：
    1. 文字带（y 698~874，x 190~1008）整段用「上一行 / 下一行按列线性插值」擦掉，
       圆盘在该区间是竖直渐变，插值出来的底色与周围无缝；
  文字带上下都验证过没有其它元素：喇叭的两道绿色弧线止于 y=687，圆盘边缘在
  y=874 处已到 x≈179 / 1018 之外，所以这个矩形内部全是圆盘底色。

  2. 用 STHeiti Medium 画「夜帧影视」，颜色取自原文字的中位色，带一层暗绿投影，
     4× 超采样后缩放，保证边缘不毛糙。

用法：
  python3 scripts/rebrand-icon.py          # 生成 docs/store/icon_source.png
  python3 scripts/rebrand-icon.py --preview  # 只出预览图，不写源图
"""

import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join('/Users/uuxia/.workbuddy/clipboard-images',
                   'clipboard-2026-11-03T01-24-23-881Z-302c3f19.jpg')
OUT = os.path.join(ROOT, 'docs', 'store', 'icon_source.png')

TEXT = '夜帧影视'

# 文字带（实测：原文字 bbox x 239~974、y 714~849；喇叭绿弧止于 y=687）
BAND_TOP, BAND_BOT = 698, 874        # 要擦除的行区间（含端点外沿）
BAND_X0, BAND_X1 = 190, 1008         # 要擦除的列区间

# 新字：视觉高度 ≈ 原文字的大写高（101px）略大一点，2 个字撑住版面
TARGET_H = 112
FILL = (184, 239, 201)               # 原文字中位色 #B8EFC9
SHADOW = (10, 74, 50)                # 原文字下方的暗绿投影
SS = 4                               # 超采样倍数

FONT = '/System/Library/Fonts/STHeiti Medium.ttc'


def erase_band(a, cx, cy, R):
    """把圆盘上原有的文字抹掉（OpenCV TELEA 修补）。

    试过两种自制方案都不行：
      · 整条矩形按列上下插值 —— 盘面是径向明暗，线性渐变对不上，留下可见方框；
      · 二次曲面拟合 + 噪声回填 —— 噪声量级控不住，整条带变成毛玻璃。
    TELEA 修补是沿等照度线从掩膜外向内推进，天然会延续盘面的渐变方向，不会有
    方框边或颗粒感，这里只要把掩膜圈准即可。

    掩膜 = 浅绿文字像素（连同其下方暗投影），再膨胀 7px 把抗锯齿边一起圈进去。
    """
    import cv2
    from scipy import ndimage as ndi

    h, w, _ = a.shape
    g, r, b = a[:, :, 1], a[:, :, 0], a[:, :, 2]
    yy, xx = np.mgrid[0:h, 0:w]
    rr = np.hypot(xx - cx, yy - cy) / R
    band = (yy >= BAND_TOP) & (yy <= BAND_BOT) & (xx >= BAND_X0) & (xx <= BAND_X1)
    # 必须严格限制在盘内：盘边那圈亮绿(#7FD99A)与文字同色系，不挡住就会把
    # 掩膜扩到圆外，修补后在左右各鼓起一个包（像长了两只耳朵）。
    # 文字左右端点 r 最大约 0.82，取 0.88 既圈得住字，又离盘边有余量。
    inside = rr < 0.88
    band = band & inside

    mint = (g > 172) & (g > r + 12) & (g > b + 12) & band
    # 文字下方的暗投影：同一行内比左右邻居暗一截的像素
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    base = ndi.median_filter(lum, size=(1, 61))
    shadow = band & (lum < base - 5)

    mask = ndi.binary_dilation(mint | shadow, np.ones((13, 13))) & inside
    mask = ndi.binary_closing(mask, np.ones((7, 7)))

    mask8 = (mask * 255).astype(np.uint8)
    bgr = cv2.cvtColor(a, cv2.COLOR_RGB2BGR)
    filled = cv2.inpaint(bgr, mask8, 9, cv2.INPAINT_TELEA)
    out = cv2.cvtColor(filled, cv2.COLOR_BGR2RGB)

    # TELEA 是从掩膜边界向内推的，上下边界亮度不同时会留下横向条纹。
    # 掩膜内本来就是一片光滑的盘面底色，所以再叠一层大半径模糊把低频压平，
    # 边缘用羽化的掩膜过渡，条纹就没了。
    soft = ndi.gaussian_filter(mask.astype(np.float32), 3.0)[..., None]
    flat = cv2.GaussianBlur(out, (0, 0), 14)
    out = np.clip(out.astype(np.float32) * (1 - soft) + flat.astype(np.float32) * soft,
                  0, 255).astype(np.uint8)

    print('  擦除：掩膜像素 %d（占文字带 %.1f%%）'
          % (int(mask.sum()), 100.0 * mask.sum() / max(band.sum(), 1)))
    return out


def render_text(cx, cy, height):
    """在透明画布上超采样绘制文字，返回 (RGB, alpha) 图层与尺寸。"""
    # 先用大字号量出真实 bbox，再按目标视觉高度定字号
    probe = ImageFont.truetype(FONT, 200)
    box = probe.getbbox(TEXT)
    h0 = box[3] - box[1]
    size = int(round(200 * height / float(h0)))
    font = ImageFont.truetype(FONT, size)
    box = font.getbbox(TEXT)
    w = box[2] - box[0] + 24 * SS
    h = box[3] - box[1] + 24 * SS
    big = Image.new('RGBA', (w * SS, h * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    d.text((w * SS / 2 - (box[0] + box[2]) / 2 * SS, h * SS / 2 - (box[1] + box[3]) / 2 * SS),
           TEXT, font=ImageFont.truetype(FONT, size * SS), fill=FILL + (255,))
    small = big.resize((w, h), Image.LANCZOS)
    return small


def compose():
    src = np.array(Image.open(SRC).convert('RGB'))
    h, w, _ = src.shape
    print('  源图 %dx%d' % (w, h))
    # 圆心沿用 gen-icon 测得的值
    cx, cy_disc, R = 598.5, 630.5, 484.5
    base = erase_band(src, cx, cy_disc, R)

    cy_text = 765            # 原文字光学中线
    layer = render_text(cx, cy_text, TARGET_H)
    lw, lh = layer.size
    x0 = int(round(cx - lw / 2))
    y0 = int(round(cy_text - lh / 2))

    img = Image.fromarray(base).convert('RGBA')

    # 投影：文字 alpha 偏移后模糊，压在字下面
    al = layer.split()[3]
    shadow = Image.new('RGBA', layer.size, SHADOW + (0,))
    shadow.putalpha(al.filter(ImageFilter.GaussianBlur(3)))
    img.alpha_composite(shadow, (x0 + 1, y0 + 5))
    img.alpha_composite(layer, (x0, y0))

    print('  文字「%s」 视觉高 %dpx  落位 x=%d y=%d  宽 %d'
          % (TEXT, TARGET_H, x0, y0, lw))
    return img.convert('RGB')


def main():
    img = compose()
    if '--preview' in sys.argv:
        img.resize((594, 609), Image.LANCZOS).save('/tmp/icon_source_preview.png')
        print('  预览：/tmp/icon_source_preview.png')
        return 0
    img.save(OUT, 'PNG', optimize=True)
    print('  ✓ %s  (%d KB)' % (os.path.relpath(OUT, ROOT), os.path.getsize(OUT) // 1024))
    img.resize((594, 609), Image.LANCZOS).save('/tmp/icon_source_preview.png')
    print('  预览：/tmp/icon_source_preview.png')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
