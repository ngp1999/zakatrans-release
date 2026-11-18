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
  | grep -o '"\(Apple Distribution\|iPhone Distribution\)[^"]*"' | head -1 | tr -d '"' || true)"
[ -n "$IDENTITY" ] || fail "钥匙串里没有 Distribution 证书，检查 p12 是否导错、密码是否正确。"
log "签名身份：$IDENTITY"

# ── 2. 解包 ────────────────────────────────────────────────────
log "2/9 解包 ipa"
mkdir -p "$WORK/payload"
unzip -q "$IPA" -d "$WORK/payload"
APP="$(ls -d "$WORK"/payload/Payload/*.app 2>/dev/null | head -1 || true)"
[ -n "$APP" ] || fail "ipa 结构不对：里面没有 Payload/*.app"
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
  fail "描述文件是给 $APP_BUNDLE_ID 的，但包里是 $APP_ID_FROM_PLIST，签了也装不上。"
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

# ── 9. 上传 ────────────────────────────────────────────────────
if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -n "$ASC_KEY_FILE" ]; then
  log "9/9 上传到 App Store Connect（几分钟，别中断）"
  mkdir -p "$HOME/.appstoreconnect/private_keys"
  cp "$ASC_KEY_FILE" "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  chmod 600 "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

  set +e
  xcrun altool --upload-app -f "$OUT" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --verbose 2>&1 | tee "$WORK/upload.log"
  STATUS=${PIPESTATUS[0]}
  set -e

  if grep -qE "No errors uploading|UPLOAD SUCCEEDED|success-message" "$WORK/upload.log" && [ "$STATUS" -eq 0 ]; then
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
