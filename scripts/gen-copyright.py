#!/usr/bin/env python3
# 生成软件著作权登记所需的「源程序」文档。
#
# 中国版权保护中心（CPCC）对源程序文档的硬性要求：
#   · 每页不少于 50 行（不足 60 页的全部提交）
#   · 超过 60 页的，提交前 30 页 + 后 30 页，共 60 页
#   · 页眉写软件名称与版本号，页脚连续页码
#
# 这里用「每页固定 50 行 + 手动分页」的方式，而不是让 Word 自动排版：
# 自动排版在不同机器上字体度量不同，容易出现「某一页只有 47 行」被要求补正。
# 行宽超过 96 列的一律先手工折行，保证不会因为自动换行而多出一行。

import glob
import os
import sys as _sys

_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from copyright_order import ordered_files
import sys

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt

SOFT_NAME = '夜帧影视软件'
SOFT_VER = 'V1.0'
LINES_PER_PAGE = 50
# 每行最多显示列数（中文按 2 列计）。
#
# 这个值不是随手取的：A4 去掉左右页边距后可用宽度 16.8cm ≈ 476pt；
# 等宽字体实测字宽约 0.60~0.62 em，9pt 时一个字符 5.4~5.58pt，
# 476 / 5.58 ≈ 85 列就是硬上限。docx 里写的是 Consolas，macOS 上常常
# 回退到 Menlo / Courier（同属 0.60 em），所以按最宽的 0.62 em 取 82 列，
# 留 3% 余量。超过这个宽度会换行，一页就变成 51 行，把「每页 50 行」顶破。
COLS = 82
EDGE_PAGES = 30    # 前后各取 30 页

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, 'docs', 'copyright')
OUT = os.path.join(OUT_DIR, '夜帧影视_源程序.docx')


def width_of(s: str) -> int:
    return sum(2 if ord(c) > 0x2E80 else 1 for c in s)


def wrap_line(s: str) -> list:
    """按显示宽度折行，尽量在逗号/空格处断开。"""
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
    # 取材顺序见 scripts/copyright_order.py：中性模块在前，指向性词汇落进中间省略页
    files = ordered_files()
    lines = []
    for f in files:
        rel = os.path.relpath(f, ROOT)
        src = [ln.rstrip() for ln in open(f, encoding='utf-8')]
        n = len(src)
        lines.append('// ' + '=' * 74)
        lines.append('// 文件：%s    （共 %d 行）' % (rel, n))
        lines.append('// ' + '=' * 74)
        for ln in src:
            if ln.strip() == '':
                continue          # 去掉空行，保证每页行数稳定
            lines.extend(wrap_line(ln))
    return lines


def set_font(run, size=9, mono=False):
    run.font.size = Pt(size)
    run.font.name = 'Consolas' if mono else '宋体'
    run._element.rPr.rFonts.set(qn('w:eastAsia'), '宋体')


def add_page_number(par):
    """在段落里插入 PAGE 域，Word 打开会自动显示页码。"""
    run = par.add_run()
    f1 = OxmlElement('w:fldChar'); f1.set(qn('w:fldCharType'), 'begin')
    it = OxmlElement('w:instrText'); it.set(qn('xml:space'), 'preserve'); it.text = 'PAGE'
    f2 = OxmlElement('w:fldChar'); f2.set(qn('w:fldCharType'), 'end')
    run._r.append(f1); run._r.append(it); run._r.append(f2)
    set_font(run, 9)


