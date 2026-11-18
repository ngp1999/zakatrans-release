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
"""

import base64
import json
import os
import pathlib
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


def load_jwt():
    try:
        import jwt  # PyJWT
    except ImportError:
        die("缺少 PyJWT，先 pip3 install pyjwt cryptography")
    key = pathlib.Path(os.environ["ASC_KEY_FILE"]).read_text()
    kid = os.environ["ASC_KEY_ID"]
    iss = os.environ["ASC_ISSUER_ID"]
    now = int(time.time())
    return jwt.encode(
        {"iss": iss, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": kid, "typ": "JWT"},
    )


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


def create_distribution_cert(c, csr_path, outdir):
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
            cert_id = body["data"]["id"]
            der_b64 = body["data"]["attributes"]["certificateContent"]
            log(f"分发证书已创建（CSR 格式：{label}，id={cert_id}）")
            log(f"证书有效期：{body['data']['attributes'].get('expirationDate', '?')}")
            return cert_id, der_b64
        last = f"{st} {api_error_text(body)}"
        log(f"证书创建方式「{label}」没通过：{last}")
        if "already" in last.lower() and "limit" in last.lower():
            break
    die("创建分发证书失败。常见原因：账号里 Distribution 证书已占满（上限 3 张）。"
        "去 Apple Developer → Certificates 删掉旧的 Distribution 证书（保留正在用的），再跑一次。"
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

    key_path, csr_path = make_csr(outdir)
    cert_id, der_b64 = create_distribution_cert(c, csr_path, outdir)
    p12, password = build_p12(key_path, der_b64, outdir)

    stamp = time.strftime("%Y%m%d%H%M")
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
        if check_app_group_in_profile(app_profile, app_group) is False:
            problems.append(f"主 App（{app_bid}）")
        if ext_profile and check_app_group_in_profile(ext_profile, app_group) is False:
            problems.append(f"扩展（{ext_bid}）")
        if problems:
            die(app_group_help(
                app_bid, ext_bid, app_group,
                "描述文件里没有 " + app_group + "，还没关联到：" + "、".join(problems),
            ))
        log(f"App Group 已进描述文件：{app_group}")

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
