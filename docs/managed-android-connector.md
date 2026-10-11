# Android Enterprise 受管设备连接器（阶段交付）

## 当前边界

本仓库现在提供服务端 `ManagedAndroidGateway` 接口及 Google Android Management API 官方 Java 客户端实现。默认实现为不可用且拒绝所有调用。**当前未取得 Android Enterprise EMM/Android Management API 商业准入，也没有绑定真实 enterprise 和设备；不能把它宣传为已实现受管设备强管控。** 现有家庭 BYOD 注册、策略预览与下发状态仍按原有能力边界运行，`ENFORCE` 不会因为本连接器存在而自动开放。

代码位置：`backend/src/main/java/com/aimanager/managedandroid/`。连接器仅在服务端运行；Flutter 和设备端不得持有 Google 服务账号凭证。

## 提供方接口与能力

| 操作 | 实现 | 成功语义 |
|---|---|---|
| 写应用策略 | `putApplicationPolicy` 先回读已预置的专用策略，要求明确 `playStoreMode=BLACKLIST` 且未启用 `installAppsDisabled`，然后仅更新 AMAPI `applications` 字段 | Google 接收策略版本；设备是否应用须回读 |
| 核对企业资源 | `readEnterprise` 只读官方 Enterprise 资源并验证返回名称 | 仅证明当前服务账号能读到该资源，不证明它属于某机构租户 |
| 创建注册令牌 | `createEnrollmentToken`，一次性、5–30 分钟、禁止个人使用 | 仅得到临时敏感注册材料；设备仍未受管 |
| 核对设备注册身份 | `readEnrollmentIdentity` 只读设备资源、管理模式、注册时间及令牌关联数据 | 供后续绑定流程核对；设备未与本地儿童档案自动关联 |
| 分配策略 | `assignPolicy`，仅更新设备 `policyName` | 服务端请求已接收；不是系统执行成功 |
| 回读执行状态 | `readDeviceState`，读取 `appliedPolicyName`、`appliedPolicyVersion`、`policyCompliant`、`nonComplianceDetails` | 名称和目标版本都匹配且明确合规才标记 `APPLIED`；未知或未同步为 `PENDING` |

当前应用映射仅支持 `ALLOW`、`BLOCK_LAUNCH`、`BLOCK_INSTALL`。`BLOCK_LAUNCH` 使用 `ApplicationPolicy.disabled=true`，`BLOCK_INSTALL` 使用 `installType=BLOCKED`，后者可能移除已安装应用，必须在产品界面提前说明。应用包名必须合法且单个策略最多 3000 条。日使用时长、时段、网站内容、摄像头识别等**没有**被映射到 AMAPI，不能宣称由此连接器保证执行。系统应用、不同 Android 版本与 OEM 的限制要逐机型验收。

注册令牌可附带 32–128 字符的随机 opaque `additionalData`。Google 在设备资源的 `enrollmentTokenData` 回报该值，后续绑定服务应只保存随机值摘要，并核对企业资源、令牌名称、注册模式、注册时间、一次性关联值、本地设备注册周期与机构授权。关联值不得包含儿童姓名、档案 ID 或租户 ID，也不得写日志或返回机构普通页面。当前连接器只提供读取证据的 SDK 边界；尚无企业/设备持久绑定与双人批准流程，因此这些数据不会提升本地设备能力或开启 `ENFORCE`。

Google 的设备级 `playStoreMode` 未设置时默认 `WHITELIST`：只把少数应用写入 `applications` 会使列表外应用不再可用，并可能被自动卸载。因此连接器**拒绝**不存在、未明确设为 `BLACKLIST`、或启用 `installAppsDisabled` 的策略；它不会悄悄创建策略或切换原有白名单。运维须在合格提供方、企业所有权和独占策略命名空间均已核实后预置策略。`BLACKLIST` 下未列出的应用通常仍可安装，这不是“仅允许所选应用”的全局白名单能力。完整白名单需独立的应用清单、系统必要应用保护、后果预览和真机签收流程。现有 `putApplicationPolicy` 会替换这份**专用策略**的完整应用列表，不能与其他管理工具共写同一策略。

