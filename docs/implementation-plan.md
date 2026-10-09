# 智能管家完整功能实施计划

> 执行方式：当前会话直接实施，使用 executing-plans 跟踪。用户已授权实现完整功能；不提交、推送或部署到外部账户。

**Goal:** 实现设计蓝图中全部产品功能、前后端链路、设备适配和交付验证，保持能力边界真实。

**Architecture:** Spring Boot + Spring Modulith 领域模块化后端，MySQL 事务存储，OIDC 身份、租户/对象范围授权。Flutter 管理端与儿童端复用界面和 API，Kotlin 负责许可原生接口，EMM 连接器负责系统受管策略。

**Tech Stack:** Java LTS、Spring Boot、Spring Security、Spring JDBC、Flyway、Spring Modulith、Flutter、Kotlin、成熟 OIDC/MQTT/JOSE/支付/模型 SDK。

**Spec:** parental-control-platform-design.md、parental-control-functional-spec.md、parental-control-commercial-spec.md。

**实施补充：** [完整产品交付与商业运营模型](parental-control-product-operating-model.md)提供全量功能、交互、异常与商业工作包；[数据库实施与认证规格](database-implementation-and-certification.md)提供真实 MySQL/OceanBase 认证、事务、容量和迁移门槛。二者覆盖所有阶段，不改变完整目标或将规划标为已实现。

## 全局约束

- MySQL 8.4 LTS 默认；OceanBase 独立 profile 验证后支持，不默认混用 Keycloak 数据库。
- 所有业务查询先约束租户与权限；儿童不能修改策略；身份 token 不提供设备所有者权限。
- 不能把供应商接受、伴随应用收到或预览结果标成系统生效。
- 不可覆盖底线、紧急恢复、限时例外、离线期限、管理员近期认证贯穿全部模块。
- 原始视觉默认不采集；可选识别默认关闭，不能替代身份会话或自动处罚。
- 外部密钥用配置提供；开发环境与生产配置分离；没有供应商配置时显示未配置，不假报成功。
- 100 万注册设备容量仍需工作负载压测；没有真机/部署证据不得宣布相应验收完成。

## Review Focus

1. 撤销成员后旧 JWT 仍有效：每次查询成员事实，不能仅信 JWT 中的角色。
2. 资源 UUID 来自别的租户：SQL 与关联约束必须同时限定 tenant_id。
3. 同一幂等键换请求体：返回冲突，不能复用旧结果或者重复执行。
4. 系统清理包含擦除：预览、近期认证、确认哈希及供应商后果必须一致。
5. 时间/网络失真：例外和额度不能因重启、离线或时钟回拨重新增加。

## 文件布局与实施任务

每项先写行为测试，确认失败，再实现，执行对应完整测试/构建并记录结果。尚未执行的测试不勾选。当前目录无 Git，不新建工作树或自动提交。

### Task 1：身份、租户、成员和儿童主体

Files: `backend/pom.xml`、`backend/src/main/java/com/aimanager/{identity,tenant,subject,audit,shared}/`、`backend/src/main/resources/db/migration/`、`backend/src/test/java/com/aimanager/TenantJourneyTest.java`。

Interfaces: TenantAccess.requireRole(tenantId, actorId, allowedRoles)、AuditService.record(tenantId, actorId, action, resourceId)、REST /api/v1/tenants/{tenantId}/subjects。

- [x] 写测试：成人建家庭与孩子，陌生身份/儿童/撤销成员越权失败，非法时区与输入拒绝，匿名 401。
- [x] 执行 `mvn -f backend/pom.xml test`，记录缺功能失败。
- [x] 实现 JWT audience/issuer 验证、范围查询、短事务、Flyway、关联审计、错误响应与日志。
- [x] 实现邀请/接受/取消、成员撤销、近期 MFA、持久幂等与身份排序规则隔离。
- [x] 实现主体详情、强版本编辑/归档及 OpenAPI 3.1 生成。
- [x] 当前全套回归与可执行打包通过，证据见实施记录。
- [ ] 完整所有者交接、租户维护、成员/邀请查询、机构范围、恢复与通知、限流和保留治理。
- [ ] 生产 MySQL 迁移、真实 OIDC/MFA/公钥轮换验收。

