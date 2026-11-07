#!/usr/bin/env python3
# 生成应用图标：外层 squircle（正方形 + 弧形角），内层正圆，中间内容不做任何形变。
#
# ── 为什么上一版看起来「歪歪扭扭」───────────────────────────────
# 上一版把源图的**圆形**内容按角度逐个重映射到 squircle：每个角度的半径都被
# 拉到不同的比例（对角线方向要拉长 1.23 倍，边中点方向一点不拉）。结果
#   ① 中间的白色 logo 在四个对角方向被拉伸，形状随之改变；
#   ② 源图的圆本身就不太圆（各角度半径 467.5~491，相差 5%），
#      再叠加 squircle 的角度修正，边缘忽宽忽窄。
# 这是方法错了，不是参数没调好。
#
# ── 现在怎么做 ─────────────────────────────────────────────
# 分两层，各司其职，谁也不拉伸谁：
#   外层：squircle 画布，白色底（指数 5，等同 Apple 的 22.4% 圆角）
#   内层：源图的圆形本体，**等比例**缩放后居中放入，边缘重新生成成正圆
# 缩放是各向同性的（x、y 用同一个系数），所以 logo 不可能变形；
# 圆是真的圆（单一半径 + 8×8 超采样），不会忽胖忽瘦。
#
# 用法：
#   python3 scripts/gen-icon.py           生成
#   python3 scripts/gen-icon.py --check   只体检现有文件

import os
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import median_filter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'docs', 'store', 'icon_source.png')
# 源图由 scripts/rebrand-icon.py 从原始美术稿生成：擦掉原来的 "HarmonyTV"
# 字样、改写成「夜帧影视」，其余（圆盘渐变、圆角条、播放三角、喇叭）原样保留。
# 换名时先跑 rebrand-icon.py，再跑本脚本，图标才会跟着变。

OUT_STORE = os.path.join(ROOT, 'docs', 'store', 'icon_1024.png')
OUT_APP = [
    os.path.join(ROOT, 'AppScope/resources/base/media/app_icon.png'),
    os.path.join(ROOT, 'entry/src/main/resources/base/media/app_icon.png'),
]
OUT_PREVIEW = os.path.join(ROOT, 'docs', 'store', 'icon_preview.png')

SIZE = 1024           # 主图边长
APP = 512             # 工程内图标边长

# 外层 squircle 指数。n=5 的超椭圆在 45° 方向的边界点距中心 1.2311，
# Apple 图标（圆角 22.4%）在 45° 是 1.228 —— 差 0.25%，视觉上就是同一条曲线。
N_EXP = 5
SS = 8                # 边缘抗锯齿超采样倍数

# 图层颜色
PLATE = np.array([255.0, 255.0, 255.0], np.float32)   # 外层方形底：白
RING = np.array([118.0, 215.0, 154.0], np.float32)    # 内层圆的边：源图描边中位色 #76D79A

# 内层圆形直径 ÷ 外层方形边长。0.90 = 直边处留 5% 白边、
# 角上留 17% 白边，一眼能看出「方形里嵌了一个圆」，圆又不至于显小。
DISC_RATIO = 0.90

# 圆形边缘的统一带（占圆半径的比例）。源图那圈亮绿描边在不同方向的宽度
# 相差近 5%，不统一就会「一边粗一边细」；统一之后圆边是恒定的一圈亮绿。
BAND = 0.07
# 源图本体半径的取样位置：取各角度最小值的 99%，保证任何方向都不会把
# 外面的白底采样进来（白底一旦进来，圆边就会发白）。
R_SAFE = 0.99


def load():
    return np.array(Image.open(SRC).convert('RGB')).astype(np.float32)


