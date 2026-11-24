#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用 App Store Connect API 自动准备签名材料，替代手工导出 p12 / 建描述文件。

产出（默认到 ./provision/）：
  dist.p12                      Apple Distribution 证书 + 私钥
  dist.p12.password             p12 密码
  ZakaTrans_AppStore.mobileprovision
  ZakaTrans_Ext_AppStore.mobileprovision
  manifest.json                 给后续签名脚本读的信息

需要的环境变量：
  ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_FILE  —— App Store Connect API Key
  APP_BUNDLE_ID（默认 com.zakatrans.app）
  EXT_BUNDLE_ID（默认 com.zakatrans.app.ext，留空表示不处理扩展）
  APP_GROUP（默认 group.com.zaka.trans，留空表示跳过能力检查）
  TEAM_APP_NAME（默认 ZakaTrans）

可选：
  ASC_DIST_P12_BASE64 / ASC_DIST_P12_PASSWORD
      现成的分发证书（p12 转 base64）。给了就直接用，账号里的证书一张都不动。
      不给就自动处理：有旧证书先吊销腾额度，再新建。
  ASC_KEEP_CERT_SERIALS
      逗号分隔的证书序列号，这几张不吊销（默认一张都不留）。
"""

import base64
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"


# ─────────────────────────── 基础工具 ───────────────────────────

def log(msg):
    print(f"[provision] {msg}", flush=True)


def die(msg):
    print(f"[provision] 失败：{msg}", flush=True)
    sys.exit(1)


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), check=True,
                          capture_output=True, text=True, **kw)


def _b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _der_ecdsa_to_raw(der: bytes) -> bytes:
    """openssl 输出的是 DER 编码的 ECDSA 签名（SEQUENCE{r,s}），JWT 要的是 raw R||S。"""
    i = 0
    if der[i] != 0x30:
        die("openssl 返回的签名格式不认识。")
    i += 1
    if der[i] & 0x80:
        i += 1 + (der[i] & 0x7F)
    else:
        i += 1

    def read_int() -> bytes:
        nonlocal i
        if der[i] != 0x02:
            die("openssl 返回的签名格式不认识。")
        i += 1
        n = der[i]
        i += 1
        val = der[i:i + n]
        i += n
        return val.lstrip(b"\x00") or b"\x00"

    r = read_int()
    s = read_int()
    return r.rjust(32, b"\x00") + s.rjust(32, b"\x00")


def _jwt_via_openssl(key_path: str, kid: str, iss: str, now: int) -> str:
    """不依赖 PyJWT / cryptography：用系统 openssl 直接签 ES256。"""
    header = {"alg": "ES256", "kid": kid, "typ": "JWT"}
    payload = {"iss": iss, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = "{}.{}".format(
        _b64u(json.dumps(header, separators=(",", ":"), sort_keys=False).encode()),
        _b64u(json.dumps(payload, separators=(",", ":"), sort_keys=False).encode()),
    )
    proc = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode(), capture_output=True,
    )
    if proc.returncode != 0 or not proc.stdout:
        die("openssl 签 JWT 失败：" + proc.stderr.decode(errors="replace")[:300])
    return signing_input + "." + _b64u(_der_ecdsa_to_raw(proc.stdout))


def load_jwt():
    key_path = os.environ["ASC_KEY_FILE"]
    kid = os.environ["ASC_KEY_ID"]
    iss = os.environ["ASC_ISSUER_ID"]
    now = int(time.time())
    try:
        import jwt  # PyJWT
        return jwt.encode(
            {"iss": iss, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
            pathlib.Path(key_path).read_text(), algorithm="ES256",
            headers={"kid": kid, "typ": "JWT"},
        )
    except Exception as exc:  # 没装 PyJWT / cryptography，或版本不兼容
        log(f"PyJWT 不可用（{exc.__class__.__name__}），改用 openssl 签 JWT")
    return _jwt_via_openssl(key_path, kid, iss, now)


class Client:
    def __init__(self):
        self.token = load_jwt()

    def req(self, method, path, body=None, ok=(200, 201, 204)):
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(
            API + path, data=data, method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(r) as resp:
                raw = resp.read().decode()
                return resp.status, (json.loads(raw) if raw.strip() else {})
        except urllib.error.HTTPError as e:
            raw = e.read().decode()
            try:
                parsed = json.loads(raw)
            except Exception:
                parsed = {"raw": raw}
            return e.code, parsed


def api_error_text(parsed):
    out = []
    for err in (parsed.get("errors") or []):
        title = err.get("title", "")
        detail = err.get("detail", "")
        code = err.get("code", "")
        out.append(f"{code} {title} {detail}".strip())
    return " | ".join(out) or json.dumps(parsed)[:400]


# ─────────────────────────── 业务步骤 ───────────────────────────

def ensure_bundle_id(c, identifier, name):
    """App ID 不存在就建，返回 (资源 id, 是否本次新建)。"""
    q = f"/v1/bundleIds?filter[identifier]={identifier}&limit=10"
    st, body = c.req("GET", q)
    if st == 200:
        for item in body.get("data", []):
            if item["attributes"]["identifier"] == identifier:
                log(f"App ID 已存在：{identifier} (id={item['id']})")
                return item["id"], False
    elif st not in (200,):
        die(f"查询 App ID 失败 {st}：{api_error_text(body)}")

    st, body = c.req("POST", "/v1/bundleIds", {
        "data": {
            "type": "bundleIds",
            "attributes": {"identifier": identifier, "name": name, "platform": "IOS"},
        }
    })
    if st not in (200, 201):
        die(f"创建 App ID {identifier} 失败 {st}：{api_error_text(body)}")
    new_id = body["data"]["id"]
    log(f"App ID 已创建：{identifier} (id={new_id})")
    return new_id, True


def enable_app_groups(c, bundle_resource_id, identifier):
    """开 App Groups 能力。开不出来不致命，后面会校验 profile 里有没有 group。"""
    st, body = c.req("POST", "/v1/bundleIdCapabilities", {
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": "APP_GROUPS"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_resource_id}}
            },
        }
    })
    if st in (200, 201):
        log(f"已开启 App Groups 能力：{identifier}")
    else:
        log(f"开启 App Groups 能力返回 {st}（可能本来就开着）：{api_error_text(body)}")


def list_capabilities(c, bundle_resource_id):
    st, body = c.req("GET", f"/v1/bundleIds/{bundle_resource_id}/bundleIdCapabilities?limit=200")
    if st != 200:
        return None
    return {i.get("attributes", {}).get("capabilityType") for i in body.get("data", [])}


def app_group_help(app_bid, ext_bid, app_group, reason):
    """App Group 只能在网页后台点，接口没开。把该点的地方一次写全。"""
    lines = [
        "",
        "=" * 62,
        f"停在这里：{reason}",
        "",
        f"录屏扩展要靠 App Group（{app_group}）把录好的东西交给主 App。",
        "这一项苹果没开接口，只能在后台点一次（一辈子就这一次，以后改版不用再点）。",
        "",
        "去点这三下：",
        "",
        "① 建 App Group（如果已经有了就跳过）",
        "   https://developer.apple.com/account/resources/identifiers/list/applicationGroup",
        "   右上角 + → 勾 App Groups → Continue",
        f"   Description：随便填，比如 ZakaTrans",
        f"   Identifier ：一字不差填 {app_group}",
        "   Continue → Register",
        "",
        f"② 主 App 勾上它：{app_bid}",
        "   https://developer.apple.com/account/resources/identifiers/list",
        f"   点列表里的 {app_bid} → 拉到 Capabilities",
        "   勾 App Groups → 点旁边的 Configure → 勾上那个 group → Continue → Save",
        "   右上角 Save",
        "",
    ]
    if ext_bid:
        lines += [
            f"③ 扩展也勾一遍：{ext_bid}",
            "   同样点进去 → Capabilities → App Groups → Configure → 勾上 → Continue → Save → 右上角 Save",
            "",
        ]
    lines += [
        "做完回 GitHub → Actions → 再点一次 Run workflow，这次就能一次跑完。",
        "=" * 62,
        "",
    ]
    return "\n".join(lines)


def make_csr(outdir):
    key = outdir / "dist.key"
    csr = outdir / "dist.csr"
    sh(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(csr),
        "-subj", "/CN=ZakaTrans Distribution/OU=ZAKA/O=ZAKA/C=CN"])
    return key, csr


DIST_CERT_TYPES = ("DISTRIBUTION", "IOS_DISTRIBUTION")


def norm_serial(value):
    """序列号统一成大写、去分隔符、去前导 0，好做比较。"""
    s = "".join(ch for ch in (value or "") if ch in "0123456789abcdefABCDEF")
    return s.lstrip("0").upper()


def list_distribution_certs(c):
    """列出账号里现有的分发证书，返回 (列表, 错误说明)。"""
    st, body = c.req(
        "GET",
        "/v1/certificates?limit=200"
        "&fields[certificates]=certificateType,displayName,expirationDate,serialNumber",
    )
    if st != 200:
        return None, f"{st} {api_error_text(body)}"
    out = []
    for item in body.get("data", []):
        kind = (item.get("attributes") or {}).get("certificateType") or ""
        if kind in DIST_CERT_TYPES:
            out.append(item)
    return out, ""


def revoke_certs(c, certs):
    for item in certs:
        attrs = item.get("attributes") or {}
        st, body = c.req("DELETE", f"/v1/certificates/{item['id']}")
        if st in (200, 204):
            log(f"已吊销分发证书：{attrs.get('displayName', '?')}"
                f"（序列号 {attrs.get('serialNumber', '?')}）")
        else:
            log(f"吊销「{attrs.get('displayName', '?')}」没成功：{st} {api_error_text(body)}")


def wait_certs_gone(c, tries=8, delay=5):
    """吊销在苹果那边是异步的，额度要过几秒才真的空出来。"""
    for i in range(tries):
        left, _ = list_distribution_certs(c)
        if left is None:
            return
        if not left:
            if i:
                log("额度已腾空。")
            return
        log(f"还有 {len(left)} 张分发证书没消失，等 {delay} 秒再看…")
        time.sleep(delay)


def try_create_cert(c, csr_path):
    """按两种 CSR 格式各试一次，成功返回 (cert_id, 证书 base64, '')。"""
    pem_body = "".join(
        line for line in csr_path.read_text().splitlines()
        if "-----" not in line
    )
    attempts = [
        ("base64(DER 正文)", pem_body),
        ("PEM 全文的 base64", base64.b64encode(csr_path.read_bytes()).decode()),
    ]
    last = ""
    for label, content in attempts:
        st, body = c.req("POST", "/v1/certificates", {
            "data": {
                "type": "certificates",
                "attributes": {"certificateType": "DISTRIBUTION", "csrContent": content},
            }
        })
        if st in (200, 201):
            data = body["data"]
            log(f"分发证书已创建（CSR 格式：{label}，id={data['id']}）")
            log(f"证书有效期：{(data.get('attributes') or {}).get('expirationDate', '?')}")
            return data["id"], data["attributes"]["certificateContent"], ""
        last = f"{st} {api_error_text(body)}"
        log(f"证书创建方式「{label}」没通过：{last}")
    return None, None, last


def p12_identity(p12_path, password):
    """从 p12 里读出证书序列号和中文名，读不出来返回 (None, None)。"""
    pem = ""
    for extra in ([], ["-legacy"], ["-nomacver"], ["-legacy", "-nomacver"]):
        proc = subprocess.run(
            ["openssl", "pkcs12", "-in", str(p12_path), "-nokeys",
             "-passin", f"pass:{password}"] + extra,
            capture_output=True, text=True,
        )
        if proc.returncode == 0 and "BEGIN CERTIFICATE" in proc.stdout:
            pem = proc.stdout
            break
    if not pem:
        return None, None
    proc = subprocess.run(["openssl", "x509", "-noout", "-serial", "-subject"],
                          input=pem, capture_output=True, text=True)
    serial = cn = None
    for line in (proc.stdout or "").splitlines():
        if line.startswith("serial="):
            serial = norm_serial(line.split("=", 1)[1])
        elif line.startswith("subject="):
            hit = re.search(r"CN\s*=\s*([^/\n]+)", line)
            if hit:
                cn = hit.group(1).strip()
    return serial, cn


def try_env_p12(c, outdir):
    """给了 ASC_DIST_P12_BASE64 就用现成的，一张证书都不吊销。"""
    raw = (os.environ.get("ASC_DIST_P12_BASE64") or "").strip()
    if not raw:
        return None
    p12 = outdir / "dist.p12"
    try:
        p12.write_bytes(base64.b64decode(raw, validate=False))
    except Exception:  # noqa: BLE001
        die("ASC_DIST_P12_BASE64 不是有效的 base64。")
    password = os.environ.get("ASC_DIST_P12_PASSWORD", "")
    serial, cn = p12_identity(p12, password)
    if not serial:
        die("这个 p12 打不开：检查 ASC_DIST_P12_PASSWORD 对不对、p12 是不是完整的。")
    if "Distribution" not in (cn or ""):
        die(f"这个 p12 不是分发证书（CN={cn}）。App Store 只能用 Apple Distribution 证书。")
    certs, err = list_distribution_certs(c)
    if certs is None:
        log(f"查证书列表失败（{err}），先按这个 p12 继续。")
        return None
    for item in certs:
        if norm_serial((item.get("attributes") or {}).get("serialNumber")) == serial:
            log(f"用现成的分发证书：{cn}（序列号 {serial}），不打不删。")
            return item["id"], p12, password
    log(f"账号里没有序列号 {serial} 的分发证书（可能已被吊销或过期），改用自动新建。")
    return None


def ensure_distribution_cert(c, outdir):
    """拿到 (cert_id, p12 路径, 密码)。

    顺序：
      1) 有 ASC_DIST_P12_BASE64 → 直接用，账号里的证书一张都不动
      2) 账号里有旧分发证书 → 吊销腾额度（私钥不在流水线里，留着也签不了名）
      3) 新建，带重试（苹果释放额度是异步的，偶尔要等几秒）
    """
    got = try_env_p12(c, outdir)
    if got:
        return got

    certs, err = list_distribution_certs(c)
    if certs is None:
        log(f"列证书失败（{err}），直接试着新建。")
        certs = []

    keep = {norm_serial(x) for x in (os.environ.get("ASC_KEEP_CERT_SERIALS") or "").split(",") if x.strip()}
    if certs:
        log(f"账号里已有 {len(certs)} 张分发证书（苹果上限 3 张，建新证书前得先腾位置）：")
        for item in certs:
            attrs = item.get("attributes") or {}
            log(f"  · {attrs.get('displayName', '?')}  序列号 {attrs.get('serialNumber', '?')}"
                f"  到期 {attrs.get('expirationDate', '?')}")
        victims = [x for x in certs
                   if norm_serial((x.get("attributes") or {}).get("serialNumber")) not in keep]
        if keep:
            log(f"按 ASC_KEEP_CERT_SERIALS 保留 {len(certs) - len(victims)} 张，其余吊销。")
        if victims:
            log("这些旧证书的私钥不在流水线里，留着也没法用来签名，只能吊销；"
                "已上架的 App 和已经传上去的构建不受影响。")
            revoke_certs(c, victims)
            wait_certs_gone(c)

    last = ""
    for attempt in range(1, 4):
        key, csr = make_csr(outdir)
        cert_id, der_b64, last = try_create_cert(c, csr)
        if cert_id:
            p12, password = build_p12(key, der_b64, outdir)
            return cert_id, p12, password
        if attempt < 3:
            log(f"第 {attempt} 次没建成，10 秒后重试…")
            more, _ = list_distribution_certs(c)
            if more:
                revoke_certs(c, more)
            time.sleep(10)
    die("创建分发证书失败（重试 3 次都没成）。"
        "如果苹果一直回「已有证书或待处理申请」，去 "
        "https://developer.apple.com/account/resources/certificates/list 看一眼，"
        "把 Distribution 里没用到的删掉，或过几分钟再跑。"
        f"原始返回：{last}")


def build_p12(key_path, der_b64, outdir):
    cert_pem = outdir / "dist.pem"
    lines = [der_b64[i:i + 64] for i in range(0, len(der_b64), 64)]
    cert_pem.write_text(
        "-----BEGIN CERTIFICATE-----\n" + "\n".join(lines) + "\n-----END CERTIFICATE-----\n"
    )
    p12 = outdir / "dist.p12"
    password = base64.b16encode(os.urandom(8)).decode().lower()

    base = ["openssl", "pkcs12", "-export", "-inkey", str(key_path),
            "-in", str(cert_pem), "-out", str(p12), "-passout", f"pass:{password}"]
    # macOS 自带的 openssl 是 LibreSSL，不认 -legacy；Linux 上的 OpenSSL 3 又需要它。
    for extra in ([], ["-legacy"]):
        try:
            sh(base + extra)
            break
        except subprocess.CalledProcessError as e:
            err = (e.stderr or "")[-300:]
            log(f"p12 生成参数 {extra or '默认'} 失败：{err.strip()}")
    else:
        die("生成 p12 失败，openssl 不支持需要的参数。")

    (outdir / "dist.p12.password").write_text(password)
    log(f"p12 已生成：{p12}（密码写在 dist.p12.password）")
    return p12, password


def create_profile(c, name, profile_type, bundle_resource_id, cert_id, outdir, filename):
    st, body = c.req("POST", "/v1/profiles", {
        "data": {
            "type": "profiles",
            "attributes": {"name": name, "profileType": profile_type},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_resource_id}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            },
        }
    })
    if st not in (200, 201):
        die(f"创建描述文件 {name} 失败 {st}：{api_error_text(body)}")
    content = body["data"]["attributes"]["profileContent"]
    path = outdir / filename
    path.write_bytes(base64.b64decode(content))
    log(f"描述文件已创建：{filename}（{name}）")
    return path


def check_app_group_in_profile(profile_path, app_group):
    """解出描述文件里的 entitlements，确认 App Group 真的在里面。"""
    try:
        plist = subprocess.run(
            ["security", "cms", "-D", "-i", str(profile_path)],
            capture_output=True, text=True,
        )
    except (OSError, FileNotFoundError):
        log("这台机器上没有 security 命令，跳过描述文件自检。")
        return None
    if plist.returncode != 0:
        return None
    txt = plist.stdout
    return app_group in txt


def check_app_record(c, app_bid):
    """App Store Connect 里没有这个 App 的记录，包传上去也只会被顶回来。
    先查一下：没有就把新建步骤写清楚，别等签完包传上去才报错。"""
    st, body = c.req("GET", f"/v1/apps?filter[bundleId]={app_bid}&limit=1")
    if st != 200:
        log(f"查 App 记录返回 {st}（API Key 权限不够就跳过这步）：{api_error_text(body)}")
        return
    data = body.get("data") or []
    if data:
        attrs = data[0].get("attributes") or {}
        log(f"App 记录已存在：{attrs.get('name', '?')}（SKU {attrs.get('sku', '?')}）")
        return
    die("\n".join([
        "",
        "=" * 62,
        f"App Store Connect 里还没有 {app_bid} 这个 App 的记录。",
        "没有记录，包传上去苹果一定退回（No suitable application records were found）。",
        "",
        "建一次，两分钟，以后不用再建：",
        "",
        "① 打开 https://appstoreconnect.apple.com/apps",
        "② 点左上角「+」→ 新建 App",
        "③ 平台选 iOS；名称随便填（就是商店里显示的名字）",
        "   主要语言简体中文",
        f"   套装 ID 在下拉里选 {app_bid}（一定要选，别手打）",
        "   SKU 随便填，比如 zakatrans001",
        "④ 点「创建」",
        "",
        "建完回 GitHub → Actions → 再点一次 Run workflow，这次就能一路跑到上传。",
        "=" * 62,
    ]))


def clean_old_profiles(c, prefixes):
    """每次跑都会新建描述文件，旧的留着只会把额度占满，顺手清掉。"""
    st, body = c.req("GET", "/v1/profiles?limit=200&fields[profiles]=name,profileType")
    if st != 200:
        return
    stale = [
        p for p in body.get("data", [])
        if any((p.get("attributes") or {}).get("name", "").startswith(pre) for pre in prefixes)
    ]
    if not stale:
        return
    for p in stale:
        c.req("DELETE", f"/v1/profiles/{p['id']}")
    log(f"清掉 {len(stale)} 个上一次留下的描述文件（本轮会重新建）。")


# ─────────────────────────── 主流程 ───────────────────────────

def main():
    for var in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_FILE"):
        if not os.environ.get(var):
            die(f"缺少环境变量 {var}")

    app_bid = os.environ.get("APP_BUNDLE_ID", "com.zakatrans.app").strip()
    ext_bid = os.environ.get("EXT_BUNDLE_ID", "com.zakatrans.app.ext").strip()
    app_group = os.environ.get("APP_GROUP", "group.com.zaka.trans").strip()
    app_name = os.environ.get("TEAM_APP_NAME", "ZakaTrans").strip()

    outdir = pathlib.Path(os.environ.get("OUT_DIR", "provision"))
    outdir.mkdir(parents=True, exist_ok=True)

    c = Client()
    log(f"主 App bundle id：{app_bid}")
    if ext_bid:
        log(f"扩展 bundle id  ：{ext_bid}")

    app_res, app_created = ensure_bundle_id(c, app_bid, app_name)
    if app_group:
        enable_app_groups(c, app_res, app_bid)
    ext_res = None
    ext_created = False
    if ext_bid:
        ext_res, ext_created = ensure_bundle_id(c, ext_bid, app_name + " Broadcast")
        if app_group:
            enable_app_groups(c, ext_res, ext_bid)

    # App ID 是这一轮才建出来的，那它一定还没跟 App Group 关联上。
    # 这时候就把话说明白，别去建证书浪费额度（账号最多 3 张分发证书）。
    if app_group and (app_created or ext_created):
        fresh = app_bid if app_created else ext_bid
        die(app_group_help(
            app_bid, ext_bid, app_group,
            f"App ID（{fresh}）刚在云端建好，还没关联 App Group",
        ))

    # App 记录：后台没建这个 App，签得再好也传不上去，先查一次。
    check_app_record(c, app_bid)

    cert_id, p12, password = ensure_distribution_cert(c, outdir)

    stamp = time.strftime("%Y%m%d%H%M")
    clean_old_profiles(c, [f"{app_name} AppStore ", f"{app_name} Ext AppStore "])
    app_profile = create_profile(
        c, f"{app_name} AppStore {stamp}", "IOS_APP_STORE",
        app_res, cert_id, outdir, "ZakaTrans_AppStore.mobileprovision",
    )

    ext_profile = None
    if ext_res:
        ext_profile = create_profile(
            c, f"{app_name} Ext AppStore {stamp}", "IOS_APP_STORE",
            ext_res, cert_id, outdir, "ZakaTrans_Ext_AppStore.mobileprovision",
        )

    # 落签名之前最后一次自检：App Group 到底有没有进描述文件。
    # 没有就直接停，绝不能签出一个「录屏是废的」完整包传上去。
    if app_group:
        problems = []
        verified = 0
        targets = [(app_profile, f"主 App（{app_bid}）")]
        if ext_profile:
            targets.append((ext_profile, f"扩展（{ext_bid}）"))
        for path, label in targets:
            hit = check_app_group_in_profile(path, app_group)
            if hit is None:
                continue
            verified += 1
            if hit is False:
                problems.append(label)
        if problems:
            die(app_group_help(
                app_bid, ext_bid, app_group,
                "描述文件里没有 " + app_group + "，还没关联到：" + "、".join(problems),
            ))
        if verified:
            log(f"App Group 已确认进描述文件：{app_group}")

    manifest = {
        "app_bundle_id": app_bid,
        "ext_bundle_id": ext_bid,
        "app_group": app_group,
        "cert_id": cert_id,
        "app_profile": str(app_profile),
        "ext_profile": str(ext_profile) if ext_profile else "",
        "p12": str(p12),
        "p12_password": password,
    }
    (outdir / "manifest.json").write_text(json.dumps(manifest, indent=2))

    # 给 bash 用的变量文件，sign_and_upload.sh 直接 source
    import shlex
    env_lines = [
        f"CERT_P12={shlex.quote(manifest['p12'])}",
        f"CERT_PASS={shlex.quote(password)}",
        f"APP_PROFILE={shlex.quote(manifest['app_profile'])}",
        f"EXT_PROFILE={shlex.quote(manifest['ext_profile'])}",
        f"APP_BUNDLE_ID={shlex.quote(manifest['app_bundle_id'])}",
    ]
    (outdir / "env.sh").write_text("\n".join(env_lines) + "\n")

    log("全部签名材料准备完成。")


if __name__ == "__main__":
    main()
