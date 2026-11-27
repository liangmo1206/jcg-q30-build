#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
去掉 PassWall 状态页里那个 Instagram 连接检测块。

luci-app-passwall 4.68 的 view/passwall/global/status.htm 在「基本设置」顶部
硬编码了 4 个连接检测块（百度 / 谷歌 / GitHub / Instagram），每块都是一个
<div class="pure-u-1-4 check" onclick="check_connect('xxx', 'url')">，
里面内嵌 base64 图标，所以整文件 600KB+，不适合用 files/ 覆盖。

Instagram 在国内无法直连，这个检测必然失败、常驻红点，属于无效提示。
本脚本把整块删掉，并把剩下的三块从 1/4 宽改成 1/3 宽，保持一行排满。

只用标准库，按 <div>/</div> 配平定位，不依赖行号。
"""
import sys, io, re

def find_block(text, marker):
    """返回 (start, end)：包含 marker 的那个顶层 <div ...> 块。"""
    i = text.find(marker)
    if i < 0:
        return None
    # 往回找这个块的起始 <div
    start = text.rfind('<div', 0, i)
    if start < 0:
        return None
    # 从 start 开始做 <div>/</div> 配平
    depth = 0
    j = start
    n = len(text)
    while j < n:
        o = text.find('<div', j)
        c = text.find('</div', j)
        if c < 0:
            return None
        if 0 <= o < c:
            depth += 1
            j = o + 4
        else:
            depth -= 1
            j = c + 5
            if depth == 0:
                end = text.find('>', c)
                if end < 0:
                    return None
                return start, end + 1
    return None

def main(path):
    with io.open(path, encoding='utf-8') as f:
        src = f.read()

    before_div = src.count('<div')
    before_end = src.count('</div>')

    blk = find_block(src, "check_connect('instagram'")
    if not blk:
        print('  跳过：没有找到 instagram 检测块（可能上游已删）')
        return 0

    start, end = blk
    # 连同前面的空白/换行一起删掉，避免留下空行
    s0 = start
    while s0 > 0 and src[s0-1] in ' \t':
        s0 -= 1
    if s0 > 0 and src[s0-1] == '\n':
        s0 -= 1

    removed = end - s0
    out = src[:s0] + src[end:]

    # 剩下的三块改成一行的 1/3
    out = out.replace('pure-u-1-4 check', 'pure-u-1-3 check')

    after_div = out.count('<div')
    after_end = out.count('</div>')

    if 'instagram' in out:
        print('  ❌ 仍有 instagram 残留')
        return 1
    if before_div - after_div != before_end - after_end:
        print('  ❌ div 标签不配平：<div %d->%d, </div> %d->%d'
              % (before_div, after_div, before_end, after_end))
        return 1

    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(out)

    print('  删除 %d 字节' % removed)
    print('  <div> %d -> %d , </div> %d -> %d （同步减少，配平正常）'
          % (before_div, after_div, before_end, after_end))
    tiles = re.findall(r"check_connect\('([a-z]+)'", out)
    print('  剩余检测块 %d 个 %s，宽度类 pure-u-1-3 check 出现 %d 次'
          % (len(tiles), tiles, out.count('pure-u-1-3 check')))
    return 0

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: passwall-patch.py <status.htm>')
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
