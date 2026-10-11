# Android Enterprise 受管设备连接器（阶段交付）

## 当前边界

本仓库现在提供服务端 `ManagedAndroidGateway` 接口及 Google Android Management API 官方 Java 客户端实现。默认实现为不可用且拒绝所有调用。机构企业绑定申请和审核状态已可持久化，但**当前未取得 Android Enterprise EMM/Android Management API 商业准入，也没有绑定真实设备；不能把它宣传为已实现受管设备强管控。** 现有家庭 BYOD 注册、策略预览与下发状态仍按原有能力边界运行，`ENFORCE` 不会因为企业绑定记录存在而自动开放。

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

注册令牌可附带 32–128 字符的随机 opaque `additionalData`。Google 在设备资源的 `enrollmentTokenData` 回报该值，后续设备绑定服务应只保存随机值摘要，并核对企业资源、令牌名称、注册模式、注册时间、一次性关联值、本地设备注册周期与机构授权。关联值不得包含儿童姓名、档案 ID 或租户 ID，也不得写日志或返回机构普通页面。当前仍无设备持久绑定流程；这些证据不会提升本地设备能力或开启 `ENFORCE`。

## 机构企业绑定审核

机构所有者或机构管理员使用已完成近期多因素认证的身份，向 `POST /api/v1/tenants/{tenantId}/managed-android/enterprise-binding` 提交 `enterpriseId` 与 `contractReference`。申请写入 `PENDING`，并生成同事务审计记录；此时不向 EMM 发出任何写操作。`GET` 同一路径供机构所有者、管理员及审计员查看进度；租户视图隐藏平台审核员身份和内部证据索引。一个机构当前只能有一份绑定，且同一提供方企业资源不能被两个机构同时认领。

平台审核员使用独立 `SCOPE_emm:approve`、近期多因素认证和 `If-Match` 版本调用 `POST /api/v1/platform/managed-android/enterprise-bindings/{tenantId}/approve`，请求体包含 `ownershipEvidenceReference`（外部权属证明的索引）和 `reason`。Keycloak 模板将该 scope 映射到需人工授予的 `emm-binding-reviewer` 角色，`/api/v1/me` 只基于已验证令牌返回 `canReviewManagedAndroid`。系统先从提供方只读核对完整企业资源名，再在事务内检查：申请仍为 `PENDING`、申请人与审核人不同、相同合同号存在已应用审核、当前合同授予仍有效并含 `MANAGED_ANDROID`。全部通过才写为 `ACTIVE`。**提供方可读性本身不是客户所有权证明；证据索引需要平台人工复核对应合同和企业权属。** 默认连接器不可用时批准返回 `503 EMM_UNAVAILABLE`，申请仍可留在待审核队列，不会生成虚假已批准结果。

平台审核队列是 `GET /api/v1/platform/managed-android/enterprise-bindings`，单条查看路径为 `/{tenantId}`；仅审核权限可访问。批准或撤销均需 `If-Match`，并写入版本化事件和租户审计。`POST /api/v1/platform/managed-android/enterprise-bindings/{tenantId}/revoke` 会将本地映射改为 `REVOKED`，阻止后续基于此映射的新受管操作；**该动作不等于从设备移除 DPC、取消现有 Google 策略或完成退管**，这些需要单独的真机流程和回执。当前 `ACTIVE` 只是企业资源审核结果，业务策略和设备身份仍未接通，不能视为设备管控已生效。

平台管理台现有“企业绑定审核”入口，仅对 `/me` 返回 `canReviewManagedAndroid=true` 的独立审核员显示。页面可查看待审核队列、按机构 ID 查询已处理记录，并提交权属证明索引及审核理由；申请人与审核人为同一人时禁用批准，服务端再次核验。撤销操作要求填写理由，并明确提示不会自动退管。网络状态不确定时应重新读取该机构记录，界面只按服务端版本和状态展示结果。

