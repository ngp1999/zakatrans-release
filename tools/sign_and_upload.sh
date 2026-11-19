#!/usr/bin/env bash
# ZakaTrans / ARDuel 通用：给已有 .ipa 重签成 App Store 分发包，自检通过后上传 App Store Connect
#
# 签名材料可以来自 asc_provision.py 的自动产出（provision/manifest.json），
# 也可以用 CERT_P12 / APP_PROFILE / EXT_PROFILE 手工指定。
#
# 用法（在 macOS 上，或 GitHub Actions 的 macos runner 里）：
#   bash tools/sign_and_upload.sh
set -euo pipefail

log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { echo "❌ $*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "这个脚本必须在 macOS 上运行（需要 codesign）。"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MANIFEST="${MANIFEST:-provision/manifest.json}"
if [ -f "${AUTO_ENV:-provision/env.sh}" ]; then
  log "0/9 读取自动生成的签名材料"
  # shellcheck disable=SC1090
  . "${AUTO_ENV:-provision/env.sh}"
fi

CERT_P12="${CERT_P12:-certs/distribution.p12}"
CERT_PASS="${CERT_PASS:-}"
APP_PROFILE="${APP_PROFILE:-profiles/app.mobileprovision}"
EXT_PROFILE="${EXT_PROFILE:-profiles/ext.mobileprovision}"
IPA="${IPA:-ZakaTrans-AppStore-1.0.0.ipa}"
OUT="${OUT:-ZakaTrans-AppStore-signed.ipa}"

ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_FILE="${ASC_KEY_FILE:-}"

# ── 0.4 从源码编译（仓库里有 ios/project.yml 就走这一步）──────────
# 为什么要放在这里：Apple 自家 ld64 编出来的二进制才带正确的段标志，
# 手工改字节那条路已经证明会崩。编出来的包交给下面的流程重签。
if [ -f "ios/project.yml" ] && [ "${SKIP_BUILD:-0}" != "1" ]; then
  log "0.4/9 从 SwiftUI 源码编译"
  if ! command -v xcodegen >/dev/null 2>&1; then
    brew install xcodegen >/dev/null 2>&1 || true
  fi
  command -v xcodegen >/dev/null 2>&1 || fail "xcodegen 装不上，没法生成工程"
  ( cd ios && xcodegen generate --quiet ) || fail "xcodegen 生成工程失败"
  mkdir -p build
  XC=0
  set +e
  xcodebuild -project ios/ZakaTrans.xcodeproj \
    -scheme ZakaTrans -configuration Release \
    -sdk iphoneos -derivedDataPath build/dd \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" ENABLE_BITCODE=NO \
    build > build/xcodebuild.log 2>&1 || XC=$?
  set -e
  if [ "${XC}" -ne 0 ]; then
    echo "---- 编译失败，最后 60 行 ----"
    tail -60 build/xcodebuild.log || true
    echo "---- 报错汇总 ----"
    grep -nE "error:|Undefined symbols" build/xcodebuild.log | head -30 || true
    fail "xcodebuild 失败（退出码 ${XC}）"
  fi
  APP_PATH="build/dd/Build/Products/Release-iphoneos/ZakaTrans.app"
  if [ ! -d "$APP_PATH" ]; then
    echo "---- 找 .app ----"
    find build -maxdepth 6 -type d -name "*.app" 2>/dev/null | head -10
    echo "---- 编译日志末尾 ----"
    tail -30 build/xcodebuild.log || true
    fail "编译产物里没有 ZakaTrans.app"
  fi
  rm -rf build/Payload && mkdir -p build/Payload
  cp -R "$APP_PATH" build/Payload/
  ( cd build && ditto -c -k --sequesterRsrc --keepParent Payload "../$IPA" )
  log "编译完成：${IPA}（$(du -h "$IPA" | cut -f1)）"
fi

[ -f "$CERT_P12" ] || fail "找不到签名证书：$CERT_P12"
[ -f "$APP_PROFILE" ] || fail "找不到主 App 描述文件：$APP_PROFILE"
[ -f "$IPA" ] || fail "找不到待签名的 ipa：$IPA"

# ── 1. 证书导入临时钥匙串 ───────────────────────────────────────
log "1/9 导入签名证书"
KEYCHAIN="$WORK/build.keychain-db"
KEYCHAIN_PASS="$(openssl rand -hex 12)"
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security import "$CERT_P12" -k "$KEYCHAIN" -P "$CERT_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | grep -oE '"(Apple Distribution|iPhone Distribution)[^"]*"' | head -1 | tr -d '"' || true)"
[ -n "$IDENTITY" ] || fail "钥匙串里没有 Distribution 证书，检查 p12 是否导错、密码是否正确。"
log "签名身份：$IDENTITY"

# ── 2. 解包 ────────────────────────────────────────────────────
log "2/9 解包 ipa"
mkdir -p "$WORK/payload"
unzip -q "$IPA" -d "$WORK/payload"

APP="$(ls -d "$WORK"/payload/Payload/*.app 2>/dev/null | head -1 || true)"
[ -n "$APP" ] || fail "ipa 结构不对：里面没有 Payload/*.app"

# ── 2-0. 可执行文件版式 ────────────────────────────────────────
# 包里的两个二进制已经按苹果链接器（ld64）的版式排好了：
#   · 加载命令独占第 0 页，正文从 0x4000 之后开始
#   · LC_ENCRYPTION_INFO_64 的 cryptoff/cryptsize 按 ld64 口径算，末端与 __TEXT 段尾齐平
#   · __TEXT / __DATA 的 vmsize 都是 16K 整页
# 这里只做一次核对，不合规就当场停下（不再拿 .o 重链——那批 .o 是重写界面的
# 那套源码，不能用来替换完整功能版的程序）。
log "2-0/9 核对可执行文件版式"
python3 tools/check_ipa.py --version >/dev/null 2>&1 || true
for BIN in "$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")" \
           $(ls "$APP"/PlugIns/*.appex/* 2>/dev/null | grep -v Info.plist | grep -v PkgInfo || true); do
  [ -f "$BIN" ] || continue
  python3 - "$BIN" <<'PYBIN' || fail "可执行文件版式不对：$BIN"
import struct, sys
p = sys.argv[1]
d = open(p, "rb").read()
if struct.unpack("<I", d[:4])[0] != 0xFEEDFACF:
    sys.exit(0)
ncmds = struct.unpack("<I", d[16:20])[0]
off, text, enc, dcflags = 32, None, None, None 
for _ in range(ncmds):
    cmd, size = struct.unpack("<II", d[off:off + 8])
    if cmd == 0x19 and d[off + 8:off + 24].rstrip(b"\0") == b"__TEXT":
        text = struct.unpack("<QQQQ", d[off + 24:off + 56])
    elif cmd == 0x19 and d[off + 8:off + 24].rstrip(b"\0") == b"__DATA_CONST":
        dcflags = struct.unpack("<I", d[off + 68:off + 72])[0]
    elif cmd == 0x2C:
        enc = struct.unpack("<III", d[off + 8:off + 20])
    off += size
if not text or not enc:
    print("  缺 __TEXT 段或 LC_ENCRYPTION_INFO_64")
    sys.exit(1)
vm, vs, fo, fs = text
co, cs, ci = enc
bad = []
# 逐条核每条加载命令的 cmdsize —— 苹果上传时会验，错一条整包退。
# 真实事故：加密命令写成 0x2E（那是 16 字节的 LC_LINKER_OPTIMIZATION_HINT），
# 结构却按 24 字节填，苹果回 'invalid load command token, cmdsize 24 Incorrect size'。
EXPECT = {0x2: 24, 0x3: 16, 0x8: 16, 0xB: 80, 0x1B: 24, 0x1D: 16, 0x1E: 16,
          0x21: 20, 0x22: 48, 0x80000022: 48, 0x24: 16, 0x25: 16, 0x26: 16,
          0x28: 24, 0x80000028: 24, 0x29: 16, 0x2A: 16, 0x2C: 24, 0x2E: 16,
          0x2F: 16, 0x30: 16, 0x31: 40, 0x33: 16, 0x80000033: 16,
          0x34: 16, 0x80000034: 16}
cmd_end = 32 + struct.unpack("<I", d[20:24])[0]
o2 = 32
while o2 + 8 <= cmd_end:
    c, s = struct.unpack("<II", d[o2:o2 + 8])
    if s < 8 or s % 8:
        bad.append("加载命令 0x%x 的 cmdsize=%d 不合法" % (c, s))
        break
    if c in EXPECT and s != EXPECT[c]:
        bad.append("加载命令 0x%x 的 cmdsize=%d（应为 %d）" % (c, s, EXPECT[c]))
    elif c == 0x19:
        nsects = struct.unpack("<I", d[o2 + 64:o2 + 68])[0]
        if s != 72 + 80 * nsects:
            bad.append("段命令 cmdsize=%d（应为 %d）" % (s, 72 + 80 * nsects))
    elif c == 0x32:
        ntools = struct.unpack("<I", d[o2 + 20:o2 + 24])[0]
        if s != 24 + 8 * ntools:
            bad.append("LC_BUILD_VERSION cmdsize=%d（应为 %d）" % (s, 24 + 8 * ntools))
    o2 += s
if fs % 0x4000 or vs % 0x4000:
    bad.append("__TEXT 不是整页（filesize=0x%x vmsize=0x%x）" % (fs, vs))
if co != 0x4000:
    bad.append("cryptoff=0x%x（应为 0x4000）" % co)
if co + cs != fs:
    bad.append("加密末端 0x%x ≠ __TEXT 段尾 0x%x" % (co + cs, fs))
if ci != 0:
    bad.append("cryptid=%d（应为 0）" % ci)
if bad:
    print("  " + "；".join(bad))
    sys.exit(1)
if dcflags is not None and not (dcflags & 0x10):
    print("  ⚠ %s：__DATA_CONST 缺 SG_READ_ONLY（flags=0x%x）—— 2a 会补上；"
          "补不上就装上闪退" % (p.rsplit("/", 1)[-1], dcflags))
print("  %s：版式 OK（crypt [0x%x,+0x%x]，段尾 0x%x）"
      % (p.rsplit("/", 1)[-1], co, cs, fs))
PYBIN
  echo "    二进制指纹：$(shasum -a 256 "$BIN" | cut -c1-16)  $(basename "$BIN")"

  # 寻址巡检：代码里的每一条 adrp(+add/ldr) 算出来的地址必须落在映像的节里。  # 真实事故（2026-11-19）：正文被挪了 0x3100、数据段没挪，68% 的引用指到映像外面，
  # 包能传上去、TestFlight 也装得上，但一打开就崩（SIGBUS / PC alignment）。
  if [ -f tools/macho_layout.py ]; then
    AUD="$(python3 tools/macho_layout.py --audit "$BIN" 2>/dev/null || true)"
    echo "    寻址巡检：${AUD:-（没跑起来）}"
    case "$AUD" in
      *"落在节外 0 条"*) : ;;
      *"落在节外 "*) fail "可执行文件寻址错位（装了会一开就崩）：$AUD" ;;
    esac
  fi