### Task 2：设备注册、凭证、能力与健康

Files: `backend/.../fleet/`、`backend/.../deviceidentity/`、迁移 V4～V6、FleetJourneyTest。

Interfaces: 一次性 enrollment、设备注册周期、独立设备认证、capability records、heartbeat。

- [x] 测试过期/重复/并发注册、跨租户主体、凭证轮换/撤销、未知能力与模式差异。
- [x] 实现 BYOD 注册/确认、原密钥响应恢复、独立凭证、心跳/能力事实和撤销。
- [x] 两阶段凭证轮换、取消/到期与反重放；敏感关系和注册域按事务锁保护。
- [x] REST/OpenAPI 与 H2 SQL 自动化验收，受管能力保持不支持，证据见实施记录。
- [ ] 原生设备安全存储/硬件证明/密钥更换、正式 EMM 注册与系统执行、TV 真机。
- [ ] 注册/凭证/证据保留与到期作业、速率治理、真实 MySQL/OceanBase 与消息认证验收。

### Task 3：应用、权限、时间与策略

Files: `backend/.../{catalog,policy,schedule}/`、PolicyJourneyTest、ScheduleTest。

Interfaces: RuleEvaluation、PolicyVersion、preview/publish、不可变目标快照。

- [x] 实现应用身份声明、受凭证约束的可见清单上报、序号/回放/撤销与范围查询。
- [x] 实现不可变时间计划、日期例外、跨午夜、DST 缺口/重复及预览计算。
- [x] 实现规则验证/冲突、恢复豁免、草稿/模板、强 ETag、逐设备证据快照和预览校验。
- [x] 实现配置版本、事务 outbox、幂等/MFA、序列编号、历史查询与原策略内回滚草稿修订。
- [x] 最终审阅构建与 Task 3 测试结果记入实施记录；95 项测试通过，仍不等于系统执行或完整产品验收。
- [ ] 完成策略继承/组织覆盖/例外、批量作业、完整默认模板和配置保留治理。
- [ ] 完成经验证应用身份与原生权限元数据、ENFORCE 下发/执行/回执；不得以 CONFIGURE_ONLY 代替。
- [ ] 实际 MySQL/OceanBase、EMM、客户端/真机与所有设备模式 APP/PER/SCH/POL 验收。

### Task 4：消息、签名、供应商执行和回执

Files: `backend/.../{delivery,integration}/`、`deploy/`、DeliveryJourneyTest。

Interfaces: PolicyEnvelope、JWS、TransactionalOutbox、EMM adapter、规则级 receipt。

- [x] 实现 Nimbus 配置 JWS、单设备注册绑定、HTTP 拉取、目标移除、序列/分页和过期尝试重发。
- [x] 实现回执幂等/阶段冲突、历史回执隔离、撤销检查；接收/保存不作为系统执行。
- [x] 接入 Spring Modulith 持久通知与重试、Spring Kafka/JMS 适配层、配置化工作队列和低基数指标；默认关闭外部发送。
- [x] 最终 Task 4 当前范围构建与测试证据记入实施记录；116 项测试通过，外部传输/真机与系统执行仍待验证。
- [ ] 接入正式 EMM、ENFORCE、规则级执行/部分写入/补偿、批量发布取消及擦除后果确认。
- [ ] 客户端验证/离线/重启、信任根轮换、设备 MQTT 凭证/ACL/TLS、退避/限批和持续故障治理。
- [ ] Broker/供应商/真机验证后才标受管能力可用。

### Task 5：审批、紧急恢复、正常退出与撤销

Files: `backend/.../{approval,safety,lifecycle}/`、ApprovalJourneyTest、DeprovisionTest。

