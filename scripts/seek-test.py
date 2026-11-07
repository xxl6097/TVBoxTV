#!/usr/bin/env python3
# 播放器「进度条 seek」稳定性 / 可用性回归测试（模拟器或真机）
#
# 用法：
#   python3 scripts/seek-test.py            # 跑全部用例
#   python3 scripts/seek-test.py basic drag # 只跑指定用例
#
# 前置：设备上已在播放一集点播视频（进度条可见一次即可，脚本会自己唤出控制条）。
# 依赖：scripts/shoot.py（封装 hdc 的 dumpLayout / snapshot / 点击）。
#
# 用例：
#   basic   单点点击精度：20% / 60% / 90%，落点应落在对应分片附近（HLS 对齐关键帧）
#   drag    拖拽跟随手指（绝对定位）：在 30% 处按下拖到 45%，落点应≈45%
#   burst   连续快速点击 5 次不留间隔，最终停在最后一次的位置
#   edge    点 1% 回到开头；点 99.4% 不崩、正常进结尾/切集
#   pause   暂停状态下定位，位置应生效且不自动播放
#   resume  定位后返回再进同一集，应续播到该位置（不同集则从头）
#   stress  25 次随机 seek，不崩、不卡死、控件仍在
import os
import re
import sys
import time

sys.path.insert(0, 'scripts')
from shoot import Shot

# 进度条实测包围盒（3840×2160 物理像素，模拟器分辨率下测得）。
# 真机会在 __main__ 里自动从布局里探测并覆盖这三个值（见 discover_bar / auto_bar）。
BAR_X0, BAR_X1, BAR_Y = 360, 3480, 1828
# 单点定位误差容限。HLS 流 seek 是对齐关键帧的：AVPlayer 默认按最近关键帧落点，
# 本测试流 x36xhzz 的分片是 10s（TARGETDURATION 11），所以落点最多偏一个分片 ~10s。
# 之前的 3s 对这类流过严，把「正常的关键帧对齐」误判成失败。
# 用关键帧更密的流（如 mp4 本地点播 / 1s 关键帧）可把 TOL 调回 3。
# 用 SEEK_TOL 环境变量覆盖：SEEK_TOL=3 python3 scripts/seek-test.py basic ...
TOL = int(os.environ.get('SEEK_TOL', '10'))

# 目标设备：默认这台真机；模拟器/其它设备用环境变量覆盖 HDC_TARGET。
# 例：HDC_TARGET=127.0.0.1:5555 python3 scripts/seek-test.py
TARGET = os.environ.get('HDC_TARGET', '192.168.1.231:37713')
IS_EMU = TARGET.startswith('127.0.0.1')
# 点画面中央用于唤出/收起控制条：模拟器按 3840×2160，真机按 1320×2232 走屏幕中心。
CENTER = (1920, 1080) if IS_EMU else (660, 1116)

s = Shot(TARGET)


def bounds_of(a):
    """把节点的 bounds 字符串 '[x1,y1][x2,y2]' 解析成四元组，解析失败返回 None。"""
    b = a.get('bounds', '')
    m = re.findall(r'-?\d+', b)
    if len(m) >= 4:
        return int(m[0]), int(m[1]), int(m[2]), int(m[3])
    return None


def discover_bar():
    """从当前播放布局自动定位进度条：找两个时间文本（当前/总时长），
    进度条夹在它们之间（左时间的右边缘 → 右时间的左边缘），Y 取两条文本同一行的中心。
    返回 (x0, x1, y) 或 None（没在播放 / 控制条没出来时）。"""
    d = s.dump()
    times = [a for a in d if re.fullmatch(r'\d{2}:\d{2}(:\d{2})?', (a.get('text') or '').strip())]
    if len(times) < 2:
        return None
    bs = [bounds_of(a) for a in times]
    bs = [b for b in bs if b]
    if len(bs) < 2:
        return None
    bs.sort(key=lambda b: b[0])          # 按 x0 排序：左=当前，右=总时长
    left, right = bs[0], bs[1]
    x0 = left[2]                          # 左时间右边缘
    x1 = right[0]                         # 右时间左边缘
    y = (left[1] + left[3] + right[1] + right[3]) // 4
    return x0, x1, y


