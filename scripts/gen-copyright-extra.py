#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成软著登记的「其他相关证明文件」PDF 模板。

产出（docs/copyright/）：
  夜帧影视_材料清单与封面.pdf     提交材料总清单，装袋/上传时核对用
  夜帧影视_代理委托书.pdf         委托代理机构时用（填空 + 签字）
  夜帧影视_非职务开发声明.pdf     自然人申请备用（审查员要求时提交）

身份证明（身份证正反面）无法代生成，需本人拍照导出 PDF。

流程：Python 渲染 A4 HTML → scripts/cdp-print-pdf.mjs 用 Chrome CDP 打印。
这些文档纯文字无图，CDP 打印秒级完成。
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, 'docs', 'copyright')

SOFT_NAME = '夜帧影视软件'
SOFT_VER = 'V1.0'
AUTHOR = '夏小力'

CSS = """
@page { size: A4; }
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: "Songti SC", "SimSun", serif; color: #000; font-size: 11pt; line-height: 1.62; }
.title { font-size: 19pt; font-weight: bold; text-align: center; letter-spacing: 4pt;
         margin: 2pt 0 2pt; }
.sub { font-size: 10.5pt; text-align: center; color: #333; margin-bottom: 12pt; }
.h { font-size: 12pt; font-weight: bold; margin: 10pt 0 3pt; }
.p { text-indent: 2em; margin-bottom: 4pt; text-align: justify; }
.p0 { margin-bottom: 4pt; text-align: justify; }
.li { padding-left: 1.2em; text-indent: -1.2em; margin-bottom: 2.5pt; text-align: justify; }
table { width: 100%; border-collapse: collapse; margin: 6pt 0 4pt; font-size: 9.8pt; }
th, td { border: 0.6pt solid #000; padding: 3.6pt 5pt; vertical-align: top; line-height: 1.45; }
th { background: #f0f0f0; font-weight: bold; text-align: center; }
td.c { text-align: center; }
.sign { margin-top: 22pt; }
.sign .row { margin-bottom: 11pt; font-size: 11pt; }
.fill { display: inline-block; border-bottom: 0.6pt solid #000; min-width: 150pt; }
.note { font-size: 9pt; color: #444; margin-top: 8pt; line-height: 1.55; }
.pb { page-break-after: always; height: 0; }
"""


def html(title, body):
    # 源码里的换行只是为了让模板可读，折进 HTML 会变成多余空格（中文排版里尤其明显），
    # 这里统一折掉；标签本身完整、不跨行，去掉换行不影响结构。
    body = body.replace('\n', '')
    return (
        '<!DOCTYPE html><html><head><meta charset="utf-8"><title>%s</title>'
        '<style>%s</style></head><body>%s</body></html>' % (title, CSS, body)
    )