- [x] 实现云端儿童访问窗口申请、近期 MFA、强 ETag/幂等、决定/取消/撤销、期限和防重复/冷却。
- [x] 实现基础策略/主体/设备/成员生命周期失效、当前身份/主体绑定检查、后台到期与事务审计；当前不执行设备解锁。
- [x] 将最终审批旅程/全量构建证据记入实施记录；16 项审批旅程与全量 132 项验证通过，不作为设备执行证明。
- [x] 实现 BYOD 云端正常退出后果预览/确认、原密钥限时清理认证、签名命令/回执、取消/新任务与有界到期；云端撤销与本地未验证报告分开。
- [x] 云端退出/清理当前范围完成全量 150 项验证与独立可执行产物打包；真实数据库/原生/EMM/擦除仍待验证。
- [ ] 实现限时例外签名下发、设备执行/回执、离线撤销/重启、双人审批、机构委派、通知/工作台和完整 APR 状态。
- [ ] 实现 SAF 恢复及 END 正常退出/清理/擦除后果预览与全审计链。
- [ ] 退出/清理/擦除分别用可验证证据收敛。

### Task 6：共享额度

Files: `backend/.../quota/`、QuotaConcurrencyTest。

Interfaces: QuotaPool、QuotaLease、UsageLedger、reserve/settle。

- [ ] 测试并发余额、重复/乱序结算、不确定消费、跨周期、重启租约。
- [ ] 数据库短事务预留与结算、本地可信计时契约、偏差门槛。
- [ ] 数据库并发与设备停止行为分别验证。

### Task 7：Flutter 管理端与儿童端

Files: `apps/guardian/`、`apps/child/`、`packages/{api_client,design_system,domain}/`。

- [ ] 实现 OIDC PKCE、路由/状态、家庭/设备/规则/审批/报告/设置全部页面。
- [ ] 对接真实 API，支持错误/离线/空态、授权差异与可访问性，不用演示数据冒充接口。
- [ ] Flutter analyze/test/build，检查窄屏/宽屏/读屏/键盘交互。

### Task 8：Kotlin Android 与 TV

Files: `apps/child/android/`、Pigeon 契约、原生适配模块与 TV 页面。

- [ ] 实现注册、能力探测、获准使用量、策略本地存储、离线回执、重启对账、儿童/成人 TV 会话。
- [ ] 逐管理模式测试 Home/输入源/投屏/系统设置/资料隔离，不能伪装 DPC 权限。
- [ ] 支持真机矩阵与可解释失败状态。

### Task 9：网站、安全与机构工作流

Files: 内容安全/组织/名册/集成域，Flutter 对应页面。

- [ ] 实现 WEB/ORG/EXT：分类来源、域名匹配、获准 VPN/浏览器、班级权限、课堂会话与分组批量操作。
- [ ] 旁路与过滤盲区、SSO/SCIM、供应商回调验签和配额验收。

### Task 10：报告、审计、导出、删除和诊断

Files: reporting/retention/support 域，导出后台任务，Flutter 报表/诊断。

- [ ] 聚合使用、不确定性、范围授权、限时下载、数据删除及备份恢复再删除。
- [ ] 日志脱敏、support grant、诊断包与通知失败流程验证。

### Task 11：商业化全链路

Files: billing/entitlement/productcatalog 域、支付适配器、管理台商业页面。

- [ ] 实现 COM-01～06：目录、合同、订阅、权益、验签对账、退款/取消、降级、私有许可与客服。
- [ ] 真实渠道沙箱验证；区域资格与售价由正式配置，欠费不能触发设备擦除/秘密放宽。

### Task 12：智能辅助

Files: insight/consent/modelregistry/assistant 域，客户端前台视觉适配。

- [ ] 聚合趋势建议、结构化草稿和人工发布、前台可选识别与撤回。
- [ ] 正式模型/SDK 配置、隐私/质量/功耗证据，不虚构识别准确率。

### Task 13：运维与全范围验收

Files: compose/Helm/CI/SBOM、测试工作负载、恢复脚本、docs/runbook。

- [ ] 测试契约、模块边界、MySQL/OceanBase、HA、恢复、长连接、广播、重连风暴。
- [ ] 真机、支付、EMM、TV、隐私、性能和私有部署每项证据签收。
- [ ] 完整需求矩阵没有缺失/未验证项，才判定总目标完成。
