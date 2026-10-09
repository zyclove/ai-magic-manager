# 设备观察授权与报告后端

## 交付状态

本次文档提交先发布契约与实施记录。下述后端实现在工作区已完成验证，待协作任务的完整 V13～V19 先合入后，才单独提交 V20 及后端代码；不能仅依据本文件认定当前仓库提交已包含这些接口。

本阶段在 Spring Boot 后端增加每设备注册周期的应用清单、使用摘要授权以及使用摘要接收/查询。应用清单接收接口同步要求授权版本。复用 Spring Security、Bean Validation、Spring JDBC、Flyway、现有 MFA、强 ETag、幂等日志和审计组件。

**尚未交付本阶段的 Android 原生查询、设备持久上传组件和监护人编辑页面。** 服务端接收测试夹具不代表真机采集、系统管控、准确计费或 TV 兼容认证。完整产品目标继续按总方案实施。

## 权限与生命周期

| 操作 | 身份与限制 |
| --- | --- |
| 查看设置、使用摘要、应用清单 | 成人 OIDC；复用设备可见范围检查，儿童仅能读取自身范围 |
| 修改授权 | OWNER、GUARDIAN、ORG_ADMIN；最近 300 秒内 MFA；设备处于 ACTIVE；强 `If-Match` |
| 设备读取授权、上传报告 | 独立 opaque 设备凭证；凭证、租户、设备、注册周期由认证结果确定，正文不能指定其他范围 |
| 教师、审计员、儿童修改授权 | 不允许；教师/审计员的只读授权仍由现有设备范围规则决定 |
| 初始状态 | `version=0`，两种观察均关闭；没有设置记录也视为关闭 |
| 撤回使用摘要 | 同一事务内清除摘要批次及最新回执头；旧授权版本不能向重新授权周期上传 |
| 修改任一授权设置 | 清除当前应用清单，等待设备按新版本重报；不会将授权前的旧清单自动显示为新授权结果 |
| 撤销设备注册 | 订阅既有注册撤销事件，清除授权与观察载荷；不宣称设备本地数据已擦除 |

接收事务遵循设备生命周期锁 → 凭证锁 → 授权锁 → 报告头锁。授权更新遵循成员授权锁 → 设备锁 → 授权锁。撤回、撤销和报告串行化，失败时整体回滚。已经发送至调用方的响应无法通过撤回追回；客户端须清除自己的缓存，不能把历史授权响应当作当前授权。

应用清单、使用摘要都只是 `AGENT_REPORTED_UNVERIFIED`。使用摘要精度为 `OS_AGGREGATE`，不进入额度账本。设置响应不返回管理员身份或授权原因；当前原因存在授权记录，通用审计记录操作类型、资源、操作者和关联 ID。本阶段未提供完整授权版本差异历史页面。

## 管理接口

公共前缀 `/api/v1`；所有时间为 UTC epoch 毫秒，序号/版本最大 `9007199254740991`。

### GET /tenants/{tenantId}/devices/{deviceId}/observation-settings

返回 `200`、强 `ETag: "0"`，示例：

```json
{
  "deviceId": "device-id",
  "registrationId": "registration-id",
  "version": 0,
  "inventoryEnabled": false,
  "usageEnabled": false,
  "updatedAt": null
}
```

### PUT /tenants/{tenantId}/devices/{deviceId}/observation-settings

```http
If-Match: "0"
Idempotency-Key: <本次操作随机键>
Content-Type: application/json
```

```json
{"inventoryEnabled":true,"usageEnabled":false,"reason":"监护人确认应用清单用途"}
```

两个开关必填；原因去除两端空白后保存，输入非空且最多 300 字符。成功返回新设置及新 ETag。省略 `If-Match` 返回 428，弱/非法 ETag 返回 400，版本过期返回 412；没有近期 MFA 返回 401，无管理角色返回 403。

幂等键沿用平台约定，客户端应始终提供。同一键、同一请求重放返回原响应；更换正文必须更换键。原响应不是实时设置，重试恢复后再次 GET 确认当前状态。版本冲突要求重新加载并由管理员检查差异，不能后台自动覆盖。

### GET /tenants/{tenantId}/devices/{deviceId}/usage-observations

