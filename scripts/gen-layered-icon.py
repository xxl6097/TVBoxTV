#!/usr/bin/env python3
# 生成华为应用市场「分层图标」资源：前景图 + 背景图，各 1024×1024。
#
# ── 为什么现有 icon_1024.png 不能直接用于上架 ─────────────────────────
# 现有图标是「单张 squircle」：白色圆角方形 + 四角透明 + 自带圆角。
# 华为分层图标规范明确禁止这种图：
#   ① 图标必须拆成「前景图 + 背景图」两层；
#   ② 每层 1024×1024、正方形、无需圆角（圆角由系统统一裁切）；
#   ③ 背景图不允许含透明像素（禁止手动圆角 / 透明内边距）；
#   ④ 前景图非核心区域 100% 透明，仅保留核心识别图形，内容留安全区。
# 所以必须把「深绿圆形底」与「白色/浅绿 logo 元素」拆开：
#   - 背景层 = 深绿径向渐变铺满整张方形（不透明、无圆角、无文字）
#   - 前景层 = 透明底 + logo（横条 / 播放三角 / 扬声器 / 声波 / HarmonyTV 文字）
#
# 用法：
#   python3 scripts/gen-layered-icon.py           生成
#   python3 scripts/gen-layered-icon.py --check   只体检现有文件

import os
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import median_filter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'docs', 'store', 'icon_source.png')
# 与 gen-icon.py 同一张源图（由 scripts/rebrand-icon.py 生成，文字已改为「夜帧影视」）

SIZE = 1024

# 上架物料（AGC 上传用，也同时是工程内分层图标的源图）
OUT_BG = os.path.join(ROOT, 'docs', 'store', 'icon_background.png')
OUT_FG = os.path.join(ROOT, 'docs', 'store', 'icon_foreground.png')
OUT_PREVIEW = os.path.join(ROOT, 'docs', 'store', 'icon_layered_preview.png')

# 工程内分层图标资源（AppScope 全局 icon）
MEDIA_DIR = os.path.join(ROOT, 'AppScope', 'resources', 'base', 'media')
MEDIA_BG = os.path.join(MEDIA_DIR, 'background.png')
MEDIA_FG = os.path.join(MEDIA_DIR, 'foreground.png')
MEDIA_JSON = os.path.join(MEDIA_DIR, 'layered_image.json')

# ── 前景提取参数 ─────────────────────────────────────────────────
# 源图圆基本居中（几何中心 (593,609)）。逐半径实测：以几何中心为圆心，
# 半径 420 处浅绿占比 0%（干净）、440 处 46%（圆环开始）、460 处 74%（圆环主体）。
# 故圆环内边缘约在 430~440，用 430 裁掉圆环、保留圆内 logo（logo 浅绿元素都在 420 内）。
RING_CUT = 430          # 圆形 mask 半径（源图像素），超过此值裁掉圆环
RING_SOFT = 3           # mask 软边缘宽度（抗锯齿）
LUM_LO = 130            # 亮度分离下界：深绿底(40~130) → 透明
LUM_HI = 175            # 亮度分离上界：>175 完全保留（白+浅绿）
SAT_WHITE = 100         # 白平衡校正：饱和度低于此值视为「白」，拉向纯白

# 源图圆盘半径（实测 484.5，取 485）与它在 1024 画布上的目标直径。
# 安全区是中心 66% 圆（半径 338）；圆盘直径取 640 → 半宽 320，
# 留 18px 余量，文字/图形端点不会被系统圆角裁切。
CONTENT_BOX = 566

# ── 背景渐变参数 ─────────────────────────────────────────────────
# 深绿底采样：中心 R≈24 G≈112 B≈78，边缘深墨绿 R≈14 G≈92 B≈62。
BG_CENTER = np.array([30.0, 118.0, 82.0], np.float32)   # 亮（中心偏上）
BG_EDGE = np.array([11.0, 82.0, 56.0], np.float32)      # 深墨绿（边缘）
BG_CENTER_OFFSET = (0.5, 0.45)   # 渐变中心略偏上，模拟原图左上亮泽