def auto_bar():
    """非模拟器目标：试着从布局里探测进度条坐标，成功就覆盖 BAR_*。"""
    global BAR_X0, BAR_X1, BAR_Y
    if IS_EMU:
        return
    ensure_osd()                          # 控制条必须先可见，时间文本才在布局里
    r = discover_bar()
    if r:
        BAR_X0, BAR_X1, BAR_Y = r
        print('[discover] 进度条坐标已自动探测: x0=%d x1=%d y=%d' % r)
    else:
        print('[discover] 没探测到进度条（可能不在播放），沿用默认坐标 x0=%d x1=%d y=%d'
              % (BAR_X0, BAR_X1, BAR_Y))


def texts():
    d = s.dump()
    return [(a.get('text') or '').strip() for a in d if (a.get('text') or '').strip()]


def times():
    ts = texts()
    mm = [t for t in ts if re.fullmatch(r'\d{2}:\d{2}(:\d{2})?', t)]
    cur = mm[0] if mm else None
    total = mm[1] if len(mm) > 1 else None
    return cur, total, ts


def sec(t):
    if not t:
        return None
    p = [int(x) for x in t.split(':')]
    return p[0] * 3600 + p[1] * 60 + p[2] if len(p) == 3 else p[0] * 60 + p[1]


def osd_visible():
    ts = texts()
    return ('播放' in ts) or ('暂停' in ts)


def pause_if_playing():
    """测精度前先暂停：播放中每过 1 秒位置就多 1 秒，会把误差算大。"""
    if not osd_visible():
        s.click(*CENTER, wait=0.9)
    ts = texts()
    if '暂停' in ts:          # 按钮显示「暂停」= 正在播放
        press('暂停')


def ensure_osd():
    """控制条不可见时点一下画面唤出；已可见就不要再点，否则会切播放/暂停。"""
    if not osd_visible():
        s.click(*CENTER, wait=0.9)


def keep_awake():
    """长跑时防止手机自动锁屏：发一个 wakeup 把屏幕点亮（幂等，不会 toggle 熄灭）。
    ⚠ 之前用 `uitest uiInput keyEvent Wakeup` 是无效的——uitest keyEvent 只认
    keyID/Back/Home/Power，没有 Wakeup，一直报 Invalid parameters，长跑照样锁屏。"""
    if not IS_EMU:
        s.shell('power-shell wakeup')


def tap_ratio(r, wait=2.5):
    keep_awake()
    ensure_osd()
    s.shell('uitest uiInput click %d %d'
            % (BAR_X0 + int((BAR_X1 - BAR_X0) * r), BAR_Y))
    time.sleep(wait)


def drag_ratio(r0, r1, wait=3.0):
    keep_awake()
    ensure_osd()
    # 放慢到 1500ms：uitest 的 swipe 位移回报在快速滑动时会略偏大，
    # 放慢后 offsetX 更接近几何距离，落点更准（App 侧本身是忠实跟手的）。
    s.shell('uitest uiInput swipe %d %d %d %d 1500'
            % (BAR_X0 + int((BAR_X1 - BAR_X0) * r0), BAR_Y,
               BAR_X0 + int((BAR_X1 - BAR_X0) * r1), BAR_Y))
    time.sleep(wait)


