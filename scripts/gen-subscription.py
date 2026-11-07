#!/usr/bin/env python3
"""
生成「订阅源」JSON：一份文件同时带点播站源（sites）+ 直播源（lives）。

  订阅 = 用户只填一个链接，播放器一次把点播和直播都更新掉。
  产物：docs/store/subscribe.json，上传到 RustFS public 桶后对外提供一个链接。

数据来源（**均不在应用安装包内**，配合应用市场上架合规：影视/直播源只能
由用户主动订阅导入，不能随安装包下发）：
  - sites / parses  —— docs/store/sites.json（订阅源清单）
  - lives           —— 下面 LIVES 列表

用法：
  python3 scripts/gen-subscription.py
"""
import json
import os
import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITES = os.path.join(ROOT, 'docs', 'store', 'sites.json')
OUT_DIR = os.path.join(ROOT, 'docs', 'store')
OUT = os.path.join(OUT_DIR, 'subscribe.json')

GH = 'https://gh-proxy.com/https://raw.githubusercontent.com/'
LIVES = [
    {'name': '央视·IPv4', 'url': GH + 'vbskycn/iptv/master/tv/iptv4.m3u'},
    {'name': '中国频道', 'url': GH + 'iptv-org/iptv/master/streams/cn.m3u'},
    {'name': '国内电视', 'url': GH + 'YueChan/Live/main/GNTV.m3u'},
    {'name': '国内·aptv', 'url': GH + 'Kimentanm/aptv/master/m3u/iptv.m3u'},
    {'name': '国内综合', 'url': GH + 'YueChan/Live/main/IPTV.m3u'},
    {'name': '测速优选', 'url': GH + 'ssili126/tv/main/itvlist.txt'},
    {'name': '央视频道', 'url': GH + 'YueChan/Live/main/CUTV.txt'},
    {'name': '央视·IPv6', 'url': GH + 'fanmingming/live/main/tv/m3u/ipv6.m3u'},
    {'name': '聚合索引', 'url': GH + 'fanmingming/live/main/tv/m3u/index.m3u'},
    {'name': '镜像备用', 'url': 'https://ghproxy.net/https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.m3u'},
]


def main() -> None:
    with open(SITES, 'r', encoding='utf-8') as f:
        base = json.load(f)

    doc = {
        'name': '夜帧影视·订阅源',
        'version': 1,
        'updated': datetime.date.today().isoformat(),
        'sites': base.get('sites', []),
        'parses': base.get('parses', []),
        'lives': LIVES,
    }

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)

    print('站点数  :', len(doc['sites']))
    print('解析器  :', len(doc['parses']))
    print('直播源  :', len(doc['lives']))
    print('产物    :', OUT)
    print('大小    :', os.path.getsize(OUT), 'bytes')


if __name__ == '__main__':
    main()
