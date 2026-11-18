#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
App Store 提交前自检 —— 把苹果真实会拦的项全查一遍。

用法：
  python3 tools/check_ipa.py <ipa>              # 只查包本身（任何系统都能跑）
  python3 tools/check_ipa.py <ipa> --signed     # 连签名一起查（必须在 macOS 上）

退出码 0 = 全过；1 = 有拦路项（会逐条列出怎么修）。
"""
import os
import plistlib
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


# ── Mach-O ───────────────────────────────────────────────────
LC_BUILD_VERSION = 0x32
LC_CODE_SIGNATURE = 0x1D
LC_LOAD_DYLIB = (0xC, 0x8000001F, 0x80000018)
LC_SEGMENT_64 = 0x19


def macho_info(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 32:
        return {"fat": False, "error": "文件太小"}
    magic = struct.unpack("<I", data[:4])[0]
    if magic in (0xCAFEBABE, 0xBEBAFECA):
        return {"fat": True}
    if magic != 0xFEEDFACF:
        return {"fat": False, "error": "不是 64 位 Mach-O"}

    ncmds = struct.unpack("<I", data[16:20])[0]
    off = 32
    info = {"fat": False, "sdk": None, "dylibs": [], "segs": [], "has_sig": False}
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[off:off + 8])
        if cmd == LC_BUILD_VERSION:
            _, _, sdk, _ = struct.unpack("<IIII", data[off + 8:off + 24])
            info["sdk"] = (sdk >> 16, (sdk >> 8) & 255, sdk & 255)
        elif cmd == LC_CODE_SIGNATURE:
            info["has_sig"] = True
        elif cmd in LC_LOAD_DYLIB:
            nameoff = struct.unpack("<I", data[off + 8:off + 12])[0]
            name = data[off + nameoff:off + size].split(b"\0")[0].decode("utf-8", "replace")
            info["dylibs"].append(name)
        elif cmd == LC_SEGMENT_64:
            name = data[off + 8:off + 24].split(b"\0")[0].decode("utf-8", "replace")
            info["segs"].append(name)
        off += size
    return info


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

SENSITIVE_DYLIB_PREFIX = ("/System/Library/", "/usr/lib/")


def check_plist(app, pl):
    bid = pl.get("CFBundleIdentifier", "")
    if not bid or bid.count(".") < 2:
        err(f"CFBundleIdentifier 不合法：{bid!r}")
    for k in REQUIRED_KEYS:
        if k not in pl:
            err(f"Info.plist 缺 {k}")

    ver = pl.get("CFBundleShortVersionString", "")
    if ver.count(".") != 2:
        err(f"CFBundleShortVersionString 建议用三段式（如 1.0.0），现在是 {ver!r}")

    minos = pl.get("MinimumOSVersion", "0")
    if float(minos.split(".")[0]) < 12:
        warn(f"MinimumOSVersion={minos} 偏低，16.x 合适")

    if "NSSpeechRecognitionUsageDescription" not in pl:
        err("缺 NSSpeechRecognitionUsageDescription（用了 Speech 框架必填，否则审核一测就崩）")
    if "NSMicrophoneUsageDescription" not in pl:
        err("缺 NSMicrophoneUsageDescription")
    for k in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
        v = pl.get(k, "")
        if v and ("测试" in v or "test" in v.lower()):
            warn(f"{k} 里出现「测试」字样，审核容易按「声明与实际不符」质疑，改成对用户说的用途")

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
            err(f"图标 {name}.png 在包里不存在（CFBundleIconFiles 提到它）")
            continue
        info = png_info(f)
        if not info:
            err(f"{name}.png 不是有效 PNG")
            continue
        w, h, _ = info
        expect = ICON_SIZES.get(name)
        if expect and (w, h) != (expect, expect):
            err(f"{name}.png 实际 {w}x{h}，应为 {expect}x{expect}")


def check_macho(path, label):
    info = macho_info(path)
    if info.get("error"):
        err(f"{label}：{info['error']}")
        return
    if info.get("fat"):
        ok(f"{label}：fat 包（多架构）")
        return
    sdk = info.get("sdk")
    if sdk is None:
        err(f"{label}：没有 LC_BUILD_VERSION，苹果无法判定 SDK 版本")
    else:
        v = "%d.%d.%d" % sdk
        if sdk[0] < 18:
            err(f"{label}：构建 SDK 是 {v}，苹果现在只收新 SDK 编的包（ITMS-90725），会直接退")
        else:
            ok(f"{label}：构建 SDK {v}")
    if "__RESTRICT" in info["segs"]:
        err(f"{label}：含 __RESTRICT 段（防注入标记），App Store 会拒")
    for d in info["dylibs"]:
        if not d.startswith(SENSITIVE_DYLIB_PREFIX):
            err(f"{label}：链接了非系统库 {d}（App Store 不收）")


def check_signed(app, appex_list):
    """macOS 上才能跑：签名 + 描述文件 + 权限。"""
    for target, label in [(app, "主 App")] + [(e, os.path.basename(e)) for e in appex_list]:
        prof = os.path.join(target, "embedded.mobileprovision")
        if not os.path.exists(prof):
            err(f"{label}：没有 embedded.mobileprovision")
            continue
        r = subprocess.run(["codesign", "--verify", "--deep", "--strict", target],
                           capture_output=True, text=True)
        if r.returncode != 0:
            err(f"{label}：codesign 校验不过 — {r.stderr.strip()[:200]}")
        r = subprocess.run(["codesign", "-d", "--entitlements", ":-", target],
                           capture_output=True, text=True)
        ent = r.stdout
        if "get-task-allow" in ent and "true" in ent.split("get-task-allow")[1][:80]:
            err(f"{label}：entitlements 里 get-task-allow=true（这是开发签名，商店包必须没有）")
        if "platform-application" in ent:
            err(f"{label}：entitlements 里还有 platform-application（TrollStore 的私有权限，商店包必须清掉）")
        if label == "主 App" and "application-identifier" not in ent:
            err(f"{label}：entitlements 缺 application-identifier")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    ipa = sys.argv[1]
    signed = "--signed" in sys.argv

    if not os.path.exists(ipa):
        raise SystemExit(f"找不到 {ipa}")

    work = tempfile.mkdtemp()
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        z.extractall(work)

    apps = sorted({n.split("/")[1] for n in names
                   if n.startswith("Payload/") and n.count("/") >= 2 and ".app/" in n})
    apps = [a for a in apps if a.endswith(".app")]
    if len(apps) != 1:
        err(f"ipa 里应该正好一个 .app，实际 {len(apps)} 个")
        apps = apps[:1]
    app = os.path.join(work, "Payload", apps[0]) if apps else None

    print(f"检查：{os.path.basename(ipa)}")
    print(f"主包：{apps[0] if apps else '无'}\n")

    if not app:
        report()
        return

    with open(os.path.join(app, "Info.plist"), "rb") as f:
        pl = plistlib.load(f)
    check_plist(app, pl)

    exes = [os.path.join(app, pl.get("CFBundleExecutable", ""))]
    appex_dir = os.path.join(app, "PlugIns")
    appex_list = []
    if os.path.isdir(appex_dir):
        appex_list = [os.path.join(appex_dir, d) for d in sorted(os.listdir(appex_dir))
                      if d.endswith(".appex")]

    for a in appex_list:
        with open(os.path.join(a, "Info.plist"), "rb") as f:
            epl = plistlib.load(f)
        eid = epl.get("CFBundleIdentifier", "")
        if not eid.startswith(pl["CFBundleIdentifier"] + "."):
            err(f"扩展 bundle id {eid} 不是主 App id 的子域")
        if epl.get("CFBundleShortVersionString") != pl.get("CFBundleShortVersionString"):
            err(f"扩展版本号 {epl.get('CFBundleShortVersionString')} 和主 App 不一致（上传必退）")
        if epl.get("CFBundleVersion") != pl.get("CFBundleVersion"):
            err("扩展构建号和主 App 不一致（上传必退）")
        if "NSExtension" not in epl:
            err(f"{os.path.basename(a)} 没有 NSExtension 声明")
        exes.append(os.path.join(a, epl.get("CFBundleExecutable", "")))

    for exe in exes:
        if not os.path.exists(exe):
            err(f"可执行文件不存在：{exe}")
            continue
        check_macho(exe, os.path.basename(exe))

    # 隐私清单
    for d, label in [(app, "主 App")] + [(a, os.path.basename(a)) for a in appex_list]:
        if not os.path.exists(os.path.join(d, "PrivacyInfo.xcprivacy")):
            err(f"{label}：缺 PrivacyInfo.xcprivacy（2024-05 起必带）")

    # 商店图标
    mk = os.path.join(work, "iTunesArtwork@2x")
    if not os.path.exists(mk):
        warn("包根没有 iTunesArtwork@2x（1024 商店图标），上传时可能报缺图标")
    else:
        w, h, ct = png_info(mk)
        if (w, h) != (1024, 1024):
            err(f"商店图标是 {w}x{h}，必须 1024x1024")
        if ct == 6:
            err("商店图标带透明通道，苹果硬性拒收，要压成无 alpha 的 RGB")

    # 旧签名残留
    if not signed:
        for root, dirs, _ in os.walk(os.path.join(work, "Payload")):
            if "_CodeSignature" in dirs:
                err(f"{root} 里还有 _CodeSignature，旧签名没清，重签会出怪问题")

    if signed:
        check_signed(app, appex_list)
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
        print(f"\n共 {len(ERRORS)} 项，先修完再传。")
        sys.exit(1)
    print("全部通过，可以上传。")


if __name__ == "__main__":
    main()
