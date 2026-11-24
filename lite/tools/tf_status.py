#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""查 TestFlight 上最新几个构建的处理状态。

用法：tf_status.py [版本号前缀]
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (_HERE, os.path.normpath(os.path.join(_HERE, "..", "..", "tools"))):
    if _p not in sys.path:
        sys.path.insert(0, _p)
from asc_provision import Client, api_error_text  # noqa: E402

APP = os.environ.get("APP_BUNDLE_ID", "com.zakatrans.app")


def main():
    want = sys.argv[1] if len(sys.argv) > 1 else ""
    c = Client()

    st, body = c.req("GET", f"/v1/apps?filter[bundleId]={APP}&limit=5")
    if st != 200 or not body.get("data"):
        print(f"[tf] 查 App 失败 {st}: {api_error_text(body)}")
        return 1
    app_id = body["data"][0]["id"]
    print(f"[tf] app id = {app_id} ({APP})")

    st, body = c.req(
        "GET",
        f"/v1/builds?filter[app]={app_id}&limit=8&sort=-uploadedDate"
        "&include=preReleaseVersion",
    )
    if st != 200:
        print(f"[tf] 查构建失败 {st}: {api_error_text(body)}")
        return 1

    inc = {i["id"]: i for i in body.get("included", [])}
    for b in body.get("data", []):
        a = b["attributes"]
        rel = b["relationships"].get("preReleaseVersion", {}).get("data") or {}
        pv = inc.get(rel.get("id"), {}).get("attributes", {})
        ver = pv.get("version", "?")
        if want and not str(ver).startswith(want):
            continue
        print(
            f"[tf] {ver} ({a.get('version')}) 状态={a.get('processingState')} "
            f"过期={a.get('expired')} 上传={a.get('uploadedDate')}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