done

# ── 2a. 包结构规范化 ──────────────────────────────────────────
# 苹果会因为这几样直接拒，而且报错各不相同，看着像一堆问题其实是一类：
#   · 缺 LC_ENCRYPTION_INFO_64              → 'encryption info ... missing or invalid'
#   · 段 vmsize 没按 16K 取整               → 'Invalid Segment Alignment'
#   · Info.plist 缺 DTPlatformName/DTSDKName → 'Missing Info.plist value' + 'Unsupported SDK'
#   · 扩展 RPBroadcastProcessMode 放错层     → 'The key was not specified'
#   · 扩展缺 UIRequiredDeviceCapabilities    → 'Invalid Bundle ... must include arm64'
# 这里在签名前一次补齐；包本来就合规就不动它（幂等）。
log "2a/9 规范化包结构"
python3 tools/check_ipa.py --fix-dir "$WORK/payload/Payload" || fail "包结构规范化失败。"

# 2a+ 段标志复核：__DATA_CONST 必须带 SG_READ_ONLY。
# 这是 dyld 的硬性要求：缺了这一位，苹果那边全部校验都能过（上传成功、TestFlight
# 装得上），但一点图标就被系统拒绝加载、当场闪退，日志只有一句
#   DYLD: __DATA_CONST segment missing SG_READ_ONLY flag
# 真实事故：2026-11-19 build 11190220。补不上就绝不签名上传，省一次白跑。
python3 - "$WORK/payload/Payload" <<'PYFB' || fail "可执行文件的 __DATA_CONST 不是只读段，装上必闪退（见上）。"
import os, struct, sys
root = sys.argv[1]
def main_exe(bundle):
    info = os.path.join(bundle, "Info.plist")
    if not os.path.exists(info):
        return None
    try:
        import plistlib
        name = plistlib.load(open(info, "rb")).get("CFBundleExecutable")
    except Exception:
        return None
    p = os.path.join(bundle, name) if name else None
    return p if p and os.path.isfile(p) else None
