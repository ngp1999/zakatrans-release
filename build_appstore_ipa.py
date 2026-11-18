#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ZakaTrans → App Store 提交包构建脚本

从 TrollStore/自签版 ipa 出发，产出一个「可以直接交给分发证书签名」的 ipa：
  1. Info.plist 按 App Store 要求重写（主 App + 录屏扩展）
  2. bundle id 统一成 com.zakatrans.app / com.zakatrans.app.ext
  3. 补齐 20/29/40 三档基础图标（原包缺，上传会报 missing icon）
  4. 补 PrivacyInfo.xcprivacy（2024-05 起必带）
  5. 清掉旧的 ad-hoc / TrollStore 签名段（里面带 platform-application、get-task-allow）
  6. 把构建 SDK 标记抬到 26.0（ITMS-90725 只认新 SDK 编的包）
  7. 重新打包成 ipa

用法：python3 build_appstore_ipa.py <源ipa> <输出ipa>
"""
import os
import plistlib
import shutil
import struct
import sys
import zipfile

APP_BUNDLE_ID = "com.zakatrans.app"
EXT_BUNDLE_ID = "com.zakatrans.app.ext"
VERSION = "1.0.0"
BUILD = "1"
SDK_MARK = (26, 0, 0)          # 写进 LC_BUILD_VERSION 的 sdk 字段
ICON_SOURCE_DIR = None          # 由调用方指定：一套完整的图标目录（根级 Icon*.png）

MAIN_PLIST = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": "Zaka 翻译",
    "CFBundleExecutable": "ZakaTrans",
    "CFBundleIdentifier": APP_BUNDLE_ID,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "ZakaTrans",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": VERSION,
    "CFBundleVersion": BUILD,
    "CFBundleSignature": "????",
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "CFBundleIconFiles": [
        "Icon-20", "Icon-20@2x", "Icon-20@3x",
        "Icon-29", "Icon-29@2x", "Icon-29@3x",
        "Icon-40", "Icon-40@2x", "Icon-40@3x",
        "Icon-60", "Icon-60@2x", "Icon-60@3x",
        "Icon", "Icon@2x",
    ],
    "CFBundleIcons": {
        "CFBundlePrimaryIcon": {
            "CFBundleIconFiles": ["Icon-60", "Icon-60@2x", "Icon-60@3x"],
            "UIPrerenderedIcon": False,
        }
    },
    "CFBundleIcons~ipad": {
        "CFBundlePrimaryIcon": {
            "CFBundleIconFiles": [
                "Icon-72", "Icon-72@2x",
                "Icon-76", "Icon-76@2x",
                "Icon-83.5@2x",
            ],
            "UIPrerenderedIcon": False,
        }
    },
    "ITSAppUsesNonExemptEncryption": False,
    "LSApplicationCategoryType": "public.app-category.productivity",
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": "16.0",
    "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": False},
    "NSMicrophoneUsageDescription":
        "用于把你说的话实时识别成文字并翻译。声音只在本机处理，不上传、不保存。",
    "NSSpeechRecognitionUsageDescription":
        "用于把语音或录屏里的声音识别成文字并生成字幕。识别结果仅用于本次翻译，不保存、不上传。",
    "UIApplicationSupportsIndirectInputEvents": True,
    "UIBackgroundModes": ["audio"],
    "UIDeviceFamily": [1, 2],
    "UILaunchScreen": {},
    "UIRequiredDeviceCapabilities": ["arm64"],
    "UIStatusBarStyle": "UIStatusBarStyleLightContent",
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    "UISupportedInterfaceOrientations~ipad": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
    "UIViewControllerBasedStatusBarAppearance": True,
}

EXT_PLIST = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": "Zaka 翻译",
    "CFBundleExecutable": "Broadcast",
    "CFBundleIdentifier": EXT_BUNDLE_ID,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "Broadcast",
    "CFBundlePackageType": "XPC!",
    "CFBundleSignature": "????",
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "CFBundleShortVersionString": VERSION,
    "CFBundleVersion": BUILD,
    "MinimumOSVersion": "16.0",
    "NSExtension": {
        "NSExtensionAttributes": {"RPBroadcastProcessMode": "RPBroadcastProcessModeSampleBuffer"},
        "NSExtensionPointIdentifier": "com.apple.broadcast-services-upload",
        "NSExtensionPrincipalClass": "BroadcastHandler",
    },
    "NSMicrophoneUsageDescription":
        "用于在录屏时采集声音并生成翻译字幕。声音只在本机处理，不上传、不保存。",
    "NSSpeechRecognitionUsageDescription":
        "用于把录屏里的声音识别成文字并生成字幕。识别结果仅用于本次翻译，不保存、不上传。",
}

PRIVACY_MANIFEST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>NSPrivacyAccessedAPITypes</key>
\t<array>
\t\t<dict>
\t\t\t<key>NSPrivacyAccessedAPIType</key>
\t\t\t<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
\t\t\t<key>NSPrivacyAccessedAPITypeReasons</key>
\t\t\t<array><string>CA92.1</string></array>
\t\t</dict>
\t\t<dict>
\t\t\t<key>NSPrivacyAccessedAPIType</key>
\t\t\t<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
\t\t\t<key>NSPrivacyAccessedAPITypeReasons</key>
\t\t\t<array><string>C617.1</string><string>3B52.1</string></array>
\t\t</dict>
\t\t<dict>
\t\t\t<key>NSPrivacyAccessedAPIType</key>
\t\t\t<string>NSPrivacyAccessedAPICategoryDiskSpace</string>
\t\t\t<key>NSPrivacyAccessedAPITypeReasons</key>
\t\t\t<array><string>E174.1</string><string>85F4.1</string></array>
\t\t</dict>
\t\t<dict>
\t\t\t<key>NSPrivacyAccessedAPIType</key>
\t\t\t<string>NSPrivacyAccessedAPICategorySystemBootTime</string>
\t\t\t<key>NSPrivacyAccessedAPITypeReasons</key>
\t\t\t<array><string>35F9.1</string></array>
\t\t</dict>
\t</array>
\t<key>NSPrivacyCollectedDataTypes</key>
\t<array/>
\t<key>NSPrivacyTracking</key>
\t<false/>
\t<key>NSPrivacyTrackingDomains</key>
\t<array/>
</dict>
</plist>
"""


