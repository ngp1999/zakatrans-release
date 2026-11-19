#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 Linux/lld 交叉链接出来的 iOS 可执行文件整体上移一页，让正文落到第 1 页之后，
同时保证运行时的寻址关系一个都不变。

为什么不能只挪正文（上一版的错）：
  lld 产物里 __text 在文件/虚拟地址 0xf00，挤在第 0 页，苹果校验会报
  Mismatched Encryption Extents。上一版的做法是把 __TEXT 里的节整体 +0x3100，
  但 __DATA / __DATA_CONST / __LINKEDIT 原地不动。于是：
    · 代码里的 adrp 是「以当前页为基准 + 立即数」，PC 挪了 0x3100、目标没挪，
      所有指向数据段的引用全部偏了一页 → 打开就崩
      （真机日志：SIGBUS / EXC_ARM_DA_ALIGN，PC 落在 __objc_classname 字符串里）。
    · 主包 2665 条寻址里 1766 条落在映像任何节之外。

本工具的做法（整幅统一上移一页）：
  · 文件前面插入 PAGE 字节 0，之后所有内容的文件偏移 +PAGE
  · 除 __PAGEZERO 外的所有段：vmaddr +PAGE（__TEXT 保持 0x100000000，靠内容后移
    实现同样的效果）、fileoff +PAGE（__TEXT 保持 0）
  · 所有节：addr +PAGE、offset +PAGE（zerofill 节 offset 保持 0）
  · 所有绝对地址跟着改：LC_MAIN.entryoff、符号表 n_value、rebase 指针（全部段，
    不只是 __TEXT）
  · 所有指向 __LINKEDIT 的加载命令偏移 +PAGE
  · __TEXT filesize/vmsize 取到页边界；LC_ENCRYPTION_INFO_64 写 cryptoff=0x4000

因为整幅（代码 + 数据 + 链接编辑区）平移的是同一个页整数倍，所有 PC 相对寻址、
所有相对偏移（unwind / rebase 位置 / bind 位置 / function starts）全部天然成立。

用法：
    python3 macho_layout.py --check  <Mach-O> ...          # 只看要不要挪
    python3 macho_layout.py --audit  <Mach-O> ...          # 寻址巡检（会上传前跑这个）
    python3 macho_layout.py          <Mach-O> ...          # 就地重排（幂等）
    python3 macho_layout.py --uuid   <Mach-O> ...          # 换新的 LC_UUID
    python3 macho_layout.py --sdk 26.0 --minos 16.0 <Mach-O> ...   # 改 SDK 标记
