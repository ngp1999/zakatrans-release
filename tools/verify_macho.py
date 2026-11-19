#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重排后的 Mach-O 自检：段/节一致性、代码内容、ObjC 元数据指针、加密信息。

用法：python3 verify_macho.py <新二进制> [原二进制]
给了原二进制就逐字节比对 __text（只允许整体平移，不允许内容变化）。
"""
import struct
import sys


def u32(d, o):
    return struct.unpack_from('<I', d, o)[0]


def u64(d, o):
    return struct.unpack_from('<Q', d, o)[0]


class M(object):
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        self.ncmds = u32(self.d, 16)
        self.segs = []
        self.enc = None
        self.entry = None
        off = 32
        for _ in range(self.ncmds):
            cmd = u32(self.d, off)
            size = u32(self.d, off + 4)
            if cmd == 0x19:
                name = self.d[off + 8:off + 24].rstrip(b'\0').decode()
                vm, vs, fo, fs = struct.unpack_from('<QQQQ', self.d, off + 24)
                n = u32(self.d, off + 64)
                secs = {}
                p = off + 72
                for _i in range(n):
                    sn = self.d[p:p + 16].rstrip(b'\0').decode()
                    addr, sz = struct.unpack_from('<QQ', self.d, p + 32)
                    soff = u32(self.d, p + 48)
                    secs[sn] = (addr, sz, soff)
                    p += 80
                self.segs.append({'name': name, 'vm': vm, 'vs': vs, 'fo': fo,
                                  'fs': fs, 'secs': secs})
            elif cmd == 0x2E:
                co, cs, ci = struct.unpack_from('<III', self.d, off + 8)
                self.enc = (co, cs, ci)
            elif cmd == 0x80000028:
                self.entry = u64(self.d, off + 8)
            off += size

    def seg(self, name):
        for s in self.segs:
            if s['name'] == name:
                return s
        return None

    def off_of(self, vmaddr):
        for s in self.segs:
            if s['vm'] <= vmaddr < s['vm'] + max(s['vs'], s['fs']):
                return s['fo'] + (vmaddr - s['vm'])
        return None

    def cstr(self, vmaddr, limit=256):
        o = self.off_of(vmaddr)
        if o is None:
            return None
        e = self.d.find(b'\0', o, o + limit)
        if e < 0:
            return None
        try:
            return self.d[o:e].decode('utf-8')
        except UnicodeDecodeError:
            return None


def check(path, orig=None):
    problems = []
    m = M(path)

    # 1. 段与节
    for s in m.segs:
        if s['name'] == '__PAGEZERO':
            continue
        if s['fo'] % 0x4000 != s['vm'] % 0x4000:
            problems.append('%s 段 fileoff 与 vmaddr 页内偏移不一致' % s['name'])
        if s['fo'] + s['fs'] > len(m.d):
            problems.append('%s 段文件范围超出文件' % s['name'])
        for sn, (addr, sz, soff) in s['secs'].items():
            if sn == '__bss' or not soff:
                continue
            if sz and addr - s['vm'] != soff - s['fo']:
                problems.append('%s,%s 节 addr 与 offset 不对应' % (s['name'], sn))
            if sz and soff + sz > len(m.d):
                problems.append('%s,%s 节超出文件' % (s['name'], sn))

    text = m.seg('__TEXT')
    if not text:
        return ['没有 __TEXT 段']
    first_addr, first_sz, first_off = text['secs']['__text']
    if first_off < 0x4000:
        problems.append('__text 偏移 %#x 仍在第 0 页' % first_off)
    if text['fs'] % 0x4000:
        problems.append('__TEXT filesize %#x 不是整页' % text['fs'])
    if text['vs'] % 0x4000:
        problems.append('__TEXT vmsize %#x 不是整页' % text['vs'])
    for s in m.segs:
        if s['name'] not in ('__PAGEZERO', '__TEXT') and \
                text['vm'] + text['vs'] > s['vm'] and s['vm'] > text['vm']:
            problems.append('__TEXT 与 %s 虚拟地址重叠' % s['name'])

    # 2. 入口
    if m.entry is not None:
        if not (text['fo'] <= m.entry < text['fo'] + text['fs']):
            problems.append('入口 %#x 不在 __text 内' % m.entry)
        else:
            insn = u32(m.d, m.entry)
            # ARM64 函数序言常见：sub sp / stp / pacibsp / mov
            if insn == 0:
                problems.append('入口处是 0（非法指令）')

    # 3. 加密信息
    if not m.enc:
        problems.append('缺 LC_ENCRYPTION_INFO_64')
    else:
        co, cs, ci = m.enc
        if co != 0x4000:
            problems.append('cryptoff = %#x（应为 0x4000）' % co)
        if ci != 0:
            problems.append('cryptid = %d（应为 0）' % ci)
        if co + cs > text['fs']:
            problems.append('加密范围 %#x+%#x 超出 __TEXT %#x' % (co, cs, text['fs']))
        if co + cs != text['fs']:
            problems.append('加密末端 %#x ≠ __TEXT 末尾 %#x' % (co + cs, text['fs']))

    # 4. ObjC 类结构（顺着 classlist 读，验证指针都指向合法位置）
    classlist = None
    for s in m.segs:
        if '__objc_classlist' in s['secs']:
            classlist = (s, s['secs']['__objc_classlist'])
    names = []
    if classlist:
        seg, (addr, sz, soff) = classlist
        for i in range(0, sz, 8):
            cls = u64(m.d, soff + i)
            co = m.off_of(cls)
            if co is None:
                problems.append('类 %d 指针 %#x 不可解析' % (i // 8, cls))
                continue
            # class_data_bits_t 指向 class_ro_t（静态 exe 里没有 rw 层）
            ro = u64(m.d, co + 0x20) & 0x00007FFFFFFFFFF8
            roo = m.off_of(ro)
            if roo is None:
                problems.append('类 %d data 指针 %#x 不可解析' % (i // 8, ro))
                continue
            nm = m.cstr(u64(m.d, roo + 0x18))
            if not nm:
                problems.append('类 %d 名字读不出来' % (i // 8))
            else:
                names.append(nm)
    if classlist and not names:
        problems.append('一个类名都没读出来')

    # 5. 与原文件逐字节比对 __text
    if orig:
        mo = M(orig)
        t2 = mo.seg('__TEXT')
        a2, s2, o2 = t2['secs']['__text']
        if m.d[first_off:first_off + first_sz] != mo.d[o2:o2 + s2]:
            problems.append('__text 内容与原文件不一致（代码被改动了）')
        # 其余节同样比对
        for sn, (addr, sz, soff) in text['secs'].items():
            if sn == '__text' or not sz:
                continue
            if sn not in t2['secs']:
                continue
            a2, s2b, o2b = t2['secs'][sn]
            if sz != s2b or m.d[soff:soff + sz] != mo.d[o2b:o2b + s2b]:
                problems.append('%s 内容与原文件不一致' % sn)

    return problems, names


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    orig = sys.argv[2] if len(sys.argv) > 2 else None
    problems, names = check(path, orig)
    print('类：%s' % (', '.join(names[:12]) + (' …' if len(names) > 12 else '') if names else '（无）'))
    if problems:
        print('❌ %d 个问题：' % len(problems))
        for p in problems:
            print('   - ' + p)
        return 1
    print('✅ 结构自检全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
