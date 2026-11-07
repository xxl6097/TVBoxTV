#!/usr/bin/env python3
# 生成「夜帧影视」新图标（变体C：极简弯月 + 星光）的全套 PNG。
#
# 为什么新起一个脚本：旧 gen-icon.py / gen-layered-icon.py 都依赖位图源图
# icon_source.png（擦字、抠圆环、重采样），而新图标是纯矢量（弯月=两圆相减、
# 星=多边形），直接画更干净，不需要那张源图。
#
# 产物：
#   docs/store/icon_1024.png           1024 单张 squircle（上架主图）
#   docs/store/icon_background.png     1024 分层背景（夜空渐变，不透明无圆角）
#   docs/store/icon_foreground.png     1024 分层前景（透明底 + 弯月 + 星）
#   AppScope|entry/.../app_icon.png    512 合成 squircle（桌面兜底图标）
#   AppScope|entry/.../background.png  1024 分层背景
#   AppScope|entry/.../foreground.png  1024 分层前景
#
# 渲染用 rsvg-convert（librsvg），抗锯齿质量高于手写超采样。
# 用法：python3 scripts/gen-moon-icon.py

import math
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIZE = 1024
C = SIZE / 2.0  # 512
RSVG = '/opt/homebrew/bin/rsvg-convert'

# ── 配色（贴合「夜帧」：夜空 + 月光） ──────────────────────────
SKY_C = '#182144'   # 夜空渐变中心（略亮，模拟月光从上方洒下）
SKY_E = '#0B0F22'   # 夜空渐变边缘（深）
MOON = '#F6C96E'    # 月亮金
STAR = '#FFF3D6'    # 星暖白
DOT = '#F6C96E'     # 小金点

# ── 几何（1024 网格，内容控制在系统安全区 66% 圆 = 半径 338 内） ──
MOON_CX, MOON_CY, MOON_R = 512, 520, 235   # 满月（居中略沉）
CUT_CX, CUT_CY, CUT_R = 597, 462, 235      # 挖掉圆（向右上偏移 85,-58 → 月牙开口朝右上）
# 四尖 sparkle 星（8 顶点，中心 712,305，外径 44，内径 18）
SPARKLE = [(712, 261), (725, 292), (756, 305), (725, 318),
           (712, 349), (699, 318), (668, 305), (699, 292)]
DOTS = [(375, 685, 12, DOT), (655, 710, 10, DOT), (320, 345, 8, STAR)]


def squircle_path(n=5, steps=720):
    """n 次超椭圆（Apple 风格 squircle），中心 C、半径 C。"""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = C + C * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = C + C * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append('%.2f,%.2f' % (x, y))
    return 'M ' + ' L '.join(pts) + ' Z'


def grad_def():
    return ('<radialGradient id="sky" cx="50%" cy="44%" r="80%">'
            f'<stop offset="0%" stop-color="{SKY_C}"/>'
            f'<stop offset="100%" stop-color="{SKY_E}"/></radialGradient>')


def moon_svg():
    return ('<mask id="moon"><rect width="1024" height="1024" fill="#fff"/>'
            '<circle cx="%d" cy="%d" r="%d" fill="#000"/></mask>'
            '<circle cx="%d" cy="%d" r="%d" fill="%s" mask="url(#moon)"/>'
            % (CUT_CX, CUT_CY, CUT_R, MOON_CX, MOON_CY, MOON_R, MOON))


def stars_svg():
    p = ' '.join('%d,%d' % (x, y) for x, y in SPARKLE)
    out = '<path d="M %s Z" fill="%s"/>' % (p, STAR)
    for x, y, r, cc in DOTS:
        out += '<circle cx="%d" cy="%d" r="%d" fill="%s"/>' % (x, y, r, cc)
    return out


def full_svg():
    plate = '<path d="%s" fill="url(#sky)"/>' % squircle_path()
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            + grad_def() + plate + moon_svg() + stars_svg() + '</svg>')


def fg_svg():
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            + moon_svg() + stars_svg() + '</svg>')


def bg_svg():
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            + grad_def() + '<rect width="1024" height="1024" fill="url(#sky)"/></svg>')


def render(svg_text, w, h, out):
    subprocess.run([RSVG, '-w', str(w), '-h', str(h), '-o', out, '-'],
                   input=svg_text.encode(), check=True)


def main():
    tmp = '/tmp/boxn_icon'
    os.makedirs(tmp, exist_ok=True)
    fs = os.path.join(tmp, 'full.svg')
    fgs = os.path.join(tmp, 'fg.svg')
    bgs = os.path.join(tmp, 'bg.svg')
    for p, t in ((fs, full_svg()), (fgs, fg_svg()), (bgs, bg_svg())):
        with open(p, 'w') as f:
            f.write(t)

    store = os.path.join(ROOT, 'docs', 'store')
    os.makedirs(store, exist_ok=True)

    icon1024 = os.path.join(store, 'icon_1024.png')
    store_bg = os.path.join(store, 'icon_background.png')
    store_fg = os.path.join(store, 'icon_foreground.png')
    render(full_svg(), 1024, 1024, icon1024)
    render(bg_svg(), 1024, 1024, store_bg)
    render(fg_svg(), 1024, 1024, store_fg)

    # 工程内两处同步
    app512 = '/tmp/boxn_icon/app_icon.png'
    render(full_svg(), 512, 512, app512)
    targets = []
    for media in (os.path.join(ROOT, 'AppScope', 'resources', 'base', 'media'),
                  os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media')):
        targets.append(os.path.join(media, 'app_icon.png'))
        targets.append(os.path.join(media, 'background.png'))
        targets.append(os.path.join(media, 'foreground.png'))

    import shutil
    for t in targets:
        base = os.path.basename(t)
        if base == 'app_icon.png':
            shutil.copy(app512, t)
        elif base == 'background.png':
            render(bg_svg(), 1024, 1024, t)
        else:
            render(fg_svg(), 1024, 1024, t)

    print('生成完成：')
    for p in [icon1024, store_bg, store_fg, app512] + targets:
        print('  ✓ %-60s %4d KB' % (os.path.relpath(p, ROOT), os.path.getsize(p) // 1024))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