def load():
    return np.array(Image.open(SRC).convert('RGB')).astype(np.float32)


def find_center(a):
    """源图圆基本居中，直接取几何中心。

    注：原 gen-icon.py 用「饱和度边缘」迭代拟合圆心，但源图圆内有很多
    高饱和元素（浅绿声波、文字、圆环），会干扰边缘检测，把圆心测偏
    （实测偏到 (600,629)，cy 偏下 20px，导致底部圆环残留）。几何中心
    反而更准：以 (593,609) 为圆心，半径 420 干净、440 起圆环，规整。
    """
    h, w, _ = a.shape
    return w / 2.0, h / 2.0


def extract_foreground():
    """从源图提取前景：裁圆环 + 亮度分离 + 白色提纯 + 中值去噪。"""
    a = load()
    h, w, _ = a.shape
    cx, cy = find_center(a)
    r = a[:, :, 0]
    g = a[:, :, 1]
    b = a[:, :, 2]
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    sat = a.max(axis=2) - a.min(axis=2)

    yy, xx = np.mgrid[0:h, 0:w]
    rr = np.hypot(xx - cx, yy - cy)

    # 圆形 mask：裁掉圆环（圆环半径 440~475，取 432 保留圆内 logo）
    circ = np.clip((RING_CUT - rr) / RING_SOFT, 0.0, 1.0)

    # 亮度软阈值：深绿底 → 透明，白/浅绿 → 保留
    alpha = np.clip((lum - LUM_LO) / (LUM_HI - LUM_LO), 0.0, 1.0)
    alpha = alpha * circ

    # 中值滤波去孤立噪点（JPEG 噪点导致的散点）
    alpha = median_filter(alpha, size=3)

    # 白平衡校正：低饱和像素（白色元素）拉向纯白，保留浅绿渐变
    wb = np.clip(1.0 - sat / SAT_WHITE, 0.0, 1.0)          # 0=sat高, 1=纯白
    wb = wb[..., None]
    rgb = a * (1.0 - wb) + 255.0 * wb

    out = np.dstack([rgb, alpha * 255.0]).round().astype(np.uint8)
    img = Image.fromarray(out, 'RGBA')
    return img, cx, cy


def build_background():
    """深绿径向渐变铺满 1024×1024，完全不透明、无圆角。"""
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    ocx, ocy = BG_CENTER_OFFSET
    dx = (xx - ocx * (SIZE - 1)) / (SIZE - 1)
    dy = (yy - ocy * (SIZE - 1)) / (SIZE - 1)
    # 归一化到角落的距离（角落 = 1）
    t = np.hypot(dx, dy) / np.hypot(ocx, ocy)
    t = np.clip(t, 0.0, 1.0)
    t = t ** 1.3   # 轻微 gamma，让中心亮区更聚拢
    arr = (BG_CENTER[None, None, :] * (1.0 - t[..., None])
           + BG_EDGE[None, None, :] * t[..., None])
    arr = np.clip(arr, 0, 255).round().astype(np.uint8)
    # 不透明
    alpha = np.full((SIZE, SIZE, 1), 255, np.uint8)
    return Image.fromarray(np.dstack([arr, alpha]), 'RGBA')


def composite_preview(bg, fg):
    """合成预览：背景 + 前景 + 模拟系统圆角遮罩（squircle）。"""
    canvas = bg.copy().convert('RGBA')
    # 前景居中叠加
    canvas.alpha_composite(fg)
    # 叠加系统圆角遮罩（把圆角外的区域变透明，模拟桌面裁切）
    arr = np.array(canvas).astype(np.float32)
    N = 5
    c = (SIZE - 1) / 2.0
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    q = (np.abs((xx - c) / c) ** N + np.abs((yy - c) / c) ** N) ** (1.0 / N)
    mask = np.clip((1.02 - q) / 0.02, 0.0, 1.0)   # 软边缘
    arr[:, :, 3] = arr[:, :, 3] * mask
    return Image.fromarray(arr.round().astype(np.uint8), 'RGBA')