参数 `limit` 默认 5，范围 1～20；`cursor` 为上一页 `nextCursor`，严格正整数序号字符串。返回 `items`、`nextCursor`；按序号降序，不把重叠系统时间区间相加为自然日使用量。

每条摘要返回注册周期、报告 ID、序号、授权版本、profile、queryStart/queryEnd/observedAt、IANA timeZone、applications、receivedAt，以及固定 `precision=OS_AGGREGATE`、`evidenceStatus=AGENT_REPORTED_UNVERIFIED`。撤回后列表为空；跨设备注册周期不混合查询。

## 设备接口

### GET /device-api/observation-settings

使用当前设备凭证，返回与管理读取相同的最小设置视图。设备必须在线取得当前授权后再采集；云端授权与 Android 系统特殊访问是两项独立条件。此规则的客户端执行仍待后续组件实现。

### POST /device-api/application-inventory

现有正文新增必填 `authorizationVersion`。原 `sequence`、`visibility=VISIBLE_PACKAGES`、applications 的验证和规范化仍有效。授权关闭返回 403，授权版本变化返回 409；授权开启后才能接受该注册周期的清单。查询关闭状态返回 `observationStatus=NOT_AUTHORIZED`、空列表，不将空列表解释为没有安装应用。

**兼容性变更：** 没有 `authorizationVersion` 的旧上传请求返回 400。服务器升级后默认关闭旧设备的观察，旧客户端需先升级再授权；清单读取调用方需识别新增 `NOT_AUTHORIZED` 状态。旧清单在未授权时隐藏，首次修改授权时物理删除；尚未发生设置修改的遗留清单仍可能保留在原表，应按既有数据清理制度处理。

### POST /device-api/usage-observations

```json
{
  "reportId": "00000000-0000-4000-8000-000000000001",
  "sequence": 1,
  "authorizationVersion": 1,
  "source": "ANDROID_USAGE_STATS",
  "profile": "PRIMARY",
  "queryStart": 1791511200000,
  "queryEnd": 1791514800000,
  "observedAt": 1791514800000,
  "timeZone": "Asia/Shanghai",
  "applications": [{
    "packageName": "org.example.reader",
    "displayName": "阅读",
    "firstTimeStamp": 1791504000000,
    "lastTimeStamp": 1791514800000,
    "foregroundMillis": 120000
  }]
}
```

示例时间仅说明字段，调用时必须使用实际系统时间。允许 profile：PRIMARY、WORK、SECONDARY、UNKNOWN。最多 500 条聚合记录；包名/显示名分别最多 255/100 字符；同包名与相同实际时间区间不能重复。允许同一应用不同系统区间，前端不能把它们误当成互不重叠区间。

请求查询区间需递增、长度不超过 2 天，queryEnd 不晚于 observedAt；observedAt 不早于服务器 7 天、不晚于服务器 5 分钟。应用实际区间可超出查询区间，以保留 Android 扩展的聚合边界，但最早不超过 observedAt 前 7 天，最晚不超过 observedAt 后 5 分钟，前台时长不得大于实际区间。客户端报告字段为自报，服务器范围校验无法证明时钟和时长可信。

成功响应：`registrationId`、`reportId`、`sequence`、`receivedAt`。同一最新序号、规范化后相同正文返回原 ACK，不刷新观测时间；同序号不同正文返回 `USAGE_SEQUENCE_CONFLICT`，旧序号返回 `USAGE_STALE_SEQUENCE`。序号可以跳跃。报告 ID 不可在保留历史内复用。撤回清理后序号可重新开始，但授权版本必须是当前值。

客户端须持久保存原请求至 ACK 验证完成，校验注册周期、报告 ID 和序号。重放仍受当前授权、凭证和时间窗口限制；超过 7 天的旧报告不能保证获得原 ACK，应丢弃后重新采集。服务端只保存最新回执头，旧序号不提供无限重放。

其他稳定错误包括 `OBSERVATION_NOT_AUTHORIZED`(403)、`OBSERVATION_AUTHORIZATION_CHANGED`(409)、`OBSERVATION_REPORT_RATE_LIMITED`(429)、`USAGE_REPORT_ID_CONFLICT`(409)、`INVALID_OBSERVATION_WINDOW`(400)、`INVALID_TIME_ZONE`(400)。401 暂停上传并进入身份恢复流程；403 停止采集并清缓存；409 授权变化清 pending 后重新读取设置；429 退避，不能忙循环。

