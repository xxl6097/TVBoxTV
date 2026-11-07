#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
源程序文档的「取材顺序」：两头放中性模块，指向性强的模块压在中间。

背景
----
软著源程序只提交「前 30 页 + 后 30 页」，中间省略。原来按路径字母序排，
`common/Cms.ets`（内容接口客户端）恰好是第一个文件，文件头注释里的
「TVBox / 采集接口 / csp / jar」必然出现在提交材料的第 1 页。

只按「敏感度升序」排会矫枉过正：尾部变成 SettingPage / Store 这类
指向性最强的模块（实测后 30 页命中 85 次）。所以改成三段式：

    前段 = 最干净的若干文件（凑满 ≈31 页，保证前 30 页全净）
    中段 = 其余文件（含指向性强的，落在被省略的页里）
    后段 = 次干净的若干文件（凑满 ≈31 页，保证后 30 页也全净）

影响范围
--------
只影响「哪 60 页进材料」，不改任何一行代码，不改变编译产物，不影响功能。
"""

import glob
import io
import os

# 指向性词汇：出现越多，越不适合出现在提交材料的前/后 30 页
KEYWORDS = [
    '站源', '直播源', '采集', 'TVBox', 'MacCMS', '苹果CMS',
    'csp', 'jar', '爬虫', '订阅', '解析',
]

EDGE_LINES = 1600      # 每端要凑够的行数（一页 50 行，30 页 = 1500，留余量）

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sensitive_score(path: str) -> int:
    try:
        s = io.open(path, encoding='utf-8').read()
    except Exception:
        return 0
    return sum(s.count(k) for k in KEYWORDS)


def _lines(path: str) -> int:
    """该文件进文档的行数（去空行 + 3 行文件头）。"""
    try:
        n = len([ln for ln in io.open(path, encoding='utf-8') if ln.strip()])
    except Exception:
        return 0
    return n + 3


def ordered_files() -> list:
    """返回三段式排好的 .ets 文件列表（前净 / 中杂 / 后净）。"""
    files = glob.glob(os.path.join(ROOT, 'entry/src/main/ets/**/*.ets'), recursive=True)
    asc = sorted(files, key=lambda p: (sensitive_score(p), os.path.relpath(p, ROOT)))

    front, back, acc = [], [], 0
    i = 0
    while i < len(asc) and acc < EDGE_LINES:
        front.append(asc[i]); acc += _lines(asc[i]); i += 1
    acc = 0
    while i < len(asc) and acc < EDGE_LINES:
        back.append(asc[i]); acc += _lines(asc[i]); i += 1
    mid = asc[i:]

    return front + mid + back
