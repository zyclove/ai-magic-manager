# 共享额度账本与管理界面

更新：2026-10-09。此阶段提供每日额度、重复计划、事务账本与设备租约协议；不代表 Android/TV 已具备可靠停止能力。

## 数据和行为

- 所有数量使用整数秒。一个儿童、日期及范围只有一个池；范围为 `TOTAL` 或指定应用 `APPLICATION`。总额度和该应用额度同时约束发放量。
- 日期按 IANA 时区定义，周期为当地午夜到次日午夜，支持夏令时的 23/25 小时日。创建首个池或计划后，该儿童的额度时区固定。
- `limitSeconds = usedSeconds + reservedSeconds + availableSeconds`。已结算是设备上报并入账的数量；待确认预留包含可能已消费但未上报的数量；可分配是服务端剩余可发放量。
- 生产 `QuotaExecutionSupport` 当前明确拒绝发放：尚无已认证的计时、重启持久恢复和可靠停止适配器。管理页始终展示账本证据，不把配置成功标为设备执行成功。
- 设备租约用 Nimbus ES256 签名，独立类型 `aimanager-quota-lease+jws`，绑定租户、儿童、设备、注册周期、应用、启动周期、会话、单调时钟起点、池、额度和到期时间。
- 租约最长 300 秒并且不跨池的日终。相同注册周期和 requestId 永久对应原租约；重试不延长期限、不重复分配，换请求体返回冲突。
- 同一应用在该日期已有任何租约签发后，禁止新增该日应用池，返回 `QUOTA_SCOPE_ALREADY_USED`。已签名租约不能被追溯添加到新的池；可配置下一日期，或调整现有总池。
- 结算使用递增 sequence 和累计秒数。同序号同正文重放返回原结果，同序号不同正文、倒退序号、倒退时钟/计数均拒绝。累计用量同时受预留总量、本地时钟和服务端流逝时间约束。
- 超时、断网、重启不会自动退回未知消费。租约超时仅呈现 `AWAITING_RECONCILIATION`；最终确认结算才释放未消费部分。旧周期迟到结算只更新原池，不增加新周期余额。
- MySQL/JDBC 行锁串行化共享余额；余额、租约、分配、账本、审计和事件日志在同一个事务中提交。没有把 Redis 当作额度权威。
- 生命周期锁统一为主体→设备→凭证域，再锁额度日历、适用计划和池；获取设备锁后重新核对主体绑定，与策略例外的锁顺序保持一致。

## 管理 API

统一前缀 `/api/v1/tenants/{tenantId}`。

| 方法与路径 | 契约 |
|---|---|
| `POST /quota-pools` | `name, subjectId, scope, applicationId?, periodId, timeZone, limitSeconds`；成人权限、近期 MFA、必需 Idempotency-Key |
| `GET /quota-pools` | limit/cursor 分页；成人及审计角色按租户读取，儿童只读本人 |
| `GET /quota-pools/{id}` | 当前余额和强 ETag；响应 `status=CONFIGURED, evidenceStatus=LEDGER_ONLY` |
| `POST /quota-pools/{id}/adjustments` | `deltaSeconds, reason`；EXTRA_TIME/CORRECTION、成人、近期 MFA、If-Match 和幂等键 |
| `GET /quota-pools/{id}/ledger` | 分页读取 CREATED/ADJUSTED/RESERVED/SETTLED/RELEASED 及秒数变化 |

每池 0～86400 秒；日期最多提前 366 天。关闭周期不能调整。减少额度不能低于已结算和预留之和。响应错误沿用 ProblemDetail 和关联 ID。

## 重复计划 API

前缀同管理 API。响应展示最新已保存配置及其生效日期，后台生成每日池不会改变配置版本。

| 方法与路径 | 契约 |
|---|---|
| `POST /quota-plans` | `name, subjectId, scope, applicationId?, timeZone, effectiveFrom, weeklyLimits, dateOverrides`；成人、近期 MFA、幂等键 |
| `GET /quota-plans` | limit/UUID cursor 分页；儿童仅本人，其余按当前租户角色读取 |
| `GET /quota-plans/calendar` | `subjectId, defaultTimeZone`；返回该儿童已有额度时区及服务端当地日期，无已有日历时使用有效默认时区 |
| `GET /quota-plans/{id}` | 最新保存配置和强 ETag |
| `PUT /quota-plans/{id}` | `name, state, weeklyLimits, dateOverrides`；成人、近期 MFA、If-Match、幂等键；从次日生效 |
| `GET /quota-plans/{id}/revisions` | limit/数字版本 cursor 分页；不可变历史配置，版本倒序 |

`weeklyLimits` 必须提供 MONDAY 至 SUNDAY 七个键，每个值为 0～86400 整数秒。`dateOverrides` 最多 60 个日期，值同单位；日期例外优先。新计划从其时区的今天或明天开始，一个儿童每种范围只保留一个长期计划。暂停、恢复和编辑保存新版本并从次日开始；同一生效日采用最后确认的版本。

V14 保存计划、修订、自动池的 `planId/planVersion`。手工已有池不被覆盖；已生成池、消费和预留不随计划编辑重置。停机恢复只生成当前日。应用在当日已有租约且尚无应用池时，创建当天应用计划也会被拒绝，防止漏计早先消费。

Spring Scheduler 按索引扫描有界批次，每个计划独立事务，失败延后重试。默认 `QUOTA_MATERIALIZATION_JOB_ENABLED=true`、`QUOTA_MATERIALIZATION_INTERVAL_SECONDS=30`、`QUOTA_MATERIALIZATION_BATCH_SIZE=100`。设备申请新租约时在同一事务补齐总额与当前应用计划，不依赖后台批次恰好先执行；所有相交额度存在后才发放。详细决定与检查范围见[重复额度计划实施说明](quota-recurring-plan.md)。

## 设备 API

统一前缀 `/api/v1/device-api`，仅接受当前有效的独立设备凭证。

| 方法与路径 | 输入 |
|---|---|
| `POST /quota-leases` | `requestId, applicationId, bootId, sessionId, startTickMillis, requestedSeconds` |
| `GET /quota-leases/{id}` | 仅本设备、当前注册周期可读 |
| `POST /quota-leases/{id}/settlements` | `bootId, sequence, cumulativeUsedSeconds, elapsedRealtimeMillis, finished` |

设备身份与凭证状态在事务内复查，用户 JWT 不能替代设备凭证。租约事件表目前是事务内持久事件记录，尚未接入异步通知消费者。

## 管理界面

共享额度页在每日账本与重复计划之间切换，提供余额详情、增减、账本、周额度、日期例外、次日暂停/恢复和版本历史；每日池标明手工或计划来源。计划表单读取儿童已有时区和服务端日期，支持工作日/周末填充。支持宽屏表格、窄屏卡片、加载/空态/错误状态、分页、角色限制和重新认证入口。表单固定工作空间、资源版本和幂等键，未知提交结果只能重试原请求。

## 尚未完成的完整产品范围

时区安全变更、分组/机构继承、审批追加时间联动、签名策略基线绑定、客户端可信计时/离线持久化/本地停止、EMM/Android/TV 实机验证、异步事件交付和保留治理仍需实现。OceanBase、容量、高可用和备份恢复尚未认证。所有完成声明应同时引用实施记录中的实际检查范围。
