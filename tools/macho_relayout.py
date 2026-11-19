#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 lld 版式的 Mach-O 重排成苹果 ld64 版式（整幅后移一页）：
  · 头部页只留 mach header + 加载命令，正文从第 1 页之后开始（__text 不再落在头部页）
  · 所有段（虚拟地址 + 文件偏移）同步 +0x4000 → 段间距不变，指令一个字节都不动
  · 绝对地址跟改：入口、符号值、rebase 指针、dyld 信息偏移
  · __unwind_info 整体摘掉（它的函数偏移是相对 __TEXT 起点的，挪页后必然失效；
    摘掉后系统走 __eh_frame 的 DWARF 回溯，等价于 ld64 的 -no_compact_unwind）
  · 补 LC_ENCRYPTION_INFO_64、抬 LC_BUILD_VERSION.sdk、换新 LC_UUID
"""
import struct, sys, uuid

PAGE = 0x4000
DELTA = 0x4000
SLACK = 16          # 给 codesign 的 LC_CODE_SIGNATURE 留位

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_UUID = 0x1B
LC_CODE_SIGNATURE = 0x1D
LC_FUNCTION_STARTS = 0x26
LC_DATA_IN_CODE = 0x29
LC_ENCRYPTION_INFO_64 = 0x2C
LC_BUILD_VERSION = 0x32
LC_MAIN = 0x80000028
LC_DYLD_INFO_ONLY = 0x80000022
LC_DYLD_INFO = 0x22
DROP_CMDS = {LC_CODE_SIGNATURE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE}

u32 = lambda d, o: struct.unpack_from('<I', d, o)[0]
u64 = lambda d, o: struct.unpack_from('<Q', d, o)[0]


def uleb(b, p):
    r = s = 0
    while True:
        x = b[p]; p += 1
        r |= (x & 0x7F) << s
        if not (x & 0x80):
            return r, p
        s += 7


def parse_rebases(d, off, size, ptr=8):
    end = off + size
    p = off
    seg = seg_off = 0
    out = []
    while p < end:
        byte = d[p]; p += 1
        op, imm = byte & 0xF0, byte & 0x0F
        if op == 0x00:
            break
        if op == 0x10:
            pass
        elif op == 0x20:
            seg = imm
            seg_off, p = uleb(d, p)
        elif op == 0x30:
            v, p = uleb(d, p); seg_off += v
        elif op == 0x40:
            seg_off += imm * ptr
        elif op == 0x50:
            for _ in range(imm):
                out.append((seg, seg_off)); seg_off += ptr
        elif op == 0x60:
            c, p = uleb(d, p)
            for _ in range(c):
                out.append((seg, seg_off)); seg_off += ptr
        elif op == 0x70:
            out.append((seg, seg_off)); v, p = uleb(d, p); seg_off += ptr + v
        elif op == 0x80:
            c, p = uleb(d, p); skip, p = uleb(d, p)
            for _ in range(c):
                out.append((seg, seg_off)); seg_off += ptr + skip
        else:
            break
    return out


def transform(src, dst, drop_unwind=True, verbose=True):
    raw = open(src, 'rb').read()
    (magic, cputype, cpusub, filetype, ncmds,
     sizeofcmds, flags, resv) = struct.unpack_from('<IiiIIIII', raw, 0)
    assert magic == 0xfeedfacf

    cmds = []
    off = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from('<II', raw, off)
        cmds.append((cmd, off, sz))
        off += sz
    header_end = 32 + sizeofcmds

    segs = []
    for cmd, o, s in cmds:
        if cmd != LC_SEGMENT_64:
            continue
        name = raw[o + 8:o + 24].split(b'\0')[0].decode()
        vm, vs, fo, fs = struct.unpack_from('<QQQQ', raw, o + 24)
        ns = u32(raw, o + 64)
        sects = []
        so = o + 72
        for _ in range(ns):
            sects.append(dict(name=raw[so:so + 16].split(b'\0')[0].decode(),
                              hdr=so, addr=u64(raw, so + 32),
                              size=u64(raw, so + 40), offset=u32(raw, so + 48)))
            so += 80
        segs.append(dict(name=name, hdr=o, vm=vm, vs=vs, fo=fo, fs=fs, sects=sects))
    S = {s['name']: s for s in segs}
    text, linkedit = S['__TEXT'], S['__LINKEDIT']

    cs = [c for c in cmds if c[0] == LC_CODE_SIGNATURE]
    sig_at = u32(raw, cs[0][1] + 8) if cs else None
    link_size_new = (sig_at - linkedit['fo']) if sig_at else linkedit['fs']

    # ── 1. 逐条重建加载命令（__TEXT 段顺手摘掉 __unwind_info 节） ──
    blobs = []           # [(kind, name, bytes)]
    for cmd, o, s in cmds:
        if cmd in DROP_CMDS:
            continue
        if cmd == LC_SEGMENT_64:
            name = raw[o + 8:o + 24].split(b'\0')[0].decode()
            body = bytearray(raw[o:o + 72])
            sect_blobs = []
            for sec in S[name]['sects']:
                if drop_unwind and name == '__TEXT' and sec['name'] == '__unwind_info':
                    continue
                sect_blobs.append(raw[sec['hdr']:sec['hdr'] + 80])
            struct.pack_into('<I', body, 4, 72 + 80 * len(sect_blobs))
            struct.pack_into('<I', body, 64, len(sect_blobs))
            blobs.append(('seg', name, bytes(body) + b''.join(sect_blobs)))
        else:
            blobs.append(('cmd', str(cmd), raw[o:o + s]))

    enc_rel = sum(len(b[2]) for b in blobs)          # 加密命令在命令区里的相对位置
    blobs.append(('cmd', 'enc', struct.pack('<IIIIII', LC_ENCRYPTION_INFO_64, 24, PAGE, 0, 0, 0)))

    cmds_blob = b''.join(b[2] for b in blobs)
    new_ncmds = len(blobs)
    new_sizeofcmds = len(cmds_blob)
    head = bytearray(struct.pack('<IiiIIIII', magic, cputype, cpusub, filetype,
                                 new_ncmds, new_sizeofcmds, flags, resv) + cmds_blob)
    head += b'\0' * SLACK                            # codesign 的槽位
    assert len(head) <= PAGE, hex(len(head))

    # ── 2. 内容整幅后移一页 ───────────────────────────────
    pad = (header_end + DELTA) - len(head)
    out = head + bytearray(pad) + raw[header_end:]
    fix = lambda x: x + DELTA

    # 新命令区里各段命令的位置
    seg_pos = {}
    p = 32
    for kind, name, b in blobs:
        if kind == 'seg':
            seg_pos[name] = p
        p += len(b)

    # ── 3. 段 / 节 ───────────────────────────────────────
    text_end_new = None
    for s in segs:
        h = seg_pos[s['name']]
        vm, vs, fo, fs = s['vm'], s['vs'], s['fo'], s['fs']
        if s['name'] == '__TEXT':
            last = max(x['offset'] + x['size'] for x in s['sects'])
            fs = (last + DELTA + PAGE - 1) // PAGE * PAGE
            vs = fs
            fo = 0
            struct.pack_into('<QQQQ', out, h + 24, vm, vs, fo, fs)
            text_end_new = fs
        elif s['name'] == '__PAGEZERO':
            vm = fo = 0
        else:
            vm += DELTA; fo += DELTA
            if s['name'] == '__LINKEDIT':
                fs = link_size_new
            struct.pack_into('<QQQQ', out, h + 24, vm, vs, fo, fs)
        sh = h + 72
        for sec in s['sects']:
            if drop_unwind and s['name'] == '__TEXT' and sec['name'] == '__unwind_info':
                continue
            off_new = fix(sec['offset']) if sec['offset'] > 0 else 0
            struct.pack_into('<QQI', out, sh + 32, sec['addr'] + DELTA, sec['size'], off_new)
            sh += 80

    struct.pack_into('<IIII', out, 32 + enc_rel + 8, PAGE, text_end_new - PAGE, 0, 0)

    # ── 4. 命令里的绝对偏移 ───────────────────────────────
    p = 32
    for kind, name, b in blobs:
        if kind == 'cmd':
            if name in (str(LC_DYLD_INFO_ONLY), str(LC_DYLD_INFO)):
                for k in range(0, 10, 2):
                    v = u32(out, p + 8 + 4 * k)
                    if v:
                        struct.pack_into('<I', out, p + 8 + 4 * k, fix(v))
            elif name == str(LC_SYMTAB):
                so_, ns_, st_, ss_ = struct.unpack_from('<IIII', out, p + 8)
                struct.pack_into('<IIII', out, p + 8, fix(so_), ns_, fix(st_), ss_)
            elif name == str(LC_DYSYMTAB):
                v = list(struct.unpack_from('<18I', out, p + 8))
                for k in (6, 8, 10, 12, 14, 16):
                    if v[k]:
                        v[k] = fix(v[k])
                struct.pack_into('<18I', out, p + 8, *v)
            elif name == str(LC_MAIN):
                eo = u64(out, p + 8)
                struct.pack_into('<Q', out, p + 8, eo + DELTA)
            elif name == str(LC_BUILD_VERSION):
                plat, mino, sdk, nt = struct.unpack_from('<IIII', out, p + 8)
                struct.pack_into('<IIII', out, p + 8, plat, mino, (26 << 16), nt)
            elif name == str(LC_UUID):
                out[p + 8:p + 24] = uuid.uuid4().bytes
        p += len(b)

    # ── 5. rebase 指针值 ─────────────────────────────────
    di = [c for c in cmds if c[0] in (LC_DYLD_INFO_ONLY, LC_DYLD_INFO)]
    if di:
        ro, rs = struct.unpack_from('<II', raw, di[0][1] + 8)
        locs = parse_rebases(raw, ro, rs)
        img_lo = text['vm']
        img_hi = linkedit['vm'] + 0x20000
        n = 0
        for seg_i, so in locs:
            s = segs[seg_i]
            foff = s['fo'] + so
            if foff < header_end or foff + 8 > len(raw):
                continue
            v = u64(raw, foff)
            if img_lo <= v < img_hi:
                struct.pack_into('<Q', out, fix(foff), v + DELTA)
                n += 1
    else:
        locs, n = [], 0

    # ── 6. 符号表 n_value +0x4000 ────────────────────────
    sy = [c for c in cmds if c[0] == LC_SYMTAB]
    nsyms = 0
    if sy:
        so_, nsyms, st_, ss_ = struct.unpack_from('<IIII', raw, sy[0][1] + 8)
        for i in range(nsyms):
            q = fix(so_ + i * 16)
            ntype = out[q + 4]
            v = u64(out, q + 8)
            if v and (ntype & 0x0e) in (0x0e, 0x0a):
                struct.pack_into('<Q', out, q + 8, v + DELTA)

    open(dst, 'wb').write(bytes(out))
    if verbose:
        print('== %s → %s' % (src.rsplit('/', 1)[-1], dst))
        print('   __TEXT 段: 0 .. %#x（正文起点 %#x），加密 %#x + %#x'
              % (text_end_new, header_end + DELTA, PAGE, text_end_new - PAGE))
        print('   入口 %#x，rebase %d/%d，符号 %d' % (
            u64(out, [i for i in range(32, len(head))
                      if u32(out, i) == LC_MAIN][0] + 8) if False else 0, n, len(locs), nsyms))
        print('   文件 %d → %d 字节' % (len(raw), len(out)))
    return text_end_new


if __name__ == '__main__':
    transform(sys.argv[1], sys.argv[2])