def find_center(a):
    """迭代校正圆心：源图不是正圆，直接取 bbox 中心会有几像素偏差。"""
    h, w, _ = a.shape
    sat = a.max(axis=2) - a.min(axis=2)
    cx, cy = w / 2.0, h / 2.0
    for _ in range(8):
        def edge(sign, axis):
            step = np.arange(200, 700, 0.5)
            if axis == 'x':
                xs = np.clip((cx + sign * step).round().astype(int), 0, w - 1)
                ys = np.full(xs.shape, int(round(cy)), dtype=np.int32)
            else:
                xs = np.full(step.shape, int(round(cx)), dtype=np.int32)
                ys = np.clip((cy + sign * step).round().astype(int), 0, h - 1)
            v = sat[ys, xs]
            idx = np.where(v > 60)[0]
            return step[idx[-1]] if len(idx) else 0.0
        l, r = edge(-1, 'x'), edge(1, 'x')
        t, b = edge(-1, 'y'), edge(1, 'y')
        ncx, ncy = cx + (r - l) / 2.0, cy + (b - t) / 2.0
        done = abs(ncx - cx) < 0.05 and abs(ncy - cy) < 0.05
        cx, cy = ncx, ncy
        if done:
            break
    return cx, cy


def radius_table(a, cx, cy, n=720):
    """逐角度测本体半径（含亮绿描边、不含白底），中值滤波去噪。"""
    h, w, _ = a.shape
    sat = a.max(axis=2) - a.min(axis=2)
    R = np.zeros(n, np.float32)
    for i in range(n):
        t = 2 * np.pi * i / n
        rs = np.arange(300, 660, 0.5)
        xs = np.clip((cx + rs * np.cos(t)).round().astype(int), 0, w - 1)
        ys = np.clip((cy + rs * np.sin(t)).round().astype(int), 0, h - 1)
        v = sat[ys, xs]
        idx = np.where(v > 60)[0]
        R[i] = rs[idx[-1]] if len(idx) else np.nan
    if np.isnan(R).any():
        R = np.where(np.isnan(R), np.nanmean(R), R)
    return median_filter(R, size=9, mode='wrap')


def squircle_q(size):
    """squircle 度量：边界处 q=1。"""
    c = (size - 1) / 2.0
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    u = (xx - c) / c
    v = (yy - c) / c
    return (np.abs(u) ** N_EXP + np.abs(v) ** N_EXP) ** (1.0 / N_EXP)


def r_screen(size):
    """到中心的距离除以半边长（0=圆心，1=贴边）。"""
    c = (size - 1) / 2.0
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    return np.hypot(xx - c, yy - c) / c


def aa_alpha(mask_fn, size):
    """超采样生成平滑 alpha：mask_fn 收到「半像素偏移后的坐标」，返回布尔掩码。"""
    c = (size - 1) / 2.0
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    acc = np.zeros((size, size), np.float32)
    for dy in range(SS):
        for dx in range(SS):
            ox = (dx + 0.5) / SS - 0.5
            oy = (dy + 0.5) / SS - 0.5
            acc += mask_fn(xx + ox, yy + oy, c)
    return acc / (SS * SS)


def squircle_alpha(size):
    return aa_alpha(lambda x, y, c: (
        (np.abs((x - c) / c) ** N_EXP + np.abs((y - c) / c) ** N_EXP) ** (1.0 / N_EXP)) <= 1.0, size)


def circle_alpha(size, ratio):
    """ratio = 圆半径 / 半边长。"""
    return aa_alpha(lambda x, y, c: np.hypot(x - c, y - c) <= ratio * c, size)


def build_disc(a, cx, cy, R_src, out_size):
    """把源图的圆**等比例**取出来，放进 out_size 见方的图里（圆之外透明）。

    等比例是这里最关键的一点：x、y 用同一个缩放系数，圆心对齐输出图中心，
    所以 logo 只可能整体变大变小，不可能被拉扁或拉长。
    """
    half = int(np.ceil(R_src)) + 2
    box = (int(round(cx)) - half, int(round(cy)) - half,
           int(round(cx)) + half, int(round(cy)) + half)
    crop = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).crop(box)
    # 裁剪框是正方形（2*half 见方），缩放到目标尺寸同样是各向同性
    disc_rgb = np.array(crop.resize((out_size, out_size), Image.LANCZOS)).astype(np.float32)
    alpha = circle_alpha(out_size, 1.0)          # 裁到正圆
    return disc_rgb, alpha