# ---------------- 1. 材料清单与封面 ----------------
def doc_checklist():
    rows = [
        ('1', '计算机软件著作权登记申请表', '1 份', '线上填报后打印，本人签字',
         '登记系统导出'),
        ('2', '程序鉴别材料（源程序）', '60 页', '前 30 页 + 后 30 页，每页 50 行',
         '夜帧影视_源程序.pdf'),
        ('3', '文档鉴别材料（软件说明书）', '21 页', '图文说明，19 张插图',
         '夜帧影视_软件说明书.pdf'),
        ('4', '身份证明', '1 份', '身份证正反面复印件，同一页', '本人自备 PDF'),
        ('5', '代理委托书', '1 份', '仅委托代理机构时提交', '夜帧影视_代理委托书.pdf'),
        ('6', '非职务开发声明', '1 份', '备用，审查员要求时提交', '夜帧影视_非职务开发声明.pdf'),
    ]
    trs = ''.join(
        '<tr><td class="c">%s</td><td>%s</td><td class="c">%s</td><td>%s</td><td>%s</td></tr>' % r
        for r in rows
    )
    tpl = """
<div class="title">计算机软件著作权登记</div>
<div class="sub">提 交 材 料 清 单</div>

<table>
  <tr>
    <td class="c" style="width:16%">软件全称</td><td style="width:34%">{{SOFT}}</td>
    <td class="c" style="width:16%">版本号</td><td style="width:34%">{{VER}}</td>
  </tr>
  <tr>
    <td class="c">软件简称</td><td>夜帧影视</td>
    <td class="c">著作权人</td><td>{{AUTHOR}}（自然人）</td>
  </tr>
  <tr>
    <td class="c">开发方式</td><td>独立开发</td>
    <td class="c">权利取得方式</td><td>原始取得（全部权利）</td>
  </tr>
</table>

<div class="h">一、材料清单</div>
<table>
  <tr>
    <th style="width:6%">序号</th>
    <th style="width:26%">材料名称</th>
    <th style="width:10%">数量</th>
    <th style="width:32%">要求</th>
    <th style="width:26%">对应文件</th>
  </tr>
  {{ROWS}}
</table>

<div class="h">二、格式与装订要求</div>
<div class="li">1. 除申请表外，全部材料以 <b>PDF</b> 形式提交（线上系统上传）；纸质递交时用 A4 纸单面打印。</div>
<div class="li">2. 源程序与说明书页眉均已标注「{{SOFT}} {{VER}}」，页脚为连续页码，无需再手工添加。</div>
<div class="li">3. 身份证明需正反面合并为 1 页 PDF，图像清晰、四角完整、无遮挡。</div>
<div class="li">4. 申请表提交后打印，由著作权人<b>本人手写签字</b>，扫描为 PDF 一并上传。</div>
<div class="li">5. 全部材料按上表序号顺序排列，便于核对。</div>

<div class="h">三、提交前自检</div>
<div class="li">□ 申请表中的软件全称、版本号与源程序/说明书页眉完全一致</div>
<div class="li">□ 源程序 60 页、每页 50 行，第 31 页首行有省略说明</div>
<div class="li">□ 说明书页码连续、插图清晰、图号与正文引用对应</div>
<div class="li">□ 源程序量、开发完成日期等字段与实际一致</div>
<div class="li">□ 身份证在有效期内</div>

<div class="note">
说明：第 5、6 项为条件性材料——不委托代理机构则无需委托书；非职务开发声明通常不提交，
仅在审查员对权属提出问询时补充。本清单由项目脚本 scripts/gen-copyright-extra.py 生成。
</div>
"""
    body = (tpl.replace('{{SOFT}}', SOFT_NAME)
               .replace('{{VER}}', SOFT_VER)
               .replace('{{AUTHOR}}', AUTHOR)
               .replace('{{ROWS}}', trs))
    return html('计算机软件著作权登记 提交材料清单', body)


# ---------------- 2. 代理委托书 ----------------
def doc_poa():
    body = """
<div class="title">代 理 委 托 书</div>
<div class="sub">计算机软件著作权登记</div>

<div class="p0">中国版权保护中心：</div>

<div class="p">本人 <span class="fill" style="min-width:90pt"></span>（身份证号：
<span class="fill" style="min-width:210pt"></span>），系软件「%s %s」
（以下简称“本软件”）的著作权人。现委托
<span class="fill" style="min-width:170pt"></span>
代为办理本软件著作权登记的相关事宜。</div>

<div class="h">一、委托事项</div>
<div class="li">1. 提交软件著作权登记申请，填报、修改申请信息；</div>
<div class="li">2. 提交、补正程序鉴别材料与文档鉴别材料；</div>
<div class="li">3. 接收中国版权保护中心发出的各类通知、补正通知书；</div>
<div class="li">4. 领取《计算机软件著作权登记证书》并转交委托人；</div>
<div class="li">5. 办理与本软件登记有关的其他手续。</div>

<div class="h">二、代理权限</div>
<div class="p0">□ 一般代理　　□ 特别授权（含代为补正、代为签收文书、代为领取证书）</div>

<div class="h">三、委托期限</div>
<div class="p">自本委托书签署之日起，至上述登记事项办结（证书交付或申请终止）之日止。</div>

<div class="h">四、其他</div>
<div class="p">受托人在上述权限范围内所实施的行为，委托人予以认可，由此产生的法律后果由委托人承担。
本委托书一式两份，委托人与受托人各执一份，具有同等效力。</div>

<div class="sign">
  <div class="row">委托人（签字）：<span class="fill" style="min-width:150pt"></span></div>
  <div class="row">身份证号：<span class="fill" style="min-width:230pt"></span></div>
  <div class="row">联系电话：<span class="fill" style="min-width:200pt"></span></div>
  <div class="row">受托人（盖章）：<span class="fill" style="min-width:150pt"></span></div>
  <div class="row">签署日期：<span class="fill" style="min-width:60pt"></span> 年
    <span class="fill" style="min-width:40pt"></span> 月
    <span class="fill" style="min-width:40pt"></span> 日</div>
</div>

<div class="note">
填写提示：仅委托代理机构时使用，个人自行办理无需提交。委托人须本人手写签字（不可代签、
不可用签名图片）；受托人须为代理机构并加盖公章。签字后扫描为 PDF 上传。
</div>
""" % (SOFT_NAME, SOFT_VER)
    return html('代理委托书', body)