领域规则与 Google 连接器共用 `SafetyCriticalPackages` 安全底线，包含儿童端正式包 `com.aimanager.child`、调试包 `com.aimanager.child.debug`、Android Device Policy `com.google.android.apps.work.clouddpc`、设置与电话等恢复所需应用。部署项 `manager.policies.additional-protected-packages` 只能增加，不能删减基础清单。普通策略不能禁止这些包的启动、安装和必要权限；连接器直接收到 `BLOCK_LAUNCH` 或 `BLOCK_INSTALL` 时也会拒绝。未来更换应用 ID 或 EMM 提供方时必须同步核对恢复路径。连接器尚未接到领域编译与真实企业绑定，包名保护本身不构成完成受管执行验收。

## 启用门槛与配置

```properties
manager.emm.google.enabled=false
manager.emm.google.eligibility-confirmed=false
```

只有经法务/商务确认的准入、允许用途、客户关系及 Google 项目配置具备后，运维才可同时打开这两项。`enabled=true` 且未确认资格会导致服务启动失败；仅关闭时不会加载云端凭证。正式环境使用服务端 Application Default Credentials（工作负载身份优先），只授予 `androidmanagement` 所需权限；不把账号密钥放入仓库、移动客户端或聊天记录。

当前锁定依赖为 `google-api-services-androidmanagement:v1-rev20260714-2.0.0` 与 `google-auth-library-oauth2-http:1.54.0`。正式发布前应把直接和传递依赖纳入 SBOM、许可证核验和漏洞扫描；升级官方生成客户端时重跑本地请求契约与真机回归。

正式接入前还必须完成：

1. 建立租户到 Google enterprise 的持久绑定，核实企业所有权与商业用途；所有调用以当前租户授权范围解析 enterprise，禁止客户端直接提交任意 enterprise 名称。
2. 设计经监护人/机构管理员重新认证的受管注册流程，令牌只通过短时一次性通道显示；不记录明文令牌或二维码，过期后不可重放。
3. 将真实设备 ID、注册来源、受管模式与租户绑定；设备自报不能作为 `DEVICE_OWNER` 证明。只有从提供方获取的设备资源和当前所有权证明才能升级能力矩阵。
4. 将领域策略编译为可执行 AMAPI 子集，并对无法映射、系统应用例外、版本/OEM 差异显式返回 `UNSUPPORTED`；建立预览、二次确认、回滚与版本关联。
5. 持久化命令请求、提供方响应和设备回读，区分 `REQUESTED`、`PENDING`、`APPLIED`、`NON_COMPLIANT`、`FAILED`、`EXPIRED`；配置超时、重试、限流和审计，不把 HTTP 200 当作生效。
6. 完成设备退管、凭证撤销、客服恢复、批量误下发止损、区域数据驻留和真实 Android 手机/平板/TV 兼容验收。

没有合规准入时可用已审核 EMM 合作方实现同一 `ManagedAndroidGateway`；不得绕开准入自建未经批准的 DPC 或调用官方 API。

## 本地验证

`GoogleManagedAndroidGatewayTest` 使用本地 HTTP 假服务驱动官方生成客户端，验证应用字段更新范围、包名校验、一次性令牌、敏感值脱敏、策略分配，以及目标版本未同步、管理模式未确认时的 `PENDING`。`ManagedAndroidConfigurationTest` 验证默认关闭和未确认资格时启动失败。测试不需要 Google 项目和密钥，不能替代正式准入或真机验收。

## 官方依据

- [Android Management API 简介](https://developers.google.com/android/management/introduction)
- [允许用途与资格](https://developers.google.com/android/management/permissible-usage)
- [Policies patch](https://developers.google.com/android/management/reference/rest/v1/enterprises.policies/patch)
- [Policy playStoreMode 与默认行为](https://developers.google.com/android/management/reference/rest/v1/enterprises.policies#PlayStoreMode)
- [Android Device Policy 包名](https://developers.google.com/android/management/work-profile-detection)
- [Enrollment tokens](https://developers.google.com/android/management/reference/rest/v1/enterprises.enrollmentTokens)
- [Enterprise 读取](https://developers.google.com/android/management/reference/rest/v1/enterprises/get)
- [Device resource 与合规状态](https://developers.google.com/android/management/reference/rest/v1/enterprises.devices)
