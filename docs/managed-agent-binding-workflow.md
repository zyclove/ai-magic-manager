# 受管儿童端绑定工作流

状态：后端工作流阶段已实现并完成本地验证，2026-10-15。沿用 [可信绑定计划](managed-agent-binding-plan.md)；本阶段将上一阶段纯验签组件接入持久化事务和 HTTP 契约，不开放系统策略执行。

## 使用流程

1. 管理员完成近期多因素认证，选择已经核对提供方身份的注册记录，以及同一学生的已激活儿童端设备。
2. 服务端创建 10 分钟有效的挑战。相同幂等键可取回原请求，不生成多个挑战；同一设备和提供方注册记录同时最多一个待处理或已核验的关联。
3. 儿童端通过现有独立设备凭证领取属于当前注册的挑战，使用原注册私钥签名，经受管反馈通道上报。家长页面不显示挑战值或签名正文。
4. 管理员请求核验。服务端在事务外读取提供方身份、应用证明，再读身份，随后在短事务内重新核对权限、机构与合同、学生、设备注册及请求版本，验签并原子消费挑战。
5. 已核验只代表这一时点的关联证据成立。系统策略执行必须另外验证能力和回执；应用签名信任撤销、设备撤销、合同失效等仍需后续操作重新核对。
6. 管理员可以撤销本地关联；这不会自动退管提供方设备或释放合同设备名额。过期挑战停止使用并清除挑战值，保留最小操作记录。

## API 契约

管理根路径：`/api/v1/tenants/{tenantId}/managed-android/agent-bindings`。响应使用 `Cache-Control: no-store`、`Vary: Authorization`；单项返回资源版本 ETag。

| 操作 | 输入 | 结果与保护 |
| --- | --- | --- |
| `POST /` | `Idempotency-Key` 为规范 UUID；正文 `enrollmentId`、`deviceId`、`registrationId` | 201，原请求可恢复；管理员近期认证，无挑战值 |
| `GET /` | `limit`、`cursor` | 分页元数据；管理员或审计员 |
| `GET /{id}` | 无 | 当前记录与版本，无挑战值、签名正文或提供方秘密 |
| `GET /context/{enrollmentId}` | `limit`、`cursor` | 接入条件、当前关联及同一学生的已激活设备候选；管理员或审计员 |
| `POST /{id}/verify` | `If-Match` | 202 等待反馈 / 200 核验完成；重新认证与当前权限检查 |
| `POST /{id}/revoke` | `If-Match` | 本地撤销，清除挑战值，保留审计 |
| `GET /api/v1/device-api/managed-agent-challenge` | 当前设备 bearer 凭证，无调用者指定设备参数 | 200 当前挑战 / 204 无待领取挑战 |

待核验请求过期不会自动延长。读取挑战允许重复领取同一请求以恢复断网，但完成核验只消费一次。设备凭证轮换不改变注册密钥；撤销注册后不能领取挑战或完成核验。

## 实现约束

- 数据库使用独立 `managed_agent_bindings` 表，初始建表追加到 V1。新表不代表已有数据卷可直接升级，现有部署保留原冻结版本。
- 远端 I/O 不持有数据库行锁；确认事务核对前后版本，拒绝请求进行期间的撤销或变更。
- 发布包名及 SHA-256 证书集合由受控服务端配置提供，默认未配置时不可发起绑定。配置不能由管理员接口或设备请求写入。
- 提供方还需显式实现 `supportsAgentBindingEvidence()`；已有连接器默认不支持。Google 适配具备读取能力，但仍受既有地区、准入和启用门槛控制。
- 只保存证明摘要、公钥指纹、时间和关联状态；原证明不持久化。挑战随机值仅在待处理有效期内存在，不进入日志、审计或管理员响应。
- 数据目录需列出所有新增列；正式删除执行仍遵守既有受管设备退出门槛，不能通过删除绑定记录绕过退出检查。

### 配置与容量

| 配置 | 默认 / 约束 | 用途 |
| --- | --- | --- |
| `manager.emm.agent-binding.package-name` | 空，合法 Android 包名，最长 255 | 正式儿童端发布包 |
| `manager.emm.agent-binding.signing-certificates` | 空，逗号分隔的 1–8 个小写 SHA-256 十六进制摘要 | 受控发布证书信任集合 |
| `manager.emm.agent-binding.expiry-batch-size` | 100；范围 1–1000 | 每次过期清理条数 |
| `manager.emm.agent-binding.expiry-interval-seconds` | 30；范围 5–3600 | 清理间隔 |

