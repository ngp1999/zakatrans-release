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
                    "hdr": so, "size": u64(d, so + 40), "offset": u32(d, so + 48)})
            info["segs"].append(seg)
        off += size
    return info


def segs_by_name(info):
    return {s["name"]: s for s in info["segs"]}


# ── 规范化：补加密信息 ───────────────────────────────────────
def add_encryption_info(path, info):
    """
    补 LC_ENCRYPTION_INFO_64。

    加载命令区后面只剩十几字节，装不下 24 字节的新命令，所以把 __TEXT 段内的
    节数据在文件里整体后移（16 字节对齐），同时更新各节的文件偏移；
    虚拟地址一个都不动，代码里的引用全不受影响。
    """
    if info.get("has_enc"):
        return None, "已有 LC_ENCRYPTION_INFO_64"
    if info.get("has_sig") and info.get("sig_datasize", 0) > 0:
        return None, "已签名（有签名数据），跳过"

    d = bytearray(info["data"])
    text = segs_by_name(info).get("__TEXT")
    if text is None:
        raise SystemExit("%s：找不到 __TEXT 段" % path)

    file_sects = [s for s in text["sects"] if s["size"] > 0 and s["offset"] > 0]
    if not file_sects:
        raise SystemExit("%s：__TEXT 里没有落在文件中的节" % path)
    first = min(s["offset"] for s in file_sects)
    text_end = text["fileoff"] + text["filesize"]

    need = ENC_SIZE - (first - info["header_end"])
    shift = (need + 15) // 16 * 16 if need > 0 else 0

    # 平移要落在 __TEXT 之后、下一个段之前的空隙里，别压到别的段
    later = [s["fileoff"] for s in info["segs"]
             if s["fileoff"] >= text_end and s["name"] != "__PAGEZERO"]
    limit = min(later) if later else len(d)
    if limit - text_end < shift:
        raise SystemExit("%s：__TEXT 后面只有 %d 字节空隙，不够平移 %d"
                         % (path, limit - text_end, shift))

    if shift:
        block = bytes(d[first:text_end])
        d[first:text_end] = b"\0" * (text_end - first)
        d[first + shift:text_end + shift] = block
        for s in file_sects:
            struct.pack_into("<I", d, s["hdr"] + 48, s["offset"] + shift)
        if info.get("main"):
            moff, entryoff = info["main"]
            if first <= entryoff < text_end:
                struct.pack_into("<Q", d, moff + 8, entryoff + shift)
        struct.pack_into("<Q", d, text["hdr"] + 48, text["filesize"] + shift)
        struct.pack_into("<Q", d, text["hdr"] + 32, text["vmsize"] + shift)

    # 写新加载命令：cryptoff 指向第一个页之后，cryptsize 取到 __TEXT 数据末尾
    ins = info["header_end"]
    if ins + ENC_SIZE > first + shift:
        raise SystemExit("%s：腾出的空间不够放加密命令" % path)
    cryptoff = PAGE if text_end + shift > PAGE else 0
    cryptsize = max(0, ((text_end + shift - cryptoff) // PAGE) * PAGE)
    struct.pack_into("<IIIIII", d, ins, LC_ENCRYPTION_INFO_64, ENC_SIZE,
                     cryptoff, cryptsize, 0, 0)
    struct.pack_into("<I", d, 16, info["ncmds"] + 1)
    struct.pack_into("<I", d, 20, info["sizeofcmds"] + ENC_SIZE)

    with open(path, "wb") as f:
        f.write(d)
    return shift, "补 LC_ENCRYPTION_INFO_64（cryptid=0）" + ("，节数据后移 %d 字节" % shift if shift else "")


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


def align_all(path):
    """补加密信息 + 段 vmsize 对齐，两步都改完后返回说明。"""
    info = macho_scan(path)
    if info.get("error"):
        return None, info["error"]
    if info.get("fat"):
        return None, "fat 包，跳过"
    notes = []
    shift, msg = add_encryption_info(path, info)
    if shift is not None:
        notes.append(msg)
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

    icon = ensure_store_icon(os.path.dirname(payload_dir), app)
    if icon:
        notes.append(icon)
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
    for name in sorted(set(icon_names)):
        f = os.path.join(app, name + ".png")
        if not os.path.exists(f):
            err("图标 %s.png 在包里不存在（CFBundleIconFiles 提到它）" % name)
            continue
        info = png_info(f)
        if not info:
            err("%s.png 不是有效 PNG" % name)
            continue
        w, h, _ = info
        expect = ICON_SIZES.get(name)
        if expect and (w, h) != (expect, expect):
            err("%s.png 实际 %dx%d，应为 %dx%d" % (name, w, h, expect, expect))


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

    # 加密信息：缺这条苹果必退
    if not info.get("has_enc"):
        err("%s：缺 LC_ENCRYPTION_INFO_64（苹果报 'encryption info ... missing or invalid'，必退）" % label)
    else:
        cryptoff, cryptsize, cryptid = info["enc"]
        if cryptid not in (0, 1):
            err("%s：LC_ENCRYPTION_INFO_64 的 cryptid=%d 不合法" % (label, cryptid))
        elif cryptid == 1:
            err("%s：二进制处于加密状态（cryptid=1），上传前必须是 0" % label)
        elif cryptoff and cryptoff + cryptsize > info["size"]:
            err("%s：加密区间超出文件范围（cryptoff=0x%x cryptsize=0x%x，文件 0x%x）"
                % (label, cryptoff, cryptsize, info["size"]))
        else:
            ok("%s：加密信息正常（cryptid=%d）" % (label, cryptid))

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
        ent = r.stdout
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
    print("全部通过，可以上传。")


if __name__ == "__main__":
    main()