## 存储、保留与部署

新增 Flyway `V20__device_observation.sql`，包含授权设置、最新回执头、摘要批次三表。所有表绑定 tenant/device/registration 复合外键；报告 ID 在设备范围唯一，保留清理索引按 receivedAt。没有引入新的商业 SDK 或自研权限系统。

| Spring 配置键 | 默认值 | 合法范围 |
| --- | --- | --- |
| `manager.observations.minimum-report-interval-seconds` | 60 | 1～3600 |
| `manager.observations.retention-days` | 30 | 1～90 |
| `manager.observations.max-retained-batches` | 168 | 1～1024 |
| `manager.observations.retention-delay-millis` | 300000 | 正数；由部署校验 |

新报告接受后按每设备批次数和保留天数清理；查询即时隐藏超过保留期的记录，定时任务每次最多删除 100 个过期主键。大规模部署必须观测清理积压，不能把默认清理速率视为百万设备容量证明。最新 ACK 头不按年龄清除，撤回/注册撤销时删除。使用摘要不会覆盖原始事件、摄像头数据或网页内容。

保留天数是上限，不是历史完整性的承诺；168 批次限制可能更早裁剪，例如每分钟接受一批仅能保留约 2.8 小时。产品必须显示实际覆盖时间，不应在该配置下宣称具备 30 天完整趋势。后续日汇总与长期趋势需独立的数据契约和隐私设计。

部署顺序：先合入并应用协作任务的完整 V13～V19 阶段，再应用 V20；不能先发布 V20 后让已有环境补跑低版本迁移。升级前备份及检查 Flyway history，分批开放观察授权；回退应用前先关闭观察写入并保留数据库新增表，禁止自动删除含数据的表或改已应用迁移校验和。

回退到不认识观察授权的旧应用版本前，必须在入口关闭 application-inventory 的上传及读取路由，并关闭 usage-observations 写入；否则旧应用可能重新接受未授权清单或暴露隐藏的遗留清单。恢复完整授权检查前不得重新开放，不能只依赖新版本表中的关闭标记约束旧代码。

本阶段验证使用 H2 MySQL 模式，**未完成真实 MySQL/OceanBase 并发、迁移、执行计划和故障切换认证**。生产数据库仍按数据库实施规格的认证门槛发布，不能把 H2 成功当作 OceanBase 支持证明。

## 已有证据与下一步

2026-10-09：在提交基线 `9acbabb` 加本阶段自有文件的隔离快照运行现有验证，观测 7 项、清单 7 项、模块边界 1 项，共 15 项通过。曾因本机 native memory 不足导致 JVM 退出；设置进程级 `JAVA_TOOL_OPTIONS=-Xmx512m -XX:ActiveProcessorCount=2` 并释放本任务模拟器资源后成功。没有终止协作任务服务。

随后运行该快照的完整现有后端回归：19 个测试类、166 项，164 项执行通过，2 项因没有启用系统参数而跳过，失败/错误均为 0。跳过的是 DeviceConfigurationHttpInteropTest 与 DeviceIdentityHttpInteropTest，本轮未重新验证这两个跨语言真实 HTTP 流程。快照只含 HEAD 与本阶段文件，不包含协作中未提交的 V13～V19；实际部署仍须遵循上述迁移合入顺序。

同一快照随后 `mvn -DskipTests package` 退出 0，生成 Spring Boot 可执行 JAR；12 个本阶段源码/迁移/测试文件与运行时快照 SHA-256 一致。该制品属于上述隔离基线，不能代替前序迁移合入后的生产候选构建。

另取当时工作区的协作生产代码与 V1～V20 为集成快照，再运行观测、清单、模块边界 15 项，全部通过，进程退出 0。这只证明该快照的接点一致性；协作阶段仍应按其自己的提交与验收记录发布。

后续交付依次覆盖设备严格协议与持久 pending、官方 Android SDK/Pigeon 原生采集、监护人与儿童交互、真实 HTTP/Android/MySQL 联调、撤回与权限变化竞态，以及生产容量和隐私保留认证。相关未交付项不能在 UI、套餐或销售资料中标记为已支持。