"""
import struct
import sys

PAGE = 0x4000

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_MAIN = 0x80000028
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C
LC_CODE_SIGNATURE = 0x1D
LC_FUNCTION_STARTS = 0x26
LC_DATA_IN_CODE = 0x29
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_UUID = 0x1B
LC_BUILD_VERSION = 0x32

LINKEDIT_DATA_CMDS = {
    LC_CODE_SIGNATURE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE,
    LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS,
}

ZEROFILL_TYPES = (0x1, 0xc, 0x12)   # S_ZEROFILL / S_GB_ZEROFILL / S_THREAD_LOCAL_ZEROFILL


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
        if u32(self.d, 0) != 0xFEEDFACF:
            raise SystemExit('不是 64 位小端 Mach-O')
        self.ncmds = u32(self.d, 16)
        self.sizeofcmds = u32(self.d, 20)
        self.cmds = []
        off = 32
        for _ in range(self.ncmds):
            cmd = u32(self.d, off)
            size = u32(self.d, off + 4)
            if size < 8 or off + size > 32 + self.sizeofcmds:
                raise SystemExit('加载命令表损坏 @%#x size=%d' % (off, size))
            self.cmds.append([cmd, off, size])
            off += size

    def header_end(self):
        return 32 + self.sizeofcmds

    def segments(self):
        out = []
        for cmd, off, size in self.cmds:
            if cmd != LC_SEGMENT_64:
                continue
            name = bytes(self.d[off + 8:off + 24]).rstrip(b'\0').decode('utf-8', 'replace')
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', self.d, off + 24)
            nsects = u32(self.d, off + 64)
            sects = []
            for i in range(nsects):
                p = off + 72 + i * 80
                sn = bytes(self.d[p:p + 16]).rstrip(b'\0').decode('utf-8', 'replace')
                addr, sz = struct.unpack_from('<QQ', self.d, p + 32)
                soff, al = struct.unpack_from('<II', self.d, p + 48)
                flags = u32(self.d, p + 64)
                sects.append({'name': sn, 'addr': addr, 'size': sz, 'off': soff,
                              'align': al, 'flags': flags, 'hdr': p, 'seg': name})
            out.append({'name': name, 'vmaddr': vmaddr, 'vmsize': vmsize,
                        'fileoff': fileoff, 'filesize': filesize, 'nsects': nsects,
                        'sects': sects, 'hdr': off})
        return out

    def cmd_off(self, cmd_type):
        for cmd, off, size in self.cmds:
            if cmd == cmd_type:
                return off, size
        return None, None

    def image_end(self):
        return max(s['fileoff'] + s['filesize'] for s in self.segments()
                   if s['name'] != '__PAGEZERO')


def parse_rebase(data, off, size, seg_vmaddrs):
    """按 dyld rebase opcode 走一遍，返回 [(seg_index, 需要 rebase 的指针的虚拟地址)]。"""
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
                out.append((seg_index, seg_vmaddrs[seg_index] + seg_offset))
                seg_offset += psize
        elif opcode == 0x60:
            count, p = read_uleb(data, p)
            for _ in range(count):
                out.append((seg_index, seg_vmaddrs[seg_index] + seg_offset))
                seg_offset += psize
        elif opcode == 0x70:
            out.append((seg_index, seg_vmaddrs[seg_index] + seg_offset))
            seg_offset += psize
            v, p = read_uleb(data, p)
            seg_offset += v
        elif opcode == 0x80:
            count, p = read_uleb(data, p)
            skip, p = read_uleb(data, p)
            for _ in range(count):
                out.append((seg_index, seg_vmaddrs[seg_index] + seg_offset))
                seg_offset += psize + skip
        else:
            raise SystemExit('未知 rebase opcode %#02x @ %#x' % (b, p - 1))
    return out


# ── 版式测算 ─────────────────────────────────────────────────
def plan(path):
    data = open(path, 'rb').read()
    m = MachO(data)
    segs = m.segments()
    text = next((s for s in segs if s['name'] == '__TEXT'), None)
    if text is None or not text['sects']:
        return None
    content = [s for s in text['sects']
               if s['size'] > 0 and (s['flags'] & 0xFF) not in ZEROFILL_TYPES]
    if not content:
        return None
    first_off = min(s['off'] for s in content)
    shift = PAGE if first_off < PAGE else 0
    last_end = max(s['off'] + s['size'] for s in content) + shift
    text_size = align(last_end, PAGE)
    # 后面各段也跟着上移同一个 shift，所以 __TEXT 实际能用到的是「原距离 + shift」
    nxt = [(s['vmaddr'] - text['vmaddr']) for s in segs
           if s['name'] not in ('__PAGEZERO', '__TEXT') and s['vmaddr'] > text['vmaddr']]
    limit = (min(nxt) + shift) if nxt else text_size
    return {'m': m, 'segs': segs, 'text': text, 'shift': shift,
            'text_size': text_size, 'limit': limit, 'content_end': last_end,
            'first_off': first_off, 'image_end': m.image_end()}


def check(path):
    try:
        p = plan(path)
    except SystemExit as e:
        return 'FAIL: %s' % e
    if p is None:
        return 'skipped: 没有可用的 __TEXT 节'
    return ('shift=%#x 正文首节 %#x→%#x 内容末尾 %#x __TEXT 到 %#x（上限 %#x）'
            ' crypt=[%#x,+%#x] %s'
            % (p['shift'], p['first_off'], p['first_off'] + p['shift'],
               p['content_end'], p['text_size'], p['limit'], PAGE,
               max(0, p['text_size'] - PAGE),
               'OK' if p['shift'] == 0 else '需要上移'))


# ── 重排 ────────────────────────────────────────────────────
def transform(path):
    p = plan(path)
    if p is None:
        return 'skipped: 没有可用的 __TEXT 节'
    m, segs, text = p['m'], p['segs'], p['text']
    S = p['shift']
    if S == 0:
        cur = m.cmd_off(LC_ENCRYPTION_INFO_64)[0] or m.cmd_off(LC_ENCRYPTION_INFO)[0]
        if cur is not None:
            want = (PAGE, p['text_size'] - PAGE)
            if (u32(m.d, cur + 8), u32(m.d, cur + 12)) != want:
                struct.pack_into('<III', m.d, cur + 8, want[0], want[1], 0)
                open(path, 'wb').write(bytes(m.d))
                return '已是上移后的版式，加密范围修正为 %#x+%#x' % want
        return '已经是苹果版式（正文在 %#x），没动' % p['first_off']
    if p['content_end'] > p['limit']:
        raise SystemExit('上移 %#x 后正文末 %#x 会压到下一段（%#x）'
                         % (S, p['content_end'], p['limit']))

    old = bytes(m.d)
    hdr_end = m.header_end()
    new = bytearray(len(old) + S)
    new[0:hdr_end] = old[0:hdr_end]                 # 头部与加载命令留在页 0
    new[hdr_end + S:] = old[hdr_end:]               # 其余内容整体后移一页

    lo = text['vmaddr'] + p['first_off']
    hi = text['vmaddr'] + p['image_end']
    m.d = new

    # 1) 段
    for s in segs:
        h = s['hdr']
        if s['name'] == '__PAGEZERO':
            continue
        if s['name'] == '__TEXT':
            struct.pack_into('<Q', m.d, h + 24, s['vmaddr'])
            struct.pack_into('<Q', m.d, h + 32, p['text_size'])
            struct.pack_into('<Q', m.d, h + 40, s['fileoff'])
            struct.pack_into('<Q', m.d, h + 48, p['text_size'])
            continue
        struct.pack_into('<Q', m.d, h + 24, s['vmaddr'] + S)
        struct.pack_into('<Q', m.d, h + 40, s['fileoff'] + S)

    # 2) 节
    for s in segs:
        for sec in s['sects']:
            h = sec['hdr']
            zerofill = (sec['flags'] & 0xFF) in ZEROFILL_TYPES
            if sec['addr']:
                struct.pack_into('<Q', m.d, h + 32, sec['addr'] + S)
            if not zerofill and sec['off']:
                struct.pack_into('<I', m.d, h + 48, sec['off'] + S)

    # 3) 指向 __LINKEDIT 的加载命令
    for cmd, off, size in m.cmds:
        if cmd in LINKEDIT_DATA_CMDS:
            v = u32(m.d, off + 8)
            if v:
                struct.pack_into('<I', m.d, off + 8, v + S)
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            for i in range(4):
                v = u32(m.d, off + 8 + i * 8)
                if v:
                    struct.pack_into('<I', m.d, off + 8 + i * 8, v + S)
        elif cmd == LC_SYMTAB:
            for f in (8, 16):
                v = u32(m.d, off + f)
                if v:
                    struct.pack_into('<I', m.d, off + f, v + S)

    # 4) 入口
    eoff, _ = m.cmd_off(LC_MAIN)
    if eoff:
        struct.pack_into('<Q', m.d, eoff + 8, u64(m.d, eoff + 8) + S)

    # 5) 符号表
    soff, _ = m.cmd_off(LC_SYMTAB)
    patched_sym = 0
    if soff:
        symoff, nsyms = u32(m.d, soff + 8), u32(m.d, soff + 12)
        for i in range(nsyms):
            q = symoff + i * 16
            n_type = m.d[q + 4]
            if (n_type & 0x0E) == 0 or (n_type & 0xE0) != 0:   # 外部符号 / stab
                continue
            val = u64(m.d, q + 8)
            if lo <= val < hi:
                struct.pack_into('<Q', m.d, q + 8, val + S)
                patched_sym += 1

    # 6) rebase 指针：全部段一起改（上一版只改了指向 __TEXT 的）
    segs_now = m.segments()
    seg_vm = [s['vmaddr'] for s in segs_now]
    by_vm = sorted([s for s in segs_now if s['name'] != '__PAGEZERO'],
                   key=lambda s: s['vmaddr'])
    d_off, _ = m.cmd_off(LC_DYLD_INFO_ONLY)
    if d_off is None:
        d_off, _ = m.cmd_off(LC_DYLD_INFO)
    patched_ptr = 0
    if d_off:
        r_off, r_size = u32(m.d, d_off + 8), u32(m.d, d_off + 12)
        if r_size:
            for seg_idx, addr in parse_rebase(bytes(m.d), r_off, r_size, seg_vm):
                seg = next((s for s in by_vm if s['vmaddr'] <= addr <
                            s['vmaddr'] + max(s['filesize'], s['vmsize'])), None)
                if seg is None:
                    continue
                fo = seg['fileoff'] + (addr - seg['vmaddr'])
                if fo + 8 > len(m.d):
                    continue
                val = u64(m.d, fo)
                if lo <= val < hi:
                    struct.pack_into('<Q', m.d, fo, val + S)
                    patched_ptr += 1

    # 7) 加密信息
    write_encryption(m, PAGE, p['text_size'] - PAGE)

    open(path, 'wb').write(bytes(m.d))
    return ('ok: 上移 %#x 正文 %#x→%#x 符号 %d 指针 %d crypt=[%#x,+%#x] 文件 %#x→%#x'
            % (S, p['first_off'], p['first_off'] + S, patched_sym, patched_ptr,
               PAGE, p['text_size'] - PAGE, len(old), len(m.d)))


def write_encryption(m, cryptoff, cryptsize):
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
    if end + len(blob) > PAGE:
        raise SystemExit('加载命令区没空间插 LC_ENCRYPTION_INFO_64')
    m.d[end:end + len(blob)] = blob
    m.ncmds += 1
    m.sizeofcmds += len(blob)
    struct.pack_into('<I', m.d, 16, m.ncmds)
    struct.pack_into('<I', m.d, 20, m.sizeofcmds)


# ── UUID / SDK 标记 ──────────────────────────────────────────
def new_uuid(path):
    """换一个新的 LC_UUID：内容改了却留着旧 UUID，App Store Connect 会当成重复包。"""
    import uuid
    data = bytearray(open(path, 'rb').read())
    m = MachO(data)
    off, size = m.cmd_off(LC_UUID)
    if off is None:
        return '没有 LC_UUID，跳过'
    old = data[off + 8:off + 24].hex()
    new = uuid.uuid4().hex
    data[off + 8:off + 24] = bytes.fromhex(new)
    open(path, 'wb').write(bytes(data))
    return 'UUID %s-%s → %s-%s' % (old[:8], old[8:12], new[:8], new[8:12])


def set_sdk(path, ver, minos=None):
    """
    改 LC_BUILD_VERSION：sdk(+16) 记录「用哪个 SDK 编的」，minos(+12) 是最低系统版本。

    字段顺序：cmd(0) cmdsize(4) platform(8) minos(12) sdk(16) ntools(20)。
    2026-11-19 记一笔：这里第一次写成 +12，把 minos 改成了 26.0，
    那等于「iOS 26 才装得上」，必须靠 --minos 显式指定最低版本。
    """
    def enc(v):
        a, b, c = [int(x) for x in (v.split('.') + ['0', '0'])[:3]]
        return (a << 16) | (b << 8) | c
    data = bytearray(open(path, 'rb').read())
    m = MachO(data)
    off, size = m.cmd_off(LC_BUILD_VERSION)
    if off is None:
        return '没有 LC_BUILD_VERSION，跳过'
    o_minos, o_sdk = u32(data, off + 12), u32(data, off + 16)
    struct.pack_into('<I', data, off + 16, enc(ver))
    if minos is not None:
        struct.pack_into('<I', data, off + 12, enc(minos))
    open(path, 'wb').write(bytes(data))
    return ('sdk %#x→%#x（%s） minos %#x→%#x（%s）'
            % (o_sdk, u32(data, off + 16), ver, o_minos, u32(data, off + 12),
               minos if minos else '未动'))


# ── 寻址巡检 ────────────────────────────────────────────────
def audit(path):
    """
    纯 Python 的独立自查：__text / __stubs / __stub_helper 里每一条
    adrp(+add/ldr) 或 adr 算出来的地址，必须落在映像的某个节里（含 zerofill 的 __bss）。

    上一版就是栽在这：代码整体挪了 0x3100、数据没挪，主包 2665 条寻址里 1766 条
    指到映像外面，包能上传、TestFlight 也装得上，但打开即崩。
    这个检查不需要原件对照，单看一个二进制就能发现，所以放进流水线当门禁。
    """
    data = open(path, 'rb').read()
    m = MachO(data)
    secs = [s for seg in m.segments() for s in seg['sects'] if s['size'] > 0]
    code = [s for s in secs if s['name'] in
            ('__text', '__stubs', '__stub_helper', '__auth_stub', '__auth_stubs')]
    if not code:
        return 'skipped: 没有可执行的节'

    def sxt(v, bits):
        return v - (1 << bits) if v & (1 << (bits - 1)) else v

    total = bad = 0
    samples = []
    for sec in code:
        buf = data[sec['off']:sec['off'] + sec['size']]
        for i in range(0, len(buf) - 4, 4):
            w = struct.unpack_from('<I', buf, i)[0]
            pc = sec['addr'] + i
            target = None
            if (w & 0x9F000000) == 0x90000000:                     # adrp
                imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
                target = (pc & ~0xFFF) + (sxt(imm, 21) << 12)
            elif (w & 0x1F000000) == 0x10000000:                    # adr
                imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
                target = pc + sxt(imm, 21)
            if target is None:
                continue
            add = 0
            if i + 4 < len(buf):
                n = struct.unpack_from('<I', buf, i + 4)[0]
                if (n & 0x7F000000) == 0x11000000:                  # add/sub 立即数
                    add = ((n >> 10) & 0xFFF) << (12 if (n >> 22) & 1 else 0)
                elif (n & 0x3B000000) == 0x39000000:                # ldr/str 无符号立即数
                    # 立即数已经除以访问宽度（8/4/2/1），要按 1<<size 还原
                    add = ((n >> 10) & 0xFFF) << ((n >> 30) & 3)
            total += 1
            full = target + add
            if not any(s['addr'] <= full < s['addr'] + s['size'] for s in secs):
                bad += 1
                if len(samples) < 4:
                    samples.append('%#x→%#x' % (pc, full))
    return ('寻址 %d 条，落在节外 %d 条%s'
            % (total, bad, '' if not bad else '（例：' + '，'.join(samples) + '）'))


def main():
    argv = sys.argv[1:]
    if not argv:
        print(__doc__)
        return 1
    skip = set()
    if '--sdk' in argv:
        skip.add(argv.index('--sdk') + 1)
    if '--minos' in argv:
        skip.add(argv.index('--minos') + 1)
    args = [a for i, a in enumerate(argv) if not a.startswith('--') and i not in skip]
    if not args:
        print(__doc__)
        return 1

    if '--sdk' in argv:
        ver = argv[argv.index('--sdk') + 1]
        minos = argv[argv.index('--minos') + 1] if '--minos' in argv else None
        for p in args:
            print('%s: %s' % (p, set_sdk(p, ver, minos)))
    elif '--uuid' in argv:
        for p in args:
            print('%s: %s' % (p, new_uuid(p)))
    elif '--check' in argv:
        for p in args:
            print('%s: %s' % (p, check(p)))
    elif '--audit' in argv:
        for p in args:
            print('%s: %s' % (p, audit(p)))
    else:
        for p in args:
            print('%s: %s' % (p, transform(p)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
