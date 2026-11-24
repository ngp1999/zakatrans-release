#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验签名产物里真的有 entitlement。签名没生效时这里直接失败，不让包上传。

用法：verify_entitlements.py <ZakaTrans.app> [--allow-dev]
  --allow-dev  归档阶段用（这时挂的是开发描述文件，get-task-allow 正常为真），
               只核对 Apple 登录与 App Group；是否可上架由导出后的 ipa 判定。
"""

import plistlib
import subprocess
import sys


def entitlements(path):
    proc = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", path],
        capture_output=True,
    )
    if not proc.stdout:
        return None, proc.stderr.decode(errors="replace")[:400]
    try:
        return plistlib.loads(proc.stdout), ""
    except Exception as exc:
        return None, f"{exc}: {proc.stdout[:300]!r}"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    allow_dev = "--allow-dev" in sys.argv
    app = args[0]
    ok = True

    ent, err = entitlements(app)
    if ent is None:
        print(f"❌ 主 App 没有签名/取不到 entitlement：{err}")
        return 1

    print("主 App entitlement：")
    for k, v in sorted(ent.items()):
        print(f"  {k} = {v}")

    signin = ent.get("com.apple.developer.applesignin")
    if not signin:
        print("❌ 缺少 com.apple.developer.applesignin —— Apple 登录会在运行时报 1000")
        ok = False

    groups = ent.get("com.apple.security.application-groups") or []
    if "group.com.zaka.trans" not in groups:
        print("❌ 缺少 App Group group.com.zaka.trans —— 录屏扩展拿不到共享数据")
        ok = False

    if ent.get("get-task-allow"):
        if allow_dev:
            print("ℹ️ get-task-allow 为真（归档阶段使用开发描述文件，属正常；导出时会换成分发描述文件）")
        else:
            print("❌ get-task-allow 为真 —— 这是开发描述文件，不能上传商店")
            ok = False

    ext_path = f"{app}/PlugIns/Broadcast.appex"
    import os
    if os.path.isdir(ext_path):
        eent, eerr = entitlements(ext_path)
        if eent is None:
            print(f"❌ 扩展没有签名/取不到 entitlement：{eerr}")
            return 1
        print("扩展 entitlement：")
        for k, v in sorted(eent.items()):
            print(f"  {k} = {v}")
        if "group.com.zaka.trans" not in (eent.get("com.apple.security.application-groups") or []):
            print("❌ 扩展缺少 App Group")
            ok = False

    print("✅ entitlement 校验通过" if ok else "❌ entitlement 校验失败")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
