# ZakaTrans Release

GitHub Actions 流水线：在 macOS runner 上自动申请签名材料 → 重签 App Store 分发包 → 提交前自检 → 上传 App Store Connect。

## 目录

```
.github/workflows/appstore.yml   流水线定义
tools/asc_provision.py           自动创建 App ID / 分发证书 / 描述文件
tools/sign_and_upload.sh         重签 → 自检 → 上传
tools/check_ipa.py               提交前自检（结构 / 图标 / 隐私清单 / SDK / 签名）
ZakaTrans-AppStore-1.0.0.ipa     待签名的分发包（默认输入）
```

## 必需的 Secret

仓库 Settings → Secrets and variables → Actions，三个名字必须完全一致：

| 名称 | 值 |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API Key 的 Key ID（10 位） |
| `ASC_ISSUER_ID` | API Key 的 Issuer ID（UUID） |
| `ASC_KEY_P8` | `AuthKey_XXXXXXXXXX.p8` 的 base64（单行） |

API Key 角色必须是 **Admin**，否则无法创建 App ID 与证书。

## 运行

Actions → 左侧 `ZakaTrans -> App Store Connect` → Run workflow。

输入项留默认即可：

- `ipa`：`ZakaTrans-AppStore-1.0.0.ipa`
- `app_bundle_id`：`com.zakatrans.app`
- `ext_bundle_id`：`com.zakatrans.app.ext`
- `app_group`：`group.com.zaka.trans`
- `skip_upload`：`false`

## 前置（只需做一次，网页后台）

App Group 的具体关联苹果没有开放接口，必须在后台人工点：

1. 建 `group.com.zaka.trans`
2. `com.zakatrans.app` 与 `com.zakatrans.app.ext` 两个 App ID 都勾 App Groups，并点 Configure 勾选该 group

未完成时流水线会在建完 App ID 后停下，日志里直接写明还差哪一步。

## 产物

- Artifacts → `signed-ipa`：签好名的分发包（14 天）
- Artifacts → `signing-materials`：证书与描述文件（下次重签免申请）

上传成功后到 App Store Connect → TestFlight 等待处理，处理完成即可提交审核。
