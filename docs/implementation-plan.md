# 智能管家完整功能实施计划

> 执行方式：当前会话直接实施，使用 executing-plans 跟踪。用户已授权实现完整功能，并于 2026-10-09 授权阶段性提交和推送到 `git@github.com:zyclove/ai-magic-manager.git` 的 `dev` 分支。外部生产部署另按实际授权和发布门槛执行。

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

每项先写行为测试，确认失败，再实现，执行对应完整测试/构建并记录结果。尚未执行的测试不勾选。当前目录已有 Git，使用 `dev` 分支；并行任务按文件协调，阶段验证通过后按用户授权提交和推送，不覆盖本机凭据或其他任务的未完成变更。

### Task 1：身份、租户、成员和儿童主体

Files: `backend/pom.xml`、`backend/src/main/java/com/aimanager/{identity,tenant,subject,audit,shared}/`、`backend/src/main/resources/db/migration/`、`backend/src/test/java/com/aimanager/TenantJourneyTest.java`。

Interfaces: TenantAccess.requireRole(tenantId, actorId, allowedRoles)、AuditService.record(tenantId, actorId, action, resourceId)、REST /api/v1/tenants/{tenantId}/subjects。

- [x] 写测试：成人建家庭与孩子，陌生身份/儿童/撤销成员越权失败，非法时区与输入拒绝，匿名 401。
- [x] 执行 `mvn -f backend/pom.xml test`，记录缺功能失败。
- [x] 实现 JWT audience/issuer 验证、范围查询、短事务、Flyway、关联审计、错误响应与日志。
- [x] 实现邀请/接受/取消、成员撤销、近期 MFA、持久幂等与身份排序规则隔离。
- [x] 实现主体详情、强版本编辑/归档及 OpenAPI 3.1 生成。
- [x] 当前全套回归与可执行打包通过，证据见实施记录。
- [x] 双方确认所有者交接：近期 MFA、目标成人资格、24 小时截止、唯一待办、双方成员版本、幂等/强版本、原所有者待办失效及管理端操作；合同与验证见 ownership-transfer-plan.md。
- [x] 租户资料维护、当前成员与邀请分页查询；所有者交接后重新读取数据库角色。
- [x] 可识别成员资料、儿童邮箱隐藏、角色/档案范围调整、强版本撤销、权限历史与敏感待办同事务失效；前后端与真实 MySQL 验证见 member-access-plan.md。
- [ ] 扩展机构班级/组范围与教师业务、账号恢复与通知、限流和保留治理。
- [ ] 生产 MySQL 迁移、真实 OIDC/MFA/公钥轮换验收。

### Task 2：设备注册、凭证、能力与健康

Files: `backend/.../fleet/`、`backend/.../deviceidentity/`、迁移 V4～V6、FleetJourneyTest。

Interfaces: 一次性 enrollment、设备注册周期、独立设备认证、capability records、heartbeat。

- [x] 测试过期/重复/并发注册、跨租户主体、凭证轮换/撤销、未知能力与模式差异。
- [x] 实现 BYOD 注册/确认、原密钥响应恢复、独立凭证、心跳/能力事实和撤销。
- [x] 两阶段凭证轮换、取消/到期与反重放；敏感关系和注册域按事务锁保护。
- [x] REST/OpenAPI 与 H2 SQL 自动化验收，受管能力保持不支持，证据见实施记录。
- [x] Dart 设备身份组件：原密钥认领/恢复、持久心跳、凭证轮换/取消与认证暂停；37 项 VM、5 项 Chrome 和真实 Spring/Nimbus/Dart 联调通过，见设备身份客户端契约；原生安全存储仍待验收。
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
- [x] Dart 配置验签、注册绑定、事务存储、来源序列/墓碑和回执队列；文件关闭/重开、Chrome 与真实 Nimbus 互操作通过，见设备接收契约；原生执行仍待完成。
- [x] Dart 设备 HTTPS/opaque 认证、整页事务续点、有界同步、原 ID 回执重放与退避；真实 Spring HTTP/文件存储/撤销联调及自动构建对接，证据见设备接收契约第 7 节；OS 调度和系统执行仍待完成。
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
- [x] 实现 CONFIGURE_ONLY 审批签名窗口/撤回文档、固定截止、注册绑定、幂等回执、当前交付/历史管理界面；V15、本机运行与数据库证据见实施记录。
- [x] 实现临时拒收的有界交付重试、不可变原文档、退避/上限、旧回执隔离和逐次诊断；V16 与真实 MySQL 并发/非空迁移证据见实施记录。
- [x] 独立 `device_access` 组件：完整范围验签、原期限与撤回水位、事务回执、文件重开恢复和后端 Nimbus 记录互操作；只提供 CONFIGURE_ONLY 接收基础，HTTP 进展见下一项，宿主集成继续实施。
- [x] 审批组件的有界 HTTP 同步：设备 opaque 身份、扫描续点/完整复扫、回执投递、临时拒收自动恢复和结果诊断；真实 Spring/Dart 文件恢复、撤回/到期与凭据撤销已联调，宿主/原生执行及发布门槛整合继续实施。
- [ ] 实现正式限时例外执行、规则级回执、离线撤销/重启、双人审批、机构委派、通知/工作台和完整 APR 状态；当前配置文档不代表设备解锁或使用额度追加。
- [ ] 实现 SAF 恢复及 END 正常退出/清理/擦除后果预览与全审计链。
- [ ] 退出/清理/擦除分别用可验证证据收敛。