每设备一小时最多 10 次新请求，每租户最多 1000 个有效待处理请求；单个请求的远端核验间隔至少 5 秒。时间均使用服务端 UTC 毫秒，挑战签名 `iat/exp` 按 JWT 规范使用秒。客户端重复领取不延长截止时间；清理停机也不会让过期挑战重新可用。

### 事务与恢复

发起/核验事务的锁顺序为操作者授权 → 机构绑定 → 学生 → 本地设备 → 商业账户/来源 → 绑定记录；远端 I/O 位于两个独立短事务之间。撤销和过期清理仅修改当前关联，不调用远端退管接口。唯一约束保护活动设备槽、活动提供方注册槽及幂等请求；撤销或过期释放的是本地关联槽，提供方注册及合同占用保持原事实。

`VERIFIED` 是历史核验结果，不是持续在线或系统策略已应用证明。管理员读取仍可查看失效资格下的历史记录以进行撤销；设备领取和下一次核验需当前有效的资格、注册与学生状态。后续任何系统执行消费者必须再次检查这些事实和发布信任，不得只查询历史 `VERIFIED` 状态。

错误恢复：`RESOURCE_VERSION_CONFLICT` 先读取当前记录；`MANAGED_BINDING_ALREADY_EXISTS` 查找已有记录；`MANAGED_BINDING_EXPIRED` 重新发起；`MANAGED_BINDING_VERIFY_RATE_LIMITED` 至少等待 5 秒；提供方/合同不可用时保留待处理状态直到恢复或自然到期，不自动放宽要求。

## 尚需独立完成

AndroidX 反馈发送、客户端签名与重试、真实 EMM 与设备验收、最终策略执行接入。管理员可视化操作已在后续阶段接入，详见 [儿童端关联操作流程](managed-agent-binding-experience.md)。正式准入与发布证书未提供时，不启用生产绑定通道。

## 验证记录

验证副本以 `3094497` 后端归档为基础，仅覆盖本阶段文件、独立建表片段和数据目录条目；不包含家庭任务的未提交实现，不使用运行服务或现有数据库。

- RED：修正测试夹具的依赖注入后，创建请求得到 404 而非期望的 201，确认缺失的是目标接口。
- 工作流专项覆盖创建/幂等恢复、独立设备凭证领取、其他设备不可领取、成功验签与单次消费、撤销、等待反馈和轮询限流、学生归档、设备凭证撤销、租户/角色/近期认证/版本、远端读取期间成员/绑定/合同撤销、错误提供方身份、错误签名、到期清理、学生或注册不匹配、提供方能力默认关闭、并发创建与消费。
- 数据目录回归发现 `proof_sha256` 未列入新增数据目录，已补齐。目录全量核对重新通过，没有放宽目录审查条件。
- 完整回归在 22:22（Asia/Shanghai）正常退出：1170 项，1095 通过、75 条件跳过，0 失败、0 错误；本阶段当时的 14 项工作流测试包含在内。
- 随后增加活动槽查询优化、待处理计数索引和 OpenAPI 说明，并补充配置与索引断言；最终冻结版本执行 98 项专项检查，全部通过、无跳过，22:25 正常退出。其中工作流 16 项、证明/网关/配置 57 项，其他为模块边界、初始建表、目录及删除预检等回归。两轮结果不相加为覆盖总数。
- 75 个跳过项需要另行配置 Dart / Android 参数或外部数据库环境；本轮未执行真实 EMM、真机、MySQL / OceanBase 或生产部署验证。数据库事务检查使用 H2 MySQL 模式，不能替代目标数据库并发验收。

复现：Java 17，在冻结后端目录执行 `mvn -o -Dspring.test.context.cache.maxSize=2 test`。本地测试使用 `JAVA_TOOL_OPTIONS=-Xmx1536m -XX:MaxMetaspaceSize=384m -XX:ActiveProcessorCount=2 -XX:+UseSerialGC`。最终专项选择 `ManagedAgentBindingJourneyTest,ManagedAgentProofVerifierTest,GoogleManagedAgentEvidenceTest,GoogleManagedAndroidGatewayTest,ManagedAndroidConfigurationTest,ModuleBoundariesTest,DatabaseInitializationTest,*Preflight*,*Catalog*`。本地记录为 `.local/managed-binding-backend-full.log` 和 `.local/managed-binding-final-check.log`，生成物不提交。

新增表进入首版 V1 初始建库脚本；已有开发库不能以修改 Flyway 校验和的方式升级。当前演示部署不纳入这次 schema 变化，正式上线需按新库/数据迁移发布方案单独验证。
