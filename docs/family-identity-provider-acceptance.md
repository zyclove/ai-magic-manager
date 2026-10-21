# 家庭账号供应商联调验收

已经准备可执行的本地预检与证据复核工具，2026-10-17 进一步新增独立平台「短信与微信」配置页面、加密草稿、发布准备及联调待办入口，见 [管理配置说明](family-identity-provider-admin.md)。真实短信、微信和四条账号流程尚未通过供应商验收；当前没有供应商凭据、授权接收号码和正式签名真机，不发送测试短信、不调用真实微信、不开放购买。

## 本地预检

管理端已增加当前版本绑定、自动产物摘要、最近登记与收费门禁，见 [验收入口说明](family-identity-acceptance-gate.md)。正式安卓包和本机设备的只读检查另见 [安卓预检](family-android-acceptance-preflight.md)。这些准备检查不替代下文十二项真实验收。

运行 [`scripts/test_family_identity_providers.ps1`](../scripts/test_family_identity_providers.ps1) 检查现有独立消费者部署。脚本只读取固定配置、固定秘密文件和指定产物；不启动服务、不更改身份域、不调用供应商、不修改任何开关。

```powershell
./scripts/test_family_identity_providers.ps1 `
  -Directory .local/family-identity-pilot `
  -EnvironmentId family-cn-pilot `
  -IdentityProviderJar .local/family-identity-pilot/artifacts/consumer-identity-1.0.0.jar `
  -ParentApk .local/family-identity-pilot/artifacts/parent-release.apk `
  -ParentWechatAppId $env:PARENT_WECHAT_APP_ID `
  -OutputPath .cache/family-identity-provider-acceptance/preflight.json
```

`ParentWechatAppId` 是非秘密 AppID；脚本将它与服务端配置比较，但不声称已经读取 APK 内 AppID 或验证发布证书。真实签名、包名及包内配置另有独立必验项。未提供 JAR/APK 也能生成报告，对应版本检查保持 `BLOCKED`。

此预检工具仍读取部署的 `.env`、`deployment.json` 和 `secrets/` 中的固定文件。新管理界面保存的是独立加密配置版本，需按 [发布准备说明](family-identity-provider-release.md) 审查部署后才会影响身份服务；数据库保存成功不能代替部署生效。密钥内容和密钥摘要均不写入报告，报告只保存 `present`、`validFormat`。格式检查不能证明凭据有效、权限已开通、签名/模板已审核、微信移动应用审核通过或短信实际送达。

以下文件必须存在，单行 UTF-8、无 BOM、最多 8192 字节；只有未使用的 STS 文件允许为空。任一秘密文件无法加载时，身份服务会关闭全部消费者入口，不能只看其中一个供应商的配置卡片。

| 文件 | 内容 |
| --- | --- |
| `consumer_otp_hmac_key` | 至少 32 字节独立随机 HMAC 密钥 |
| `consumer_sms_access_key_id` | 短信 RAM AccessKey ID |
| `consumer_sms_access_key_secret` | 配套短信 AccessKey Secret |
| `consumer_sms_security_token` | 可选 STS token；不使用时保留空文件 |
| `consumer_wechat_app_secret` | 与移动应用 AppID 配套的服务端 AppSecret |

工具拒绝直接放在 `.env` 的已知供应商秘密；不会执行配置文本。报告采用新文件写入，拒绝覆盖现有记录。新输出默认位于仓库忽略的 `.cache/family-identity-provider-acceptance/`，显式路径兼容仓库 `.cache/` 和既有 `.local/`；归一化后越界、相似前缀和路径中的链接均拒绝，不创建盘根目录。现有部署配置无需移动，最终交付摘要仍保存到 `docs/evidence/`。错误消息不回显输入、秘密文件路径或供应商响应。

退出码 `2` 表示报告已生成且真实验收仍有阻塞；退出码 `1` 表示报告未能安全生成。当前工具不会返回“已通过收费发布”。

## 管理界面可读取的报告

报告 `schemaVersion=1`、`kind=family-identity-provider-preflight`。固定字段：

| 字段 | 含义 |
| --- | --- |
| `environmentId`、`generatedAt` | 非敏感环境别名和 UTC 生成时间；不保存真实入口地址 |
| `readinessStatus` | 本地配置格式与产物登记是否齐全；仅为 `PASS` / `BLOCKED` |
| `acceptanceStatus` | 当前工具固定为 `BLOCKED`；真实流程需要另行验收 |
| `salesAllowed` | 固定 `false`，不能据此启用购买 |
| `providerRequestsPerformed` | 固定 `false` |
| `credentials` | 固定秘密项的 `present` / `validFormat` 两个布尔值 |
| `artifacts`、`sourceFiles` | 指定 JAR/APK 与固定关键源码的 SHA-256；不证明产物一定由该源码构建 |
| `nonSecretConfigurationSha256` | 非秘密配置版本绑定；不包含任何密钥或密钥摘要 |
| `secretRotationVerified` | 固定 `false`；本地格式预检不能证明密钥轮换成功 |
| `requiredChecks` | 固定 `id`、中文 `label` / `stage`、`status`、`reasonCode` 和下一步 `action` |
| `evidenceReview` | 旧预检记录与当前版本是否匹配；仅复核本地记录，不证明真实验收 |