def unify_ring(rgb, size):
    """把圆的最外一圈收拢成同一圈亮绿。

    源图的亮绿描边宽度在各方向相差近 5%，叠加 JPEG 噪声后，圆边会「忽粗忽细、
    深浅不匀」。按半径做 smoothstep：r/R >= 1 处完全是 RING，r/R <= 1-BAND 处
    保留原色，中间平滑过渡 —— 于是圆边是恒定的一圈色，且与内部无缝。
    """
    rr = r_screen(size)
    t = np.clip((rr - (1.0 - BAND)) / (BAND * 0.6), 0.0, 1.0)
    t = t * t * (3.0 - 2.0 * t)
    w = t[..., None]
    return rgb * (1.0 - w) + RING * w


def compose(size):
    a = load()
    cx, cy = find_center(a)
    R = radius_table(a, cx, cy)
    R_src = float(R.min()) * R_SAFE
    print('  源图圆心 (%.1f, %.1f)   本体半径 %.1f~%.1f   取样半径 %.1f'
          % (cx, cy, R.min(), R.max(), R_src))

    disc_px = int(round(size * DISC_RATIO))
    print('  内层圆：直径 %dpx（占外层 %.0f%%），外层方形 %dpx，直边白边 %dpx'
          % (disc_px, DISC_RATIO * 100, size, (size - disc_px) // 2))

    disc_rgb, disc_a = build_disc(a, cx, cy, R_src, disc_px)
    disc_rgb = unify_ring(disc_rgb, disc_px)

    # 画布：白色方形底
    canvas = np.ones((size, size, 3), np.float32) * PLATE
    # 圆形贴到正中
    off = (size - disc_px) // 2
    da = disc_a[..., None]
    canvas[off:off + disc_px, off:off + disc_px] = (
        disc_rgb * da + canvas[off:off + disc_px, off:off + disc_px] * (1.0 - da))

    alpha = squircle_alpha(size)
    arr = np.dstack([np.clip(canvas, 0, 255), alpha * 255.0]).round().astype(np.uint8)
    return Image.fromarray(arr, 'RGBA')


def resize_premultiplied(img, size):
    """带 alpha 缩放必须预乘：否则半透明像素的颜色会被背景拉偏，边缘发灰。"""
    a = np.array(img).astype(np.float32)
    al = a[:, :, 3:4] / 255.0
    pm = np.dstack([a[:, :, :3] * al, a[:, :, 3:4]]).round().astype(np.uint8)
    small = np.array(Image.fromarray(pm, 'RGBA').resize((size, size), Image.LANCZOS)).astype(np.float32)
    a2 = np.clip(small[:, :, 3:4], 0, 255)
    rgb = np.where(a2 > 0, small[:, :, :3] / np.maximum(a2 / 255.0, 1e-6), 0)
    out = np.dstack([np.clip(rgb, 0, 255), a2]).round().astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


def logo_aspect(a, cx, cy, rad, alpha=None):
    """白色 logo 的宽高比。用它判断内容有没有被拉扁/拉长：等比例缩放不改变宽高比。"""
    rgb = a[:, :, :3]
    lum = 0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]
    sat = rgb.max(axis=2) - rgb.min(axis=2)
    yy, xx = np.mgrid[0:a.shape[0], 0:a.shape[1]]
    m = (lum > 218) & (sat < 38) & (np.hypot(xx - cx, yy - cy) < rad * 0.82)
    if alpha is not None:
        m &= alpha > 200
    ys, xs = np.where(m)
    # 用分位数而不是 min/max：边上偶尔有一两个杂散像素，会把极值拉偏
    x0, x1 = np.percentile(xs, 0.3), np.percentile(xs, 99.7)
    y0, y1 = np.percentile(ys, 0.3), np.percentile(ys, 99.7)
    return (x1 - x0) / (y1 - y0)


def check_distortion():
    """内容形变自检：源图与输出的 logo 宽高比必须一致（差 < 1.5%）。"""
    src = np.array(Image.open(SRC).convert('RGB')).astype(np.float32)
    out = np.array(Image.open(OUT_STORE).convert('RGBA')).astype(np.float32)
    cx, cy = find_center(src)
    # 半径必须和 build_disc 用的一致：半径不同会让「圆内 82%」的取样范围跟着变，
    # 边缘处多算/少算一圈抗锯齿像素，宽高比就会假性偏移好几个百分点。
    r_src = float(radius_table(src, cx, cy).min()) * R_SAFE
    a_src = logo_aspect(src, cx, cy, r_src)
    a_out = logo_aspect(out, (SIZE - 1) / 2, (SIZE - 1) / 2, SIZE * DISC_RATIO / 2, out[:, :, 3])
    dev = abs(a_out - a_src) / a_src * 100
    print('  内容形变检查：logo 宽高比 源图 %.4f / 输出 %.4f，差 %.2f%%  %s'
          % (a_src, a_out, dev, '✓ 无形变' if dev < 1.5 else '✗ 被拉伸'))
    return dev < 1.5


def check(img, label, want):
    """图标体检：形状、圆度、圆边颜色、角部底色。"""
    a = np.array(img).astype(np.float32)
    h, w, _ = a.shape
    rgb, al = a[:, :, :3], a[:, :, 3]
    lum = 0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]
    sat = rgb.max(axis=2) - rgb.min(axis=2)
    corners = [al[2, 2], al[2, -3], al[-3, 2], al[-3, -3]]
    print('  [%s] %dx%d' % (label, w, h))

    ok_size = (w == h == want)
    ok_corner = max(float(v) for v in corners) == 0
    print('    尺寸 / 四角透明 : %s / %s' % ('✓' if ok_size else '✗',
                                            '✓ 全透明' if ok_corner else '✗ 有残留'))

    # 圆度：沿 72 个方向找内圆最外沿的半径，看离散度
    c = (h - 1) / 2.0
    rs = []
    for i in range(72):
        t = 2 * np.pi * i / 72
        last = None
        for r in np.arange(DISC_RATIO * 0.80, DISC_RATIO * 1.02, 0.5):
            x = int(round(c + r * c * np.cos(t)))
            y = int(round(c + r * c * np.sin(t)))
            if 0 <= x < h and 0 <= y < h and sat[y, x] > 60 and al[y, x] > 200:
                last = r
        if last:
            rs.append(last)
    rs = np.array(rs)
    circle_dev = (rs.max() - rs.min()) / rs.mean() * 100 if len(rs) > 8 else 99
    print('    内圆半径离散度   : %.2f%%  %s' % (circle_dev,
          '✓ 是正圆' if circle_dev < 1.5 else '✗ 明显不圆'))

    # 圆边颜色均匀度
    rr = r_screen(h)
    edge = (rr > DISC_RATIO * 0.975) & (rr < DISC_RATIO * 0.995) & (al > 250)
    edge_lum, edge_sat = lum[edge], sat[edge]
    ok_edge = edge_lum.std() < 5 and edge_sat.mean() > 60
    print('    圆边颜色         : 亮度 %.0f±%.1f 饱和 %.0f  %s' % (
        edge_lum.mean(), edge_lum.std(), edge_sat.mean(),
        '✓ 一圈同色' if ok_edge else '✗ 深浅不匀'))

    # 角部：squircle 内、圆外，应当是白底
    q = squircle_q(h)
    zone = (q > 0.55) & (q < 0.95) & (rr > DISC_RATIO * 1.06) & (al > 250)
    if zone.sum() > 200:
        cz = lum[zone]
        ok_plate = cz.mean() > 245 and cz.std() < 4
        print('    角部底色         : 亮度 %.0f±%.1f  %s' % (cz.mean(), cz.std(),
              '✓ 白色' if ok_plate else '✗ 不纯'))
    else:
        ok_plate = False
        print('    角部底色         : 取样不足 ✗')

    return ok_size and ok_corner and circle_dev < 1.5 and ok_edge and ok_plate


