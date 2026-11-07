#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
重绘图标主图形：把原来「空白色圆角条 + 一个偏大的播放三角 + 一个偏小的喇叭」
换成一套尺寸、基线、风格统一的媒体标记（播放三角 + 三道同心声波）+ 下方文字。

为什么原来的不行（实测数据，源图 1186×1218）：
  · 白色圆角条 527×145、中心 x=590，里面**没有任何内容**，纯占位；
  · 播放三角 133×144，喇叭只有 73×68 —— 两者体量差 2.1 倍；
  · 三角中心 y=616、喇叭中心 y=627，垂直差 11px；
  · 三角+喇叭作为一组，中心 x≈696，比圆条中心偏右 105px —— 肉眼就是「歪」。
  · 另外三角是实心几何形，喇叭是圆角团块 + 细弧线，两种视觉语言混在一起。

重绘规则（图标设计常用的一套）：
  1. 只保留一个视觉主体：三角 + 声波合成一个 lockup，去掉空圆条；
  2. 统一光学校正：三角是实心、声波是描边，所以描边要比几何等宽略粗
     （22→24），视觉重量才持平；
  3. 三角高度 : 声波最大半径 : 文字高 ≈ 230 : 195 : 110，按 1:0.85:0.48 收敛；
  4. 三角与声波用同一个光学中心（三角的垂直中线 = 声波圆心）；
  5. 整体 bbox 以圆盘几何中心为基准居中，不再让某一侧偏出；
  6. 全部 4× 超采样后再降采样，边缘不毛糙。

用法：
  python3 scripts/redesign-emblem.py            # 生成 docs/store/icon_source.png
  python3 scripts/redesign-emblem.py --preview  # 只出预览，不覆盖源图
