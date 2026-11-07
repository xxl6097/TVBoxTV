#!/usr/bin/env python3
# 校验「软著材料」与当前代码是否一致。
#
# 为什么需要它：软著材料是脚本生成的，代码改了却忘了重跑脚本，材料就会过期，
# 而这类问题从界面上完全看不出来 —— 提交后才发现说明书写的功能已经变了，
# 只能撤回重报。这里把「该对齐的东西」变成可执行的检查：
#   · 源程序文档 60 页、每页 50 行、页眉含软件名与版本
#   · 说明书含全部功能小节、截图张数够、页眉一致
#   · 申请表里的「源程序量」与实际代码行数一致
#   · 两份 docx 不比最新改动的源码文件旧
#
# 退出码：0 全部通过（可能有警告）；1 有必须处理的问题。

import glob
import os
import re
import sys

from docx import Document

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, 'docs', 'copyright')
SRC_DOC = os.path.join(DOCS, '夜帧影视_源程序.docx')
MAN_DOC = os.path.join(DOCS, '夜帧影视_软件说明书.docx')
FORM = os.path.join(DOCS, '软著申请表填写信息.md')

FAILS = []
WARNS = []


def fail(t):
    FAILS.append(t)
    print('  ✗ ' + t)


def warn(t):
    WARNS.append(t)
    print('  ! ' + t)


def ok(t):
    print('  ✓ ' + t)


def code_stats():
    files = sorted(glob.glob(os.path.join(ROOT, 'entry/src/main/ets/**/*.ets'), recursive=True))
    nonblank = 0
    newest = 0.0
    for f in files:
        for ln in open(f, encoding='utf-8'):
            if ln.strip():
                nonblank += 1
        newest = max(newest, os.path.getmtime(f))
    return files, nonblank, newest


def docx_pages(path):
    """按「手动分页」切页，返回每页的段落文本列表。"""
    d = Document(path)
    pages, cur = [], []
    for p in d.paragraphs:
        page_break = p.text.strip() == '' and 'type="page"' in p._p.xml and 'w:br' in p._p.xml
        if page_break:
            pages.append(cur)
            cur = []
        elif p.text.strip() == '' and not cur:
            continue
        else:
            cur.append(p.text)
    if cur:
        pages.append(cur)
    return d, pages


# 提交材料里不该出现的词。前两类是「生态/品牌指向」，第三类是「预设已上架」的表述，
# 会与申请表的「首次发表日期：未发表」自相矛盾。
RISK_WORDS = ['站源', '直播源', 'TVBox', 'csp', 'jar', '爬虫', '采集接口', '订阅',
              '苹果CMS', 'MacCMS']
BRAND_WORDS = ['量子', '金鹰', '番茄', '暴风', '速播', '红牛', '非凡', '最大',
               'Guovin', 'iptv-org', 'jinying', 'lziapi', 'lovedan']
PUBLISH_WORDS = ['在华为应用市场搜索', '点击安装即可']


def _visible_text(html_path):
    """把生成的 HTML 去标签、压缩空白，得到正文文本。"""
    if not os.path.isfile(html_path):
        return ''
    h = open(html_path, encoding='utf-8').read()
    t = re.sub(r'<[^>]+>', '', h)
    return re.sub(r'\s+', ' ', t)


