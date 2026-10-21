# 安卓正式包与设备准备核对

[`test_family_android_acceptance.ps1`](../scripts/test_family_android_acceptance.ps1) 为平台验收人员生成只读准备报告。它核对指定家长 APK 的真实摘要、签名、正式证书登记、包名和可调试状态，并读取本机已运行 ADB 的连接状态。它不安装或启动 App，不启动或停止 ADB，不发送短信、不打开微信，也不修改部署、账号或购买开关。

## 一次准备核对

先准备本次 APK、管理员已核对的正式证书 SHA-256、公有微信 AppID，以及安装有 build-tools 35.0.0 和 platform-tools 的 SDK。证书摘要和 AppID 可公开；签名密钥、密码、手机号、验证码、微信 code 和 token 都不作为本工具参数。

```powershell
./scripts/test_family_android_acceptance.ps1 `
  -EnvironmentId family-cn-pilot `
  -ParentApk .local/family-identity-pilot/artifacts/parent-release.apk `
  -ExpectedCertificateSha256 $env:PARENT_RELEASE_CERT_SHA256 `
  -ParentWechatAppId $env:PARENT_WECHAT_APP_ID `
  -AndroidSdkDirectory $env:ANDROID_HOME `
  -OutputPath .cache/family-provider-acceptance-20261017-r3/android/preflight.json
```

选择其他已安装版本时显式设置 `-BuildToolsVersion`。工具固定使用该 SDK 中的 `lib/apksigner.jar`、`aapt` 和 platform-tools，不接受任意检查命令。Java 需可用。不会自动下载工具或生成签名。

每次使用新的报告文件名；既有报告不会覆盖。省略输出路径时，在 `.cache/family-provider-acceptance-20261017-r3/android/` 创建随机文件名。兼容仓库 `.local/` 输出，拒绝越界、相似前缀、目录链接和文件链接。APK 可以是仓库外的指定只读文件，路径祖先同样不能有链接。

退出码 `2` 表示准备报告已生成，真实验收仍然阻塞；`1` 表示无法安全生成报告。当前工具不会返回收费验收通过。

## 如何理解结果

报告 `schemaVersion=1`、`kind=family-android-acceptance-preflight`。`readinessStatus` 仅表示本地准备情况；即使准备全部通过，`acceptanceStatus` 仍为 `BLOCKED`，`salesAllowed` 和 `providerRequestsPerformed` 均为 `false`。报告不能直接导入为收费通过凭据。

| 检查 | 通过的实际含义 |
| --- | --- |
| APK 摘要 | 对实际文件计算 SHA-256，登记本次版本；不会复制大安装包 |
| 安装包签名 | 固定 SDK 验签成功，且识别到一个签名证书；多签名或未知签名格式保持阻塞 |
| 证书匹配 | APK 中公有证书 SHA-256 与管理员提供的正式登记值一致 |
| 使用正式证书 | 没有识别到常见 Android Debug 证书；仍需核对开放平台实际登记 |
| 包名与构建 | 从真实 APK 清单读取包名 `com.aimanager.parent`，并确认未标记 `application-debuggable` |
| 计划 AppID | 仅检查调用者声明的 AppID 格式；不是包内值核验 |
| 本机连接 | 读取固定 `127.0.0.1:5037` 的 `host:devices-l`，存在已授权、非明确模拟器的连接 |

即使把调试证书摘要填为“预期证书”，Android Debug 证书或可调试 APK 仍各自阻塞正式准备。SDK 命令非零退出、超时、输出超限或格式未知时不接受其结果。报告不保留工具原始输出和输入路径。

家长端当前微信 AppID 位于 `BuildConfig`，没有暴露为可直接核验的清单字段。`wechatAppId.status=NOT_VERIFIED`、`apkValueVerified=false` 和 `platformRegistrationVerified=false` 不会因填写 AppID 而改变。正式构建、实际安装版本、微信平台包名及证书登记、真机原生授权仍须独立核对。

设备原始序列号只在协议解析时短暂存在内存。报告仅保存本次随机别名、连接状态、连接类型和是否带设备元信息，不保留序列号、稳定设备哈希或型号文本。每次报告的别名不同，不能跨报告追踪设备。ADB 连接不是物理真机或已安装版本的证明；`physicalDeviceVerified` 固定为 `false`。本机服务未运行、无设备、未授权、仅模拟器或协议异常都分别显示待准备，工具不会帮用户点击设备授权。

SDK 每条命令最多运行 10 秒，标准输出和错误输出合计最多 65,536 字符；ADB 只读请求总期限 3 秒、响应最多 32 KiB、最多 64 条连接。它不读取远端 ADB 环境变量，也不运行会自动启动服务的 `adb devices` 命令。

## 后续正式验收缺口

真实短信送达、正式签名真机微信授权、账号换绑/恢复/绑定/解绑，以及真机中断恢复仍保持待验收，继续遵循 [供应商联调说明](family-identity-provider-acceptance.md)。没有准备好正式供应商、成人接收人和真机时，保留阻塞原因即可，不需要填造通过结果。

[`build-parent-android.ps1`](../scripts/build-parent-android.ps1) 默认仍为机构试点；使用 `-ReleaseProfile FamilyAcceptance` 才会显式编入手机号登录、微信登录和账号安全入口。该模式要求环境变量中的公有 `PARENT_WECHAT_APP_ID`，以及独立登记的正式证书 SHA-256；签名密钥和密码继续只从受限构建环境读取。构建前、依赖解析后和构建后都要求源码干净且已提交，不放宽签名条件。

```powershell
./scripts/build-parent-android.ps1 `
  -Issuer https://identity.example.cn/realms/ai-manager `
  -ApiUrl https://api.example.cn/api/v1 `
  -ConsoleUrl https://console.example.cn/ `
  -BuildName 1.0.0 -BuildNumber 1 `
  -ReleaseProfile FamilyAcceptance `
  -ExpectedCertificateSha256 $env:PARENT_RELEASE_CERT_SHA256
```

上述地址仅为占位示例，正式使用时替换为已批准的受限试点地址。脚本验签后拒绝证书不匹配、多签名和常见 Android Debug 证书。生成的 `apps/parent/build/parent-release-manifest.json`（schemaVersion 2）登记源码提交、实际 APK 摘要、证书、构建模式和编入的功能开关；它保持 `acceptanceStatus=PENDING`、`salesAllowed=false`。构建清单中的 AppID 是构建配置声明，不能代替包内值及微信平台登记核对。

正式签名包生成后，将 APK 和该次清单保存在 `.local/family-identity-pilot/artifacts/`，再按本文步骤使用实际 APK 完成只读预检。此入口不启用服务端消费者登录，不部署受限试点，也不开放购买；真实短信、微信、安卓设备与账号流程仍需逐项验收。目前未执行正式签名构建或真机验收。

聚焦回归位于 [`test_family_android_acceptance.py`](../scripts/tests/test_family_android_acceptance.py)。测试使用明确的 SDK 输出夹具验证工具边界，不代表真实签名包、微信 SDK、供应商或真机通过。