bins = []
for dirpath, dirnames, _ in os.walk(root):
    if dirpath.endswith(".app") or dirpath.endswith(".appex"):
        b = main_exe(dirpath)
        if b:
            bins.append(b)
        dirnames[:] = [d for d in dirnames if not (d.endswith(".app") or d.endswith(".appex"))]
missing = []
for b in bins:
    d = open(b, "rb").read()
    if struct.unpack("<I", d[:4])[0] != 0xFEEDFACF:
        continue
    ncmds = struct.unpack("<I", d[16:20])[0]
    off = 32
    have = None
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", d[off:off + 8])
        if cmd == 0x19 and d[off + 8:off + 24].rstrip(b"\0") == b"__DATA_CONST":
            have = struct.unpack("<I", d[off + 68:off + 72])[0]
        off += size
    if have is not None and not (have & 0x10):
        missing.append("%s（flags=0x%x）" % (os.path.basename(b), have))
if missing:
    print("  ✗ 这些可执行文件的 __DATA_CONST 缺 SG_READ_ONLY：" + "、".join(missing))
    sys.exit(1)
print("  ✓ 可执行文件的 __DATA_CONST 都是只读段（%d 个）" % len(bins))
PYFB

APPEX="$(ls -d "$APP"/PlugIns/*.appex 2>/dev/null | head -1 || true)"

APP_ID_FROM_PLIST="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
log "包内主 App bundle id：$APP_ID_FROM_PLIST"
if [ -n "$APPEX" ]; then
  log "带扩展：$(basename "$APPEX")"
  EXT_ID_FROM_PLIST="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPEX/Info.plist")"
  log "包内扩展 bundle id：$EXT_ID_FROM_PLIST"
  [ -f "$EXT_PROFILE" ] || fail "这个包含扩展，必须给扩展的描述文件（EXT_PROFILE）。"
