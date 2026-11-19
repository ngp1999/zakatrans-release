#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 Linux/lld 交叉链接出来的 iOS 可执行文件，重排成苹果 ld64 的版式。

ld64 编 iOS 可执行文件时有两条硬规矩（ld/OutputFile.cpp::makeEncryptable）：

  1. 加载命令独占第 0 页：正文第一个节的文件偏移 ≥ 1 个页（0x4000）。
     _encryptedTEXTstartOffset = textPage * segmentAlignment，textPage >= 1。
  2. 加密范围 = [0x4000, pageAlign(最后一个 __TEXT 节结束)]。

lld 的产物正文直接从 0xf00/0xd10 开始（挤在第 0 页里），苹果校验就报
「Mismatched Encryption Extents」。

做法（关键：一个虚拟地址都不改）：
  - __TEXT 段内所有节整体后移 delta，让第一个节落在 0x4000
  - 段内节的 addr / offset 同步平移（保持 addr - vmaddr == off - fileoff）
  - __TEXT.filesize += delta
  - 如果平移后 __TEXT 越过下一段的起始页，就把后面各段的**文件偏移**推到新的
    页边界（vmaddr 不动）。段的 fileoff 只要与 vmaddr 页内偏移一致就合法，
    这里所有段的页内偏移都是 0，所以推到 0x4000 的整数倍即可。
    虚拟地址不变 → 代码里的 adrp/add、objc 元数据、stub 全部不用改。
  - LC_MAIN.entryoff、符号表 n_value、rebase 指针（按 dyld opcode 精确定位）
    指向 __TEXT 的做 +delta；其余段地址没变，一律不动。
  - 所有指向 __LINKEDIT 内部数据的加载命令字段（symtab / dyld info / 
    function starts / data in code / code signature）跟着新偏移走。
  - 写入 / 修正 LC_ENCRYPTION_INFO_64（cryptoff = 0x4000）。

用法：
    python3 macho_text_align.py --check <Mach-O> ...
    python3 macho_text_align.py <Mach-O> ...