### Task 6：共享额度

Files: `backend/.../quota/`、QuotaConcurrencyTest。

Interfaces: QuotaPool、QuotaLease、UsageLedger、reserve/settle。

- [x] 交付云端按日池、事务预留/结算、独立签名租约和管理账本；真实 MySQL 并发、未知消费及跨周期证据见实施记录。
- [x] 交付七日重复计划、日期例外、次日修改/暂停/恢复、来源版本、后台有界生成及设备申请前交集生成。
- [ ] 测试并发余额、重复/乱序结算、不确定消费、跨周期、重启租约。
- [ ] 数据库短事务预留与结算、本地可信计时契约、偏差门槛。
- [ ] 数据库并发与设备停止行为分别验证。

### Task 7：Flutter 管理端与儿童端

Files: `apps/guardian/`、`apps/child/`、`packages/{api_client,design_system,domain}/`。

- [x] 已有业务 API 的 Flutter Web 管理端、共享额度账本与重复计划表单；本机 OIDC 登录及真实接口交互，实际证据见管理端交付记录。
- [ ] 实现 OIDC PKCE、路由/状态、家庭/设备/规则/审批/报告/设置全部页面。
- [ ] 对接真实 API，支持错误/离线/空态、授权差异与可访问性，不用演示数据冒充接口。
- [ ] Flutter analyze/test/build，检查窄屏/宽屏/读屏/键盘交互。

### Task 8：Kotlin Android 与 TV

Files: `apps/child/android/`、Pigeon 契约、原生适配模块与 TV 页面。

阶段实现：Android TV 原生模式识别、电视侧边导航与配对输入说明见 [电视界面阶段](android-tv-interface-stage.md)；真机焦点、系统键盘、重启对账和系统执行仍待验证。

- [ ] 实现注册、能力探测、获准使用量、策略本地存储、离线回执、重启对账、儿童/成人 TV 会话。
- [ ] 逐管理模式测试 Home/输入源/投屏/系统设置/资料隔离，不能伪装 DPC 权限。
- [ ] 支持真机矩阵与可解释失败状态。

### Task 9：网站、安全与机构工作流

Files: 内容安全/组织/名册/集成域，Flutter 对应页面。

- [ ] 实现 WEB/ORG/EXT：分类来源、域名匹配、获准 VPN/浏览器、班级权限、课堂会话与分组批量操作。
  - 班级目录/名册、双版本转班、归档、多班级成员授权和范围内教师只读界面已实现，见 [机构工作流阶段](organization-workflow-plan.md)。教师申请、课堂会话、设备组及批量功能继续实施，不能据此勾选整项完成。
- [ ] 旁路与过滤盲区、SSO/SCIM、供应商回调验签和配额验收。

### Task 10：报告、审计、导出、删除和诊断

Files: reporting/retention/support 域，导出后台任务，Flutter 报表/诊断。

- [ ] 聚合使用、不确定性、范围授权、限时下载、数据删除及备份恢复再删除。
- [ ] 日志脱敏、support grant、诊断包与通知失败流程验证。

### Task 11：商业化全链路

Files: billing/entitlement/productcatalog 域、支付适配器、管理台商业页面。

阶段实现：已新增 [商业权益账本](commercial-entitlement-ledger.md) 的来源版本、退款/撤销重算、租户只读接口与 V28 迁移；当前无核验支付渠道、已发布目录或购买入口，不能将这一阶段视为 COM-01～06 完成。

下一阶段的产品定义、报价、审核与发布边界见 [商业产品目录与发布控制](commercial-product-catalog.md)。现已建立报价项输入约束及平台操作/审批角色配置；尚未完成 V30 持久化、审核 API 或正式销售资格验证。

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
