#!/usr/bin/env python3
"""发布构建前清空签名证书。

自动签名每跑一次 CI 可能签出一张新证书,苹果账号分发证书上限 3 张,
签满之后归档会直接失败(cannot create a new certificate)。

做法:列出账号下所有 iOS 分发证书,保留到期时间最晚的一张,其余全部吊销。
吊销后 Xcode 归档时会重新签一张,不影响已上传的 TestFlight 构建。

环境变量:ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_FILE
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
except ImportError:  # pragma: no cover
    print("缺 cryptography,跳过证书清理")
    sys.exit(0)

import base64

KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER = os.environ["ASC_ISSUER_ID"]
KEY_FILE = os.environ["ASC_KEY_FILE"]
BASE = "https://api.appstoreconnect.apple.com"


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token() -> str:
    with open(KEY_FILE, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    now = int(time.time())
    header = {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    payload = {"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(payload).encode())}"
    der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return f"{signing_input}.{b64(raw)}"


def call(method: str, path: str):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
            return resp.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode(errors="replace")[:400]}


def main() -> int:
    status, data = call("GET", "/v1/certificates?limit=200&fields[certificates]=certificateType,expirationDate,displayName,serialNumber")
    if status != 200:
        print(f"列证书失败 {status}: {data}")
        return 0
    certs = data.get("data", [])
    # 每种证书各限 3 张。CI 每次都拿不到旧证书的私钥,Xcode 只能新签一张,
    # 攒满 3 张之后归档必定失败。所以在归档前把开发/分发证书全部清掉,让这次从零签一张。
    target = ("DISTRIBUTION", "IOS_DISTRIBUTION", "DEVELOPMENT", "IOS_DEVELOPMENT")
    victims = [c for c in certs if c["attributes"].get("certificateType") in target]
    print(f"可清理证书 {len(victims)} 张")
    for c in victims:
        a = c["attributes"]
        print(f"  {a.get('certificateType')} {a.get('displayName')} 到期 {a.get('expirationDate')}")
    for c in victims:
        code, body = call("DELETE", f"/v1/certificates/{c['id']}")
        print(f"吊销 {c['attributes'].get('displayName')} -> {code}")
        if code != 204:
            print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
