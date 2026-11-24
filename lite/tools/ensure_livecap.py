#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LiveCap 的签名材料准备：建 App ID、开 App Groups、确认 App Store Connect 里有 App 记录。

只做准备工作，不建证书、不动已有 App。缺 App 记录时直接给出一步一步的操作说明。
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_CANDIDATES = [
    os.path.normpath(os.path.join(_HERE, "..", "..", "ios", "tools")),          # repo/lite/tools -> repo/ios/tools
    os.path.normpath(os.path.join(_HERE, "..", "..", "commercial", "ios", "tools")),  # 本地工作区
]
for _p in _CANDIDATES:
    if os.path.isdir(_p) and _p not in sys.path:
        sys.path.insert(0, _p)

from asc_provision import (  # noqa: E402
    Client,
    ensure_bundle_id,
    enable_app_groups,
    list_capabilities,
    check_app_record,
)

APP = os.environ.get("APP_BUNDLE_ID", "com.zakatrans.livecap")
EXT = os.environ.get("EXT_BUNDLE_ID", "com.zakatrans.livecap.ext")


def log(m):
    print(f"[livecap] {m}", flush=True)


def main():
    c = Client()
    app_id, _ = ensure_bundle_id(c, APP, "LiveCap")
    ext_id, _ = ensure_bundle_id(c, EXT, "LiveCap Broadcast")

    for bid, name in ((app_id, APP), (ext_id, EXT)):
        caps = list_capabilities(c, bid) or set()
        if "APP_GROUPS" in caps:
            log(f"{name} App Groups 已开启")
        else:
            enable_app_groups(c, bid, name)
            log(f"{name} 已请求开启 App Groups")

    check_app_record(c, APP)
    return 0


if __name__ == "__main__":
    main()