"""
import struct
import sys

PAGE = 0x4000

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_MAIN = 0x80000028
LC_ENCRYPTION_INFO = 0x2C
LC_ENCRYPTION_INFO_64 = 0x2E
LC_CODE_SIGNATURE = 0x1D
LC_FUNCTION_STARTS = 0x26
LC_DATA_IN_CODE = 0x29
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_DYLD_CHAINED_FIXUPS = 0x80000034

# 这些命令后面跟着一个 (dataoff, datasize) 指向 __LINKEDIT
LINKEDIT_DATA_CMDS = {
    LC_CODE_SIGNATURE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE,
    LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS,
}


def u32(d, o):
    return struct.unpack_from('<I', d, o)[0]


def u64(d, o):
    return struct.unpack_from('<Q', d, o)[0]


def align(v, a):
    return (v + a - 1) // a * a


def read_uleb(data, p):
    result = 0
    shift = 0
    while True:
        b = data[p]
        p += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return result, p


class MachO(object):
    def __init__(self, data):
        self.d = bytearray(data)
        self.ncmds = u32(self.d, 16)
        self.sizeofcmds = u32(self.d, 20)
        self.cmds = []
        off = 32
        for _ in range(self.ncmds):
            cmd = u32(self.d, off)
            size = u32(self.d, off + 4)
            if size < 8 or off + size > 32 + self.sizeofcmds + 8:
                raise SystemExit('加载命令表损坏 @%#x size=%d' % (off, size))
            self.cmds.append([cmd, off, size])
            off += size

    def segments(self):
        out = []
        for cmd, off, size in self.cmds:
            if cmd != LC_SEGMENT_64:
                continue
            name = bytes(self.d[off + 8:off + 24]).rstrip(b'\0').decode('utf-8', 'replace')
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', self.d, off + 24)
            nsects = u32(self.d, off + 64)
            sections = []
            for i in range(nsects):
                p = off + 72 + i * 80
                sn = bytes(self.d[p:p + 16]).rstrip(b'\0').decode('utf-8', 'replace')
                addr, sz = struct.unpack_from('<QQ', self.d, p + 32)
                soff, al = struct.unpack_from('<II', self.d, p + 48)
                sections.append({'name': sn, 'addr': addr, 'size': sz,
                                 'off': soff, 'align': al, 'hdr': p})
            out.append({'name': name, 'vmaddr': vmaddr, 'vmsize': vmsize,
                        'fileoff': fileoff, 'filesize': filesize,
                        'nsects': nsects, 'sections': sections, 'hdr': off,
                        'cmd_size': size})
        return out

    def seg_by_name(self, name):
        for s in self.segments():
            if s['name'] == name:
                return s
        return None

    def cmd_off(self, cmd_type):
        for cmd, off, size in self.cmds:
            if cmd == cmd_type:
                return off, size
        return None, None

    def header_end(self):
        return 32 + self.sizeofcmds

    def insert_command(self, blob, before_offset='__TEXT_FIRST_SECTION__'):
        end = self.header_end()
        if end + len(blob) > before_offset:
            raise SystemExit('加载命令区没有空间：需要 %d，只剩 %d'
                             % (len(blob), before_offset - end))
        self.d[end:end] = blob
        self.ncmds += 1
        self.sizeofcmds += len(blob)
        struct.pack_into('<I', self.d, 16, self.ncmds)
        struct.pack_into('<I', self.d, 20, self.sizeofcmds)
        self.cmds.append([struct.unpack_from('<I', blob, 0)[0], end, len(blob)])

    def bytes(self):
        return bytes(self.d)


def parse_rebase(data, off, size, segs):
    """按 dyld rebase opcode 走一遍，返回 [(seg_index, vmaddr)]。"""
    out = []
    p, end = off, off + size
    seg_index, seg_offset, psize = 0, 0, 8
    while p < end:
        b = data[p]
        p += 1
        opcode, imm = b & 0xF0, b & 0x0F
        if opcode == 0x00:
            break
        elif opcode == 0x10:
            pass
        elif opcode == 0x20:
            seg_index = imm
            seg_offset, p = read_uleb(data, p)
            psize = 8
        elif opcode == 0x30:
            v, p = read_uleb(data, p)
            seg_offset += v
        elif opcode == 0x40:
            seg_offset += imm * psize
        elif opcode == 0x50:
            for _ in range(imm):
                out.append((seg_index, segs[seg_index]['vmaddr'] + seg_offset))
                seg_offset += psize
        elif opcode == 0x60:
            count, p = read_uleb(data, p)
            for _ in range(count):
                out.append((seg_index, segs[seg_index]['vmaddr'] + seg_offset))
                seg_offset += psize
        elif opcode == 0x70:
            out.append((seg_index, segs[seg_index]['vmaddr'] + seg_offset))
            seg_offset += psize
            v, p = read_uleb(data, p)
            seg_offset += v
        elif opcode == 0x80:
            count, p = read_uleb(data, p)
            skip, p = read_uleb(data, p)
            for _ in range(count):
                out.append((seg_index, segs[seg_index]['vmaddr'] + seg_offset))
                seg_offset += psize + skip
        else:
            raise SystemExit('未知 rebase opcode %#02x @ %#x' % (b, p - 1))
    return out


def _text_limit(m, text, fallback):
    """__TEXT 段能长到多大（下一个段的 vmaddr 相对偏移）。"""
    nxt = None
    for s in m.segments():
        if s['name'] == '__PAGEZERO' or s['name'] == '__TEXT':
            continue
        if s['vmaddr'] >= text['vmaddr']:
            if nxt is None or s['vmaddr'] < nxt:
                nxt = s['vmaddr']
    return (nxt - text['vmaddr']) if nxt else align(fallback, PAGE)


def plan(path):
    """算出新的段布局，不写盘。"""
    data = open(path, 'rb').read()
    m = MachO(data)
    text = m.seg_by_name('__TEXT')
    if not text or not text['sections']:
        return None
    first = min(text['sections'], key=lambda s: s['off'])
    delta = PAGE - first['off']
    if delta <= 0:
        delta = 0

    # 越界时：丢掉段尾可选的 __eh_frame（arm64 走 __unwind_info，这条只是备用栈回溯）
    drop = []
    last_sec = max(text['sections'], key=lambda s: s['off'] + s['size'])
    last_end = last_sec['off'] + last_sec['size']
    pending_limit = _text_limit(m, text, last_end)
    if delta and last_end + delta > pending_limit and last_sec['name'] == '__eh_frame':
        drop.append(last_sec)
        keep = [s for s in text['sections'] if s is not last_sec]
        last_end = max(s['off'] + s['size'] for s in keep)
    segs = m.segments()
    segs_sorted = sorted([s for s in segs if s['name'] != '__PAGEZERO'],
                         key=lambda s: s['vmaddr'])

    # 新文件布局
    layout = []
    prev_end = 0
    for s in segs_sorted:
        if s['name'] == '__TEXT':
            new_off = 0
            # ld64 产出的 __TEXT 一定是整页的：filesize / vmsize 都取到页边界
            new_size = min(align(last_end + delta, PAGE), _text_limit(m, text, last_end))
        else:
            new_off = align(prev_end, PAGE)
            if new_off < s['fileoff']:
                new_off = s['fileoff']
            new_size = s['filesize']
        if s['vmaddr'] % PAGE != new_off % PAGE:
            raise SystemExit('%s 的 vmaddr 页内偏移 %#x 与 fileoff %#x 对不上'
                             % (s['name'], s['vmaddr'] % PAGE, new_off % PAGE))
        old_end = s['fileoff'] + s['filesize']
        layout.append({'name': s['name'], 'old_off': s['fileoff'], 'new_off': new_off,
                       'old_size': s['filesize'], 'new_size': new_size,
                       'old_end': old_end, 'vmaddr': s['vmaddr'],
                       'vmsize': s['vmsize'], 'hdr': s['hdr']})
        prev_end = new_off + new_size

    # __TEXT 平移后不能撞上下一段的虚拟地址
    limit = _text_limit(m, text, max(s['off'] + s['size'] for s in text['sections']
                                     if s not in drop))
    if delta and (last_end + delta) > limit:
        raise SystemExit('__TEXT 平移 %#x 后末尾 %#x 越过下一段虚拟地址 %#x'
                         % (delta, last_end + delta, limit))
    return {'m': m, 'delta': delta, 'layout': layout, 'text': text,
            'first': first, 'last_end': last_end, 'limit': limit, 'drop': drop}


def check(path):
    try:
        p = plan(path)
    except SystemExit as e:
        return 'FAIL: %s' % e
    if p is None:
        return 'skipped: 没有 __TEXT 节'
    moved = [l['name'] for l in p['layout'] if l['new_off'] != l['old_off']]
    return ('delta=%#x 首节 %#x→%#x 末节 %#x→%#x 上限 %#x %s；需要重排的段：%s'
            % (p['delta'], p['first']['off'], PAGE, p['last_end'],
               p['last_end'] + p['delta'], p['limit'],
               'OK' if p['last_end'] + p['delta'] <= p['limit'] else '越界',
               ','.join(moved) or '无'))


def transform(path):
    p = plan(path)
    if p is None:
        return 'skipped: 没有 __TEXT 节'
    m = p['m']
    delta = p['delta']
    text = p['text']
    old_start = p['first']['off']
    old_end = p['last_end']
    # __TEXT 内外虚拟地址范围（判据：值落在 [vmaddr+old_start, vmaddr+old_end)）
    lo = text['vmaddr'] + old_start
    hi = text['vmaddr'] + old_end

    # ── 1. 计算新文件镜像 ────────────────────────────────────
    old = bytes(m.d)
    total = max(l['new_off'] + l['new_size'] for l in p['layout'])
    new = bytearray(total)

    for l in p['layout']:
        if l['name'] == '__TEXT':
            # 节内容整体后移 delta，中间留 0
            chunk = old[old_start:old_end]
            new[old_start + delta:old_end + delta] = chunk
        else:
            # 段内容原样搬到新偏移（bss 部分 filesize=0）
            if l['old_size']:
                new[l['new_off']:l['new_off'] + l['old_size']] = \
                    old[l['old_off']:l['old_off'] + l['old_size']]
    # header + load commands 原样保留（__TEXT 段头在 32..）
    new[0:32 + m.sizeofcmds] = old[0:32 + m.sizeofcmds]

    m.d = new

    # ── 2. 段与节 ────────────────────────────────────────────
    off_map = {}     # 旧文件偏移区间 → 新偏移（搬动后的差值）
    shift = {}       # 段名 → (new_off - old_off)
    for l in p['layout']:
        shift[l['name']] = l['new_off'] - l['old_off']
        struct.pack_into('<Q', m.d, l['hdr'] + 40, l['new_off'])      # fileoff
        struct.pack_into('<Q', m.d, l['hdr'] + 48, l['new_size'])     # filesize
        if l['name'] == '__TEXT':
            # vmsize 必须覆盖到新内容末尾，且不越过下一段
            struct.pack_into('<Q', m.d, l['hdr'] + 32, l['new_size'])  # vmsize

    dropped = {id(x) for x in p.get('drop', [])}
    for s in text['sections']:
        if id(s) in dropped:
            struct.pack_into('<Q', m.d, s['hdr'] + 32, 0)   # addr
            struct.pack_into('<Q', m.d, s['hdr'] + 40, 0)   # size
            struct.pack_into('<I', m.d, s['hdr'] + 48, 0)   # offset
            continue
        struct.pack_into('<Q', m.d, s['hdr'] + 32, s['addr'] + delta)  # addr
        struct.pack_into('<I', m.d, s['hdr'] + 48, s['off'] + delta)   # offset
        # reloff（重定位表在 __LINKEDIT 里）跟着段走
        reloff = struct.unpack_from('<I', old, s['hdr'] + 56)[0]
        if reloff:
            struct.pack_into('<I', m.d, s['hdr'] + 56, reloff + shift.get('__LINKEDIT', 0))

    # ── 3. 加载命令里指向 __LINKEDIT 的偏移 ──────────────────
    le_shift = shift.get('__LINKEDIT', 0)
    for cmd, off, size in m.cmds:
        if cmd in LINKEDIT_DATA_CMDS:
            dataoff = u32(m.d, off + 8)
            if dataoff:
                struct.pack_into('<I', m.d, off + 8, dataoff + le_shift)
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            for i in range(4):
                dataoff = u32(m.d, off + 8 + i * 8)
                if dataoff:
                    struct.pack_into('<I', m.d, off + 8 + i * 8, dataoff + le_shift)
        elif cmd == LC_SYMTAB:
            symoff = u32(m.d, off + 8)
            stroff = u32(m.d, off + 16)
            if symoff:
                struct.pack_into('<I', m.d, off + 8, symoff + le_shift)
            if stroff:
                struct.pack_into('<I', m.d, off + 16, stroff + le_shift)

    # ── 4. LC_MAIN 入口 ─────────────────────────────────────
    eoff, _ = m.cmd_off(LC_MAIN)
    if eoff:
        entry = u64(m.d, eoff + 8)
        if old_start <= entry < old_end:
            struct.pack_into('<Q', m.d, eoff + 8, entry + delta)

    # ── 5. 符号表 n_value ───────────────────────────────────
    soff, _ = m.cmd_off(LC_SYMTAB)
    patched_sym = 0
    if soff:
        symoff = u32(m.d, soff + 8)
        nsyms = u32(m.d, soff + 12)
        for i in range(nsyms):
            q = symoff + i * 16
            n_type = m.d[q + 4]
            if (n_type & 0x0E) != 0x0E:      # 只要 N_SECT
                continue
            val = u64(m.d, q + 8)
            if lo <= val < hi:
                struct.pack_into('<Q', m.d, q + 8, val + delta)
                patched_sym += 1

    # ── 6. rebase 指针（指向 __TEXT 的值 +delta）────────────
    segs_now = m.segments()
    # rebase opcode 里的段序号是「加载命令里段出现的顺序」，含 __PAGEZERO
    seg_vm = [s['vmaddr'] for s in segs_now]
    d_off, _ = m.cmd_off(LC_DYLD_INFO)
    if not d_off:
        d_off, _ = m.cmd_off(LC_DYLD_INFO_ONLY)
    patched_ptr = 0
    if d_off:
        r_off = u32(m.d, d_off + 8)
        r_size = u32(m.d, d_off + 12)
        if r_size:
            segs_for_parse = [{'vmaddr': v} for v in seg_vm]
            for seg_idx, addr in parse_rebase(bytes(m.d), r_off, r_size, segs_for_parse):
                # addr 是「需要 rebase 的指针所在位置」，不是指针值本身
                # 由虚拟地址反查文件偏移
                seg = None
                for s in segs_now:
                    if s['vmaddr'] <= addr < s['vmaddr'] + max(s['filesize'], s['vmsize']):
                        seg = s
                        break
                if seg is None or seg['name'] == '__TEXT':
                    continue          # __TEXT 内没有可 rebase 的指针
                fo = seg['fileoff'] + (addr - seg['vmaddr'])
                if fo + 8 > len(m.d):
                    continue
                val = u64(m.d, fo)
                if lo <= val < hi:
                    struct.pack_into('<Q', m.d, fo, val + delta)
                    patched_ptr += 1

    # ── 7. 加密信息（ld64 口径）─────────────────────────────
    cryptsize = align(p['last_end'] + delta, PAGE) - PAGE
    write_encryption(m, PAGE, cryptsize, before=PAGE)

    open(path, 'wb').write(m.bytes())
    moved = ','.join(l['name'] for l in p['layout'] if l['new_off'] != l['old_off']) or '无'
    return ('ok: delta=%#x 符号=%d 指针=%d crypt=[%#x,+%#x] 文件 %#x→%#x 挪动的段：%s'
            % (delta, patched_sym, patched_ptr, PAGE, cryptsize,
               0, len(m.d), moved))


def write_encryption(m, cryptoff, cryptsize, before=PAGE):
    off, _ = m.cmd_off(LC_ENCRYPTION_INFO_64)
    if off:
        struct.pack_into('<III', m.d, off + 8, cryptoff, cryptsize, 0)
        return
    off, _ = m.cmd_off(LC_ENCRYPTION_INFO)
    if off:
        struct.pack_into('<II', m.d, off, LC_ENCRYPTION_INFO_64, 24)
        struct.pack_into('<III', m.d, off + 8, cryptoff, cryptsize, 0)
        struct.pack_into('<I', m.d, off + 20, 0)
        return
    blob = struct.pack('<IIIIII', LC_ENCRYPTION_INFO_64, 24, cryptoff, cryptsize, 0, 0)
    end = m.header_end()
    if end + len(blob) > before:
        raise SystemExit('加载命令区没有空间插 LC_ENCRYPTION_INFO_64')
    # 原地覆盖加载命令区尾部的填充（不移动任何已有内容）
    m.d[end:end + len(blob)] = blob
    m.ncmds += 1
    m.sizeofcmds += len(blob)
    struct.pack_into('<I', m.d, 16, m.ncmds)
    struct.pack_into('<I', m.d, 20, m.sizeofcmds)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    check_mode = '--check' in sys.argv
    for path in [a for a in sys.argv[1:] if not a.startswith('--')]:
        if check_mode:
            print('%s: %s' % (path, check(path)))
        else:
            print('%s: %s' % (path, transform(path)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
