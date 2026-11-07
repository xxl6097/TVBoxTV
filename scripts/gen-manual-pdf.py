#!/usr/bin/env python3
# 把「软件说明书」docx 转成 PDF（软著提交要求 PDF）。
#
# 本机没有 LibreOffice / Word，也没有可用的 PDF 生成库，所以走：
#   docx → 结构化 HTML（按字号/加粗/对齐还原层级）→ Chrome headless 打印 PDF
#
# 说明书的段落都套 Normal 样式、靠字号区分层级，因此这里用字号映射：
#   30pt bold → 封面主标题      22pt bold → 封面副标题
#   15pt bold → 一级标题        12.5pt bold → 二级标题
#   11.5pt → 目录条目           11pt → 正文（· 开头视作项目符号）
#   9.5pt → 图注
#
#   用法：python3 scripts/gen-manual-pdf.py

import os
import re
import shutil
import subprocess
import tempfile
import zipfile

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn

SOFT_NAME = '夜帧影视软件'
SOFT_VER = 'V1.0'

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, 'docs', 'copyright')
SRC = os.path.join(OUT_DIR, '夜帧影视_软件说明书.docx')
OUT_HTML = os.path.join(OUT_DIR, '夜帧影视_软件说明书.html')


def esc(s: str) -> str:
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def emu_to_cm(v) -> float:
    try:
        return int(v) / 360000.0
    except Exception:
        return 0.0


def main() -> None:
    doc = Document(SRC)

    # ---------- 解压 docx 内的图片 ----------
    media_dir = os.path.join(tempfile.gettempdir(), 'hmy_manual_media')
    if os.path.exists(media_dir):
        shutil.rmtree(media_dir)
    os.makedirs(media_dir)
    with zipfile.ZipFile(SRC) as z:
        for n in z.namelist():
            if n.startswith('word/media/'):
                z.extract(n, media_dir)

    # docx 里的截图是 3840×2160 的 PNG（单张 500KB+，19 张合计 9MB+）。
    # Chrome 的 CDP Page.printToPDF 遇到这种大图会卡死（实测 >150s 不返回），
    # 但同页面用 CLI --print-to-pdf 只要 4s —— 是 CDP 打印路径对大图的性能问题。
    # 这里先把图缩到最长边 1600px、转 JPEG q80，体积降到约 1/6，肉眼几乎无差。
    def shrink(png_path: str) -> str:
        jpg = png_path[:-4] + '.jpg'
        try:
            r = subprocess.run(
                ['sips', '-Z', '1600', '-s', 'format', 'jpeg',
                 '-s', 'formatOptions', '80', png_path, '--out', jpg],
                capture_output=True, timeout=60)
            if r.returncode == 0 and os.path.exists(jpg):
                return jpg
        except Exception:
            pass
        return png_path

    # rId → 图片绝对路径（已压缩）
    rel_map = {}
    for rid, rel in doc.part.rels.items():
        if 'image' in rel.reltype:
            name = os.path.basename(rel.target_ref)
            p = os.path.join(media_dir, 'word', 'media', name)
            if os.path.exists(p):
                rel_map[rid] = shrink(p)

    parts = []
    stats = {'img': 0, 'p': 0, 'h1': 0, 'h2': 0, 'cap': 0, 'pb': 0}

    for par in doc.paragraphs:
        el = par._element

        # 分页符
        has_break = False
        for br in el.findall('.//' + qn('w:br')):
            if br.get(qn('w:type')) == 'page':
                has_break = True
                break

        # 图片
        drawings = el.findall('.//' + qn('w:drawing'))
        if drawings:
            for d in drawings:
                for blip in d.findall('.//' + qn('a:blip')):
                    rid = blip.get(qn('r:embed'))
                    path = rel_map.get(rid)
                    if not path:
                        continue
                    width_cm = 14.2
                    for ext in d.findall('.//' + qn('wp:extent')):
                        w = emu_to_cm(ext.get('cx'))
                        if w > 0:
                            width_cm = round(w, 1)
                    parts.append(
                        '<div class="fig"><img src="file://%s" style="width:%.1fcm"></div>'
                        % (path, width_cm)
                    )
                    stats['img'] += 1
            if has_break:
                parts.append('<div class="pb"></div>')
                stats['pb'] += 1
            continue

        text = par.text.rstrip()
        if not text.strip():
            parts.append('<div class="blank"></div>')
            if has_break:
                parts.append('<div class="pb"></div>')
                stats['pb'] += 1
            continue

        # 字号 / 加粗
        sz = None
        bold = False
        for r in par.runs:
            if r.font.size and sz is None:
                sz = r.font.size.pt
            if r.font.bold:
                bold = True
        centered = par.alignment == WD_ALIGN_PARAGRAPH.CENTER

        if sz is not None and sz >= 28:
            cls = 'cover-t'
        elif sz is not None and sz >= 20:
            cls = 'cover-s'
        elif sz is not None and sz >= 14.5:
            cls = 'h1'
            stats['h1'] += 1
        elif sz is not None and sz >= 13:
            cls = 'cover-meta' if centered else 'h2'
        elif sz is not None and sz >= 12.3:
            cls = 'h2'
            stats['h2'] += 1
        elif sz is not None and sz >= 11.3:
            cls = 'toc'
        elif sz is not None and sz <= 10:
            cls = 'cap'
            stats['cap'] += 1
        else:
            cls = 'p'
            if text.strip().startswith('· '):
                cls = 'bullet'
            stats['p'] += 1

        parts.append('<div class="%s">%s</div>' % (cls, esc(text)))
        if has_break:
            parts.append('<div class="pb"></div>')
            stats['pb'] += 1

    css = """
@page { size: A4; margin: 22mm 24mm 20mm 26mm; }
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: "Songti SC", "SimSun", serif; color: #000; }
.cover-t { font-size: 30pt; font-weight: bold; text-align: center; line-height: 2.2; }
.cover-s { font-size: 22pt; font-weight: bold; text-align: center; line-height: 2; }
.cover-meta { font-size: 14pt; text-align: center; line-height: 2; }
.h1 { font-size: 15pt; font-weight: bold; margin: 16pt 0 8pt; page-break-after: avoid; }
.h2 { font-size: 12.5pt; font-weight: bold; margin: 10pt 0 4pt; page-break-after: avoid; }
.p { font-size: 11pt; line-height: 1.45; text-indent: 2em; margin-bottom: 4pt; text-align: justify; }
.bullet { font-size: 11pt; line-height: 1.45; padding-left: 0.9cm; text-indent: -0.35cm; margin-bottom: 3pt; }
.toc { font-size: 11.5pt; line-height: 1.9; }
.cap { font-size: 9.5pt; line-height: 1.4; color: #555; text-align: center; margin: 2pt 0 10pt; }
.fig { text-align: center; margin: 6pt 0 2pt; page-break-inside: avoid; }
.blank { height: 0.6em; }
.pb { page-break-after: always; height: 0; }
img { display: inline-block; max-width: 100%; }
"""
    html_doc = (
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<title>%s %s 软件说明书</title><style>%s</style></head><body>%s</body></html>'
    ) % (SOFT_NAME, SOFT_VER, css, ''.join(parts))

    with open(OUT_HTML, 'w', encoding='utf-8') as fp:
        fp.write(html_doc)
    print('结构统计：图片 %d，一级标题 %d，二级标题 %d，正文 %d，图注 %d，分页 %d'
          % (stats['img'], stats['h1'], stats['h2'], stats['p'], stats['cap'], stats['pb']))
    print('HTML：%s' % OUT_HTML)


if __name__ == '__main__':
    main()
