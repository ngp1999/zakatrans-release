#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
确保 App ID 上开了必要的能力（Sign in with Apple / App Groups）。

自动签名只负责「拿一张描述文件」，它不会替你去开发者后台开能力。
能力没开 → 描述文件里就没有对应 entitlement → 运行时 Apple 登录报
ASAuthorizationError 1000、App Group 读不到共享目录。

用法（环境变量）：
  ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_FILE
  APP_BUNDLE_ID   默认 com.zakatrans.app
  EXT_BUNDLE_ID   默认 com.zakatrans.app.ext（留空跳过）
"""

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (_HERE, os.path.normpath(os.path.join(_HERE, "..", "..", "tools"))):
    if _p not in sys.path:
        sys.path.insert(0, _p)
from asc_provision import Client, api_error_text  # noqa: E402

WANT = ["APPLE_ID_AUTH", "APP_GROUPS"]

log = lambda m: print(f"[caps] {m}", flush=True)


def bundle_id_of(c, identifier):
    st, body = c.req("GET", f"/v1/bundleIds?filter[identifier]={identifier}&limit=10")
    if st != 200:
        return None
    for item in body.get("data", []):
        if item["attributes"]["identifier"] == identifier:
            return item["id"]
    return None


def caps_of(c, bid):
    st, body = c.req("GET", f"/v1/bundleIds/{bid}/bundleIdCapabilities")
    if st != 200:
        log(f"查询能力失败 {st}：{api_error_text(body)}")
        return set()
    return {i.get("attributes", {}).get("capabilityType") for i in body.get("data", [])}


# Sign in with Apple 在后台要额外选一个「配置」（作为主 App ID）。
# 这一步 API 文档没写清楚，下面按几种可能的写法依次试，全失败就提示手工勾选。
SETTINGS_VARIANTS = [
    [{"key": "APPLE_ID_AUTH_APP_CONSENT",
      "options": [{"key": "PRIMARY_APP_CONSENT", "enabled": True}]}],
    [{"key": "APPLE_ID_AUTH_APP_CONSENT",
      "options": [{"key": "PRIMARY_APP_CONSENT"}]}],
    [{"key": "APPLE_ID_AUTH_APP_CONSENT"}],
]


def enable_once(c, bid, capability, settings):
    attributes = {"capabilityType": capability}
    if settings is not None:
        attributes["settings"] = settings
    return c.req("POST", "/v1/bundleIdCapabilities", {
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": attributes,
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bid}}
            },
        }
    })


def enable(c, bid, capability, identifier):
    for idx, settings in enumerate(SETTINGS_VARIANTS):
        st, body = enable_once(c, bid, capability, settings)
        if st in (200, 201, 204):
            log(f"已开启 {capability}（第 {idx + 1} 种配置写法）：{identifier}")
            return True
        txt = api_error_text(body)
        if "at least one configuration" in txt and idx < len(SETTINGS_VARIANTS) - 1:
            continue
        log(f"开启 {capability}（写法 {idx + 1}）返回 {st}：{txt}")
        if "at least one configuration" not in txt:
            break
    return False


def main():
    app = os.environ.get("APP_BUNDLE_ID", "com.zakatrans.app")
    ext = os.environ.get("EXT_BUNDLE_ID", "com.zakatrans.app.ext").strip()
    c = Client()

    for identifier, wants in ((app, WANT), (ext, ["APP_GROUPS"])):
        if not identifier:
            continue
        bid = bundle_id_of(c, identifier)
        if not bid:
            log(f"找不到 App ID：{identifier}")
            sys.exit(1)
        have = caps_of(c, bid)
        log(f"{identifier} 现有能力：{sorted(x for x in have if x)}")
        for capability in wants:
            if capability in have:
                log(f"{capability} 已开启，跳过")
            else:
                enable(c, bid, capability, identifier)

    # 复核
    ok = True
    bid = bundle_id_of(c, app)
    have = caps_of(c, bid)
    if "APPLE_ID_AUTH" not in have:
        log("❌ 主 App 仍未开启 APPLE_ID_AUTH（Sign in with Apple）")
        log("👉 需要在开发者后台 App ID 里手工勾选并选择配置（一次即可）")
        ok = False
    else:
        log("✅ 主 App 已具备 Sign in with Apple")
    if not ok:
        # 不阻塞编译：能力缺失时仍然打包，由 entitlement 校验给出明确结论
        log("继续打包，等待后面的 entitlement 校验结果")
    return 0 if ok else 0


if __name__ == "__main__":
    main()
