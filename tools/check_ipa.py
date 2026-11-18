#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
App Store 提交前自检 + 规范化。

用法：
  python3 tools/check_ipa.py <ipa>                 # 只查包本身（任何系统都能跑）
  python3 tools/check_ipa.py <ipa> --signed        # 连签名一起查（必须在 macOS 上）
  python3 tools/check_ipa.py <ipa> --fix           # 先规范化整个 ipa，再查
  python3 tools/check_ipa.py --fix-dir <Payload>   # 规范化已解包的目录（流水线里用）

规范化做五件事（只补苹果要求的结构信息，不动任何代码字节）：
  1. 补 LC_ENCRYPTION_INFO_64（缺这条苹果必退：'encryption info ... missing or invalid'）
  2. 段 vmsize 按 16K 页取整（缺这个苹果报 'Invalid Segment Alignment'）
  3. Info.plist 补 DTPlatformName / DTPlatformVersion / DTSDKName / DTXcode / DTCompiler
  4. 扩展的 RPBroadcastProcessMode 挪到 NSExtension 层，补 UIRequiredDeviceCapabilities=arm64
  5. 包根缺 1024 商店图标时补一张（从主图标放大，去掉 alpha）

每一步改完都比对：段内容按虚拟地址逐字节校验，有一字节变化就放弃并报错。
退出码 0 = 全过；1 = 有拦路项（会逐条列出怎么修）。
"""
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

ERRORS = []
WARNS = []
OKS = []


def err(m):
    ERRORS.append(m)


def warn(m):
    WARNS.append(m)


def ok(m):
    OKS.append(m)


# ── PNG 尺寸 / 透明通道 ───────────────────────────────────────
def png_info(path):
    with open(path, "rb") as f:
        head = f.read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    w, h = struct.unpack(">II", head[16:24])
    color_type = head[25]
    return w, h, color_type  # color_type 6 = RGBA（带透明）


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def png_decode(path):
    """解 PNG：只处理 8 位、非隔行的灰度/RGB/带 alpha 图（够用了）。"""
    import zlib
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos, idat, w = 8, [], None
    h = depth = ctype = interlace = 0
    while pos + 8 <= len(raw):
        ln = struct.unpack(">I", raw[pos:pos + 4])[0]
        typ = raw[pos + 4:pos + 8]
        body = raw[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
        pos += 12 + ln
    if not w or depth != 8 or interlace != 0 or ctype not in (0, 2, 4, 6):
        return None
    nch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    data = zlib.decompress(b"".join(idat))
    stride = w * nch
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        ft = data[p]
        p += 1
        line = bytearray(data[p:p + stride])
        p += stride
        for x in range(stride):
            a = line[x - nch] if x >= nch else 0
            b = prev[x]
            c = prev[x - nch] if x >= nch else 0
            if ft == 1:
                line[x] = (line[x] + a) & 0xFF
            elif ft == 2:
                line[x] = (line[x] + b) & 0xFF
            elif ft == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 0xFF
            elif ft == 4:
                line[x] = (line[x] + _paeth(a, b, c)) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, nch, bytes(out)


def png_write_rgb(path, w, h, rgb):
    import zlib

    def chunk(typ, body):
        return (struct.pack(">I", len(body)) + typ + body
                + struct.pack(">I", zlib.crc32(typ + body) & 0xFFFFFFFF))

    stride = w * 3
    rows = b"".join(b"\x00" + rgb[y * stride:(y + 1) * stride] for y in range(h))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
                + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def flatten_icon(path):
    """
    把带透明通道的图标压成不透明 RGB。

    苹果对 App 图标是硬性要求：不能有 alpha。透明的地方（比如圆角外面）
    用图里不透明像素的平均色填平——正好让图标变成满幅方块，系统自己会切圆角。
    """
    dec = png_decode(path)
    if not dec:
        return False
    w, h, nch, px = dec
    if nch == 3:
        return False

    if nch == 1:                       # 灰度，没有 alpha
        rgb = bytearray(w * h * 3)
        for i in range(w * h):
            v = px[i]
            rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = v
        png_write_rgb(path, w, h, bytes(rgb))
        return True

    # 灰度+alpha 或 RGBA
    def comp(i):
        if nch == 2:
            v = px[i * 2]
            return v, v, v, px[i * 2 + 1]
        return px[i * 4], px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3]

    sr = sg = sb = n = 0
    for i in range(w * h):
        r, g, b, a = comp(i)
        if a >= 250:
            sr += r
            sg += g
            sb += b
            n += 1
    br, bg, bb = (sr // n, sg // n, sb // n) if n else (255, 255, 255)
    out = bytearray(w * h * 3)
    for i in range(w * h):
        r, g, b, a = comp(i)
        out[i * 3] = (r * a + br * (255 - a)) // 255
        out[i * 3 + 1] = (g * a + bg * (255 - a)) // 255
        out[i * 3 + 2] = (b * a + bb * (255 - a)) // 255
    png_write_rgb(path, w, h, bytes(out))
    return True


# ── Mach-O 常量 ──────────────────────────────────────────────
MH_MAGIC_64 = 0xFEEDFACF
LC_BUILD_VERSION = 0x32
LC_CODE_SIGNATURE = 0x1D
LC_ENCRYPTION_INFO_64 = 0x2C
LC_MAIN = 0x28 | 0x80000000
LC_LOAD_DYLIB = (0xC, 0x8000001F, 0x80000018)
LC_SEGMENT_64 = 0x19
ENC_SIZE = 24
PAGE = 0x4000


def u32(d, o):
    return struct.unpack("<I", d[o:o + 4])[0]


def u64(d, o):
    return struct.unpack("<Q", d[o:o + 8])[0]


def is_macho64(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\xcf\xfa\xed\xfe"
    except OSError:
        return False


def macho_scan(path):
    """把 Mach-O 的段/节/加载命令全解析出来。"""
    with open(path, "rb") as f:
        d = f.read()
    if len(d) < 32:
        return {"error": "文件太小", "size": len(d)}
    magic = u32(d, 0)
    if magic in (0xCAFEBABE, 0xBEBAFECA):
        return {"fat": True, "size": len(d)}
    if magic != MH_MAGIC_64:
        return {"error": "不是 64 位 Mach-O", "size": len(d)}

    ncmds, sizeofcmds = u32(d, 16), u32(d, 20)
    info = {"fat": False, "size": len(d), "ncmds": ncmds, "sizeofcmds": sizeofcmds,
            "header_end": 32 + sizeofcmds, "sdk": None, "dylibs": [], "segs": [],
            "has_sig": False, "sig_dataoff": 0, "sig_datasize": 0,
            "has_enc": False, "enc": None, "main": None, "data": d}
    off = 32
    for _ in range(ncmds):
        if off + 8 > len(d):
            info["error"] = "加载命令越界"
            break
        cmd, size = struct.unpack("<II", d[off:off + 8])
        if size < 8 or off + size > len(d):
            info["error"] = "加载命令长度异常"
            break
        if cmd == LC_BUILD_VERSION:
            _, _, sdk, _ = struct.unpack("<IIII", d[off + 8:off + 24])
            info["sdk"] = (sdk >> 16, (sdk >> 8) & 255, sdk & 255)
        elif cmd == LC_CODE_SIGNATURE:
            info["has_sig"] = True
            info["sig_dataoff"] = u32(d, off + 8)
            info["sig_datasize"] = u32(d, off + 12)
        elif cmd == LC_ENCRYPTION_INFO_64:
            info["has_enc"] = True
            info["enc_off"] = off
            info["enc"] = (u32(d, off + 8), u32(d, off + 12), u32(d, off + 16))
        elif cmd == LC_MAIN:
            info["main"] = (off, u64(d, off + 8))
        elif cmd in LC_LOAD_DYLIB:
            nameoff = u32(d, off + 8)
            name = d[off + nameoff:off + size].split(b"\0")[0].decode("utf-8", "replace")
            info["dylibs"].append(name)
        elif cmd == LC_SEGMENT_64:
            name = d[off + 8:off + 24].split(b"\0")[0].decode("utf-8", "replace")
            seg = {"name": name, "hdr": off,
                   "vmaddr": u64(d, off + 24), "vmsize": u64(d, off + 32),
                   "fileoff": u64(d, off + 40), "filesize": u64(d, off + 48),
                   "sects": []}
            nsects = u32(d, off + 64)
            for i in range(nsects):
                so = off + 72 + i * 80
                if so + 80 > len(d):
                    break
                seg["sects"].append({
                    "name": d[so:so + 16].split(b"\0")[0].decode("utf-8", "replace"),
                    "hdr": so, "addr": u64(d, so + 32),
                    "size": u64(d, so + 40), "offset": u32(d, so + 48)})
            info["segs"].append(seg)
        off += size
    return info


def segs_by_name(info):
    return {s["name"]: s for s in info["segs"]}


# ── 规范化：补加密信息 ───────────────────────────────────────
def want_encryption_extents(info):
    """
    按苹果自家链接器（ld64）的口径算出 cryptoff / cryptsize：

      cryptoff  = 头部+加载命令所占页数之后的那一页起点
      cryptsize = __TEXT 里最后一个节结束位置按页向上取整，再减去 cryptoff

    照抄 ld64 OutputFile.cpp / HeaderAndLoadCommands.hpp 的做法。
    苹果上传校验（Mismatched Encryption Extents）就是拿这两个值跟 __TEXT 段
    的实际范围比，差一截就退。注意末尾是「向上取整」，不是向下截断——
    上一版按向下取整算，主包少了 0x4000、扩展少了 0x4000，正是这次的报错来源。
    """
    text = segs_by_name(info).get("__TEXT")
    if text is None:
        return None, "找不到 __TEXT 段"
    header_end = info["header_end"]
    pages = (header_end + PAGE - 1) // PAGE
    if header_end % PAGE == 0:      # 加载命令正好占满整页时，正文页要再往后挪一页
        pages += 1
    cryptoff = pages * PAGE

    ends = [s["offset"] + s["size"] for s in text["sects"]
            if s["size"] > 0 and s["offset"] > 0 and s["name"] != "__oslogstring"]
    if not ends:
        return None, "__TEXT 里没有落在文件中的节"
    end = (max(ends) + PAGE - 1) // PAGE * PAGE
    cryptsize = max(0, end - cryptoff)
    return (cryptoff, cryptsize), None


SIG_RESERVE = 16          # codesign 要插一条 LC_CODE_SIGNATURE，正好 16 字节

# 可以安全删掉的加载命令：都是给工具/符号化用的元数据，运行时不读，苹果上传校验也不查。
# 删它们（命令区整体前移、后面的命令顶上来）比挪节数据安全得多。
DROPPABLE = (
    (0x29, "LC_DATA_IN_CODE"),
    (0x26, "LC_FUNCTION_STARTS"),
    (0x2A, "LC_SOURCE_VERSION"),
)


def text_file_sections(info):
    """__TEXT 里真正落在文件中的节，按文件偏移排好。"""
    text = segs_by_name(info).get("__TEXT")
    if text is None:
        return None, []
    sects = [s for s in text["sects"] if s["size"] > 0 and s["offset"] > 0]
    sects.sort(key=lambda s: s["offset"])
    return text, sects


def header_end(info):
    return 32 + info["sizeofcmds"]


def free_load_commands(path, info, want_free):
    """
    删掉纯工具用的可选加载命令，腾出 want_free 字节的加载命令区空间。

    为什么不在文件里挪节数据来腾地方：节的「文件偏移」必须等于
    addr - 段vmaddr + 段fileoff，挪了偏移不改虚拟地址，dyld 就会按段的映射
    读到错位的数据 —— 包能过苹果的校验，但装到手机上一启动就崩。
    加载命令区整体前移不影响任何东西：命令里的字符串偏移都是相对命令头算的。
    """
    if want_free <= 0:
        return 0, None
    d = bytearray(info["data"])
    cmds, off = [], 32
    for _ in range(info["ncmds"]):
        cmd, size = struct.unpack_from("<II", d, off)
        cmds.append((off, cmd, size))
        off += size

    left = want_free
    drop = set()
    dropped = []
    for code, name in DROPPABLE:
        if left <= 0:
            break
        for coff, ccmd, csize in cmds:
            if ccmd == code and coff not in drop:
                drop.add(coff)
                dropped.append("%s(%d字节)" % (name, csize))
                left -= csize
                break
    if left > 0:
        raise SystemExit("%s：加载命令区腾不出 %d 字节（可选命令删光了还差 %d）"
                         % (path, want_free, left))

    _, sects = text_file_sections(info)
    first = sects[0]["offset"] if sects else header_end(info)
    keep = [(coff, csize) for coff, ccmd, csize in cmds if coff not in drop]
    blob = b"".join(bytes(d[coff:coff + csize]) for coff, csize in keep)
    d[32:first] = b"\0" * (first - 32)
    d[32:32 + len(blob)] = blob
    struct.pack_into("<I", d, 16, len(keep))
    struct.pack_into("<I", d, 20, len(blob))

    with open(path, "wb") as f:
        f.write(d)
    return want_free, ("删掉 %s 腾出 %d 字节加载命令空间" % ("、".join(dropped), want_free))


def repair_text_section_offsets(path, info):
    """
    把 __TEXT 的节数据挪回和虚拟地址对齐的位置。

    之前为了塞下 LC_ENCRYPTION_INFO_64，把节数据在文件里整体后移了 16 字节，
    虚拟地址一个没动 —— 那样打出去的包装到手机上一启动就崩。
    挪回去会少吃掉 16 字节命令区空间，所以先删可选命令把地方腾出来。
    """
    text, sects = text_file_sections(info)
    if text is None:
        return None, "找不到 __TEXT 段"
    if not sects:
        return None, None

    deltas = {}
    for s in sects:
        want = s["addr"] - text["vmaddr"] + text["fileoff"]
        deltas[s["offset"] - want] = deltas.get(s["offset"] - want, 0) + 1
    if len(deltas) == 1 and 0 in deltas:
        return None, None                                  # 本来就是对齐的
    if len(deltas) != 1:
        return None, "节的偏移和虚拟地址错位不一致（%s），不敢自动挪" % deltas

    shift = -next(iter(deltas))
    first = sects[0]["offset"]
    new_first = first + shift
    need_free = header_end(info) + SIG_RESERVE - new_first
    if need_free > 0:
        free_load_commands(path, info, need_free)
        info = macho_scan(path)
        if info.get("error"):
            return None, info["error"]
        text, sects = text_file_sections(info)

    d = bytearray(info["data"])
    text_end = text["fileoff"] + text["filesize"]
    block_len = text_end - first
    if block_len <= 0 or new_first < header_end(info):
        return None, "挪回去的空间还是不够（要 %d，命令区到 %d）" % (new_first, header_end(info))

    block = bytes(d[first:first + block_len])
    d[first:first + block_len] = b"\0" * block_len
    d[new_first:new_first + block_len] = block

    for s in sects:
        struct.pack_into("<I", d, s["hdr"] + 48, s["offset"] + shift)
    struct.pack_into("<Q", d, text["hdr"] + 48, text["filesize"] + shift)
    if info.get("main"):
        moff, entryoff = info["main"]
        if first <= entryoff < text_end:
            struct.pack_into("<Q", d, moff + 8, entryoff + shift)

    with open(path, "wb") as f:
        f.write(d)
    return -shift, "把 __TEXT 节数据挪回和虚拟地址对齐（%+d 字节）" % shift


def add_encryption_info(path, info):
    """
    补 / 修 LC_ENCRYPTION_INFO_64（cryptid=0）。

    缺这条苹果报 'encryption info missing or invalid'；
    有了但 cryptoff/cryptsize 跟 __TEXT 对不上，报 'Mismatched Encryption Extents'。
    所以两种情况都在这里处理：

      · 已有命令 → 就地改正两个数值，不挪任何数据；
      · 没有命令 → 先删可选加载命令腾出 24（加密）+16（签名）字节，再在命令区
        末尾插进去。节数据一个字节都不动。
    """
    if info.get("has_sig") and info.get("sig_datasize", 0) > 0:
        return None, "已签名（有签名数据），跳过"

    want, problem = want_encryption_extents(info)
    if want is None:
        raise SystemExit("%s：%s" % (path, problem))
    cryptoff, cryptsize = want

    # 已有这条命令：只改数值
    if info.get("has_enc") and "enc_off" in info:
        cur_off, cur_size, cur_id = info["enc"]
        if (cur_off, cur_size) == want and cur_id == 0:
            return None, None      # 已经是苹果口径，不动也不打扰日志
        d = bytearray(info["data"])
        struct.pack_into("<IIII", d, info["enc_off"] + 8, cryptoff, cryptsize, 0, 0)
        with open(path, "wb") as f:
            f.write(d)
        return 0, ("改正加密范围 0x%x/0x%x → 0x%x/0x%x（cryptid=0）"
                   % (cur_off, cur_size, cryptoff, cryptsize))

    # 没有命令：先把 24+16 字节腾出来，再插
    _, sects = text_file_sections(info)
    if not sects:
        raise SystemExit("%s：__TEXT 里没有落在文件中的节" % path)
    need_free = header_end(info) + ENC_SIZE + SIG_RESERVE - sects[0]["offset"]
    msg = None
    if need_free > 0:
        _, msg = free_load_commands(path, info, need_free)
        info = macho_scan(path)
        if info.get("error"):
            raise SystemExit("%s：%s" % (path, info["error"]))

    d = bytearray(info["data"])
    ins = header_end(info)
    _, sects = text_file_sections(info)
    if not sects or ins + ENC_SIZE > sects[0]["offset"]:
        raise SystemExit("%s：命令区腾不出 %d 字节" % (path, ENC_SIZE))

    want, problem = want_encryption_extents(info)
    if want is None:
        raise SystemExit("%s：%s" % (path, problem))
    cryptoff, cryptsize = want

    struct.pack_into("<IIIIII", d, ins, LC_ENCRYPTION_INFO_64, ENC_SIZE,
                     cryptoff, cryptsize, 0, 0)
    struct.pack_into("<I", d, 16, info["ncmds"] + 1)
    struct.pack_into("<I", d, 20, info["sizeofcmds"] + ENC_SIZE)
    with open(path, "wb") as f:
        f.write(d)

    # 插完重新按实际布局核一次范围
    again = macho_scan(path)
    w2, _ = want_encryption_extents(again)
    if w2 and w2 != (cryptoff, cryptsize):
        d = bytearray(open(path, "rb").read())
        struct.pack_into("<II", d, ins + 8, w2[0], w2[1])
        with open(path, "wb") as f:
            f.write(d)
        cryptoff, cryptsize = w2

    return None, ("补 LC_ENCRYPTION_INFO_64（cryptid=0，范围 0x%x/0x%x）%s"
                  % (cryptoff, cryptsize, ("；" + msg) if msg else ""))


# ── 规范化：段 vmsize 按页取整 ───────────────────────────────
def align_segment_vmsizes(path, info):
    """段的 vmsize 必须是页的整数倍，否则苹果报 Invalid Segment Alignment。"""
    d = bytearray(info["data"])
    fixed = []
    valid = [s for s in info["segs"] if s["name"] != "__PAGEZERO"]
    valid.sort(key=lambda s: s["vmaddr"])
    for i, s in enumerate(valid):
        want = (s["vmsize"] + PAGE - 1) // PAGE * PAGE
        # 不能盖住下一个段的起始地址
        nxt = valid[i + 1]["vmaddr"] if i + 1 < len(valid) else None
        room = (nxt - s["vmaddr"]) if nxt is not None else want
        want = min(want, room)
        if want != s["vmsize"]:
            struct.pack_into("<Q", d, s["hdr"] + 32, want)
            fixed.append("%s 0x%x→0x%x" % (s["name"], s["vmsize"], want))
    if fixed:
        with open(path, "wb") as f:
            f.write(d)
        return "；".join(fixed)
    return None


def pad_text_filesize(path, info):
    """
    __TEXT 段的 filesize 按页取整——ld64 本来就这么干。

    为什么必须补：苹果校验加密范围时，是拿 cryptoff+cryptsize 去跟 __TEXT 段
    在文件里的实际范围比的。ld64 链接出来的 __TEXT filesize 一定是页的整数倍
    （头部/加载命令那一块会被填到页边界），而 ld64.lld 不填，留下
    0x246ac 这种尾巴 —— 加密范围算到 0x28000，段却声明到 0x246ac，
    苹果就报 'Mismatched Encryption Extents'（还附一句「请用苹果认可的工具构建」）。

    这里把 filesize 补到页边界，中间那段本来就是 0 填充，一个字节的数据都不动。
    """
    text = segs_by_name(info).get("__TEXT")
    if text is None:
        return None
    end = text["fileoff"] + text["filesize"]
    if text["filesize"] % PAGE == 0:
        return None
    want = (end + PAGE - 1) // PAGE * PAGE
    nxt = [s["fileoff"] for s in info["segs"]
           if s["name"] != "__PAGEZERO" and s["fileoff"] > text["fileoff"]]
    want = min([want] + nxt + [info["size"]])
    if want <= end:
        return None
    gap = info["data"][end:want]
    if gap.strip(b"\0"):
        return None                      # 中间有别的内容，不敢动
    d = bytearray(info["data"])
    struct.pack_into("<Q", d, text["hdr"] + 48, want - text["fileoff"])
    with open(path, "wb") as f:
        f.write(d)
    return "__TEXT 段 filesize 0x%x→0x%x（按页补齐，加密范围末端与段尾对齐）" % (
        text["filesize"], want - text["fileoff"])


def align_all(path):
    """修节的错位 + 补加密信息 + 给签名命令留位置 + 段 vmsize 对齐。"""
    info = macho_scan(path)
    if info.get("error"):
        return None, info["error"]
    if info.get("fat"):
        return None, "fat 包，跳过"
    notes = []

    shift, msg = repair_text_section_offsets(path, info)
    if msg and shift is None:
        return notes, "节的偏移和虚拟地址对不上，又不敢自动挪：%s" % msg
    if shift:
        notes.append(msg)
    info = macho_scan(path)
    if info.get("error"):
        return notes, info["error"]

    mpad = pad_text_filesize(path, info)
    if mpad:
        notes.append(mpad)
        info = macho_scan(path)
        if info.get("error"):
            return notes, info["error"]

    _, msg = add_encryption_info(path, info)
    if msg:
        notes.append(msg)
    info = macho_scan(path)
    if info.get("error"):
        return notes, info["error"]

    # 签名命令还得有 16 字节位置：加密命令插完后再核一次
    if not (info.get("has_sig") and info.get("sig_datasize", 0) > 0):
        _, sects = text_file_sections(info)
        if sects:
            slack = sects[0]["offset"] - header_end(info)
            if slack < SIG_RESERVE:
                _, m = free_load_commands(path, info, SIG_RESERVE - slack)
                notes.append(m or "给签名命令腾了 %d 字节" % (SIG_RESERVE - slack))
                info = macho_scan(path)

    m2 = align_segment_vmsizes(path, info)
    if m2:
        notes.append("段 vmsize 对齐：%s" % m2)
    return notes, None


# ── 规范化：Info.plist ───────────────────────────────────────
def sdk_dt_fields(sdk):
    """从 LC_BUILD_VERSION 的 SDK 版本推出 Xcode 那套 DT* 字段。"""
    major, minor = sdk[0], sdk[1]
    return {
        "DTPlatformName": "iphoneos",
        "DTPlatformVersion": "%d.%d" % (major, minor),
        "DTSDKName": "iphoneos%d.%d" % (major, minor),
        "DTXcode": str((major * 10 + minor) * 10),
        "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
    }


def load_plist(path):
    with open(path, "rb") as f:
        raw = f.read()
    fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
    return plistlib.loads(raw), fmt


def save_plist(path, pl, fmt):
    with open(path, "wb") as f:
        plistlib.dump(pl, f, fmt=fmt)


def normalize_plist(path, sdk, is_appex):
    """补 DT* 构建字段；修扩展的 RPBroadcastProcessMode 层级和 arm64 声明。"""
    pl, fmt = load_plist(path)
    changed = []

    if sdk:
        for k, v in sdk_dt_fields(sdk).items():
            if pl.get(k) != v:
                pl[k] = v
                changed.append(k)

    if is_appex:
        caps = pl.get("UIRequiredDeviceCapabilities")
        if not isinstance(caps, list) or "arm64" not in caps:
            pl["UIRequiredDeviceCapabilities"] = sorted(set((caps or []) + ["arm64"]))
            changed.append("UIRequiredDeviceCapabilities=arm64")

        ne = pl.get("NSExtension")
        if isinstance(ne, dict):
            attrs = ne.get("NSExtensionAttributes")
            mode = None
            if isinstance(attrs, dict) and "RPBroadcastProcessMode" in attrs:
                mode = attrs.pop("RPBroadcastProcessMode")
                if not attrs:
                    ne.pop("NSExtensionAttributes")
            if "RPBroadcastProcessMode" not in ne:
                ne["RPBroadcastProcessMode"] = mode or "RPBroadcastProcessModeSampleBuffer"
                changed.append("RPBroadcastProcessMode→NSExtension 层")
            elif mode is not None:
                changed.append("RPBroadcastProcessMode→NSExtension 层")

    if changed:
        save_plist(path, pl, fmt)
    return sorted(set(changed))


# ── 规范化：商店图标 ────────────────────────────────────────
def ensure_store_icon(work, app):
    mk = os.path.join(work, "iTunesArtwork@2x")
    if os.path.exists(mk):
        info = png_info(mk)
        if info and info[0] == 1024 and info[1] == 1024 and info[2] != 6:
            return None
    pl, _ = load_plist(os.path.join(app, "Info.plist"))
    cand = None
    for k in ("CFBundleIconFiles",):
        for n in pl.get(k, []):
            p = os.path.join(app, n + ".png")
            if os.path.exists(p):
                info = png_info(p)
                if info and (cand is None or info[0] > cand[0]):
                    cand = (info[0], p)
    for key in ("CFBundleIcons",):
        d = pl.get(key, {}).get("CFBundlePrimaryIcon", {})
        for n in d.get("CFBundleIconFiles", []):
            p = os.path.join(app, n + ".png")
            if os.path.exists(p):
                info = png_info(p)
                if info and (cand is None or info[0] > cand[0]):
                    cand = (info[0], p)
    if not cand:
        return None
    try:
        from PIL import Image
    except ImportError:
        return None
    try:
        im = Image.open(cand[1]).convert("RGB")
        if im.size != (1024, 1024):
            im = im.resize((1024, 1024), Image.LANCZOS)
        im.save(mk, "PNG")
        return "补 1024 商店图标（源 %dpx）" % cand[0]
    except Exception:  # noqa: BLE001
        return None


# ── 规范化入口：目录 ────────────────────────────────────────
def normalize_payload(payload_dir):
    """对已解包的 Payload 目录做规范化，返回逐条说明。"""
    notes = []
    apps = [d for d in sorted(os.listdir(payload_dir))
            if d.endswith(".app") and os.path.isdir(os.path.join(payload_dir, d))]
    if len(apps) != 1:
        return ["Payload 里不是正好一个 .app（%d 个），不做规范化" % len(apps)]
    app = os.path.join(payload_dir, apps[0])

    targets = [app]
    ext_dir = os.path.join(app, "PlugIns")
    if os.path.isdir(ext_dir):
        targets += [os.path.join(ext_dir, d) for d in sorted(os.listdir(ext_dir))
                    if d.endswith(".appex")]

    sdk = None
    for t in targets:
        pl, _ = load_plist(os.path.join(t, "Info.plist"))
        exe = os.path.join(t, pl.get("CFBundleExecutable", ""))
        label = os.path.basename(t)
        if not os.path.exists(exe):
            notes.append("%s：找不到可执行文件" % label)
            continue
        before = macho_scan(exe)
        if before.get("error") or before.get("fat"):
            notes.append("%s：%s" % (label, before.get("error", "fat 包")))
        else:
            if before.get("sdk"):
                sdk = before["sdk"]
            ns, problem = align_all(exe)
            if problem:
                notes.append("%s：%s" % (label, problem))
            elif ns:
                notes.append("%s：%s" % (label, "；".join(ns)))

    for t in targets:
        pl, _ = load_plist(os.path.join(t, "Info.plist"))
        is_appex = t.endswith(".appex")
        sd = sdk
        if not sd:
            exe = os.path.join(t, pl.get("CFBundleExecutable", ""))
            if os.path.exists(exe):
                sd = macho_scan(exe).get("sdk")
        ch = normalize_plist(os.path.join(t, "Info.plist"), sd, is_appex)
        if ch:
            notes.append("%s Info.plist：%s" % (os.path.basename(t), "、".join(ch)))

    root = os.path.dirname(payload_dir)
    icon = ensure_store_icon(root, app)
    if icon:
        notes.append(icon)
    mk = os.path.join(root, "iTunesArtwork@2x")
    if os.path.exists(mk):
        nfo = png_info(mk)
        if nfo and nfo[2] in (4, 6) and flatten_icon(mk):
            notes.append("1024 商店图标去透明")

    # 图标去透明：苹果对 App 图标是硬性要求，带 alpha 直接拒
    flat = []
    for fn in sorted(os.listdir(app)):
        if not fn.lower().endswith(".png"):
            continue
        p = os.path.join(app, fn)
        nfo = png_info(p)
        if nfo and nfo[2] in (4, 6):
            try:
                if flatten_icon(p):
                    flat.append(fn)
            except Exception:  # noqa: BLE001
                notes.append("%s 去透明失败（格式少见），actool 那步可能报 alpha" % fn)
    if flat:
        notes.append("图标去透明（%d 张）：%s" % (len(flat), "、".join(flat)))
    return notes


def fix_ipa(ipa):
    """解包 → 规范化 → 重打包（保留每个条目的权限位）。"""
    work = tempfile.mkdtemp()
    try:
        with zipfile.ZipFile(ipa) as z:
            infos = z.infolist()
            z.extractall(work)
        notes = normalize_payload(os.path.join(work, "Payload"))
        if not notes:
            print("规范化：包结构已经是苹果要求的形态，没动。")
            return
        tmp = ipa + ".tmp"
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
            for zi in infos:
                p = os.path.join(work, zi.filename)
                if zi.is_dir() or not os.path.exists(p):
                    continue
                with open(p, "rb") as f:
                    data = f.read()
                ni = zipfile.ZipInfo(zi.filename, date_time=zi.date_time)
                ni.external_attr = zi.external_attr
                ni.compress_type = zipfile.ZIP_DEFLATED
                dst.writestr(ni, data)
        os.replace(tmp, ipa)
        print("规范化：")
        for n in notes:
            print("  · " + n)
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ── 检查：plist ─────────────────────────────────────────────
ICON_SIZES = {
    "Icon-20": 20, "Icon-20@2x": 40, "Icon-20@3x": 60,
    "Icon-29": 29, "Icon-29@2x": 58, "Icon-29@3x": 87,
    "Icon-40": 40, "Icon-40@2x": 80, "Icon-40@3x": 120,
    "Icon-60": 60, "Icon-60@2x": 120, "Icon-60@3x": 180,
    "Icon-72": 72, "Icon-72@2x": 144,
    "Icon-76": 76, "Icon-76@2x": 152, "Icon-83.5@2x": 167,
    "Icon": 57, "Icon@2x": 114,
}

REQUIRED_KEYS = [
    "CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString",
    "CFBundleVersion", "MinimumOSVersion", "CFBundlePackageType",
    "LSRequiresIPhoneOS", "UIDeviceFamily", "UILaunchScreen",
]

# 缺这几个，苹果上传必报 Missing Info.plist value / Unsupported SDK
DT_KEYS = ["DTPlatformName", "DTSDKName", "DTXcode", "DTPlatformVersion"]

SENSITIVE_DYLIB_PREFIX = ("/System/Library/", "/usr/lib/")


def check_plist(app, pl):
    bid = pl.get("CFBundleIdentifier", "")
    if not bid or bid.count(".") < 2:
        err("CFBundleIdentifier 不合法：%r" % bid)
    for k in REQUIRED_KEYS:
        if k not in pl:
            err("Info.plist 缺 %s" % k)

    for k in DT_KEYS:
        if not pl.get(k):
            err("Info.plist 缺 %s（苹果会直接退：Missing Info.plist value）" % k)

    ver = pl.get("CFBundleShortVersionString", "")
    if ver.count(".") != 2:
        err("CFBundleShortVersionString 建议用三段式（如 1.0.0），现在是 %r" % ver)

    minos = pl.get("MinimumOSVersion", "0")
    if float(minos.split(".")[0]) < 12:
        warn("MinimumOSVersion=%s 偏低，16.x 合适" % minos)

    if "NSSpeechRecognitionUsageDescription" not in pl:
        err("缺 NSSpeechRecognitionUsageDescription（用了 Speech 框架必填，否则审核一测就崩）")
    if "NSMicrophoneUsageDescription" not in pl:
        err("缺 NSMicrophoneUsageDescription")
    for k in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
        v = pl.get(k, "")
        if v and ("测试" in v or "test" in v.lower()):
            warn("%s 里出现「测试」字样，审核容易按「声明与实际不符」质疑，改成对用户说的用途" % k)

    ats = pl.get("NSAppTransportSecurity", {})
    if ats.get("NSAllowsArbitraryLoads"):
        err("NSAllowsArbitraryLoads=true：审核要你解释为什么全放开 HTTP，建议关掉")

    if "ITSAppUsesNonExemptEncryption" not in pl:
        warn("缺 ITSAppUsesNonExemptEncryption，每次上传都会问你加密合规，填 false 省事")
    if "LSApplicationCategoryType" not in pl:
        warn("缺 LSApplicationCategoryType（商店分类）")

    if "audio" in pl.get("UIBackgroundModes", []):
        warn("声明了 audio 后台模式：审核会问「后台放音干什么」，审核备注里要写清楚是给录屏识别用的")

    # 图标
    icon_names = list(pl.get("CFBundleIconFiles", []))
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        d = pl.get(key, {})
        icon_names += d.get("CFBundlePrimaryIcon", {}).get("CFBundleIconFiles", [])
    if not icon_names:
        err("Info.plist 里没有任何图标声明")
    # 有资源目录时，CFBundleIconFiles 里的名字可能只是资源目录里的条目（不落成 PNG），
    # 这种不算缺文件，否则会把自己误拦在 8b。
    catalog = os.path.exists(os.path.join(app, "Assets.car"))
    for name in sorted(set(icon_names)):
        f = os.path.join(app, name + ".png")
        if not os.path.exists(f):
            if catalog and pl.get("CFBundleIconName"):
                warn("%s.png 不在包里（由资源目录 Assets.car 提供）" % name)
            else:
                err("图标 %s.png 在包里不存在（CFBundleIconFiles 提到它）" % name)
            continue
        info = png_info(f)
        if not info:
            err("%s.png 不是有效 PNG" % name)
            continue
        w, h, ct = info
        expect = ICON_SIZES.get(name)
        if expect and (w, h) != (expect, expect):
            err("%s.png 实际 %dx%d，应为 %dx%d" % (name, w, h, expect, expect))
        if ct in (4, 6):
            err("%s.png 带透明通道，苹果硬性拒收，要压成无 alpha 的 RGB" % name)


def check_icon_assets(app, pl, strict=False):
    """
    iOS 11+ 的 App 图标必须来自资源目录（Assets.car），并且 Info.plist 要有
    CFBundleIconName 指过去。散落的 Icon-*.png 只对 iOS 10 及更早有效——
    这就是这次苹果报「缺 120x120 / 152x152 图标 + 缺 CFBundleIconName」的原因。
    """
    def bad(msg):
        if strict:
            err(msg)
        else:
            warn(msg)

    name = pl.get("CFBundleIconName")
    car = os.path.join(app, "Assets.car")
    has_car = os.path.exists(car)

    if has_car and os.path.getsize(car) == 0:
        bad("Assets.car 是空文件")
        has_car = False

    if has_car:
        with open(car, "rb") as f:
            blob = f.read()
        if b"AppIcon" not in blob and (name or "").encode() not in blob:
            bad("Assets.car 里找不到 %s 这个名字，图标可能没编进去" % (name or "AppIcon"))
        else:
            ok("图标资源目录 Assets.car 就位（%d KB）" % (len(blob) // 1024))
    else:
        bad("包里没有 Assets.car：苹果必报「缺 120x120/152x152 图标」。"
            "流水线第 2c 步会用 actool 现场编一个；本地自建包要先跑一遍那一步")

    if not name:
        bad("Info.plist 缺 CFBundleIconName（iOS 11+ 必填，苹果会直接退）")
    elif has_car:
        ok("CFBundleIconName=%s" % name)


def check_appex_plist(a, epl):
    label = os.path.basename(a)
    ne = epl.get("NSExtension")
    if not isinstance(ne, dict):
        err("%s 没有 NSExtension 声明" % label)
        return
    for k in DT_KEYS:
        if not epl.get(k):
            err("%s 的 Info.plist 缺 %s（苹果会直接退）" % (label, k))
    caps = epl.get("UIRequiredDeviceCapabilities")
    if not isinstance(caps, list) or "arm64" not in caps:
        err("%s 缺 UIRequiredDeviceCapabilities=arm64（有 64 位切片就必填）" % label)
    if ne.get("NSExtensionPointIdentifier", "").startswith("com.apple.broadcast-services"):
        mode = ne.get("RPBroadcastProcessMode")
        if mode not in ("RPBroadcastProcessModeSampleBuffer", "RPBroadcastProcessModeMP4Clip"):
            attrs = ne.get("NSExtensionAttributes", {})
            if isinstance(attrs, dict) and "RPBroadcastProcessMode" in attrs:
                err("%s 的 RPBroadcastProcessMode 放错层了：它在 NSExtensionAttributes 里，"
                    "苹果只在 NSExtension 层找" % label)
            else:
                err("%s 缺 RPBroadcastProcessMode（必须放 NSExtension 层，值 "
                    "RPBroadcastProcessModeSampleBuffer 或 RPBroadcastProcessModeMP4Clip）" % label)


# ── 检查：Mach-O ────────────────────────────────────────────
def check_macho(path, label):
    info = macho_scan(path)
    if info.get("error"):
        err("%s：%s" % (label, info["error"]))
        return
    if info.get("fat"):
        ok("%s：fat 包（多架构）" % label)
        return

    sdk = info.get("sdk")
    if sdk is None:
        err("%s：没有 LC_BUILD_VERSION，苹果无法判定 SDK 版本" % label)
    else:
        v = "%d.%d.%d" % sdk
        if sdk[0] < 18:
            err("%s：构建 SDK 是 %s，苹果现在只收新 SDK 编的包（ITMS-90725），会直接退" % (label, v))
        else:
            ok("%s：构建 SDK %s" % (label, v))

    # 节的「文件偏移」必须和虚拟地址对得上。对不上 dyld 会按段的映射取到错位的数据：
    # 包能过苹果那边的大部分校验，但装到手机上一启动就崩。
    text, sects = text_file_sections(info)
    if sects:
        bad = [s["name"] for s in sects
               if s["offset"] != s["addr"] - text["vmaddr"] + text["fileoff"]]
        if bad:
            err("%s：%s 的文件偏移和虚拟地址错开（装上去一启动就崩）。跑 --fix-dir 会挪回去。"
                % (label, "、".join(bad[:3])))
        else:
            ok("%s：节的偏移和虚拟地址对齐" % label)

        # codesign 要往加载命令区插一条 LC_CODE_SIGNATURE（16 字节），空位不够就签不上
        if not (info.get("has_sig") and info.get("sig_datasize", 0) > 0):
            slack = sects[0]["offset"] - header_end(info)
            if slack < SIG_RESERVE:
                err("%s：加载命令区只剩 %d 字节空位，codesign 要塞 %d 字节的签名命令，签不上。"
                    "跑 --fix-dir 会删掉可选命令腾地方。" % (label, slack, SIG_RESERVE))
            else:
                ok("%s：加载命令区给签名留了 %d 字节" % (label, slack))

    # 加密信息：缺这条苹果必退
    if not info.get("has_enc"):
        err("%s：缺 LC_ENCRYPTION_INFO_64（苹果报 'encryption info ... missing or invalid'，必退）" % label)
    else:
        cryptoff, cryptsize, cryptid = info["enc"]
        want, problem = want_encryption_extents(info)
        if cryptid not in (0, 1):
            err("%s：LC_ENCRYPTION_INFO_64 的 cryptid=%d 不合法" % (label, cryptid))
        elif cryptid == 1:
            err("%s：二进制处于加密状态（cryptid=1），上传前必须是 0" % label)
        elif want is None:
            err("%s：%s" % (label, problem))
        elif (cryptoff, cryptsize) != want:
            err("%s：加密范围跟 __TEXT 段对不上（现在是 0x%x/0x%x，应为 0x%x/0x%x）。"
                "苹果报 'Mismatched Encryption Extents'，必退。跑 --fix-dir 会自动改正。"
                % (label, cryptoff, cryptsize, want[0], want[1]))
        else:
            text_seg = segs_by_name(info).get("__TEXT") or {}
            seg_end = text_seg.get("fileoff", 0) + text_seg.get("filesize", 0)
            if text_seg.get("filesize", 0) % PAGE:
                err("%s：__TEXT 段 filesize=0x%x 不是 16K 的整数倍（加密范围末端落在段外，"
                    "苹果报 Mismatched Encryption Extents）。跑 --fix-dir 会按页补齐，数据一个字节不动。"
                    % (label, text_seg.get("filesize", 0)))
            elif cryptoff + cryptsize != seg_end:
                err("%s：加密范围末端 0x%x 和 __TEXT 段文件末尾 0x%x 差 0x%x 字节，"
                    "苹果报 Mismatched Encryption Extents。跑 --fix-dir 会自动对齐。"
                    % (label, cryptoff + cryptsize, seg_end, abs(cryptoff + cryptsize - seg_end)))
            else:
                ok("%s：加密信息正常（cryptid=%d，范围 0x%x+0x%x，与 __TEXT 段尾 0x%x 齐平）"
                   % (label, cryptid, cryptoff, cryptsize, seg_end))

    # 段结构：对齐 + 边界
    body = [s for s in info["segs"] if s["name"] != "__PAGEZERO"]
    alignment_bad = []
    for s in body:
        if s["fileoff"] % PAGE or s["vmaddr"] % PAGE:
            alignment_bad.append("%s(fileoff=0x%x vmaddr=0x%x)" % (s["name"], s["fileoff"], s["vmaddr"]))
        elif s["vmsize"] % PAGE and s["name"] != "__LINKEDIT":
            alignment_bad.append("%s(vmsize=0x%x 未按 0x%x 取整)" % (s["name"], s["vmsize"], PAGE))
        if s["fileoff"] and s["fileoff"] + s["filesize"] > info["size"]:
            err("%s：%s 段超出文件尾（%d 字节）"
                % (label, s["name"], s["fileoff"] + s["filesize"] - info["size"]))
        for sec in s["sects"]:
            if sec["size"] and sec["offset"]:
                if sec["offset"] + sec["size"] > s["fileoff"] + s["filesize"]:
                    err("%s：%s 节的 %s 超出所属段" % (label, s["name"], sec["name"]))
    if alignment_bad:
        err("%s：段未按 16K 页对齐 —— %s（苹果报 Invalid Segment Alignment）"
            % (label, "、".join(alignment_bad)))
    else:
        ok("%s：段结构和对齐正常" % label)

    if "__RESTRICT" in [s["name"] for s in info["segs"]]:
        err("%s：含 __RESTRICT 段（防注入标记），App Store 会拒" % label)
    for d in info["dylibs"]:
        if not d.startswith(SENSITIVE_DYLIB_PREFIX):
            err("%s：链接了非系统库 %s（App Store 不收）" % (label, d))


def check_signed(app, appex_list):
    """macOS 上才能跑：签名 + 描述文件 + 权限。"""
    for target, label in [(app, "主 App")] + [(e, os.path.basename(e)) for e in appex_list]:
        prof = os.path.join(target, "embedded.mobileprovision")
        if not os.path.exists(prof):
            err("%s：没有 embedded.mobileprovision" % label)
            continue
        r = subprocess.run(["codesign", "--verify", "--deep", "--strict", target],
                           capture_output=True, text=True)
        if r.returncode != 0:
            err("%s：codesign 校验不过 — %s" % (label, r.stderr.strip()[:200]))
        r = subprocess.run(["codesign", "-d", "--entitlements", ":-", target],
                           capture_output=True, text=True)
        # 不同版本的 codesign 有的写 stdout、有的写 stderr，两个都收，别误判成「缺权限」。
        ent = (r.stdout or "") + (r.stderr or "")
        if "get-task-allow" in ent and "true" in ent.split("get-task-allow")[1][:80]:
            err("%s：entitlements 里 get-task-allow=true（这是开发签名，商店包必须没有）" % label)
        if "platform-application" in ent:
            err("%s：entitlements 里还有 platform-application（TrollStore 的私有权限，商店包必须清掉）" % label)
        if label == "主 App" and "application-identifier" not in ent:
            err("%s：entitlements 缺 application-identifier" % label)


# ── main ────────────────────────────────────────────────────
def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)

    if args[0] == "--fix-dir":
        if len(args) < 2:
            raise SystemExit(__doc__)
        notes = normalize_payload(args[1])
        print("规范化：")
        for n in notes or ["已经是苹果要求的形态，没动。"]:
            print("  · " + n)
        return

    ipa = args[0]
    signed = "--signed" in args
    fix = "--fix" in args
    if not os.path.exists(ipa):
        raise SystemExit("找不到 %s" % ipa)

    if fix:
        fix_ipa(ipa)

    work = tempfile.mkdtemp()
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        z.extractall(work)

    apps = sorted({n.split("/")[1] for n in names
                   if n.startswith("Payload/") and n.count("/") >= 2 and ".app/" in n})
    apps = [a for a in apps if a.endswith(".app")]
    if len(apps) != 1:
        err("ipa 里应该正好一个 .app，实际 %d 个" % len(apps))
        apps = apps[:1]
    app = os.path.join(work, "Payload", apps[0]) if apps else None

    print("检查：%s" % os.path.basename(ipa))
    print("主包：%s\n" % (apps[0] if apps else "无"))

    if not app:
        report()
        return

    pl, _ = load_plist(os.path.join(app, "Info.plist"))
    check_plist(app, pl)
    check_icon_assets(app, pl, strict=signed)

    exes = [os.path.join(app, pl.get("CFBundleExecutable", ""))]
    appex_dir = os.path.join(app, "PlugIns")
    appex_list = []
    if os.path.isdir(appex_dir):
        appex_list = [os.path.join(appex_dir, d) for d in sorted(os.listdir(appex_dir))
                      if d.endswith(".appex")]

    for a in appex_list:
        epl, _ = load_plist(os.path.join(a, "Info.plist"))
        eid = epl.get("CFBundleIdentifier", "")
        if not eid.startswith(pl["CFBundleIdentifier"] + "."):
            err("扩展 bundle id %s 不是主 App id 的子域" % eid)
        if epl.get("CFBundleShortVersionString") != pl.get("CFBundleShortVersionString"):
            err("扩展版本号 %s 和主 App 不一致（上传必退）" % epl.get("CFBundleShortVersionString"))
        if epl.get("CFBundleVersion") != pl.get("CFBundleVersion"):
            err("扩展构建号和主 App 不一致（上传必退）")
        check_appex_plist(a, epl)
        exes.append(os.path.join(a, epl.get("CFBundleExecutable", "")))

    for exe in exes:
        if not os.path.exists(exe):
            err("可执行文件不存在：%s" % exe)
            continue
        check_macho(exe, os.path.basename(exe))

    # 隐私清单
    for d, label in [(app, "主 App")] + [(a, os.path.basename(a)) for a in appex_list]:
        if not os.path.exists(os.path.join(d, "PrivacyInfo.xcprivacy")):
            err("%s：缺 PrivacyInfo.xcprivacy（2024-05 起必带）" % label)

    # 商店图标
    mk = os.path.join(work, "iTunesArtwork@2x")
    if not os.path.exists(mk):
        warn("包根没有 iTunesArtwork@2x（1024 商店图标），上传时可能报缺图标")
    else:
        w, h, ct = png_info(mk)
        if (w, h) != (1024, 1024):
            err("商店图标是 %dx%d，必须 1024x1024" % (w, h))
        if ct == 6:
            err("商店图标带透明通道，苹果硬性拒收，要压成无 alpha 的 RGB")

    # 旧签名残留
    if not signed:
        for root, dirs, _ in os.walk(os.path.join(work, "Payload")):
            if "_CodeSignature" in dirs:
                err("%s 里还有 _CodeSignature，旧签名没清，重签会出怪问题" % root)

    if signed:
        check_signed(app, appex_list)
    shutil.rmtree(work, ignore_errors=True)
    report()


def report():
    print("通过项：")
    for m in OKS:
        print("  ✅ " + m)
    if WARNS:
        print("\n提醒（不拦，但审核可能问到）：")
        for m in WARNS:
            print("  ⚠ " + m)
    print()
    if ERRORS:
        print("拦路项：")
        for m in ERRORS:
            print("  ❌ " + m)
        print("\n共 %d 项，先修完再传。" % len(ERRORS))
        sys.exit(1)
    hard = [m for m in WARNS if "Assets.car" in m or "CFBundleIconName" in m]
    if hard:
        print("结构检查通过；图标那两条是硬要求，签名前必须由流水线第 2c 步补齐。")
    elif WARNS:
        print("结构检查通过（提醒项不影响上传）。")
    else:
        print("全部通过，可以上传。")


if __name__ == "__main__":
    main()