def place_foreground(fg_img):
    """把前景等比缩放到「最长边 = CONTENT_BOX」，居中放到 1024 透明画布。

    缩放口径为什么要按最长边而不是宽度：
      · 按宽度拉满时，内容一变宽（比如早先那条横向白圆条），高度就被压扁；
      · 按圆盘直径映射又会让内容随圆盘消失而缩得只有画布的三分之一。
      取最长边统一，内容无论怎么改，视觉尺寸都稳定在画布的 62.5%，
      同时最长边 640 → 半宽 320 < 安全区半径 338，不会被系统圆角裁到。
    """
    bbox = fg_img.getbbox()
    if bbox is None:
        raise SystemExit('✗ 前景提取为空，检查阈值')
    crop = fg_img.crop(bbox)
    w, h = crop.size
    scale = CONTENT_BOX / float(max(w, h))
    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    crop = crop.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    canvas.paste(crop, ((SIZE - nw) // 2, (SIZE - nh) // 2), crop)
    print('  内容 %dx%d → %dx%d（最长边 %d，占画布 %.0f%%）'
          % (w, h, nw, nh, CONTENT_BOX, CONTENT_BOX * 100.0 / SIZE))
    return canvas


def check(img, label, want_transparent):
    """体检：尺寸、透明像素占比。"""
    a = np.array(img).astype(np.float32)
    h, w, _ = a.shape
    al = a[:, :, 3]
    transparent = float((al < 255).sum())
    ratio = transparent / (h * w) * 100
    ok_size = (w == h == SIZE)
    print('  [%s] %dx%d  透明像素 %d (%.1f%%)'
          % (label, w, h, int(transparent), ratio))
    if want_transparent:
        ok = ok_size and transparent > 0
    else:
        ok = ok_size and transparent == 0
    print('    %s' % ('✓ 通过' if ok else '✗ 不达标'))
    return ok


def verify():
    ok = True
    for p, label, want in ((OUT_BG, '背景层', False), (OUT_FG, '前景层', True)):
        if not os.path.isfile(p):
            print('  ✗ 缺文件：%s' % os.path.relpath(p, ROOT))
            ok = False
            continue
        ok = check(Image.open(p).convert('RGBA'), label, want) and ok
    return 0 if ok else 1


def main():
    print('  生成华为分层图标（前景 + 背景，各 1024×1024）')
    print('  源图：%s' % os.path.basename(SRC))

    fg_raw, cx, cy = extract_foreground()
    print('  圆心 (%.1f, %.1f)，前景 bbox %s' % (cx, cy, fg_raw.getbbox()))

    fg = place_foreground(fg_raw)
    bg = build_background()

    fg.save(OUT_FG, 'PNG', optimize=True)
    bg.save(OUT_BG, 'PNG', optimize=True)
    preview = composite_preview(bg, fg)
    preview.save(OUT_PREVIEW, 'PNG', optimize=True)

    # 工程内资源（同一套图）
    fg.save(MEDIA_FG, 'PNG', optimize=True)
    bg.save(MEDIA_BG, 'PNG', optimize=True)

    ok1 = check(bg, '背景层', want_transparent=False)
    ok2 = check(fg, '前景层', want_transparent=True)
    ok3 = check(preview, '合成预览', want_transparent=True)

    print()
    for p in (OUT_BG, OUT_FG, OUT_PREVIEW, MEDIA_BG, MEDIA_FG):
        print('  ✓ %-52s %4d KB' % (os.path.relpath(p, ROOT), os.path.getsize(p) // 1024))
    ok = ok1 and ok2 and ok3
    print('  体检：%s' % ('通过' if ok else '有问题，见上'))
    return 0 if ok else 1


if __name__ == '__main__':
    if '--check' in sys.argv:
        raise SystemExit(verify())
    raise SystemExit(main())
