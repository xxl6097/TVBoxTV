#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
在鸿蒙模拟器上「录屏 + 自动走一遍功能」的脚本。

背景：HarmonyOS 模拟器镜像里没有 screenrecord，宿主机的 avfoundation 也拿不到
屏幕采集设备（无录屏权限），所以只能在设备侧连续 snapshot_display 抓帧，
再用 ffmpeg 按每帧真实间隔合成 mp4。实测约 6 fps，够看清界面切换。

    ./scripts/record-tour.py                # 录一遍全功能巡览 → dist/tour.mp4
    ./scripts/record-tour.py --dry          # 只走动作不录（校准坐标用）

前提：模拟器已启动、应用已装、订阅已导入。
"""
import os
import shutil
import subprocess
import sys
import threading
import time

HDC = os.environ.get(
    'HDC',
    '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc')
TGT = os.environ.get('EMU_TARGET', '127.0.0.1:5555')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAMES = '/tmp/tour-frames'
OUT = os.path.join(ROOT, 'dist', '夜帧影视-TV功能巡览.mp4')
SUB_URL = 'https://fs.abber.cn:88/public/json/hongtv.json'

_lock = threading.Lock()


def hdc(*args, timeout=60):
    try:
        subprocess.run([HDC, '-t', TGT, *args], capture_output=True, timeout=timeout)
    except Exception:
        pass


def connect():
    subprocess.run([HDC, 'tconn', TGT], capture_output=True, timeout=30)


# ---------------- 抓帧线程 ----------------

class Recorder(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.stop_flag = threading.Event()
        self.n = 0
        self.stamps = []  # (index, epoch_ms)
        shutil.rmtree(FRAMES, ignore_errors=True)
        os.makedirs(FRAMES, exist_ok=True)

    def run(self):
        while not self.stop_flag.is_set():
            t0 = time.time()
            self.n += 1
            path = os.path.join(FRAMES, '%06d.jpg' % self.n)
            hdc('shell', 'snapshot_display -f /data/local/tmp/_cap.jpeg')
            hdc('file', 'recv', '/data/local/tmp/_cap.jpeg', path)
            with _lock:
                self.stamps.append((self.n, int(t0 * 1000)))
            # 目标 ~6fps：抓一次约 150ms，余量留给下一次
            slack = 0.16 - (time.time() - t0)
            if slack > 0:
                time.sleep(slack)

    def stop(self):
        self.stop_flag.set()


# ---------------- 动作 ----------------

def dump_text():
    """把当前界面的文字抓下来（用于判断到底停在哪一页）"""
    try:
        subprocess.run([HDC, '-t', TGT, 'shell',
                        'uitest dumpLayout -p /data/local/tmp/_l.json'],
                       capture_output=True, timeout=40)
        subprocess.run([HDC, '-t', TGT, 'file', 'recv',
                        '/data/local/tmp/_l.json', '/tmp/_l.json'],
                       capture_output=True, timeout=40)
        return open('/tmp/_l.json', encoding='utf-8').read()
    except Exception:
        return ''


def ensure_home(tries=3):
    """退回到首页。

    直接连按 Back 有风险：从详情退到首页后再按一次 Back 会把应用退出到桌面，
    后面所有点击都打在桌面上（实测录出一整段桌面壁纸）。
    所以每次只退一步，然后用控件树确认「点播/直播/直连」这排导航在不在。
    """
    for _ in range(tries):
        t = dump_text()
        if '点播' in t and '直播' in t and '设置' in t:
            return True
        key('Back', 2.5)
    # 还不行就把应用重新拉到前台
    hdc('shell', 'aa start -a EntryAbility -b com.hong.tv')
    time.sleep(5)
    t = dump_text()
    return '点播' in t


def tap_home_tab(x, label, wait=4.0):
    """点首页顶部导航，并确认真的切过去了"""
    tap(x, 384, wait)
    t = dump_text()
    return label in t



def tap(x, y, wait):
    hdc('shell', 'uitest uiInput click %d %d' % (x, y))
    time.sleep(wait)


def key(code, wait):
    hdc('shell', 'uitest uiInput keyEvent %s' % code)
    time.sleep(wait)


def text(x, y, s, wait):
    hdc('shell', 'uitest uiInput inputText %d %d %s' % (x, y, s))
    time.sleep(wait)


def tour(dry=False):
    """按顺序走一遍。每个元组：(说明, 可调用)。"""
    steps = []

    # —— 首页 ——
    steps.append(('首页 · 点播', lambda: time.sleep(4)))

    # —— 详情 ——
    steps.append(('打开详情', lambda: tap(384, 800, 6)))

    # —— 播放 + 控制条 + 选集 ——
    steps.append(('起播第 1 集', lambda: tap(290, 1443, 11)))
    steps.append(('唤出控制条', lambda: tap(1920, 700, 4)))
    steps.append(('选集面板', lambda: tap(1920, 1970, 6)))
    steps.append(('关选集', lambda: tap(3600, 300, 3)))
    steps.append(('退回首页', lambda: ensure_home()))

    # —— 直播 ——
    steps.append(('直播列表', lambda: tap(755, 384, 7)))
    steps.append(('切到央视频道', lambda: tap(108, 725, 5)))
    steps.append(('切回 4K 频道', lambda: tap(108, 569, 5)))
    steps.append(('播一个频道', lambda: tap(1080, 310, 11)))
    steps.append(('直播控制条', lambda: tap(1920, 700, 5)))
    steps.append(('直播里回列表', lambda: key('Back', 3)))
    steps.append(('退回首页', lambda: ensure_home()))

    # —— 搜索 ——
    steps.append(('搜索页', lambda: tap(2153, 384, 4)))
    steps.append(('输入关键词', lambda: text(900, 150, '凡人修仙传', 3)))
    steps.append(('看结果', lambda: tap(2061, 150, 10)))
    steps.append(('退回首页', lambda: ensure_home()))

    # —— 收藏 / 历史 ——
    steps.append(('收藏页', lambda: tap_home_tab(2620, '收藏')))
    steps.append(('历史页', lambda: tap_home_tab(3086, '历史')))

    # —— 直连 / 网盘 ——
    steps.append(('直连播放', lambda: tap_home_tab(1220, '直连')))
    steps.append(('退回首页', lambda: ensure_home()))
    steps.append(('网盘', lambda: tap_home_tab(1687, 'WebDAV')))
    steps.append(('退回首页', lambda: ensure_home()))

    # —— 设置各分类 ——
    steps.append(('设置 · 播放源', lambda: tap_home_tab(3553, '设置')))
    steps.append(('设置 · 内容更新', lambda: tap(144, 432, 4)))
    steps.append(('设置 · 站源', lambda: tap(144, 744, 5)))
    steps.append(('设置 · 数据', lambda: tap(144, 900, 4)))
    steps.append(('设置 · 关于', lambda: tap(144, 1056, 5)))
    steps.append(('回播放源', lambda: tap(144, 276, 3)))

    # —— 订阅流程 ——
    steps.append(('打开订阅', lambda: tap(2200, 329, 5)))
    steps.append(('手动输入', lambda: tap(1951, 1347, 4)))
    steps.append(('填地址', lambda: text(2300, 1230, SUB_URL, 3)))
    steps.append(('提交', lambda: tap(2738, 2055, 10)))
    steps.append(('结束', lambda: key('Back', 3)))

    total = 0
    for i, (name, fn) in enumerate(steps, 1):
        t0 = time.time()
        fn()
        d = time.time() - t0
        total += d
        print('  %2d/%d %-16s %5.1fs' % (i, len(steps), name, d), flush=True)
    print('总时长约 %.0f 秒' % total)


def encode():
    stamps = STAMPS
    if len(stamps) < 10:
        print('✗ 帧太少，放弃合成')
        return 1
    lst = os.path.join(FRAMES, 'list.txt')
    with open(lst, 'w', encoding='utf-8') as f:
        for i, (idx, ms) in enumerate(stamps):
            nxt = stamps[i + 1][1] if i + 1 < len(stamps) else ms + 160
            dur = max(0.04, (nxt - ms) / 1000.0)
            f.write("file '%06d.jpg'\nduration %.3f\n" % (idx, dur))
        f.write("file '%06d.jpg'\n" % stamps[-1][0])
    cmd = [
        'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'concat', '-safe', '0', '-i', lst,
        '-vf', 'scale=1920:1080:flags=lanczos,fps=30,format=yuv420p',
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23',
        '-movflags', '+faststart', OUT,
    ]
    print('合成中…')
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[-1500:])
        return 1
    print('✓ %s' % OUT)
    return 0


STAMPS = []

if __name__ == '__main__':
    dry = '--dry' in sys.argv
    connect()
    rec = None
    if not dry:
        rec = Recorder()
        rec.start()
        time.sleep(1.5)
    tour(dry)
    if rec:
        rec.stop()
        rec.join()
        STAMPS = list(rec.stamps)
        print('抓帧 %d 张' % len(STAMPS))
        sys.exit(encode())