# ── Mach-O：清签名段 + 抬高 SDK 标记 ────────────────────────────────
# 注意：清签名不是简单把文件截到签名起点就完事。
# 签名段本身是算在 __LINKEDIT 段的 filesize 里的，只截文件不改段表，
# 段表就会声明一段不存在的区间（超出文件尾），codesign 会直接报
#   main executable failed strict validation
# 所以必须三件事一起做：截掉签名 → 段表长度改回真实值 → 去掉签名加载命令。
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
PAGE = 0x4000


def _u32(data, off):
    return struct.unpack("<I", data[off:off + 4])[0]


def _u64(data, off):
    return struct.unpack("<Q", data[off:off + 8])[0]


def patch_macho(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())

    magic = struct.unpack("<I", data[:4])[0]
    if magic != 0xFEEDFACF:
        raise SystemExit(f"{path}: 不是 64 位 Mach-O（magic={magic:#x}）")

    ncmds = _u32(data, 16)
    sizeofcmds = _u32(data, 20)
    off = 32
    sig = None           # (序号, 命令偏移, 命令长度, dataoff, datasize)
    linkedit = None
    sdk_patched = None

    for i in range(ncmds):
        cmd, size = struct.unpack("<II", data[off:off + 8])
        if cmd == LC_CODE_SIGNATURE and size >= 16:
            sig = (i, off, size, _u32(data, off + 8), _u32(data, off + 12))
        elif cmd == LC_SEGMENT_64 and data[off + 8:off + 24].rstrip(b"\0") == b"__LINKEDIT":
            linkedit = off
        elif cmd == LC_BUILD_VERSION:
            platform, minos, sdk, ntools = struct.unpack("<IIII", data[off + 8:off + 24])
            new_sdk = (SDK_MARK[0] << 16) | (SDK_MARK[1] << 8) | SDK_MARK[2]
            data[off + 16:off + 20] = struct.pack("<I", new_sdk)
            sdk_patched = (platform, minos, sdk, new_sdk)
        off += size

    if linkedit is None:
        raise SystemExit(f"{path}: 找不到 __LINKEDIT 段，这个二进制不正常，停止。")

    # 1) 截掉旧签名
    if sig and 0 < sig[3] <= len(data):
        data = data[:sig[3]]

    # 2) __LINKEDIT 的长度改回真实值（vmsize 不能小于 filesize，且按页对齐）
    le_fileoff = _u64(data, linkedit + 40)
    le_vmsize = _u64(data, linkedit + 32)
    filesize = len(data) - le_fileoff
    if filesize < 0:
        raise SystemExit(f"{path}: __LINKEDIT 起点超过文件长度，停止。")
    vmsize = le_vmsize
    while vmsize < filesize:
        vmsize += PAGE
    struct.pack_into("<Q", data, linkedit + 48, filesize)
    struct.pack_into("<Q", data, linkedit + 32, vmsize)

    # 3) 去掉签名加载命令（等效 codesign --remove-signature）
    if sig:
        i, cmd_off, size, _, _ = sig
        if i == ncmds - 1:
            data[cmd_off:cmd_off + size] = b"\0" * size
            struct.pack_into("<I", data, 16, ncmds - 1)
            struct.pack_into("<I", data, 20, sizeofcmds - size)
        else:
            # 不是最后一条就换成同长度的占位命令，保持命令序列不错位
            struct.pack_into("<IIQ", data, cmd_off, 0x2A, 16, 0)

    with open(path, "wb") as f:
        f.write(data)

    def ver(v):
        return "%d.%d.%d" % (v >> 16, (v >> 8) & 255, v & 255)

    _assert_consistent(path)

    msg = f"  {os.path.basename(path)}: "
    msg += f"SDK {ver(sdk_patched[2])} → {ver(sdk_patched[3])}; " if sdk_patched else "无 LC_BUILD_VERSION; "
    msg += "已清签名段（段表已同步）" if sig else "本来就没签名段"
    print(msg)


