#!/usr/bin/env python3
# 生成软著「源程序」PDF —— 与 gen-copyright.py 同源（同样的取码 / 折行 / 分页规则），
# 只是把渲染层从 docx 换成「HTML + Chrome headless 打印」。
#
# 为什么这么做：CPCC 提交要 PDF；本机 LibreOffice 的 app bundle 缺失，
# pillow/reportlab 也装不上，于是用 Chrome 的 --print-to-pdf 打印一份
# 精确控制分页的 HTML：每页固定 50 行、页眉「软件名称 版本号 源程序」、页脚页码。
#
#   用法：python3 scripts/gen-copyright-pdf.py

import glob
import os
import sys as _sys

_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from copyright_order import ordered_files
import subprocess

SOFT_NAME = '夜帧影视软件'
SOFT_VER = 'V1.0'
LINES_PER_PAGE = 50
COLS = 82
EDGE_PAGES = 30

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, 'docs', 'copyright')
OUT_HTML = os.path.join(OUT_DIR, '夜帧影视_源程序.html')
OUT_PDF = os.path.join(OUT_DIR, '夜帧影视_源程序.pdf')

CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'


def width_of(s: str) -> int:
    return sum(2 if ord(c) > 0x2E80 else 1 for c in s)


def wrap_line(s: str) -> list:
    """按显示宽度折行（中文按 2 列），与 gen-copyright.py 一致。"""
    if width_of(s) <= COLS:
        return [s]
    out, cur, cur_w = [], '', 0
    for ch in s:
        w = 2 if ord(ch) > 0x2E80 else 1
        if cur_w + w > COLS:
            out.append(cur)
            cur, cur_w = ch, w
        else:
            cur += ch
            cur_w += w
    if cur:
        out.append(cur)
    return out


def collect_lines() -> list:
    files = ordered_files()   # 取材顺序见 copyright_order.py
    lines = []
    for f in files:
        rel = os.path.relpath(f, ROOT)
        src = [ln.rstrip() for ln in open(f, encoding='utf-8')]
        lines.append('// ' + '=' * 74)
        lines.append('// 文件：%s    （共 %d 行）' % (rel, len(src)))
        lines.append('// ' + '=' * 74)
        for ln in src:
            if ln.strip() == '':
                continue
            lines.extend(wrap_line(ln))
    return lines


def esc(s: str) -> str:
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def page_html(lines: list, page_no: int) -> str:
    body = '\n'.join(esc(x) for x in lines)
    return (
        '<div class="page">'
        '<div class="hd">%s&nbsp;&nbsp;%s&nbsp;&nbsp;&nbsp;源程序</div>'
        '<div class="code">%s</div>'
        '<div class="ft">%d</div>'
        '</div>'
    ) % (SOFT_NAME, SOFT_VER, body, page_no)


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    lines = collect_lines()
    lines += [
        '// ' + '=' * 74,
        '// 源程序结束',
        '// 软件名称：%s    版本号：%s' % (SOFT_NAME, SOFT_VER),
        '// 开发完成日期：2026 年 11 月 04 日',
        '// ' + '=' * 74,
    ]
    while len(lines) % LINES_PER_PAGE != 0:
        lines.append('//')
    total = len(lines) // LINES_PER_PAGE
    print('源码行数（去空行、含文件头）：%d → %d 页' % (len(lines), total))

    if total > 2 * EDGE_PAGES:
        head_lines = lines[:EDGE_PAGES * LINES_PER_PAGE]
        tail_lines = lines[-(EDGE_PAGES * LINES_PER_PAGE - 1):]
        omitted = total - EDGE_PAGES - EDGE_PAGES
    else:
        head_lines, tail_lines, omitted = lines, [], 0

    pages = []
    # 前 30 页
    for i in range(0, len(head_lines), LINES_PER_PAGE):
        pages.append(head_lines[i:i + LINES_PER_PAGE])
    # 第 31 页：省略说明占第 1 行 + 49 行源码
    if tail_lines:
        first = tail_lines[:LINES_PER_PAGE - 1]
        marker = '// ……（此处省略中间 %d 页源码，按登记要求提交前 30 页与后 30 页）……' % omitted
        pages.append([marker] + first)
        rest = tail_lines[LINES_PER_PAGE - 1:]
        for i in range(0, len(rest), LINES_PER_PAGE):
            pages.append(rest[i:i + LINES_PER_PAGE])

    # 兜底：每页补齐到 50 行（末页不足时补 //）
    norm = []
    for pg in pages:
        if len(pg) < LINES_PER_PAGE:
            pg = pg + ['//'] * (LINES_PER_PAGE - len(pg))
        norm.append(pg)
    pages = norm
    print('提交 %d 页（前 30 + 后 30），中间省略 %d 页' % (len(pages), omitted))

    css = """
@page { size: A4; margin: 0; }
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: #fff; }
.page {
  width: 210mm; height: 297mm;
  padding: 18mm 20mm 16mm 22mm;
  page-break-after: always;
  position: relative;
  overflow: hidden;
}
.page:last-child { page-break-after: auto; }
.hd {
  text-align: center; font-size: 9pt; line-height: 1;
  margin-bottom: 5mm;
  font-family: "Songti SC", "SimSun", serif;
}
.code {
  font-family: "Menlo", "Consolas", "Courier New", monospace;
  font-size: 9pt; line-height: 13pt; white-space: pre;
}
.ft {
  position: absolute; left: 0; right: 0; bottom: 8mm;
  text-align: center; font-size: 9pt;
  font-family: "Songti SC", "SimSun", serif;
}
"""
    html_doc = (
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<title>%s %s 源程序</title><style>%s</style></head><body>%s</body></html>'
    ) % (SOFT_NAME, SOFT_VER, css,
         ''.join(page_html(pg, i + 1) for i, pg in enumerate(pages)))

    with open(OUT_HTML, 'w', encoding='utf-8') as fp:
        fp.write(html_doc)
    print('HTML：%s' % OUT_HTML)

    if not os.path.exists(CHROME):
        print('✗ 找不到 Chrome：%s' % CHROME)
        print('  可手动用浏览器打开上面的 HTML，打印为 PDF（A4、无边距、关闭页眉页脚）')
        return

    if os.path.exists(OUT_PDF):
        os.remove(OUT_PDF)
    cmd = [
        CHROME, '--headless', '--no-sandbox', '--disable-gpu',
        '--disable-dev-shm-usage', '--no-pdf-header-footer',
        '--print-to-pdf=%s' % OUT_PDF, 'file://%s' % OUT_HTML,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if r.returncode != 0 or not os.path.exists(OUT_PDF):
        print('✗ Chrome 打印失败（code=%d）' % r.returncode)
        print(r.stderr[-800:])
        return
    size = os.path.getsize(OUT_PDF)
    print('✓ %s  (%.0f KB, %d 页)' % (OUT_PDF, size / 1024.0, len(pages)))


if __name__ == '__main__':
    main()