def preview(icon):
    """预览：深底 / 浅底各三种尺寸，右侧是外框圆角与内圆边的放大。"""
    W, H = 1560, 640
    canvas = np.zeros((H, W, 3), np.float32)
    canvas[:H // 2] = (22, 22, 25)
    canvas[H // 2:] = (242, 242, 245)

    def paste(size, cx, cy):
        arr = np.array(resize_premultiplied(icon, size)).astype(np.float32)
        al = arr[:, :, 3:4] / 255.0
        x0, y0 = int(cx - size / 2), int(cy - size / 2)
        reg = canvas[y0:y0 + size, x0:x0 + size]
        canvas[y0:y0 + size, x0:x0 + size] = arr[:, :, :3] * al + reg * (1 - al)

    for cy in (160, H - 160):
        paste(300, 190, cy)
        paste(120, 420, cy)
        paste(48, 550, cy)

    # 两处放大：外层圆角、内圆边缘
    half = SIZE / 2
    zooms = [
        # (左, 上, 宽, 高, 输出边长, 背景)
        (SIZE - 130, 0, 130, 130, 300, (22, 22, 25)),
        (0, int(half - 60), 130, 130, 300, (242, 242, 245)),
    ]
    for i, (x0, y0, cw, ch, out, bg) in enumerate(zooms):
        crop = icon.crop((x0, y0, x0 + cw, y0 + ch)).resize((out, out), Image.NEAREST)
        ba = np.array(crop).astype(np.float32)
        bal = ba[:, :, 3:4] / 255.0
        b = np.array(bg, np.float32)
        px, py = 780 + i * 380, 5 if i == 0 else H // 2 + 5
        canvas[py:py + out, px:px + out] = ba[:, :, :3] * bal + b * (1 - bal)

    Image.fromarray(np.clip(canvas, 0, 255).astype(np.uint8)).save(OUT_PREVIEW, 'PNG')
    print('  预览：%s（左=深/浅底下的 300·120·48px，右=外角与内圆边放大）'
          % os.path.relpath(OUT_PREVIEW, ROOT))


def main():
    big = compose(SIZE)
    small = resize_premultiplied(big, APP)
    big.save(OUT_STORE, 'PNG', optimize=True)
    for p in OUT_APP:
        small.save(p, 'PNG', optimize=True)

    ok1 = check(big, '主图 1024', SIZE)
    ok2 = check(small, '工程 512', APP)
    ok3 = check_distortion()
    preview(big)

    print()
    for p in [OUT_STORE] + OUT_APP:
        print('  ✓ %-56s %4d KB' % (os.path.relpath(p, ROOT), os.path.getsize(p) // 1024))
    ok = ok1 and ok2 and ok3
    print('  体检：%s' % ('通过' if ok else '有问题，见上'))
    return 0 if ok else 1


def verify():
    print('  图标规范检查')
    ok = True
    for path, label, want in ((OUT_STORE, '主图 1024', SIZE),
                              (OUT_APP[0], 'AppScope 512', APP),
                              (OUT_APP[1], 'entry 512', APP)):
        if not os.path.isfile(path):
            print('  ✗ 缺文件：%s' % os.path.relpath(path, ROOT))
            ok = False
            continue
        ok = check(Image.open(path).convert('RGBA'), label, want) and ok
    return 0 if ok else 1


if __name__ == '__main__':
    if '--check' in sys.argv:
        raise SystemExit(verify())
    raise SystemExit(main())
