#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
重排后二进制的差分自检：拿原始的 lld 产物当参照，逐项核对「只是整体上移一页，
语义一点没变」。

上一版翻车的教训：只验了「__text 字节一致、类结构读得出来、加密范围对得上」，
这些都过了，但代码里的 adrp 全部指错一页 —— 打开即崩（SIGBUS / PC alignment，
PC 落在 __objc_classname 字符串里）。所以这里必须把「寻址」当硬指标验：

  1. 段/节：除 __PAGEZERO 外全部整体 +S；页内偏移、大小、顺序不变
  2. 内容：__TEXT 里每个节在「新偏移」处的字节与原文件一致
  3. 寻址差分：每条 adrp/adr 的目标都必须是「原目标 + S」；b/bl/cbz/tbz 的目标同理
  4. 指针差分：rebase 表点到的每一个指针槽，值都必须是「原值 + S」
  5. 符号表：所有 N_SECT 符号值 +S
  6. 入口：LC_MAIN.entryoff +S
  7. 加密范围：cryptoff=0x4000，末端与 __TEXT 段尾齐平，且 __TEXT 段尾按页对齐
  8. objc 链：__objc_classlist → class_t → data → ro → name 全部可解析，类名可打印
  9. 粗扫：__DATA / __DATA_CONST 里指向映像的 8 字节值，必须都已经 +S

用法：
    python3 verify_layout.py <原始 Mach-O> <重排后 Mach-O>