"""

import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from scipy import ndimage as ndi

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'docs', 'store', 'icon_source.png')
LEGACY = os.path.join(ROOT, 'docs', 'store', 'icon_source_legacy.png')

CX, CY, R = 598.5, 630.5, 484.5          # 圆盘几何中心与半径（早前实测）
WHITE = (255, 255, 255)
MINT = (184, 239, 201)                   # 文字原色 #B8EFC9
SHADOW = (18, 92, 66)                    # 圆盘暗部绿，用作极轻的投影
SS = 4                                   # 超采样倍数
FONT = '/System/Library/Fonts/STHeiti Medium.ttc'
WORD = '夜帧影视'


# ---------------------------------------------------------------- 擦除旧元素
def erase_old(a):
    """抹掉旧圆条 / 三角 / 喇叭 / 文字，只留干净的绿色圆盘。"""
    h, w, _ = a.shape
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    sat = a.max(axis=2) - a.min(axis=2)
    yy, xx = np.mgrid[0:h, 0:w]
    rr = np.hypot(xx - CX, yy - CY) / R

    inside = rr < 0.90
    white = (lum > 185) & (sat < 44) & inside          # 圆条 + 三角 + 喇叭
    mint = (g > 165) & (g > r + 12) & (g > b + 12) & inside & (yy > 530)  # 文字 + 喇叭弧线
    base_mask = ndi.binary_dilation(white | mint, np.ones((19, 19))) & inside

    # 旧圆条下方那圈深色立体边，颜色接近盘面、不会被白色阈值抓到，
    # 单靠上面两类会留一条淡淡的横线。这里补一遍「明显暗于邻域」的检测。
    base_lum = ndi.median_filter(lum, size=41)
    darker = (lum < base_lum - 7) & (rr < 0.86)
    mask = ndi.binary_closing(base_mask | darker, np.ones((11, 11)))

    m8 = (mask * 255).astype(np.uint8)
    filled = cv2.inpaint(cv2.cvtColor(a, cv2.COLOR_RGB2BGR), m8, 9, cv2.INPAINT_TELEA)
    out = cv2.cvtColor(filled, cv2.COLOR_BGR2RGB)

    soft = ndi.gaussian_filter(mask.astype(np.float32), 3.0)[..., None]
    flat = cv2.GaussianBlur(out, (0, 0), 16)
    out = np.clip(out.astype(np.float32) * (1 - soft) + flat.astype(np.float32) * soft, 0, 255)
    print('  擦除：掩膜 %d 像素' % int(mask.sum()))
    return out.astype(np.uint8)


# ---------------------------------------------------------------- 画新图形
def rounded_polygon(draw, pts, radius, fill):
    """圆角多边形：先描粗边（joint=curve 自动圆角）再填内部。"""
    draw.line(list(pts) + [pts[0]], fill=fill, width=int(round(radius * 2)), joint='curve')
    draw.polygon(pts, fill=fill)


def draw_mark(size_px, tri_h):
    """在透明画布上画「播放三角 + 三道声波」，返回 RGBA（已按内容裁紧）。

    声波不用 PIL 的 arc（它不支持圆头，手工补圆点会变成「串珠」），
    改成按极坐标直接算环形扇区：
        |r - ri| <= w/2  且  |θ| <= 40°  → 弧身
        到两端点的距离 <= w/2          → 圆头
    这样描边宽度处处一致，端点也是干净的半圆。
    """
    W = int(size_px)
    tri_w = tri_h * 0.866                  # 等边三角指向右
    stroke = tri_h * 0.100                 # 描边略粗于几何等宽，抵消实心三角的视觉重量
    radii = [tri_h * 0.42, tri_h * 0.60, tri_h * 0.78]
    gap = tri_h * 0.17                     # 三角右顶点与最小声波之间留出呼吸，不然贴成一坨
    sweep = np.deg2rad(40)

    img = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    cy = W / 2.0
    pts = [(0.0, cy - tri_h / 2), (tri_w, cy), (0.0, cy + tri_h / 2)]
    rounded_polygon(d, pts, tri_h * 0.07, WHITE + (255,))

    arc_cx = tri_w + gap
    yy, xx = np.mgrid[0:W, 0:W]
    dx = xx - arc_cx
    dy = yy - cy
    rad = np.hypot(dx, dy)
    ang = np.arctan2(dy, dx)

    cover = np.zeros((W, W), bool)
    for ri in radii:
        ring = (np.abs(rad - ri) <= stroke / 2.0) & (np.abs(ang) <= sweep)
        for sgn in (-1, 1):
            ex = arc_cx + ri * np.cos(sgn * sweep)
            ey = cy + ri * np.sin(sgn * sweep)
            ring |= np.hypot(xx - ex, yy - ey) <= stroke / 2.0
        cover |= ring

    layer = np.zeros((W, W, 4), np.uint8)
    layer[cover] = (255, 255, 255, 255)
    img = Image.alpha_composite(img, Image.fromarray(layer, 'RGBA'))

    bbox = img.getbbox()
    return img.crop(bbox)


def draw_word(height):
    """画中文名，4× 超采样后按视觉高度缩回。"""
    probe = ImageFont.truetype(FONT, 200)
    bb = probe.getbbox(WORD)
    size = int(round(200 * height / (bb[3] - bb[1])))
    f = ImageFont.truetype(FONT, size)
    bb = f.getbbox(WORD)
    pad = 30
    w = bb[2] - bb[0] + pad * 2
    h = bb[3] - bb[1] + pad * 2
    big = Image.new('RGBA', (w * SS, h * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    d.text((w * SS / 2 - (bb[0] + bb[2]) / 2 * SS, h * SS / 2 - (bb[1] + bb[3]) / 2 * SS),
           WORD, font=ImageFont.truetype(FONT, size * SS), fill=MINT + (255,))
    small = big.resize((w, h), Image.LANCZOS)
    return small


def compose(base):
    """把新图形合成到干净圆盘上，整体以圆盘中心居中。"""
    h, w, _ = base.shape
    tri_h = 216.0
    word_h = 96.0          # 字宽控制在图形宽度附近，避免「下重」
    gap = 88.0

    mark = draw_mark(900, tri_h)
    word = draw_word(word_h)

    total_h = mark.size[1] + gap + word.size[1]
    top = CY - total_h / 2.0

    img = Image.fromarray(base).convert('RGBA')

    def paste(layer, cy_center):
        # 光学居中：实心三角偏重左半，整体右移 1.2% 看起来才是正的
        x = int(round(CX + 5 - layer.size[0] / 2.0))
        y = int(round(cy_center - layer.size[1] / 2.0))
        # 极轻投影：只压一点点暗，避免图形"浮"在盘面上
        sh = Image.new('RGBA', layer.size, SHADOW + (0,))
        sh.putalpha(layer.split()[3].filter(ImageFilter.GaussianBlur(5)))
        img.alpha_composite(sh, (x + 2, y + 6))
        img.alpha_composite(layer, (x, y))
        return x, y

    mx, my = paste(mark, top + mark.size[1] / 2.0)
    wx, wy = paste(word, top + mark.size[1] + gap + word.size[1] / 2.0)

    print('  图形 %dx%d @ (%d,%d)   文字 %dx%d @ (%d,%d)'
          % (mark.size[0], mark.size[1], mx, my, word.size[0], word.size[1], wx, wy))
    print('  组中心 x=%.0f（圆盘中心 %.0f）  纵向 %d~%d'
          % ((wx + word.size[0] / 2 + CX - CX), CX, top, top + total_h))

    # 自查：新内容 bbox 相对圆盘中心的左右偏差
    arr = np.array(img)[:, :, 3]
    ys, xs = np.where(arr > 8)
    print('  内容 bbox x[%d,%d] 中心 %.1f，相对圆盘偏 %.1f px'
          % (xs.min(), xs.max(), (xs.min() + xs.max()) / 2.0,
             (xs.min() + xs.max()) / 2.0 - CX))
    return img.convert('RGB')


def main():
    a = np.array(Image.open(SRC).convert('RGB'))
    if not os.path.exists(LEGACY):
        Image.fromarray(a).save(LEGACY)
        print('  旧源图已备份：%s' % os.path.relpath(LEGACY, ROOT))
    clean = erase_old(a)
    out = compose(clean)
    out.resize((594, 609), Image.LANCZOS).save('/tmp/emblem_new_preview.png')
    if '--preview' in sys.argv:
        print('  预览：/tmp/emblem_new_preview.png')
        return 0
    out.save(SRC, 'PNG', optimize=True)
    print('  ✓ %s (%d KB)' % (os.path.relpath(SRC, ROOT), os.path.getsize(SRC) // 1024))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