def press(label):
    d = s.dump()
    b = [a for a in d if (a.get('text') or '').strip() == label]
    if not b:
        return False
    n = [int(float(v)) for v in b[0].get('bounds', '').replace('][', ',').strip('[]').split(',')]
    s.click((n[0] + n[2]) // 2, (n[1] + n[3]) // 2, wait=1.2)
    return True


def check(tag, ratio, tol=None):
    ensure_osd()                      # OSD 会自动隐藏，读数前先确保还在
    cur, total, _ = times()
    tot, got = sec(total), sec(cur)
    exp = int(tot * ratio) if tot else None
    diff = (got - exp) if (got is not None and exp is not None) else None
    lim = TOL if tol is None else tol
    ok = diff is not None and abs(diff) <= lim
    print('  %-18s %s / %s   期望 %s   Δ=%s   %s'
          % (tag, cur or '-', total or '-',
             '%02d:%02d' % (exp // 60, exp % 60) if exp is not None else '-',
             ('%+d' % diff) if diff is not None else '-',
             'PASS' if ok else 'FAIL'))
    return ok


def t_basic():
    pause_if_playing()
    print('[basic] 单点点击精度')
    for r in (0.2, 0.6, 0.9):
        tap_ratio(r)
        check('tap %d%%' % (r * 100), r)


def tol_drag():
    """拖拽的合理误差：手指拖动本身是粗定位（用户拖到 ~45% 落点有 ±几 % 很正常），
    且 uitest 的 swipe 位移回报会略偏大，这里按总时长 4% 给一个符合真实 UX 的容差。"""
    total = times()[1]
    tot = sec(total)
    return max(8, int((tot or 0) * 0.04))


def t_drag():
    pause_if_playing()
    print('[drag] 拖拽应跟随手指（绝对定位）')
    tap_ratio(0.1)
    drag_ratio(0.30, 0.45)
    check('drag 30→45%', 0.45, tol_drag())
    drag_ratio(0.70, 0.35)
    check('drag 70→35%', 0.35, tol_drag())


def t_burst():
    pause_if_playing()
    print('[burst] 连续快速点击 5 次')
    for r in (0.05, 0.30, 0.55, 0.75, 0.95):
        ensure_osd()
        s.shell('uitest uiInput click %d %d'
                % (BAR_X0 + int((BAR_X1 - BAR_X0) * r), BAR_Y))
        time.sleep(0.35)
        print('    点 %.0f%% -> %s（OSD可见=%s）' % (r * 100, times()[0], osd_visible()))
    time.sleep(3)
    check('burst 末次 95%', 0.95)


def t_edge():
    pause_if_playing()
    print('[edge] 两端极值')
    tap_ratio(0.994, wait=4)
    check('tap 99.4%', 0.994)
    cur, total, ts = times()
    print('    结尾后:', cur, '/', total, '|', [t for t in ts if '集' in t][:2])
    tap_ratio(0.01, wait=3)
    check('tap 1%', 0.01)


def t_pause():
    print('[pause] 暂停状态下定位')
    if osd_visible() and '暂停' in texts():
        press('暂停')
    tap_ratio(0.6)
    check('暂停时 tap 60%', 0.6)
    a = sec(times()[0])
    time.sleep(2.5)
    b = sec(times()[0])
    print('    暂停 2.5 秒后位置变化 %s 秒（应≈0）' % (None if (a is None or b is None) else b - a))


def t_stress():
    print('[stress] 25 次随机 seek')
    import random
    random.seed(11)
    t0 = time.time()
    for _ in range(25):
        keep_awake()
        if not osd_visible():
            s.click(*CENTER, wait=0.4)
        r = random.uniform(0.02, 0.96)
        s.shell('uitest uiInput click %d %d'
                % (BAR_X0 + int((BAR_X1 - BAR_X0) * r), BAR_Y))
        time.sleep(0.35)
    time.sleep(4)
    # 长跑期间控制条会自动收起、手机也可能息屏，读数前再点亮一次并把控制条唤回来，
    # 否则会把「控制条自动隐藏」误判成「控件消失 / 卡死」。
    keep_awake()
    ensure_osd()
    cur, total, ts = times()
    print('    %.1fs 完成，末态 %s / %s，控件仍在: %s'
          % (time.time() - t0, cur, total, osd_visible()))


def t_discover():
    ensure_osd()
    print('[discover] 进度条坐标:', discover_bar())


CASES = {'basic': t_basic, 'drag': t_drag, 'burst': t_burst,
         'edge': t_edge, 'pause': t_pause, 'stress': t_stress,
         'discover': t_discover}


if __name__ == '__main__':
    want = sys.argv[1:] or list(CASES.keys())
    if want == ['discover']:
        t_discover()
        sys.exit(0)
    auto_bar()
    cur, total, _ = times()
    print('当前播放位置: %s / %s\n' % (cur, total))
    for name in want:
        fn = CASES.get(name)
        if fn is None:
            print('未知用例:', name)
            continue
        keep_awake()
        fn()
        print()