fi

if [ -n "${APP_BUNDLE_ID:-}" ] && [ "$APP_BUNDLE_ID" != "$APP_ID_FROM_PLIST" ]; then
  fail "描述文件是给 ${APP_BUNDLE_ID} 的，但包里是 ${APP_ID_FROM_PLIST}，签了也装不上。"
fi

# ── 2b. Mach-O 段表自检/自愈 ────────────────────────────────────
# 旧签名被截掉、但 __LINKEDIT 段声明的长度没跟着改，二进制就声称存在一段
# 超出文件尾的区间。这种包 codesign 会直接拒绝：
#   ZakaTrans.app/PlugIns/Broadcast.appex: main executable failed strict validation
# 这里在签名前统一修好：截签名 → 段表长度改回真实值 → 去掉签名加载命令。
log "2b/9 检查 Mach-O 段表"
python3 - "$WORK/payload/Payload" <<'PY'
import os, struct, sys

LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
MAGIC = 0xFEEDFACF
PAGE = 0x4000


def u32(d, o):
    return struct.unpack("<I", d[o:o + 4])[0]


def u64(d, o):
    return struct.unpack("<Q", d[o:o + 8])[0]


def load_cmds(d):
    ncmds = u32(d, 16)
    sizeofcmds = u32(d, 20)
    off, cmds = 32, []
    for i in range(ncmds):
        cmd, size = struct.unpack("<II", d[off:off + 8])
        cmds.append((i, off, cmd, size))
        off += size
    return ncmds, sizeofcmds, cmds


def fix(path):
    d = bytearray(open(path, "rb").read())
    orig_len = len(d)
    ncmds, sizeofcmds, cmds = load_cmds(d)
    sig = None
    linkedit = None
    for i, off, cmd, size in cmds:
        if cmd == LC_CODE_SIGNATURE and size >= 16:
            sig = (i, off, size, u32(d, off + 8), u32(d, off + 12))
        elif cmd == LC_SEGMENT_64 and d[off + 8:off + 24].rstrip(b"\0") == b"__LINKEDIT":
            linkedit = off
    if linkedit is None:
        raise SystemExit("%s: 找不到 __LINKEDIT 段" % path)

    le_fileoff = u64(d, linkedit + 40)
    le_filesize = u64(d, linkedit + 48)
    le_vmsize = u64(d, linkedit + 32)

    notes = []
    if sig and sig[3] == 0 and sig[4] == 0:
        notes.append("签名命令是空的")
    if le_fileoff + le_filesize > orig_len:
        notes.append("__LINKEDIT 超出文件 %d 字节" % (le_fileoff + le_filesize - orig_len))

    if sig and 0 < sig[3] <= len(d):
        d = d[:sig[3]]
        notes.append("清掉旧签名段")

    filesize = len(d) - le_fileoff
    if filesize < 0:
        raise SystemExit("%s: __LINKEDIT 起点超过文件长度" % path)
    vmsize = le_vmsize
    while vmsize < filesize:
        vmsize += PAGE
    struct.pack_into("<Q", d, linkedit + 48, filesize)
    struct.pack_into("<Q", d, linkedit + 32, vmsize)

    if sig:
        i, cmd_off, size = sig[0], sig[1], sig[2]
        if i == ncmds - 1:
            d[cmd_off:cmd_off + size] = b"\0" * size
            struct.pack_into("<I", d, 16, ncmds - 1)
            struct.pack_into("<I", d, 20, sizeofcmds - size)
        else:
            struct.pack_into("<IIQ", d, cmd_off, 0x2A, 16, 0)

    open(path, "wb").write(d)
    return "、".join(dict.fromkeys(notes)) if notes else "本来就是好的"


def check(path):
    d = open(path, "rb").read()
    ncmds, sizeofcmds, cmds = load_cmds(d)
    for i, off, cmd, size in cmds:
        if cmd == LC_SEGMENT_64:
            name = d[off + 8:off + 24].rstrip(b"\0").decode()
            fileoff, filesize = u64(d, off + 40), u64(d, off + 48)
            if fileoff + filesize > len(d) and name != "__PAGEZERO":
                return "%s 段超出文件尾" % name
        elif cmd == LC_CODE_SIGNATURE:
            return "还残留 LC_CODE_SIGNATURE"
    return None


root = sys.argv[1]
targets = []
for base, dirs, files in os.walk(root):
    for fn in files:
        p = os.path.join(base, fn)
        try:
            with open(p, "rb") as f:
                if f.read(4) == b"\xcf\xfa\xed\xfe":
                    targets.append(p)
        except OSError:
            pass

if not targets:
    raise SystemExit("Payload 里没找到 64 位 Mach-O，包结构不对")