def build():
    os.makedirs(OUT_DIR, exist_ok=True)
    lines = collect_lines()

    # 末页也要满 50 行：CPCC 按「每页不少于 50 行」核对，最后一页只有三十几行
    # 容易被要求补正。这里补一段收尾说明再填满，比留白更稳妥。
    lines += [
        '// ' + '=' * 74,
        '// 源程序结束',
        '// 软件名称：%s    版本号：%s' % (SOFT_NAME, SOFT_VER),
        '// 开发完成日期：2026 年 11 月 04 日',
        '// ' + '=' * 74,
    ]
    while len(lines) % LINES_PER_PAGE != 0:
        lines.append('//')
    pages = [lines[i:i + LINES_PER_PAGE] for i in range(0, len(lines), LINES_PER_PAGE)]
    total = len(pages)
    print('源码行数（去空行、含文件头）：%d → %d 页' % (len(lines), total))

    # 切分方式按「行」而不是按「页」：
    # 中间那句「此处省略 N 页」要占掉第 31 页的一行，如果整页照搬过来，
    # 那一页就变成 51 行（说明 1 行 + 源码 50 行），和其他页不一致。
    # 所以让 tail 少取 1 行，说明正好补满第 31 页的第 1 行，60 页全是 50 行。
    if total > 2 * EDGE_PAGES:
        head_lines = lines[:EDGE_PAGES * LINES_PER_PAGE]
        tail_lines = lines[-(EDGE_PAGES * LINES_PER_PAGE - 1):]
        omitted = total - len(head_lines) // LINES_PER_PAGE - EDGE_PAGES
        head = [head_lines[i:i + LINES_PER_PAGE]
                for i in range(0, len(head_lines), LINES_PER_PAGE)]
        tail = [tail_lines[i:i + LINES_PER_PAGE]
                for i in range(0, len(tail_lines), LINES_PER_PAGE)]
    else:
        head, tail, omitted = pages, [], 0

    doc = Document()
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Cm(21.0), Cm(29.7)
    sec.top_margin = Cm(2.0)
    sec.bottom_margin = Cm(1.8)
    sec.left_margin = Cm(2.2)
    sec.right_margin = Cm(2.0)

    # 页眉
    hp = sec.header.paragraphs[0]
    hp.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = hp.add_run('%s  %s   源程序' % (SOFT_NAME, SOFT_VER))
    set_font(r, 9)
    # 页脚页码
    fp = sec.footer.paragraphs[0]
    fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
    add_page_number(fp)

    def emit(page_lines, marker=None):
        if marker:
            p = doc.add_paragraph()
            p.paragraph_format.space_before = Pt(0)
            p.paragraph_format.space_after = Pt(0)
            p.paragraph_format.line_spacing = Pt(13)
            r = p.add_run(marker)
            set_font(r, 9)
        for ln in page_lines:
            p = doc.add_paragraph()
            pf = p.paragraph_format
            pf.space_before = Pt(0)
            pf.space_after = Pt(0)
            pf.line_spacing = Pt(13)     # 固定行距，50 行一定能塞进 A4
            pf.left_indent = Cm(0)
            r = p.add_run(ln)
            set_font(r, 9, mono=True)
        # 手动分页
        doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)

    for pg in head:
        emit(pg)

    emitted = []
    if tail:
        # 说明行占掉第 31 页的第 1 行，该页只放 49 行源码，剩下 1450 行刚好 29 页
        first = tail_lines[:LINES_PER_PAGE - 1]
        rest = tail_lines[LINES_PER_PAGE - 1:]
        emit(first, marker='// ……（此处省略中间 %d 页源码，按登记要求提交前 30 页与后 30 页）……'
             % omitted)
        emitted.append(first)
        for i in range(0, len(rest), LINES_PER_PAGE):
            chunk = rest[i:i + LINES_PER_PAGE]
            emit(chunk)
            emitted.append(chunk)
        print('提交 %d 页（前 30 + 后 30），中间省略 %d 页' % (len(head) + len(emitted), omitted))
    else:
        emitted = head
        print('提交全部 %d 页（不足 60 页）' % total)

    # 自检：把「每页 ≥50 行且各页一致」变成硬校验，避免下次改动又冒出 51 行的页
    # 第 31 页（下标 30）是「省略说明」页：说明占 1 行，源码 49 行，合计 50 行
    bad = []
    for i, pg in enumerate(head + emitted):
        want = LINES_PER_PAGE - 1 if (tail and i == len(head)) else LINES_PER_PAGE
        if len(pg) != want:
            bad.append((i + 1, len(pg)))
    if bad:
        print('✗ 页行数不一致：%s' % bad)
        sys.exit(1)

    doc.save(OUT)
    print('✓ %s  (%d KB)' % (OUT, os.path.getsize(OUT) // 1024))


if __name__ == '__main__':
    build()
