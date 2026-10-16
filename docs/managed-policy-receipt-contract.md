# 受管策略回执的资源与版本契约

日期：2026-10-16。状态：回执修正已通过本地 HTTP 契约回归，尚未部署或开放系统执行。

## 为什么要核对回执

官方设备 PATCH 返回 Device，策略 PATCH 返回 Policy。连接器继续使用官方生成 Java SDK，额外核对返回对象是否对应本次请求，不能根据 HTTP 成功或请求参数自行构造成功事实。依据：[设备 PATCH](https://developers.google.com/android/management/reference/rest/v1/enterprises.devices/patch)、[策略 PATCH](https://developers.google.com/android/management/reference/rest/v1/enterprises.policies/patch)。

设备的 `appliedPolicyVersion` 表示当前应用的版本。平台需要把回执归属到一个具体的发布版本，因此选择精确匹配；后续版本可能改变规则，不能据其推断先前版本生效。这是本平台的发布归因规则。依据：[Device 字段说明](https://developers.google.com/android/management/reference/rest/v1/enterprises.devices)。

## 行为

| 操作 | 必须满足的条件 | 未满足时 |
| --- | --- | --- |
| 更新应用策略 | 响应 Policy.name 与请求完全相同，version 为正数 | 抛出固定、无响应正文的异常 |
| 分配设备策略 | 响应 Device.name 与目标设备相同，policyName 与目标策略相同 | 结果不能确认，不能返回成功分配回执 |
| 核对策略应用 | 期望/已应用策略名称相同、已应用版本精确相同、受管模式可识别 | 不标为 APPLIED |
| 核对合规 | 明确合规且无不合规明细 | 明细存在或明确不合规时标为 NON_COMPLIANT |

策略写入与分配的回执只确认提供方返回了对应资源，不表示设备执行。资源不符的写入响应属于结果不确定：提供方可能已经接受写入，连接器不会因为校验失败而自动重放写入。后续编排应先查询原目标，再决定恢复动作。

原有注册服务已独立检查精确版本，并将较新版本映射为 DRIFT。本次把相同约束落实到 SDK 边界；没有新增执行状态枚举或改变前端响应契约。`ENFORCE`、区域准入和提供方配置门槛保持原样。

## 验证结果

`GoogleManagedPolicyReceiptTest` 使用回环 HTTP 服务驱动真实生成 SDK，覆盖错误企业/策略/设备、缺失字段、无效版本、更新版本不能证明旧发布、不合规明细与合规标志矛盾，以及正常请求。测试不使用 Google 项目或服务账号。

在 `b940d1d` 的独立源码快照中验证，未混入并行家庭、部署及界面改动。D 盘空间不足时，将源码、编译产物、临时文件及日志放到 C 盘隔离目录，离线使用现有依赖，并限制 JVM 内存。

- 旧网关复现：20 项中 13 项按预期失败、7 项通过，0 错误、0 跳过。失败覆盖错误/缺失资源身份、把较新版本当作旧发布生效，以及合规信息矛盾。
- 修正后干净重建：44 项全部通过，0 失败、0 错误、0 跳过。其中新增回执场景 20 项、既有网关 4 项、应用证据读取 18 项、默认关闭与配置限制 2 项。
- 中途一次增量构建因复制保留时间戳而使用了旧 class，仍出现原 13 项失败；该次不计为修正后证据。清除独立目录的可重建输出，确认重新编译后才记录通过。
- 只使用回环 HTTP 服务，不包含真实 Google/合作 EMM、Android 设备或系统执行验收。写入响应异常不会被解释为服务器肯定没有执行，仍须查询原目标确认。

测试类：`GoogleManagedPolicyReceiptTest`、`GoogleManagedAndroidGatewayTest`、`GoogleManagedAgentEvidenceTest`、`ManagedAndroidConfigurationTest`。

## 后续执行接入

此修正只解决回执解释。正式应用控制还需要把可信设备绑定、应用身份、领域策略编译、权限/合同复核、持久命令、规则级回执与补偿接通，并完成符合目标地区与机型的提供方及真机验收。
