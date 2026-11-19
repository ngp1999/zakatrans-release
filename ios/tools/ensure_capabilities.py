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

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from asc_provision import Client, api_error_text  # noqa: E402

WANT = ["SIGN_IN_WITH_APPLE"]

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
    st, body = c.req("GET", f"/v1/bundleIds/{bid}/bundleIdCapabilities?limit=200")
    if st != 200:
        log(f"查询能力失败 {st}：{api_error_text(body)}")
        return set()
    return {i.get("attributes", {}).get("capabilityType") for i in body.get("data", [])}


def enable(c, bid, capability, identifier):
    st, body = c.req("POST", "/v1/bundleIdCapabilities", {
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": capability},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bid}}
            },
        }
    })
    if st in (200, 201):
        log(f"已开启 {capability}：{identifier}")
        return True
    log(f"开启 {capability} 返回 {st}：{api_error_text(body)}")
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
    if "SIGN_IN_WITH_APPLE" not in have:
        log("❌ 主 App 仍未开启 SIGN_IN_WITH_APPLE")
        ok = False
    else:
        log("✅ 主 App 已具备 Sign in with Apple")
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