# ---------------- 3. 非职务开发声明 ----------------
def doc_statement():
    body = """
<div class="title">非 职 务 软 件 开 发 声 明</div>
<div class="sub">计算机软件著作权登记</div>

<div class="p">本人 <span class="fill" style="min-width:90pt"></span>（身份证号：
<span class="fill" style="min-width:210pt"></span>），系软件「%s %s」
（以下简称“本软件”）的开发者与著作权人。就本软件的开发性质，郑重声明如下：</div>

<div class="h">一、开发情形</div>
<div class="p">本软件系本人利用业余时间、以个人自有设备独立开发完成，开发过程未使用任何单位的
物质技术条件（包括资金、设备、场地、未公开的技术资料等），亦未接受任何单位的任务指派
或研发委托。</div>

<div class="h">二、非职务作品</div>
<div class="p">本软件的开发不属于本人任职单位的本职工作范围，与本人所在岗位职责无关联，
不构成《计算机软件保护条例》第十三条所称的职务软件。</div>

<div class="h">三、权属状况</div>
<div class="p">本软件的全部著作权（含发表权、署名权、修改权、复制权、发行权、信息网络传播权等）
归本人单独享有，不存在合作开发、委托开发、职务开发或权利转让情形，不存在任何权属争议
或权利负担。</div>

<div class="h">四、责任承担</div>
<div class="p">本人保证上述声明内容真实、准确。如声明不实，本人愿承担由此产生的一切法律责任，
并接受登记机构依据相关规定作出的处理。</div>

<div class="sign">
  <div class="row">声明人（签字）：<span class="fill" style="min-width:150pt"></span></div>
  <div class="row">身份证号：<span class="fill" style="min-width:230pt"></span></div>
  <div class="row">联系电话：<span class="fill" style="min-width:200pt"></span></div>
  <div class="row">声明日期：<span class="fill" style="min-width:60pt"></span> 年
    <span class="fill" style="min-width:40pt"></span> 月
    <span class="fill" style="min-width:40pt"></span> 日</div>
</div>

<div class="note">
使用提示：本声明为<b>备用材料</b>，正常申请流程无需提交；当审查员对本软件是否属于
职务软件、权属是否清晰提出问询时，按要求补交。签署前请确认声明内容与实际开发情形一致。
</div>
""" % (SOFT_NAME, SOFT_VER)
    return html('非职务软件开发声明', body)


DOCS = [
    ('夜帧影视_材料清单与封面', '计算机软件著作权登记 提交材料清单', doc_checklist),
    ('夜帧影视_代理委托书', '代理委托书', doc_poa),
    ('夜帧影视_非职务开发声明', '非职务软件开发声明', doc_statement),
]


def main():
    if not os.path.isdir(OUT_DIR):
        sys.exit('目录不存在：' + OUT_DIR)
    node = os.path.join(ROOT, 'scripts', 'cdp-print-pdf.mjs')
    for name, header, fn in DOCS:
        html_path = os.path.join(OUT_DIR, name + '.html')
        pdf_path = os.path.join(OUT_DIR, name + '.pdf')
        with open(html_path, 'w', encoding='utf-8') as f:
            f.write(fn())
        print('→ 生成 HTML：%s' % os.path.basename(html_path))
        r = subprocess.run(
            ['node', node, html_path, pdf_path, header],
            cwd=ROOT, capture_output=True, text=True,
        )
        if r.returncode != 0:
            print(r.stdout[-800:])
            print(r.stderr[-800:])
            sys.exit('✗ 打印失败：' + name)
        size = os.path.getsize(pdf_path) / 1024
        print('  ✓ PDF：%s (%.0f KB)' % (os.path.basename(pdf_path), size))


if __name__ == '__main__':
    main()