后续设备注册与策略服务应通过服务端 `ManagedEnterpriseAuthority.requireActive(tenantId)` 解析企业，而非直接接受浏览器传来的企业 ID。该入口每次检查绑定仍为 `ACTIVE`、提供方仍可用、对应合同及 `MANAGED_ANDROID` 权益在当前时间仍有效。它只返回企业资源定位信息，不授予设备级执行权限；后续调用还需独立核对设备注册、管理模式和策略版本。

## 短时受管注册与提供方设备核对

机构管理台的“受管 Android”页面现已接入企业绑定申请、绑定状态、注册资料发放、设备证据核对和令牌取消。机构所有者和机构管理员可发起操作；审计员只能查看脱敏进度。页面按租户和登录身份隔离，切换工作空间会清除在屏幕上显示的一次性资料。注册资料的二维码载荷只在创建响应和当次窗口显示；管理台使用本地 `qr_flutter` 组件渲染二维码，不调用在线转换服务。若载荷超出可显示范围，可复制载荷交由机构批准的**本地离线**二维码工具处理，不能提交给在线转换服务。管理员应在设备端完成 Android Enterprise 注册后，从提供方设备记录取得设备 ID 再核对。页面持续提示：提供方核对成功仍不等于本地儿童 App 已绑定或策略已生效。