bad = 0
for p in targets:
    rel = os.path.relpath(p, root)
    try:
        print("  %s：%s" % (rel, fix(p)))
        err = check(p)
    except Exception as e:  # noqa: BLE001
        print("  %s：修正失败 %s" % (rel, e))
        bad += 1
        continue
    if err:
        print("  ❌ %s：%s" % (rel, err))
        bad += 1

if bad:
    raise SystemExit("段表自检没过，停止签名")
print("  段表全部一致，可以签名")
PY

# ── 2b2. 复核 ─────────────────────────────────────────────────
# 上面这步会清掉二进制里的旧签名命令。如果送进来的是已签名的包，
# 2a 那轮会因为「有签名数据」跳过加密信息，清完签名这里再补一次。
log "2b2/9 复核包结构（清签名后再补一次加密信息）"
python3 tools/check_ipa.py --fix-dir "$WORK/payload/Payload" || fail "包结构复核失败。"

# ── 2c. 图标资源目录 ──────────────────────────────────────────
# 苹果对 iOS 11 以上的包只从 Assets.car 里找 App 图标，散落的 Icon-*.png 一律不认，
# 于是报「Missing required icon file 120x120 / 152x152」+「Missing CFBundleIconName」。
# 这一步用 Xcode 自带的 actool 现场编一个（runner 是 macOS，工具自带），
# 编完把 CFBundleIconName 指过去。散图标照样留着，老系统还要用。
log "2c/9 编译图标资源目录（actool）"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP/Info.plist" 2>/dev/null || echo 16.0)"
ICONSET="$WORK/Assets.xcassets/AppIcon.appiconset"
rm -rf "$WORK/Assets.xcassets"
mkdir -p "$ICONSET"
printf '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' > "$WORK/Assets.xcassets/Contents.json"

# 1024 商店图标：AppIcon 里必须有 ios-marketing 这一格，缺了 actool 直接报错。
# 包里没带就从最大的那张放大一张（sips 是 macOS 自带，不依赖第三方库）。
if [ ! -f "$WORK/payload/iTunesArtwork@2x" ]; then
  BIGGEST="$( { ls -S "$APP/Icon-83.5@2x.png" "$APP/Icon-76@2x.png" "$APP/Icon-60@3x.png" 2>/dev/null || true; } | sed -n "1p")"
  if [ -n "$BIGGEST" ]; then
    log "包里没带 1024 商店图标，从 $(basename "$BIGGEST") 放大一张补上"
    sips -z 1024 1024 "$BIGGEST" --out "$WORK/payload/iTunesArtwork@2x" >/dev/null 2>&1 || true
  fi
fi

# 注意：unzip -d "$WORK/payload" 之后，包根的 iTunesArtwork 系列在 "$WORK/payload" 下，
# 不在它的上一级。这里传的必须是 "$WORK/payload"。
python3 - "$APP" "$WORK/payload" "$ICONSET" <<'PY'
import json, os, shutil, struct, sys

app, root, iconset = sys.argv[1], sys.argv[2], sys.argv[3]

# (idiom, size, scale, 包里的文件名)
MAP = [
    ("iphone", "20x20", "2x", "Icon-20@2x.png"),
    ("iphone", "20x20", "3x", "Icon-20@3x.png"),
    ("iphone", "29x29", "2x", "Icon-29@2x.png"),
    ("iphone", "29x29", "3x", "Icon-29@3x.png"),
    ("iphone", "40x40", "2x", "Icon-40@2x.png"),
    ("iphone", "40x40", "3x", "Icon-40@3x.png"),
    ("iphone", "60x60", "2x", "Icon-60@2x.png"),
    ("iphone", "60x60", "3x", "Icon-60@3x.png"),
    ("ipad", "20x20", "1x", "Icon-20.png"),
    ("ipad", "20x20", "2x", "Icon-20@2x.png"),
    ("ipad", "29x29", "1x", "Icon-29.png"),
    ("ipad", "29x29", "2x", "Icon-29@2x.png"),
    ("ipad", "40x40", "1x", "Icon-40.png"),
    ("ipad", "40x40", "2x", "Icon-40@2x.png"),
    ("ipad", "76x76", "1x", "Icon-76.png"),
    ("ipad", "76x76", "2x", "Icon-76@2x.png"),
    ("ipad", "83.5x83.5", "2x", "Icon-83.5@2x.png"),
]