后续平台界面可以按“配置准备 → 版本核对 → 真实联调”展示这些检查，默认只突出当前阻塞及一个下一步按钮。不能把“配置格式通过”改写成“短信正常”“微信正常”或“已可收费”。

复核现有报告：

```powershell
./scripts/test_family_identity_providers.ps1 `
  -Directory .local/family-identity-pilot `
  -EnvironmentId family-cn-pilot `
  -IdentityProviderJar .local/family-identity-pilot/artifacts/consumer-identity-1.0.0.jar `
  -ParentApk .local/family-identity-pilot/artifacts/parent-release.apk `
  -ParentWechatAppId $env:PARENT_WECHAT_APP_ID `
  -VerifyManifest .cache/family-identity-provider-acceptance/preflight.json `
  -OutputPath .cache/family-identity-provider-acceptance/review.json
```

复核重新计算当前源码、产物和非秘密配置的摘要，检查环境别名、生成时间与固定真实案例，拒绝篡改成真实 `PASS` 或允许购买的报告。一天以前的预检需要重新生成。秘密内容发生变化后必须重新联调；报告有意不保存秘密摘要，因此不能用摘要比较证明秘密未变化。手工清单、供应商假响应、测试 JAR 或 fixture JSON 都不能替代真实供应商验收。

## 真实验收顺序

先冻结验收版本，记录正式 APK/JAR、Keycloak/MySQL 镜像摘要、MySQL 隔离级别、节点数、非敏感环境别名和开始时间。使用独立身份域、独立测试数据库及自愿参与的成人测试账号；接收人和号码由负责验收的人在受限渠道确认，号码、验证码、微信 code、token 不进入脚本参数、命令历史、截图、报告或 Git。

手机号操作全部在 App 打开的正常 OIDC/PKCE 安全浏览器中完成；验证码只能由接收人输入。微信 code 只能由正式签名真机的原生微信 SDK 获取，在内存中校验 state 后通过原有 PKCE 流提交。不能把 code 复制到 CLI、文件、自动化脚本或聊天。

| 必验 ID | 实际操作与通过条件 |
| --- | --- |
| `LOG_REDACTION` | 发起真实请求前，核对入口、WAF、反向代理、APM、崩溃采集和供应商出站日志；不记录 `/identity/` 查询/表单、不记录授权头和出站 URL 查询。验收时再次核对，不能开启 HTTP 调试日志取证 |
| `SIGNED_DEVICE_BUILD` | 在微信开放平台核对正式包名 `com.aimanager.parent`、发布证书及 AppID；核对本次实际安装 APK 摘要和包内 AppID；调试构建不作为正式验收 |
| `REAL_SMS_DELIVERY` | 真实阿里云中国站发送至已授权接收人，接收人实际收码并完成登录；核对错误验证码、过期、频控与供应商故障提示。`SendSms` 的 `Code=OK` 仅证明请求成功提交，不能代替收码或发送状态核对 |
| `REAL_WECHAT_NATIVE_AUTH` | 真机安装微信，完成原生授权、安全浏览器验证和 App 回调；分别检查取消、拒绝、未安装微信与重复回调，不保存 code |
| `CHANGE_PHONE_E2E` | A 账号验证原号和新号后完成换绑；同一用户、家庭、设备、订单和会员保持不变；原号不能重新登录原账号，新号可以 |
| `RECOVER_PHONE_E2E` | A 已绑定微信、原号不可用时，从“找回账号”完成真实微信授权和新号验证；仍为 A 原账号；未知微信或 B 的微信不能恢复 A |
| `BIND_WECHAT_E2E` | A 通过当前手机号验证绑定真实微信后可用该微信登录；已有不同绑定不得被覆盖 |
| `UNBIND_WECHAT_E2E` | 验证当前手机号后解绑；当前手机号仍可登录，原微信不再登录该账号；家庭及权益不变 |
| `IDENTITY_CONFLICTS` | 两组已授权账号检查被占用手机号、已属 B 的微信、旧版本操作、同操作重放及预期账号不一致，均明确拒绝、不合并账号 |
| `OLD_SESSION_REVOKED` | 第二设备保留旧会话；账号变更后，旧 JWT 访问业务 API、身份状态及刷新均拒绝，新会话正常；离线 session 一并撤销 |
| `INTERRUPTION_RECOVERY` | 在提交前后分别取消浏览器、掉网、杀 App 和丢回调；重新进入读取当前事实与原操作回执，不自动重放更改、不错误宣称成功 |
| `MYSQL_CONCURRENCY_ROLLBACK` | 在目标 MySQL/Keycloak 组合真实运行，验证 RR 并发、手机号/微信唯一归属、最终版本核对、失败回滚释放锁、锁等待和多节点缓存失效；H2 与 Mockito 不替代这些检查 |

阿里云短信提交不提供幂等保证。发送超时后先核对发送状态与接收情况，不能立即绕过应用限流重发；本项目不以增加自动重试来掩盖未知结果。该要求来自 [阿里云 SendSms 官方说明](https://help.aliyun.com/zh/sms/developer-reference/api-dysmsapi-2017-05-25-sendsms)。微信链路以原生 SDK、当前已审核应用配置和实际真机结果为准；[微信移动应用登录文档](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/WeChat_Login/Development_Guide.html) 在本轮研究环境无法抓取，不作为已完成授权验收的证据。

每个案例至少记录：固定案例 ID、源码和产物版本、环境别名、UTC 开始/结束时间、测试账号 A/B 的本次随机别名、观察到的结果、非敏感状态码和证据文件摘要。供应商控制台回执若带完整号码，只在受限验收渠道查看，公开摘要不保存原始回执。需要关联用户是否一致时在验收会话中比较原始 subject，证据只保留“相同/不同”，避免把手机号、openid 或可长期关联儿童家庭的标识写入报告。实际失败必须保留失败原因与后续复测结果，不能改写历史记录。

## 平台管理配置边界与剩余发布工作

配置页面、不可变加密版本、离线检查、加密准备、受控执行器、实际身份实例确认与历史版本回退已实现，见 [受控发布说明](family-identity-controlled-release.md)。本轮执行器只加载关闭消费者入口的配置；真实试发送、供应商自动采证及正式启用仍待独立完成，没有 Keycloak 热更新能力。以下约束继续有效，不能用配置加载证明替代十二项真实验收。

- 入口放在独立的平台管理员工作台，与家长“我的 → 账号与安全”分开；普通家庭成员、家庭监护人及儿童端不得读取或修改供应商配置。
- 配置读取/变更、试发送、启用、回退分别鉴权；敏感动作使用现有平台管理员 MFA 和近期验证，不能把手机号验证码当作管理员 MFA。
- 密钥采用只写输入：保存后只显示“已配置”、版本和更新时间，不回传原文、摘要、前后若干字符或现有值。读取状态与密钥写入使用不同权限；不得进入浏览器持久存储、URL、审计、异常、前端分析或自动截图。
- 非秘密项展示短信签名、模板、AppID、正式包名和证书登记检查；配置以不可变版本保存草稿，校验通过后发布。必须先完成受控试发送、原生微信授权和本文件的真实联调，再由有权限管理员显式启用消费者入口；“保存成功”不表示“已经生效”。
- 试发送只允许指定已授权接收人，另行频控、预算和审计，默认不自动重试。号码不写普通日志；试发送页面结束后清除临时输入。微信不提供粘贴 code 的管理入口，始终由真机原生授权。
- 当前身份服务读取固定秘密文件，需在发布版本中一致更新并受控重启实例；不要新增一个仅更新业务数据库而身份服务仍读取旧文件的配置 API，也不要提前承诺运行中热更新。
- 轮换记录独立配置版本和生效范围，先在隔离环境验收后逐步发布；HMAC 更换会使未验证验证码失效，所有节点必须协调。STS 按有效期轮换，微信 AppID 改变会改变绑定范围，不能当作普通 AppSecret 轮换。
- 回退保留上一已验收配置版本与受限秘密引用；先确认旧密钥仍有效、供应商端吊销状态与当前身份版本，再执行受控回退。回退不能把已失效的旧登录或已解绑微信恢复成有效身份。
- 审计仅记录管理员、动作、配置版本、结果码、环境别名和时间；不记录秘密、完整接收号码、验证码、微信 code、token、完整请求/响应或出站 URL。购买保持独立门禁，供应商配置无法自行解除收费验收条件。

## 本轮验证记录

预检工具的离线回归位于 [`scripts/tests/test_family_identity_providers.py`](../scripts/tests/test_family_identity_providers.py)，覆盖不泄密、错误文件关闭、配置注入拒绝、版本绑定、假 PASS 拒绝与输出保护，补充默认 `.cache`、既有 `.local` 兼容、归一化越界与链接目标保护。新测试 scratch 位于 `.cache/identity-provider-preflight-tests/`，TEMP/TMP 只在测试进程设置；每例只清理自己的随机目录，链接先解除再清理，不遍历目标。测试使用明确的格式 fixture，不调用短信、微信、生产身份域或数据库；测试通过只说明工具行为通过。

本轮私有记录目录：`.local/family-p0-integration-20261016/provider-acceptance/`。真实供应商 `PASS` 数量仍为 0。