管理台新增依赖 `qr_flutter 4.1.0`（BSD-3-Clause）及传递依赖 `qr 3.0.2`，版本与校验和锁定在 `apps/guardian/pubspec.lock`。发布前仍需纳入统一 SBOM、许可证与漏洞核验。[qr_flutter 包资料](https://pub.dev/packages/qr_flutter)

服务端已建立 `managed_enrollment_intents` 及版本事件账本，与原有 BYOD 设备注册分开。机构所有者或管理员完成近期多因素认证后，调用 `POST /api/v1/tenants/{tenantId}/managed-android/enrollment-intents`，请求体为 `{ "subjectId": "..." }`。服务端核对当前企业绑定、合同权益和有效儿童档案，限制同一儿童一个有效申请、每儿童每小时最多 10 次、每机构最多 100 个有效申请。部署时需配置经人工预置并独占的 `manager.emm.google.bootstrap-policy-id`。Google 连接器会先后两次读取初始策略，要求明确 `BLACKLIST`、空应用清单且没有其他配置字段，确认版本未变化后才接受一次性 5 分钟令牌；若本地持久化失败，会尝试立即删除提供方令牌。Google 支持[删除注册令牌](https://developers.google.com/android/management/reference/rest/v1/enterprises.enrollmentTokens/delete)，删除后不能继续用该令牌注册。

创建成功的响应一次性返回 `tokenValue` 和 `qrCode`，设置 `Cache-Control: no-store`；数据库只保存随机 `additionalData` 的 SHA-256 摘要、提供方令牌资源名、关联儿童、企业/策略版本及过期时间。查询 `GET .../enrollment-intents[/{id}]` 仅返回不含令牌和摘要的进度，可用于提交结果丢失后的核对；丢失的一次性材料不能从查询接口恢复，应取消旧申请并重新创建。管理员可带 `If-Match` 调用 `POST .../{id}/cancel`，服务端先标记 `CANCEL_PENDING` 再删除令牌；远端暂不可用时保留待清理状态，不能把它显示为已取消。后台清理任务使用数据库租约跨节点竞争，按有上限的退避重试删除令牌，成功后写入 `CANCELLED` 与审计；默认每 30 秒处理最多 25 项，可用 `manager.emm.enrollment-cleanup.*` 调整。

设备完成系统级注册后，管理员带 `If-Match` 提交 `POST .../{id}/verify` 与 `{ "providerDeviceId": "..." }`。服务端从提供方回读设备资源，核对完整资源名、`DEVICE_OWNER` 模式、令牌资源名、随机关联值摘要和真实注册时间，再把意图记为 `VERIFIED`。**这里验证的是提供方设备与机构儿童档案的关联证据，不是本地儿童 App 的密钥/注册周期，也不是应用策略生效回执。** 原 BYOD `devices` 记录不会因此变成受管设备；真实设备链接、策略执行、退管和 Android TV 兼容仍需继续实现。没有合规 EMM 时，令牌创建保持 `503 EMM_UNAVAILABLE`，不得展示虚构二维码。

对已核对的记录，管理员或审计员可按需调用 `GET .../{id}/provider-status`。服务端重新读取提供方设备的原始注册证据，核对令牌名称、随机关联值、注册时间和 `DEVICE_OWNER` 模式；再检查初始安全策略仍为原版本、读取提供方最后报告的策略状态，并再次核对设备注册证据。响应区分 `PENDING`、`APPLIED`、`NON_COMPLIANT`、`DRIFT`、`STALE`，附检查时间、最近策略同步时间和有限的原因码，**始终返回 `localAgentBound=false`**。默认超过 24 小时未同步或无同步时间时不能显示 `APPLIED`，阈值可通过 `manager.emm.provider-status-max-age-seconds` 在 1 小时至 7 天内配置。页面必须把“提供方初始安全策略曾报告应用”和“本地儿童 App 策略已生效”分开。此接口是人工诊断读取，不会给普通 BYOD 设备升级能力，也不替代持续状态监控或真机验收。提供方暂不可用或合同/绑定失效时应显示不可核对，而不是沿用旧成功状态。

新建的企业和注册数据表已纳入儿童数据覆盖目录；数据删除预检遇到待清理令牌或已核对的提供方设备会显示明确阻断项。当前儿童数据执行删除整体尚未开放，后续必须先完成 EMM 真正退管、令牌取消、审计保留和跨系统清理，再允许删除关联档案；本阶段不能用删除数据库行代替远端退管。

Google 的设备级 `playStoreMode` 未设置时默认 `WHITELIST`：只把少数应用写入 `applications` 会使列表外应用不再可用，并可能被自动卸载。因此连接器**拒绝**不存在、未明确设为 `BLACKLIST`、或启用 `installAppsDisabled` 的策略；它不会悄悄创建策略或切换原有白名单。运维须在合格提供方、企业所有权和独占策略命名空间均已核实后预置策略。`BLACKLIST` 下未列出的应用通常仍可安装，这不是“仅允许所选应用”的全局白名单能力。完整白名单需独立的应用清单、系统必要应用保护、后果预览和真机签收流程。现有 `putApplicationPolicy` 会替换这份**专用策略**的完整应用列表，不能与其他管理工具共写同一策略。

领域规则与 Google 连接器共用 `SafetyCriticalPackages` 安全底线，包含儿童端正式包 `com.aimanager.child`、调试包 `com.aimanager.child.debug`、Android Device Policy `com.google.android.apps.work.clouddpc`、设置与电话等恢复所需应用。部署项 `manager.policies.additional-protected-packages` 只能增加，不能删减基础清单。普通策略不能禁止这些包的启动、安装和必要权限；连接器直接收到 `BLOCK_LAUNCH` 或 `BLOCK_INSTALL` 时也会拒绝。未来更换应用 ID 或 EMM 提供方时必须同步核对恢复路径。连接器尚未接到领域编译与真实设备绑定，企业审核记录也未用于策略调用；包名保护本身不构成完成受管执行验收。

## 启用门槛与配置

```properties
manager.emm.google.enabled=false
manager.emm.google.eligibility-confirmed=false
```

只有经法务/商务确认的准入、允许用途、客户关系及 Google 项目配置具备后，运维才可同时打开这两项。`enabled=true` 且未确认资格会导致服务启动失败；仅关闭时不会加载云端凭证。正式环境使用服务端 Application Default Credentials（工作负载身份优先），只授予 `androidmanagement` 所需权限；不把账号密钥放入仓库、移动客户端或聊天记录。

当前锁定依赖为 `google-api-services-androidmanagement:v1-rev20260714-2.0.0` 与 `google-auth-library-oauth2-http:1.54.0`。正式发布前应把直接和传递依赖纳入 SBOM、许可证核验和漏洞扫描；升级官方生成客户端时重跑本地请求契约与真机回归。

正式接入前还必须完成：

1. 将已审核的企业绑定接入后续受管操作：所有写调用应从当前租户解析 `ACTIVE` 企业资源，实时检查合同和设备绑定；目前连接器仍是独立边界，没有任何策略写入入口。
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