def risk_checks():
    """内容层面的降险检查：指向性词汇、品牌名、与申请表口径的矛盾。"""
    src_html = os.path.join(DOCS, '夜帧影视_源程序.html')
    man_html = os.path.join(DOCS, '夜帧影视_软件说明书.html')

    # ---- 源程序：只提交前后各 30 页，这两段必须干净 ----
    if os.path.isfile(src_html):
        h = open(src_html, encoding='utf-8').read()
        pages = [re.sub(r'<[^>]+>', '', x) for x in re.split(r'<div class="page">', h)[1:]]
        if len(pages) >= 60:
            bad = []
            for rng, label in ((range(0, 30), '前 30 页'), (range(30, 60), '后 30 页')):
                for i in rng:
                    n = sum(pages[i].count(w) for w in RISK_WORDS)
                    if n:
                        bad.append('%s第 %d 页 %d 次' % (label, i + 1, n))
            if bad:
                fail('源程序提交页出现指向性词汇：' + '、'.join(bad[:6]))
            else:
                ok('源程序前后 30 页无指向性词汇（取材顺序见 copyright_order.py）')
        else:
            warn('源程序 HTML 不足 60 页，跳过扫描')

    # ---- 说明书：不出现生态标签与第三方站名 ----
    man = _visible_text(man_html)
    if man:
        hard = [w for w in ('TVBox', '苹果CMS', 'MacCMS') if w in man]
        if hard:
            fail('说明书出现生态/品牌指向词：' + '、'.join(hard))
        else:
            ok('说明书无 TVBox / 苹果CMS 等生态标签')
        hit = [w for w in BRAND_WORDS if w in man]
        if hit:
            warn('说明书正文出现疑似第三方站名：' + '、'.join(hit))
        else:
            ok('说明书无第三方站名（量子/金鹰/番茄等）')
        if '内容来源与使用边界' not in man:
            warn('说明书缺少「内容来源与使用边界」一节（建议保留，用于说明包内不含内容）')

    # ---- 与申请表口径的一致性 ----
    if os.path.isfile(FORM):
        form = open(FORM, encoding='utf-8').read()
        unpublished = '首次发表日期' in form and '未发表' in form
        if unpublished and man:
            # 「应用市场上架后，也可在…搜索安装」这类带前置条件的表述是合规的，
            # 只有把「已可下载安装」当既成事实来写，才与「未发表」冲突。
            bad = []
            for w in PUBLISH_WORDS:
                for m in re.finditer(re.escape(w), man):
                    ctx = man[max(0, m.start() - 40):m.start()]
                    if '上架后' not in ctx and '上架之后' not in ctx:
                        bad.append(w)
                        break
            if bad:
                fail('申请表填「未发表」，但说明书把「%s」写成既成事实' % bad[0])
            else:
                ok('说明书安装说明与「首次发表日期」口径一致（已注明「上架后」）')
        elif not unpublished:
            warn('申请表未写「未发表」，请核对首次发表日期是否为实际日期')


