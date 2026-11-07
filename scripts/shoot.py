#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TV 端截图工具：按控件文字定位并点击，抓图存成 1920×1080 PNG。

为什么按文字找控件而不是写死坐标：
  写死坐标在换分辨率/换布局后全废，而且点偏一格就跑到别的页面。dumpLayout 拿到
  的 bounds 是物理像素，直接用中心点点击最稳。

用法（被 capture-screens.py 调用）：
  from shoot import Shot
  s = Shot('127.0.0.1:5555')
  s.click_text('点播')
  s.save('01_点播分类')
"""

import json
import os
import subprocess
import time

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, 'docs', 'store', 'screenshots')
HDC = os.path.expanduser('~/harmonyos-sdk/toolchains/hdc')
HDCX = os.path.join(ROOT, 'scripts', 'hdcx.sh')
TMP = '/data/local/tmp'


class Shot:
    def __init__(self, target):
        self.t = target

    # ---------- hdc 基础 ----------
    def sh(self, *args, timeout=60):
        # 真机无线调试会话极短命（隔一个 shell 调用就失效），
        # 非本机模拟器目标统一走 hdcx.sh，它在每条命令里自动 kill→start→tconn 重连。
        # 模拟器（127.0.0.1）保持原样直连，不动它的会话。
        if not self.t.startswith('127.0.0.1') and os.path.exists(HDCX):
            env = dict(os.environ)
            env['TV_IP'] = self.t
            cmd = ['bash', HDCX, *args]
            return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env).stdout
        cmd = [HDC, '-t', self.t] + list(args)
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout

    def shell(self, cmd, timeout=60):
        return self.sh('shell', cmd, timeout=timeout)

    # ---------- UI ----------
    def dump(self):
        """dumpLayout 到远端文件，拉回本地解析，返回节点列表。"""
        import re
        out = self.shell('uitest dumpLayout')
        # 输出形如 "DumpLayout saved to:/data/local/tmp/layout_694175910.json"，
        # hdc 的 shell 回包带 \r，不剥掉会把文件名拼坏，file recv 直接失败。
        m = re.search(r'(/data/local/tmp/layout_\d+\.json)', out)
        path = m.group(1) if m else ''
        if not path:
            ls = self.shell('ls -t %s | grep layout_ | head -1' % TMP).strip().replace('\r', '')
            path = os.path.join(TMP, ls) if ls else ''
        if not path:
            return []
        local = '/tmp/__layout.json'
        self.sh('file', 'recv', path, local)
        try:
            root = json.load(open(local, encoding='utf-8'))
        except Exception:
            return []
        nodes = []

        def walk(n):
            if isinstance(n, dict):
                a = n.get('attributes', {})
                if a:
                    nodes.append(a)
                for c in n.get('children', []) or []:
                    walk(c)
            elif isinstance(n, list):
                for c in n:
                    walk(c)

        walk(root)
        return nodes

    @staticmethod
    def center(bounds):
        # "left top [right bottom]"? 实测格式形如 "[x1,y1][x2,y2]"
        try:
            s = bounds.replace('][', ',').strip('[]')
            x1, y1, x2, y2 = [int(float(v)) for v in s.split(',')]
            return (x1 + x2) // 2, (y1 + y2) // 2
        except Exception:
            return None

    def find(self, text, exact=True, clickable_only=False):
        for a in self.dump():
            t = (a.get('text') or '').strip()
            if not t:
                continue
            ok = (t == text) if exact else (text in t)
            if not ok:
                continue
            if clickable_only and a.get('clickable') != 'true':
                continue
            c = self.center(a.get('bounds', ''))
            if c:
                return c
        return None

    def click(self, x, y, wait=1.2):
        self.shell('uitest uiInput click %d %d' % (x, y))
        time.sleep(wait)

    def click_text(self, text, exact=True, wait=1.2, tries=3):
        for _ in range(tries):
            c = self.find(text, exact=exact)
            if c:
                self.click(c[0], c[1], wait)
                return True
            time.sleep(1.0)
        print('   ✗ 找不到控件：%s' % text)
        return False

    # ---------- 抓图 ----------
    def save(self, name, resize=(1920, 1080)):
        remote = os.path.join(TMP, 'shot.jpeg')
        self.shell('snapshot_display -f %s' % remote)
        local_jpg = '/tmp/__shot.jpeg'
        self.sh('file', 'recv', remote, local_jpg)
        dst = os.path.join(OUT_DIR, name + '.png')
        im = Image.open(local_jpg).convert('RGB')
        if resize:
            im = im.resize(resize, Image.LANCZOS)
        im.save(dst, 'PNG', optimize=True)
        print('   ✓ %s  %dx%d' % (name, im.size[0], im.size[1]))
        return dst
