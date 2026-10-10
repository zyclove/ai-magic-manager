# Android Enterprise 受管设备连接器（阶段交付）

## 当前边界

本仓库现在提供服务端 `ManagedAndroidGateway` 接口及 Google Android Management API 官方 Java 客户端实现。默认实现为不可用且拒绝所有调用。**当前未取得 Android Enterprise EMM/Android Management API 商业准入，也没有绑定真实 enterprise 和设备；不能把它宣传为已实现受管设备强管控。** 现有家庭 BYOD 注册、策略预览与下发状态仍按原有能力边界运行，`ENFORCE` 不会因为本连接器存在而自动开放。

代码位置：`backend/src/main/java/com/aimanager/managedandroid/`。连接器仅在服务端运行；Flutter 和设备端不得持有 Google 服务账号凭证。

## 提供方接口与能力

| 操作 | 实现 | 成功语义 |
|---|---|---|
| 写应用策略 | `putApplicationPolicy`，仅更新 AMAPI `applications` 字段 | Google 接收策略版本；设备是否应用须回读 |
| 创建注册令牌 | `createEnrollmentToken`，一次性、5–30 分钟、禁止个人使用 | 仅得到临时敏感注册材料；设备仍未受管 |
| 分配策略 | `assignPolicy`，仅更新设备 `policyName` | 服务端请求已接收；不是系统执行成功 |
| 回读执行状态 | `readDeviceState`，读取 `appliedPolicyName`、`appliedPolicyVersion`、`policyCompliant`、`nonComplianceDetails` | 名称和目标版本都匹配且明确合规才标记 `APPLIED`；未知或未同步为 `PENDING` |

当前应用映射仅支持 `ALLOW`、`BLOCK_LAUNCH`、`BLOCK_INSTALL`。`BLOCK_LAUNCH` 使用 `ApplicationPolicy.disabled=true`，`BLOCK_INSTALL` 使用 `installType=BLOCKED`，后者可能移除已安装应用，必须在产品界面提前说明。应用包名必须合法且单个策略最多 3000 条。日使用时长、时段、网站内容、摄像头识别等**没有**被映射到 AMAPI，不能宣称由此连接器保证执行。系统应用、不同 Android 版本与 OEM 的限制要逐机型验收。

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
- [Enrollment tokens](https://developers.google.com/android/management/reference/rest/v1/enterprises.enrollmentTokens)
- [Device resource 与合规状态](https://developers.google.com/android/management/reference/rest/v1/enterprises.devices)