def main():
    files, nonblank, newest_src = code_stats()
    print('  代码：%d 个 ArkTS 文件，%d 行非空' % (len(files), nonblank))

    for p in (SRC_DOC, MAN_DOC, FORM):
        if not os.path.isfile(p):
            fail('缺少材料：%s' % os.path.relpath(p, ROOT))

    # ---------- 源程序 ----------
    if os.path.isfile(SRC_DOC):
        d, pages = docx_pages(SRC_DOC)
        if len(pages) != 60:
            fail('源程序为 %d 页，登记要求 60 页（前 30 + 后 30）' % len(pages))
        else:
            ok('源程序 60 页')
        # 第 31 页（下标 30）首行是「此处省略 N 页」的说明，也算 1 行，
        # 所以每页的段落数都应当是 50
        bad = [(i + 1, len(pg)) for i, pg in enumerate(pages) if len(pg) != 50]
        if not bad and not pages[30][0].startswith('// ……'):
            bad.append((31, 'L2 缺少省略说明'))
        if bad:
            fail('页行数不符合 50 行：%s' % bad[:6])
        else:
            ok('每页 50 行（第 31 页首行为省略说明 + 49 行源码）')
        head = '\n'.join(p.text for p in d.sections[0].header.paragraphs)
        if '夜帧影视软件' not in head or 'V1.0' not in head:
            fail('源程序页眉缺软件名或版本号：%r' % head.strip())
        else:
            ok('源程序页眉：%s' % head.strip())

    # ---------- 说明书 ----------
    if os.path.isfile(MAN_DOC):
        m, mps = docx_pages(MAN_DOC)
        txt = '\n'.join(p.text for p in m.paragraphs)
        figs = [p.text.strip() for p in m.paragraphs if p.text.strip().startswith('图 ')]
        if len(m.inline_shapes) < 18:
            fail('说明书只有 %d 张图，至少 18 张（含应用图标）才够说明功能'
                 % len(m.inline_shapes))
        else:
            ok('说明书 %d 张插图 / %d 条图注' % (len(m.inline_shapes), len(figs)))
        # 图标必须出现在说明书里：它是软件外观的一部分，登记时审查员会对照
        if '图 3-1' in txt and '应用图标' in txt:
            ok('应用图标已写入 3.1 安装（图 3-1）')
        else:
            fail('说明书缺应用图标小节（3.1 的图 3-1）')
        need = ['5.2  刷新与缓存', '5.3  父分类的汇总显示', '5.8  观看历史',
                '10.1  设置页', '14  版本记录']
        miss = [k for k in need if k not in txt]
        if miss:
            fail('说明书缺小节：%s' % '、'.join(miss))
        else:
            ok('关键小节齐全（缓存 / 父分类 / 历史 / 设置 / 版本记录）')
        head = '\n'.join(p.text for p in m.sections[0].header.paragraphs)
        if '夜帧影视软件' not in head or 'V1.0' not in head:
            fail('说明书页眉缺软件名或版本号：%r' % head.strip())

        # 图号必须按章连续（插一张图后忘了顺延编号，是最容易出的错）
        dup, bad_seq = [], []
        last = (0, 0)
        for cap in figs:
            m2 = re.match(r'图 (\d+)-(\d+)', cap)
            if not m2:
                continue
            ch, no = int(m2.group(1)), int(m2.group(2))
            if (ch, no) in dup:
                bad_seq.append('图 %d-%d 重复' % (ch, no))
            dup.append((ch, no))
            if ch == last[0] and no != last[1] + 1:
                bad_seq.append('图 %d-%d 前应为 %d-%d' % (ch, no, ch, last[1] + 1))
            last = (ch, no)
        if bad_seq:
            fail('图号不连续：%s' % '、'.join(bad_seq[:4]))
        else:
            ok('图号连续（共 %d 条，按章编号）' % len(figs))

    # ---------- 申请表 ----------
    if os.path.isfile(FORM):
        s = open(FORM, encoding='utf-8').read()
        m = re.search(r'源程序量 \| ([0-9]+) 行（[^）]*?(\d+) 个', s)
        if not m:
            warn('申请表里没找到「源程序量」一栏，跳过行数比对')
        else:
            stated, nfiles = int(m.group(1)), int(m.group(2))
            if stated != nonblank or nfiles != len(files):
                fail('申请表写 %d 行 / %d 个文件，实际 %d 行 / %d 个文件'
                     % (stated, nfiles, nonblank, len(files)))
            else:
                ok('申请表源程序量与实际一致（%d 行 / %d 文件）' % (nonblank, len(files)))
        if '## 十一、功能改动与材料的对应关系' not in s:
            warn('申请表缺少「功能 → 材料」对应表')

    risk_checks()

    # ---------- 新鲜度 ----------
    for p, name in ((SRC_DOC, '源程序'), (MAN_DOC, '说明书')):
        if os.path.isfile(p) and os.path.getmtime(p) < newest_src - 1:
            fail('%s比最新改动过的源码旧，需重跑生成脚本' % name)
    if not FAILS and not WARNS:
        ok('两份 docx 均不早于最新源码改动')

    print()
    if FAILS:
        print('  结论：%d 项必须处理（重跑 python3 scripts/gen-copyright.py 与 gen-manual.py）' % len(FAILS))
        return 1
    print('  结论：软著材料与当前代码一致%s' % ('（%d 条提醒）' % len(WARNS) if WARNS else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