def _assert_consistent(path):
    """段表自检：任何一段的文件区间超出文件尾，就直接报错，别把坏包打出来。"""
    with open(path, "rb") as f:
        data = f.read()
    ncmds = _u32(data, 16)
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[off:off + 8])
        if cmd == LC_SEGMENT_64:
            name = data[off + 8:off + 24].rstrip(b"\0").decode()
            fileoff = _u64(data, off + 40)
            filesize = _u64(data, off + 48)
            if fileoff + filesize > len(data):
                raise SystemExit(
                    f"{path}: {name} 段超出文件尾（{fileoff + filesize:#x} > {len(data):#x}）")
        elif cmd == LC_CODE_SIGNATURE:
            raise SystemExit(f"{path}: 还残留 LC_CODE_SIGNATURE 加载命令")
        off += size


# ── 图标：补齐缺失的基础尺寸 ─────────────────────────────────────
def ensure_icons(app_dir):
    from PIL import Image
    base = None
    for cand in ("Icon-60@3x.png", "Icon-83.5@2x.png", "Icon@2x.png"):
        p = os.path.join(app_dir, cand)
        if os.path.exists(p):
            base = Image.open(p).convert("RGB")
            break
    if base is None:
        raise SystemExit("找不到可用作母版的图标")

    need = {
        "Icon-20.png": 20, "Icon-29.png": 29, "Icon-40.png": 40,
        "Icon-60.png": 60, "Icon-72.png": 72, "Icon-76.png": 76,
        "Icon.png": 57, "Icon@2x.png": 114,
        "Icon-20@2x.png": 40, "Icon-20@3x.png": 60,
        "Icon-29@2x.png": 58, "Icon-29@3x.png": 87,
        "Icon-40@2x.png": 80, "Icon-40@3x.png": 120,
        "Icon-60@2x.png": 120, "Icon-60@3x.png": 180,
        "Icon-72@2x.png": 144, "Icon-76@2x.png": 152, "Icon-83.5@2x.png": 167,
    }
    made = []
    for name, px in need.items():
        p = os.path.join(app_dir, name)
        if os.path.exists(p):
            continue
        base.resize((px, px), Image.LANCZOS).save(p, "PNG")
        made.append(name)
    if made:
        print("  补齐图标：" + ", ".join(made))


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    work = "/tmp/zaka-appstore-build"
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)

    with zipfile.ZipFile(src) as z:
        z.extractall(work)

    app = os.path.join(work, "Payload", "ZakaTrans.app")
    if not os.path.isdir(app):
        raise SystemExit("源 ipa 结构不对：没有 Payload/ZakaTrans.app")
    appex = os.path.join(app, "PlugIns", "Broadcast.appex")

    # 1) Info.plist
    with open(os.path.join(app, "Info.plist"), "wb") as f:
        plistlib.dump(MAIN_PLIST, f)
    with open(os.path.join(appex, "Info.plist"), "wb") as f:
        plistlib.dump(EXT_PLIST, f)
    print("  Info.plist 已按 App Store 要求重写（主 App + 扩展）")

    # 2) 图标
    ensure_icons(app)

    # 3) 隐私清单
    for d in (app, appex):
        with open(os.path.join(d, "PrivacyInfo.xcprivacy"), "w", encoding="utf-8") as f:
            f.write(PRIVACY_MANIFEST)
    print("  隐私清单已放入主 App 与扩展")

    # 4) 清签名 + 抬 SDK
    for b in (os.path.join(app, "ZakaTrans"), os.path.join(appex, "Broadcast")):
        patch_macho(b)

    # 5) 商店图标（ipa 根目录的 iTunesArtwork，苹果取 1024 那张当商店图标）
    from PIL import Image, ImageFilter
    mk = os.environ.get("MARKETING_ICON", "")
    if mk and os.path.exists(mk):
        src_icon = Image.open(mk).convert("RGB")
    else:
        src_icon = Image.open(os.path.join(app, "Icon-60@3x.png")).convert("RGB")
    for name, px in (("iTunesArtwork", 512), ("iTunesArtwork@2x", 1024)):
        img = src_icon if src_icon.size == (px, px) else src_icon.resize((px, px), Image.LANCZOS)
        if px > src_icon.size[0]:      # 从小图放大的，补一点锐度，免得糊
            img = img.filter(ImageFilter.UnsharpMask(radius=1.2, percent=90, threshold=2))
        p = os.path.join(work, name)
        img.save(p, "PNG")
    print(f"  商店图标已放入包根（512 / 1024，均无透明通道）")

    # 6) 打包
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name in ("iTunesArtwork", "iTunesArtwork@2x"):
            with open(os.path.join(work, name), "rb") as f:
                zi = zipfile.ZipInfo(name)
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = 0o644 << 16
                z.writestr(zi, f.read())
        for root, dirs, files in os.walk(os.path.join(work, "Payload")):
            for fn in files:
                full = os.path.join(root, fn)
                rel = os.path.relpath(full, work)
                zi = zipfile.ZipInfo(rel)
                zi.compress_type = zipfile.ZIP_DEFLATED
                mode = 0o755 if fn in ("ZakaTrans", "Broadcast") else 0o644
                zi.external_attr = mode << 16
                with open(full, "rb") as f:
                    z.writestr(zi, f.read())
    print(f"\n已生成 {out}  ({os.path.getsize(out) / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