def png_size(p):
    """读 PNG 头拿像素尺寸；不是 PNG 返回 None。"""
    try:
        d = open(p, "rb").read(24)
    except OSError:
        return None
    if d[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", d[16:24])


def want_px(size, scale):
    base = float(size.split("x")[0])
    return int(round(base * float(scale.rstrip("x"))))


images, missing, wrong = [], [], []
for idiom, size, scale, fname in MAP:
    src = os.path.join(app, fname)
    if not os.path.exists(src):
        missing.append(fname)
        continue
    got = png_size(src)
    exp = want_px(size, scale)
    if got and got != (exp, exp):
        wrong.append("%s 是 %dx%d，这一格要 %dx%d" % (fname, got[0], got[1], exp, exp))
        continue
    dst = os.path.join(iconset, "icon-%s-%s@%s.png" % (idiom, size.split("x")[0], scale))
    shutil.copyfile(src, dst)
    images.append({"idiom": idiom, "size": size, "scale": scale,
                   "filename": os.path.basename(dst)})

# 1024 商店图标（App Store 必带，不能有 alpha）
mk = os.path.join(root, "iTunesArtwork@2x")
if os.path.exists(mk) and png_size(mk) == (1024, 1024):
    dst = os.path.join(iconset, "icon-marketing-1024@1x.png")
    shutil.copyfile(mk, dst)
    images.append({"idiom": "ios-marketing", "size": "1024x1024", "scale": "1x",
                   "filename": os.path.basename(dst)})
else:
    missing.append("iTunesArtwork@2x(1024)")

with open(os.path.join(iconset, "Contents.json"), "w") as f:
    json.dump({"images": images, "info": {"version": 1, "author": "zaka"}}, f, indent=2)

print("  图标条目：%d 个" % len(images))
if missing:
    print("  缺：%s" % "、".join(missing))
if wrong:
    print("  尺寸对不上（已跳过）：%s" % "；".join(wrong))
PY

CAR_OK=0
if xcrun --find actool >/dev/null 2>&1; then
  ACT_OUT="$WORK/asset-out"
  ACT_LOG="$WORK/actool.log"
  rm -rf "$ACT_OUT"
  mkdir -p "$ACT_OUT"
  # actool 不会自己建输出目录，目录不存在它直接报
  # 「The output directory ... does not exist」然后什么都不产出。
  set +e
  xcrun actool "$WORK/Assets.xcassets" \
    --compile "$ACT_OUT" \
    --platform iphoneos \
    --minimum-deployment-target "${MINOS:-16.0}" \
    --target-device iphone --target-device ipad \
    --app-icon AppIcon \
    --output-partial-info-plist "$WORK/asset-partial.plist" \
    --output-format human-readable-text > "$ACT_LOG" 2>&1
  ACT_STATUS=$?
  set -e
  sed 's/^/    /' "$ACT_LOG" || true

  if [ -s "$ACT_OUT/Assets.car" ]; then
    CAR_OK=1
    cp "$ACT_OUT/Assets.car" "$APP/Assets.car"
    # Xcode 编资源目录时也会把这两张编好的图标（AppIcon60x60@2x.png /
    # AppIcon76x76@2x~ipad.png）一起放进包里，老系统靠它们兜底。
    # 苹果的分析器在找「120x120 / 152x152 的 png」时也会看这几张。
    for pn in "$ACT_OUT"/*.png; do
      [ -e "$pn" ] || continue
      cp "$pn" "$APP/"
    done
    # 把 actool 的 partial plist 里的 CFBundleIconName 并进 Info.plist。
    # 缺这一项苹果直接退（Missing Info.plist value CFBundleIconName）。
    python3 - "$WORK/asset-partial.plist" "$APP/Info.plist" <<'PY' || true
import os, plistlib, sys

part, plist = sys.argv[1], sys.argv[2]
if not os.path.exists(part):
    raise SystemExit(0)
try:
    p = plistlib.load(open(part, "rb"))
except Exception:  # noqa: BLE001
    raise SystemExit(0)
if not isinstance(p, dict):
    raise SystemExit(0)
with open(plist, "rb") as f:
    info = plistlib.load(f)

name = p.get("CFBundleIconName") or "AppIcon"

# 按 actool 的输出整份对齐，别只抄 CFBundleIconName 一项。
# Xcode 编出来的包长这样（这一整套苹果的分析器都认）：
#   CFBundleIconName = AppIcon
#   CFBundleIcons      = {CFBundlePrimaryIcon = {CFBundleIconFiles = (AppIcon60x60), CFBundleIconName = AppIcon}}
#   CFBundleIcons~ipad = {CFBundlePrimaryIcon = {CFBundleIconFiles = (AppIcon60x60, AppIcon76x76), CFBundleIconName = AppIcon}}
info["CFBundleIconName"] = name
if isinstance(p.get("CFBundleIcons"), dict):
    info["CFBundleIcons"] = p["CFBundleIcons"]
if isinstance(p.get("CFBundleIcons~ipad"), dict):
    info["CFBundleIcons~ipad"] = p["CFBundleIcons~ipad"]
for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
    d = info.get(key)
    if isinstance(d, dict) and isinstance(d.get("CFBundlePrimaryIcon"), dict):
        d["CFBundlePrimaryIcon"].setdefault("CFBundleIconName", name)

# 老式顶层 CFBundleIconFiles（iOS 3.2~6 那套散图名字数组）删掉：
# iOS 11 以后苹果只认资源目录，留着它会让分析器走「找散图」的老路，
# 结果就是同时报「缺 120x120/152x152」+「缺 CFBundleIconName」。
info.pop("CFBundleIconFiles", None)

with open(plist, "wb") as f:
    plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)

print("  Info.plist 图标键：CFBundleIconName=%s；CFBundleIcons.CFBundlePrimaryIcon=%s；~ipad=%s"
      % (name,
         (info.get("CFBundleIcons") or {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconFiles"),
         (info.get("CFBundleIcons~ipad") or {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconFiles")))
PY
    /usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$APP/Info.plist" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Info.plist"
    log "已编入 Assets.car（$(du -h "$APP/Assets.car" | cut -f1)），CFBundleIconName=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Info.plist")"
  else
    log "⚠ actool 退出码 ${ACT_STATUS}，没产出 Assets.car —— 报错原文在上面"
  fi
else
  log "⚠ 这台机器上找不到 actool（非 Xcode 环境）"
fi

# 包里本来就带着资源目录（比如包是 Xcode 直接导出的）：那 actool 没跑成也不耽误
if [ "$CAR_OK" -ne 1 ] && [ -s "$APP/Assets.car" ] \
   && /usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$APP/Info.plist" >/dev/null 2>&1; then
  CAR_OK=1
  log "包里本来就有 Assets.car + CFBundleIconName，用包里这份"
fi

if [ "$CAR_OK" -ne 1 ]; then
  fail "图标资源目录没编出来。苹果只从 Resources 目录里找图标，散落的 PNG 它不认，
继续走下去必报「缺 120x120 / 152x152」+「缺 CFBundleIconName」。先修上面 actool 的报错再跑。"
fi


# 构建号：苹果只认比上一次高的，重复传同一个号会被 ITMS-90189 顶回来
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%m%d%H%M)}"
log "设置构建号 CFBundleVersion = $BUILD_NUMBER"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Info.plist"
[ -n "$APPEX" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APPEX/Info.plist"
log "版本号：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist") ($BUILD_NUMBER)"

# ── 3. 放描述文件 + 提 entitlements ────────────────────────────
log "3/9 放入描述文件"
cp "$APP_PROFILE" "$APP/embedded.mobileprovision"
[ -n "$APPEX" ] && cp "$EXT_PROFILE" "$APPEX/embedded.mobileprovision"

log "4/9 从描述文件生成 entitlements（保证和 profile 完全一致）"
security cms -D -i "$APP_PROFILE" > "$WORK/app_profile.plist"
plutil -extract Entitlements xml1 -o "$WORK/app.entitlements" "$WORK/app_profile.plist" 2>/dev/null \
  || fail "描述文件里没有 Entitlements，文件可能损坏。"
if [ -n "$APPEX" ]; then
  security cms -D -i "$EXT_PROFILE" > "$WORK/ext_profile.plist"
  plutil -extract Entitlements xml1 -o "$WORK/ext.entitlements" "$WORK/ext_profile.plist" 2>/dev/null \
    || fail "扩展描述文件里没有 Entitlements。"
fi

TEAM_ID="$(plutil -extract TeamIdentifier.0 raw "$WORK/app_profile.plist" 2>/dev/null || echo unknown)"
log "Team ID：$TEAM_ID"
echo "—— 主 App 权限 ——"
cat "$WORK/app.entitlements"

# App Group 自检：录屏扩展靠它和主 App 交换数据
if grep -q "com.apple.security.application-groups" "$WORK/app.entitlements"; then
  log "App Group 已授予"
  grep -A2 "com.apple.security.application-groups" "$WORK/app.entitlements" | grep -o 'group\.[A-Za-z0-9._-]*' | sort -u | sed 's/^/    /'
else
  log "⚠ 描述文件里没有 App Group —— 录屏扩展和主 App 将无法共享数据。"
  log "  修法：Apple Developer → Identifiers → 该 App ID → App Groups 勾上后重新生成描述文件。"
fi

# ── 5. 清掉旧签名 ──────────────────────────────────────────────
log "5/9 清理旧签名"
find "$WORK/payload" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
find "$WORK/payload" -name "CodeResources" -delete 2>/dev/null || true

# ── 6. 签名：先子后父 ──────────────────────────────────────────
log "6/9 签名（先扩展，后主 App）"
if [ -n "$APPEX" ]; then
  codesign --force --timestamp=none --sign "$IDENTITY" \
    --entitlements "$WORK/ext.entitlements" "$APPEX"
  log "扩展已签"
fi
codesign --force --timestamp=none --sign "$IDENTITY" \
  --entitlements "$WORK/app.entitlements" "$APP"
log "主 App 已签"

# ── 7. 校验 ────────────────────────────────────────────────────
log "7/9 校验签名"
codesign --verify --deep --strict --verbose=2 "$APP" || fail "签名校验没通过。"
echo "—— 实际写入主 App 的权限 ——"
codesign -d --entitlements :- "$APP" 2>/dev/null || true
if [ -n "$APPEX" ]; then
  echo "—— 实际写入扩展的权限 ——"
  codesign -d --entitlements :- "$APPEX" 2>/dev/null || true
fi

# ── 8. 重新打包（用 ditto，别用 zip，zip 会弄坏包结构）──────────
log "8/9 重新打包"
rm -rf "$WORK/repack" && mkdir -p "$WORK/repack"
cp -R "$WORK/payload/Payload" "$WORK/repack/Payload"
# 包根的 1024 商店图标一起带上（自检会看它）
for f in "$WORK"/payload/iTunesArtwork*; do
  [ -e "$f" ] || continue
  cp "$f" "$WORK/repack/"
done
( cd "$WORK/repack" && ditto -c -k --sequesterRsrc --keepParent Payload "$WORK/out.ipa" )
cp "$WORK/out.ipa" "$OUT"
if ! unzip -l "$OUT" | grep -qE "Payload/[^/]+\.app/Info\.plist"; then
  fail "重新打包后主 Info.plist 不见了，包是坏的，停止。"
fi
log "已生成：$OUT ($(du -h "$OUT" | cut -f1))"

# ── 8b. 提交前自检：苹果会拦的项先自己查一遍 ────────────────────
log "8b/9 提交前自检"
if ! python3 tools/check_ipa.py "$OUT" --signed; then
  fail "自检没过（上面列出的拦路项先修），这个包不往上传。"
fi

# ── 8c. 用苹果自己的分析器复核（altool 上传前就是拿 swinfo 看包的）──
# 目的：不再靠猜。苹果看到什么，这里就打什么；它看不到图标声明就当场停下，
# 别白花一次上传。
log "8c/9 复核苹果分析器眼里的包"
APP_NAME="$(basename "$APP")"
if unzip -p "$OUT" "Payload/$APP_NAME/Info.plist" > "$WORK/final.plist" 2>/dev/null; then
  echo "  最终包里的图标声明："
  plutil -p "$WORK/final.plist" | grep -E "CFBundleIcon(Name|s|Files)" | sed 's/^/    /' || true
fi

SWINFO="$(ls -d /Applications/Xcode*.app/Contents/SharedFrameworks/ContentDelivery.framework/Resources/swinfo 2>/dev/null | head -1 || true)"
if [ -n "$SWINFO" ]; then
  set +e
  "$SWINFO" -f "$OUT" -o "$WORK/desc.plist" --plistFormat xml --platform ios > "$WORK/swinfo.log" 2>&1
  SW=$?
  set -e
  if [ -s "$WORK/desc.plist" ] && grep -q "CFBundleShortVersionString" "$WORK/desc.plist"; then
    if grep -q "CFBundleIconName" "$WORK/desc.plist"; then
      log "苹果分析器看到了 CFBundleIconName 和资源目录，继续"
    else
      echo "  分析器抽出来的相关行："
      grep -nE "CFBundleIcon|Assets|AppIcon|120x120|152x152" "$WORK/desc.plist" | head -12 | sed 's/^/    /' || true
      fail "苹果的分析器在包里没看到 CFBundleIconName —— 这样传上去必报缺图标。上面是它实际抽到的东西。"
    fi
  else
    log "⚠ 分析器没产出可用的描述文件（退出码 ${SW}），跳过这一步"
    sed 's/^/    /' "$WORK/swinfo.log" | head -6 || true
  fi
else
  log "⚠ 这台机器上找不到苹果的分析器，跳过"
fi

# ── 9. 上传 ────────────────────────────────────────────────────
if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -n "$ASC_KEY_FILE" ]; then
  log "9/9 上传到 App Store Connect（几分钟，别中断）"
  mkdir -p "$HOME/.appstoreconnect/private_keys"
  cp "$ASC_KEY_FILE" "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  chmod 600 "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

  set +e
  if xcrun --find altool >/dev/null 2>&1; then
    log "上传工具：altool"
    xcrun altool --upload-app -f "$OUT" -t ios \
      --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --verbose 2>&1 | tee "$WORK/upload.log"
    STATUS=${PIPESTATUS[0]}
  elif xcrun --find iTMSTransporter >/dev/null 2>&1; then
    log "上传工具：Transporter（这台镜像没带 altool）"
    xcrun iTMSTransporter -m upload -assetFile "$OUT" \
      -apiKey "$ASC_KEY_ID" -apiIssuer "$ASC_ISSUER_ID" -v informational 2>&1 | tee "$WORK/upload.log"
    STATUS=${PIPESTATUS[0]}
  else
    : > "$WORK/upload.log"
    STATUS=127
    log "⚠ 这台机器上既没有 altool 也没有 Transporter"
  fi
  set -e

  if [ "$STATUS" -eq 0 ] && grep -qE "No errors uploading|UPLOAD SUCCEEDED|success-message|Package upload succeeded" "$WORK/upload.log"; then
    echo "✅ UPLOAD_OK"
  else
    echo "—— 苹果返回的错误码 ——"
    grep -oE "ITMS-[0-9]{5}[^\"<]*" "$WORK/upload.log" | sort -u || true
    grep -E "ERROR:|error:" "$WORK/upload.log" | head -20 || true
    fail "UPLOAD_FAILED：这个包没进苹果后台。"
  fi
else
  log "9/9 没给 API Key，跳过上传，只签名。"
fi