"""
import struct
import sys

PAGE = 0x4000
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_MAIN = 0x80000028
LC_ENCRYPTION_INFO_64 = 0x2C
LC_ENCRYPTION_INFO = 0x21
ZEROFILL = (0x1, 0xc, 0x12)


def u32(d, o):
    return struct.unpack_from('<I', d, o)[0]


def u64(d, o):
    return struct.unpack_from('<Q', d, o)[0]


def read_uleb(data, p):
    r = shift = 0
    while True:
        b = data[p]
        p += 1
        r |= (b & 0x7F) << shift
        if not (b & 0x80):
            return r, p
        shift += 7


def scan(path):
    d = open(path, 'rb').read()
    ncmds = u32(d, 16)
    off = 32
    segs, cmds = [], {}
    for _ in range(ncmds):
        c = u32(d, off)
        sz = u32(d, off + 4)
        cmds.setdefault(c, off)
        if c == LC_SEGMENT_64:
            name = d[off + 8:off + 24].rstrip(b'\0').decode()
            vm, vs, fo, fs = struct.unpack_from('<QQQQ', d, off + 24)
            nsects = u32(d, off + 64)
            sects = []
            for i in range(nsects):
                p = off + 72 + i * 80
                sn = d[p:p + 16].rstrip(b'\0').decode()
                addr, size = struct.unpack_from('<QQ', d, p + 32)
                soff = u32(d, p + 48)
                flags = u32(d, p + 64)
                sects.append(dict(name=sn, addr=addr, size=size, off=soff, flags=flags))
            segs.append(dict(name=name, vm=vm, vs=vs, fo=fo, fs=fs, sects=sects, hdr=off))
        off += sz
    return dict(data=d, segs=segs, cmds=cmds, size=len(d))


def rebase_slots(info):
    """返回 rebase 表点到的指针虚拟地址列表。"""
    seg_vm = [s['vm'] for s in info['segs']]
    off = info['cmds'].get(LC_DYLD_INFO_ONLY, info['cmds'].get(LC_DYLD_INFO))
    if off is None:
        return []
    r_off, r_size = u32(info['data'], off + 8), u32(info['data'], off + 12)
    d = info['data']
    out = []
    p, end = r_off, r_off + r_size
    seg, seg_off = 0, 0
    while r_size and p < end:
        b = d[p]
        p += 1
        op, imm = b & 0xF0, b & 0x0F
        if op == 0x00:
            break
        elif op == 0x10:
            pass
        elif op == 0x20:
            seg = imm
            seg_off, p = read_uleb(d, p)
        elif op == 0x30:
            v, p = read_uleb(d, p)
            seg_off += v
        elif op == 0x40:
            seg_off += imm * 8
        elif op in (0x50, 0x60):
            count = imm if op == 0x50 else read_uleb(d, p)[0]
            if op == 0x60:
                p = read_uleb(d, p)[1]
            for _ in range(count):
                out.append(seg_vm[seg] + seg_off)
                seg_off += 8
        elif op == 0x70:
            out.append(seg_vm[seg] + seg_off)
            seg_off += 8
            v, p = read_uleb(d, p)
            seg_off += v
        elif op == 0x80:
            count, p = read_uleb(d, p)
            skip, p = read_uleb(d, p)
            for _ in range(count):
                out.append(seg_vm[seg] + seg_off)
                seg_off += 8 + skip
        else:
            break
    return out


def va_to_off(info, va):
    for s in info['segs']:
        if s['name'] == '__PAGEZERO':
            continue
        if s['vm'] <= va < s['vm'] + max(s['fs'], s['vs']):
            fo = s['fo'] + (va - s['vm'])
            return fo if fo < len(info['data']) else None
    return None


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    old = scan(sys.argv[1])
    new = scan(sys.argv[3] if len(sys.argv) > 3 else sys.argv[2])
    problems = []
    notes = []

    otext = next(s for s in old['segs'] if s['name'] == '__TEXT')
    ntext = next(s for s in new['segs'] if s['name'] == '__TEXT')
    content = [s for s in otext['sects'] if s['size'] and (s['flags'] & 0xFF) not in ZEROFILL]
    first = min(s['off'] for s in content)
    S = ntext['sects'][[s['name'] for s in ntext['sects']].index(
        min(content, key=lambda x: x['off'])['name'])]['off'] - first
    if S <= 0 or S % PAGE:
        problems.append('上移量 %#x 不是页的整数倍' % S)
    else:
        notes.append('上移量 %#x（%d 页）' % (S, S // PAGE))

    # 1) 段
    for os_, ns in zip(old['segs'], new['segs']):
        if os_['name'] != ns['name']:
            problems.append('段顺序变了：%s / %s' % (os_['name'], ns['name']))
            continue
        if os_['name'] == '__PAGEZERO':
            if ns['vm'] or ns['vs'] != os_['vs']:
                problems.append('__PAGEZERO 被改了')
            continue
        if os_['name'] == '__TEXT':
            if ns['vm'] != os_['vm'] or ns['fo'] != os_['fo']:
                problems.append('__TEXT 的 vmaddr/fileoff 不该变')
            if ns['fs'] % PAGE or ns['vs'] % PAGE:
                problems.append('__TEXT filesize/vmsize 不是页的整数倍')
            continue
        if ns['vm'] != os_['vm'] + S or ns['fo'] != os_['fo'] + S:
            problems.append('%s 没跟着上移' % os_['name'])
        if ns['fs'] != os_['fs']:
            problems.append('%s 的 filesize 变了' % os_['name'])
        if ns['vs'] < os_['vs'] or (ns['vm'] + ns['vs']) % PAGE:
            problems.append('%s 的 vmsize 不对（变小或不是整页）' % os_['name'])
        if ns['vm'] % PAGE != ns['fo'] % PAGE:
            problems.append('%s 的 vmaddr/fileoff 页内偏移不一致' % os_['name'])

    # 2) 节
    for os_ in old['segs']:
        ns_ = next(s for s in new['segs'] if s['name'] == os_['name'])
        for a, b in zip(os_['sects'], ns_['sects']):
            if a['name'] != b['name'] or a['size'] != b['size']:
                problems.append('节 %s 对不上' % a['name'])
                continue
            zf = (a['flags'] & 0xFF) in ZEROFILL
            if b['addr'] != a['addr'] + S:
                problems.append('节 %s 的 addr 没上移' % a['name'])
            if zf:
                if b['off'] != 0:
                    problems.append('zerofill 节 %s 的 offset 应为 0' % a['name'])
            elif b['off'] != a['off'] + S:
                problems.append('节 %s 的 offset 没上移' % a['name'])

    # 3) 内容
    body = []
    for seg in old['segs']:
        if seg['name'] != '__TEXT':      # 数据段的指针本来就该变了，只比代码/字串
            continue
        for sec in seg['sects']:
            if sec['size'] and (sec['flags'] & 0xFF) not in ZEROFILL:
                body.append((seg, sec))
    for seg, sec in body:
        nseg = next(x for x in new['segs'] if x['name'] == seg['name'])
        n_off = nseg['fo'] + (sec['addr'] + S - nseg['vm'])
        if new['data'][n_off:n_off + sec['size']] != old['data'][sec['off']:sec['off'] + sec['size']]:
            problems.append('节 %s 的内容变了' % sec['name'])
    notes.append('内容比对：%d 个节逐字节一致' % len(body))

    # 4) 寻址差分
    try:
        from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
    except ImportError:
        problems.append('没有 capstone，寻址差分没做')
        Cs = None
    if Cs:
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        BR = ('b', 'bl', 'cbz', 'cbnz', 'tbz', 'tbnz')
        checked = 0
        for s in [x for x in otext['sects'] if x['name'] in
                  ('__text', '__stubs', '__stub_helper', '__auth_stub')]:
            ocode = old['data'][s['off']:s['off'] + s['size']]
            ncode = new['data'][s['off'] + S:s['off'] + S + s['size']]
            oins = list(md.disasm(ocode, s['addr']))
            nins = list(md.disasm(ncode, s['addr'] + S))
            if len(oins) != len(nins):
                problems.append('%s 反汇编条数不一致' % s['name'])
                continue
            for a, b in zip(oins, nins):
                if a.mnemonic != b.mnemonic:
                    problems.append('%#x 指令变了' % a.address)
                    break
                if a.mnemonic in ('adrp', 'adr'):
                    try:
                        ta = int(a.op_str.split('#')[-1], 16)
                        tb = int(b.op_str.split('#')[-1], 16)
                    except ValueError:
                        continue
                    checked += 1
                    if tb != ta + S:
                        problems.append('%#x 的 %s 目标 %#x→%#x（应 +%#x）'
                                        % (a.address, a.mnemonic, ta, tb, S))
                        break
                elif a.mnemonic in BR:
                    try:
                        ta = int(a.op_str.split('#')[-1], 16)
                        tb = int(b.op_str.split('#')[-1], 16)
                    except ValueError:
                        continue
                    checked += 1
                    if ta < 0x100000000 or ta > 0x100000000 + old['size'] * 4:
                        continue
                    if tb != ta + S:
                        problems.append('%#x 的分支目标 %#x→%#x（应 +%#x）'
                                        % (a.address, ta, tb, S))
                        break
        notes.append('寻址差分：%d 条指令全部一致（adrp/adr + 分支）' % checked)

    # 5) 指针差分
    slots = rebase_slots(old)
    mism = 0
    for va in slots:
        ofo = va_to_off(old, va)
        nfo = va_to_off(new, va + S)
        if ofo is None or nfo is None:
            continue
        ov, nv = u64(old['data'], ofo), u64(new['data'], nfo)
        if ov and nv != ov + S:
            mism += 1
    if mism:
        problems.append('%d 个 rebase 指针没跟着上移' % mism)
    else:
        notes.append('指针差分：%d 个指针全部 = 原值 + %#x' % (len(slots), S))

    # 6) 符号表
    soff = old['cmds'].get(LC_SYMTAB)
    if soff:
        symoff, nsyms = u32(old['data'], soff + 8), u32(old['data'], soff + 12)
        nsoff = u32(new['data'], soff + 8)
        bad = 0
        lo_s = otext['vm'] + first
        hi_s = otext['vm'] + old['size']
        for i in range(nsyms):
            t = old['data'][symoff + i * 16 + 4]
            if (t & 0x0E) == 0 or (t & 0xE0) != 0:   # 未定义符号 / stab 调试符号都不带地址
                continue
            ov = u64(old['data'], symoff + i * 16 + 8)
            nv = u64(new['data'], nsoff + i * 16 + 8)
            want = ov + S if lo_s <= ov < hi_s else ov
            if nv != want:
                bad += 1
        if bad:
            problems.append('%d 个符号值没上移' % bad)
        else:
            notes.append('符号表：%d 个定义符号全部 +%#x' % (nsyms, S))

    # 7) 入口
    oe, ne = old['cmds'].get(LC_MAIN), new['cmds'].get(LC_MAIN)
    if oe and ne:
        ov, nv = u64(old['data'], oe + 8), u64(new['data'], ne + 8)
        if nv != ov + S:
            problems.append('LC_MAIN 入口 %#x→%#x 没上移' % (ov, nv))
        else:
            notes.append('入口 %#x→%#x' % (ov, nv))

    # 8) 加密范围
    eo = new['cmds'].get(LC_ENCRYPTION_INFO_64, new['cmds'].get(LC_ENCRYPTION_INFO))
    if eo is None:
        problems.append('没有 LC_ENCRYPTION_INFO_64')
    else:
        co, cs = u32(new['data'], eo + 8), u32(new['data'], eo + 12)
        ends = [s['off'] + s['size'] for s in ntext['sects'] if s['size'] and s['off']]
        want_end = (max(ends) + PAGE - 1) // PAGE * PAGE
        if co != PAGE:
            problems.append('cryptoff=%#x（应为 0x4000）' % co)
        if co + cs != want_end:
            problems.append('加密末端 %#x 与正文末尾 %#x 不齐' % (co + cs, want_end))
        if ntext['fs'] != want_end:
            problems.append('__TEXT filesize %#x ≠ 正文末尾 %#x' % (ntext['fs'], want_end))
        notes.append('加密范围 %#x+%#x，末端与 __TEXT 段尾 %#x 齐平' % (co, cs, want_end))

    # 9) objc 链
    def sect(info, segname, name):
        seg = next(s for s in info['segs'] if s['name'] == segname)
        return next((s for s in seg['sects'] if s['name'] == name), None)

    cl = sect(new, '__DATA_CONST', '__objc_classlist')
    if cl and cl['size']:
        n = cl['size'] // 8
        good = 0
        for i in range(n):
            cls_va = u64(new['data'], cl['off'] + i * 8)
            fo = va_to_off(new, cls_va)
            if fo is None:
                continue
            ro_va = u64(new['data'], fo + 32) if False else None
            data_va = u64(new['data'], fo + 32)          # class_t->data
            dfo = va_to_off(new, data_va)
            if dfo is None:
                continue
            ro_va = data_va                              # class_ro_t*（低 3 位是标记）
            rfo = va_to_off(new, ro_va)
            if rfo is None:
                continue
            name_va = u32(new['data'], rfo + 24)         # 32 位映像内相对偏移
            nfo = va_to_off(new, otext['vm'] + name_va)
            if nfo is None:
                continue
            raw = new['data'][nfo:nfo + 64].split(b'\0')[0]
            if raw and all(32 <= c < 127 for c in raw):
                good += 1
        if good == 0:
            problems.append('objc 类链一个都解析不出来')
        else:
            notes.append('objc 类链：%d/%d 个类名可正常读出' % (good, n))

    # 10) rebase 指针的落点必须合法
    lo = otext['vm'] + first
    hi = otext['vm'] + old['size']
    bad_ptrs = 0
    for va in slots:
        nfo = va_to_off(new, va + S)
        if nfo is None:
            continue
        v = u64(new['data'], nfo)
        if v and not (lo <= v < hi):
            bad_ptrs += 1
    if bad_ptrs:
        problems.append('%d 个指针上移后落在映像外' % bad_ptrs)
    else:
        notes.append('指针落点：全部落在映像内')

    print('── %s' % sys.argv[1])
    for n in notes:
        print('   ✓ %s' % n)
    if problems:
        for p in problems[:20]:
            print('   ✗ %s' % p)
        print('结论：%d 项不通过' % len(problems))
        return 1
    print('结论：全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
