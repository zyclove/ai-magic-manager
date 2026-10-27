# 后端接口与当前实现状态

> 更新：2026-10-26。本轮补充当前共享源码的定向离线验证，不是全量或发布验收。本文各阶段测试数和部署描述仅对应其原输入，不能跨阶段累加。规划功能见[完整实施计划](implementation-plan.md)，阶段证据见[实施记录](implementation-progress.md)。

## 2026-10-26 共享源码定向检查点

使用现有 Java 17 / Maven 和缓存，当前后端及全部测试 Java 源码在独立输出目录编译通过；执行前后固定 675 份源码、资源及 POM 输入。审批 16 项、通知 13 项、时间计算 7 项、预设旅程 1 项通过；修正测试扫描路径后模块边界 1 项通过，合计 **38 个不同用例**，0 跳过。首轮架构误纳测试夹具的失败保留，之后只复验该门禁，没有重跑 37 项业务用例。

这是共享工作树的 H2 / MockMvc / 模拟 JWT 证据，输入包含并行未提交内容，具体绑定见[本批记录](reviews/backend-core-20261026.md)及原始结果的 `sourcePins`；本阶段提交只交付构建输出配置、门禁适配及记录，不代替其他会话的源码交付。真实 MySQL、身份提供方、受管设备、完整后台回归及运行发布仍需各自证据；下方检查点中的其他未验证项没有因此完成。

## 2026-10-20 源码检查点：恢复期限、清理与客户端接合

状态为 **STATIC_IMPLEMENTED_PENDING_VERIFICATION / NOT_RUN / NOT_DEPLOYED**。此检查点补充后续实现来源；下方基于 `6dbfab9` 的扫描和历史运行数字保持原记录，不作为当前候选已通过的证明。

- 后端本地提交 `7a5a8d06cdfc21db53bebfbbde467efce227243d` 已接合 23 个原结果查询调用、21 个领域恢复方法与 21 个 HTTP 适配。结果自成功业务事务内记录的提交时间起固定保留 90 天，与原键 24 小时重放期分开；到期事实随最外层事务提交后转换为 410 / `IDEMPOTENCY_RESULT_EXPIRED`，`IDEMPOTENCY_RESPONSE_ERASED` 继续优先。缺失或到期均不能证明业务未提交，也不授权自动换键或重复执行。
- `IdempotencyRetentionService` 和 `IdempotencyRetentionJob` 已有有界清理源码，默认关闭并复用 WorkPermit。逻辑到期与物理清理分开，保留防重父键、请求摘要及必要归属；不将未分类响应伪装成非主体数据。不能继续把后续源码状态描述为“未找到清理作业”，也不能把源码存在解释为实际清理已完成。
- 本地提交 `61b33a125847527d9f683e993b6da174a72a40b2` 补齐默认、Compose 和 Kubernetes 示例的 MySQL UTC 会话参数；主库时间、节点偏差及持久最后观察时间的约束保留。真实 MySQL、连接池/主库切换和 OceanBase 兼容认证仍未运行。
- Guardian、Child/device_access 和 OpenAPI 的本地提交为 `ff354c06310ef021dd5cf0a137141b6b94cd2067`。Parent 最终 R4 已静态冻结 38 份生产源码，18 份既有测试文件及 1 份辅助存储已接合新协议；可直接查看当前记录，独立确认结束本机核对，原子保留最小防重状态，并检查安全验证与窗口归属。静态收口不等于完整交互、Android 存储/密钥或端到端链路已验收。

具体来源见[后端实施说明](idempotency-result-retention-backend-implementation.md)、[UTC 配置说明](mysql-utc-session-configuration.md)与[Parent 操作核对检查点](parent-operation-recovery-checkpoint-20261020.md)。Parent 最终源清单 `production-r4-manifest.json` 的 SHA-256 为 `28eec7caad617967409130eff27790af4229d5ab0a0b55bde218c4b0205c2550`；Main 源码快照与排除其他工作树改动后的精确提交目标分别记录。

本轮没有 SDK、格式化/分析、测试、浏览器、SQL、服务更新、推送或部署。后续按人类安排，在当前完整输入固定、资源及验证窗口恢复后运行验证；不能复用旧 R4 输入或旧资源样本。所有受支持客户端和后端协议验证完成前不部署新的读取截止逻辑，完整产品的其他能力与正式环境验收要求继续有效。

## 1. 运行与认证

Java 17+、Maven 3.9+，使用 Spring Boot 3.5.16、Spring Modulith 1.4.0、Spring Security、Spring JDBC/Flyway；生产数据源默认 MySQL。外部连接通过环境变量配置，不能把真实密码写入本文或源码。

| 配置 | 含义 | 当前默认 / 要求 |
|---|---|---|
| DATABASE_URL | JDBC 数据源 | 本机 MySQL ai_manager；生产显式配置 |
| DATABASE_USERNAME / PASSWORD | 独立业务账号 | 开发用户名 ai_manager；密码无内置值 |
| OIDC_ISSUER_URI | 唯一可信 issuer | 开发 localhost realm；生产必须更换 |
| OIDC_AUDIENCE | 管理接口受众 | ai-manager-api |
| CORS_ALLOWED_ORIGINS | 管理 Web 来源列表 | 开发 localhost:3000；生产显式白名单 |
| API_DOCS_ENABLED | OpenAPI/Swagger 开关 | false；启用后仍需 Bearer 认证 |
| PORT | HTTP 端口 | 8080 |

用户接口需要 Bearer JWT，验签后检查 issuer、audience、非空受限 subject 与必需过期时间；缺失 audience/expiry 不作为有效管理令牌。`tenant:create` scope 表示身份服务批准的创建资格，不能由客户端自选；租户角色取自数据库成员事实。近期敏感认证默认 300 秒，使用签名 auth_time 与 amr，支持 mfa 标记或 pwd+otp 组合，单独 OTP 不算多因素。

设备注册、独立凭证、心跳与能力 API 已实现，详见[设备接入契约](device-registration-contract.md)。儿童/家长 JWT 不能代替设备凭证或系统权限。本机 Keycloak 发现、真实密码登录与 MySQL 数据源已联通；OTP 敏感写入、公钥轮换和生产环境仍需独立验收。

## 2. 已有管理路由

所有路径前缀为 `/api/v1`；集合 limit 默认 50、最大 100。一般按 UUID 游标分页；成员列表使用精确账号的 64 位哈希游标，权限历史使用记录 UUID 并按成员版本倒序。游标本身没有授权能力。

| 方法与路径 | 输入 / 返回 | 授权和关键语义 |
|---|---|---|
| POST /tenants | name、kind、timeZone → Tenant | scope tenant:create；事务建立 OWNER；可选 Idempotency-Key |
| GET /tenants | limit、cursor → ItemPage<Tenant> | 仅有效成员租户 |
| POST /tenants/{tenantId}/subjects | nickname、ageBand → Subject | OWNER/GUARDIAN/ORG_ADMIN；可选 Idempotency-Key |
| GET /tenants/{tenantId}/subjects | limit、cursor → ItemPage<Subject> | 管理角色、范围内 TEACHER 或 CHILD 绑定主体；不含归档主体 |
| GET /tenants/{tenantId}/subjects/{subjectId} | Subject、ETag | TEACHER 受当前班级/单档案范围限制，CHILD 仅自身；外租户对象拒绝 |
| PATCH /tenants/{tenantId}/subjects/{subjectId} | nickname、ageBand、If-Match → Subject、ETag | 成人编辑；强版本前提；不自动修改设备规则 |
| POST /tenants/{tenantId}/subjects/{subjectId}/archive | If-Match → 204 | 成人、近期 MFA；仅归档，不解除管理/删除数据 |
| GET /tenants/{tenantId}/subjects/management | limit、cursor、includeArchived → 档案快照分页 | OWNER/GUARDIAN/ORG_ADMIN；可含归档状态；禁止缓存 |
| GET /tenants/{tenantId}/subjects/{subjectId}/management | 当前档案快照 | 成人管理角色；包含 state/version；禁止缓存 |
| POST /tenants/{tenantId}/subjects/changes | CREATE/UPDATE/ARCHIVE 原正文、UUID Idempotency-Key → 快照 | 创建不传编号/版本；编辑/归档在正文传原版本；家庭日常创建/编辑按成人成员授权，其余沿近期 MFA 要求 |
| POST /tenants/{tenantId}/subjects/operation-results/{requestId}/query | 原变更正文 → operation、committed、current | 成人管理角色；查询原结果不重放；原回执与当前状态分开；禁止缓存 |
| POST /tenants/{tenantId}/invitations | recipientEmail、role、subjectId?、classIds? → 邀请及一次性 token | OWNER/ORG_ADMIN、近期 MFA；教师班级/单档案互斥；接受时重新校验范围 |
| POST /invitations/accept | token → tenantId、role | 已验证收件 email；非 CHILD 需成人资格/近期 MFA；邀请者仍有权 |
| DELETE /tenants/{tenantId}/invitations/{invitationId} | 204 | OWNER/ORG_ADMIN、近期 MFA；tenant 范围；取消幂等 |
| DELETE /tenants/{tenantId}/members/{memberActor} | 204 | OWNER/ORG_ADMIN、近期 MFA；不能移除 OWNER；提升管理员仅 OWNER 可撤 |
| GET /tenants/{tenantId}/members | 分页成员、签名资料、角色/档案与权限版本 | OWNER/ORG_ADMIN；儿童邮箱不输出，旧资料缺失时以稳定账号标识显示 |
| GET /tenants/{tenantId}/members/{memberKey}/access | actorId/memberKey/role/subjectId/classIds/version、ETag | 当前管理权限；显示资料与权限版本分开 |
| PATCH /tenants/{tenantId}/members/{memberKey}/access | role、subjectId?、classIds?、If-Match → 访问描述 | 近期 MFA；可选 Idempotency-Key；保护 OWNER、管理员授予与儿童/成人身份边界 |
| DELETE /tenants/{tenantId}/members/{memberKey}/access | If-Match → 204 | 新界面使用此路由；近期 MFA/版本/幂等，旧撤销重放不移除重新加入的成员 |
| GET /tenants/{tenantId}/members/{memberKey}/access-history | 角色和范围前后差异、版本、操作人/时间 | 当前管理权限；版本倒序，跨成员/租户游标拒绝 |
| POST /tenants/{tenantId}/ownership-transfers | targetActorId、租户 If-Match → 交接、ETag | 现任 OWNER/近期 MFA；目标为已加入的无主体范围成人角色；24 小时；可选 Idempotency-Key |
| GET /tenants/{tenantId}/ownership-transfers | limit、cursor → ItemPage<Transfer> | OWNER 查看全历史；其他无范围成人仅看自己参与的申请；持久化过期/失效状态 |
| GET /tenants/{tenantId}/ownership-transfers/{id} | Transfer、ETag | 与列表相同的对象权限；新终态递增版本 |
| POST /tenants/{tenantId}/ownership-transfers/{id}/accept | 交接 If-Match → Transfer、ETag | 接收人本人、成人资格/近期 MFA；原子替换唯一所有者并失效敏感待办；可选 Idempotency-Key |
| POST /tenants/{tenantId}/ownership-transfers/{id}/decline | 交接 If-Match → Transfer、ETag | 接收人本人/近期 MFA；拒绝且保留原所有者 |
| POST /tenants/{tenantId}/ownership-transfers/{id}/cancel | 交接 If-Match → Transfer、ETag | 发起人仍是 OWNER/近期 MFA；撤销且保留原所有者 |
| GET /tenants/{tenantId}/audit-events | limit、cursor → ItemPage<Event> | OWNER/GUARDIAN/ORG_ADMIN/AUDITOR；无儿童入口 |

`Tenant.kind` 为 FAMILY/ORGANIZATION；时区是有效 IANA ZoneId。`Subject.ageBand` 为 UNDER_7、AGE_7_12、AGE_13_17，保留年龄段而非完整生日。所有输入拒绝未知字段，避免传 role 等字段被默默接受。

版本头示例：读取 `ETag: "0"` 后更新传 `If-Match: "0"`。成功返回 `"1"`；缺失版本 428，旧版本 412；不支持弱 ETag、通配符或多版本绕过。

所有者交接的接受响应可能为 200 + `EXPIRED`/`INVALIDATED`，表示本次检查持久化了失效结果，不能当成接受成功。只有 `ACCEPTED` 表示交接完成。Tenant.version 跟踪租户资料，交接递增双方成员和交接版本；客户端完成后重新查询 membership。详见[交接合同](ownership-transfer-plan.md)。

邀请 token 默认 24 小时，一次使用；数据库存 token/email 标准 SHA-256 摘要，不存原 token。取消/到期/已使用返回失效，列表和审计不能恢复邀请秘密。邀请服务尚未对接邮件发送；当前管理员在界面复制并安全传递一次性邀请。创建结果未知时先核对记录、取消未取得令牌的邀请，再重新创建，避免直接重试产生重复邀请。

V18 成员资料、权限调整和历史见[成员权限合同](member-access-plan.md)。角色或范围变化使该成员旧邀请、待确认配对、临时授权和相关预览同事务失效；MySQL 默认大小写不敏感排序下也按精确账号匹配。V19 增加教师多班级授权、班级名册及学生/设备状态范围过滤；后续代码接通教师本人有限申请及范围失效联动，验证边界见[机构工作流](organization-workflow-plan.md)。课堂会话仍待交付。

### 机构班级路由（V19）

以下路径均在 `/tenants/{tenantId}` 下，仅适用于 ORGANIZATION。所有班级写入要求 OWNER/ORG_ADMIN、近期 MFA，支持 Idempotency-Key；教师只能读取获授且未归档的班级。

| 方法与路径 | 输入 / 返回 | 版本与范围 |
|---|---|---|
| GET /classes | limit、cursor、includeArchived → 班级页 | 教师不能请求已归档班级 |
| POST /classes | name → Classroom、ETag（201） | 名称最长 100 字符 |
| GET /classes/{id} | Classroom、ETag | 当前名册关联数与班级版本 |
| PATCH /classes/{id} | name、If-Match → Classroom、ETag | 同名为无变更 |
| POST /classes/{id}/archive | If-Match → Classroom、ETag | 停止教师通过本班访问，保留历史关联 |
| GET /classes/{id}/students | limit、cursor → 名册页 | 教师仅看到未归档学生 |
| POST /classes/{id}/students | subjectId、If-Match → Classroom、ETag | 同机构未归档档案；上限 500 |
| DELETE /classes/{id}/students/{subjectId} | If-Match → Classroom、ETag | 仅移除班级关联 |
| POST /classes/{id}/students/{subjectId}/transfer | targetClassId、targetVersion、源 If-Match → source/target | 同时检查两班版本，失败整体回滚 |

邀请/成员的 classIds 最多 50 项，必须唯一且属于同一机构；仅 TEACHER 可用，不能同时传 subjectId。授权按成员版本绑定，成员重新加入不会复活旧范围。详见 [机构工作流](organization-workflow-plan.md)。

## 3. 写入、错误和日志

创建租户/主体的幂等记录按 scope、精确身份键、operation、key hash 唯一。同键同请求返回原响应，同键异请求 409；有效期 24 小时，过期键不静默重执行。业务变更、审计和响应落库同事务。只有无秘密的资源响应使用通用幂等日志。

`actor_key` 对单个可信 issuer 的精确 sub 做 SHA-256，避免默认数据库忽略大小写的排序规则合并身份。多 issuer 尚未开放，必须先建立 issuer 命名空间和关系迁移。

域错误用 ProblemDetail，提供 errorCode、messageKey、correlationId；验证字段仅回显字段名/校验类型。认证/授权错误由 Spring Security 处理。服务生成关联 UUID，响应有 X-Correlation-Id；日志只记录方法、状态、耗时、异常类与关联 ID，不记录请求正文/凭据。

敏感响应由 Spring Security 默认安全头禁止缓存；生产代理/CDN 不得覆盖 no-store。数据库审计不是不可篡改归档，长期审计保护、保留、归档与支持授权还待实现。

## 4. 验证范围与未完成项

快速回归使用 H2 MySQL 模式和 MockMvc，真实控制器、事务、SQL、权限和审计链。多数旅程用测试 JWT 上下文；令牌校验回归另使用 Nimbus 真实 RSA 签名与同一生产 validator。两者都不能证明真实 IdP 发现/轮换已验收。

租户资料维护、成员/邀请查询、所有者交接、成员权限调整、班级名册及已有功能的 Flutter Web 界面已有阶段记录，见[管理端交付记录](management-console-delivery.md)。教师有限申请的专项、真实 MySQL、表单和浏览器回归属于对应历史候选，具体版本与证据见[机构工作流](organization-workflow-plan.md)。

### 2026-10-20 源码状态同步

本轮以本地 `HEAD=6dbfab90044facc2a01cb088380354db94eac84f` 及其未提交工作树为只读检查对象；这不是新的冻结发布候选。下表的“已有”只表示读到实现入口与相应服务逻辑，本轮编译、接口调用、端到端测试和生产验证均为 **NOT_RUN**。

| 范围 | 当前源码已有 | 本轮状态与后续边界 |
| --- | --- | --- |
| 机构设备组目录 | `/api/v1/tenants/{tenantId}/device-groups` 的列表、创建、详情、改名、归档、成员查询/增删/批次、摘要及原操作结果查询；服务限制机构类型与 OWNER/ORG_ADMIN，写入检查近期认证和相应版本/幂等前提 | **NOT_RUN**；不再笼统列为未实现。分组目录不是批量策略执行；归档不等于恢复、注销或解除设备管理，完整界面联调、权限/并发/恢复流程及生产环境仍待验收 |
| 站内审批通知 | 收件箱、未读数量、单条/批量已读；服务按当前成员与主体范围查询，儿童和教师额外限定本人申请 | **NOT_RUN**；不再笼统列为未实现。已读不改变审批，站内通知源码和历史 V21 证据不能代替当前端到端结果，也不能证明外部推送或设备消息已送达 |
| 站内通知保留 | `NotificationRetentionJob` 调用有界 `purgeExpired`，具备开关、周期及批量大小配置，删除前再次约束到期条件 | **NOT_RUN**；这是源码中的作业及默认配置，不证明当前部署已启用、清理成功或全平台保留治理完成 |
| 通用过期幂等记录清理 | `IdempotencyService` 已检查 `expires_at`，重复使用过期键返回 `IDEMPOTENCY_KEY_EXPIRED` | **未完成**；本轮在后端生产源码/资源的静态检索未找到通用过期幂等清理作业。拒绝过期重放不等于记录已清理，不据此勾选完成 |

源码入口：[设备组控制器](../backend/src/main/java/com/aimanager/fleet/internal/DeviceGroupController.java)、[设备组服务](../backend/src/main/java/com/aimanager/fleet/internal/DeviceGroupService.java)、[通知控制器](../backend/src/main/java/com/aimanager/notification/internal/NotificationController.java)、[通知服务](../backend/src/main/java/com/aimanager/notification/internal/NotificationService.java)、[通知保留作业](../backend/src/main/java/com/aimanager/notification/internal/NotificationRetentionJob.java)、[通用幂等服务](../backend/src/main/java/com/aimanager/idempotency/IdempotencyService.java)。接口边界继续按[设备组契约](device-groups-contract.md)和[站内通知契约](inapp-notifications-contract.md)实施。

课堂会话、归档恢复、速率治理、通用过期幂等清理及全域保留治理仍保留待完成状态。设备组和站内通知已有的源码仍需对应端到端及生产验证；正式设备受管执行、策略继承/规则级回执、真实消息链路、Android/TV、网站、审批执行、商业、AI、部署与完整环境验收继续按各自完整规格推进。

历史候选记录包含本机真实 MySQL 管理接口联调与额度专项并发验证；本轮未重新执行。OceanBase、Broker、EMM、商店支付、电视与 Android 真机的验收仍须各自的有效证据，不能由本文的源码同步对外声明系统管控完整或百万设备容量已达到。

## 5. 应用、时间与策略接口

新增 catalog/schedule/policy 模块的实际路由与数据契约见[应用、时间与策略契约](policy-application-schedule-contract.md)。覆盖应用身份声明、设备可见清单上报/查询、IANA 计划/计算、草稿/模板复制、能力/冲突预览、配置版本、操作状态与原策略内的回滚草稿修订。

仅 `CONFIGURE_ONLY` 可保存配置版本，结果为 `CONFIGURED_NOT_ENFORCED`；`ENFORCE` 不产生虚假执行成功。代理清单标为 `AGENT_REPORTED_UNVERIFIED`，不认证所有应用或安装签名。接口和完整系统执行的验收分开记录。

## 6. 签名配置与通知接口

实际设备 signing-keys/configurations/configuration-receipts 与管理端 publication deliveries 见[配置交付契约](configuration-delivery-contract.md)。签名配置仅包含本设备内容；没有外置密钥时明确 503。配置回执不改变系统策略生效状态。

Kafka/Artemis 通知适配层通过 Spring Modulith/JDBC 保留失败并重试；默认禁用。当前外部传输测试使用替身，真实 Broker、MQTT、EMM、客户端仍未验收。

## 7. 临时访问审批接口

新增 `/tenants/{tenantId}/access-requests` 创建/列表/详情、`/options?deviceId=...` 有界申请选项，以及 `/{requestId}/decisions`、`/cancel`、`/revoke`。儿童和教师仅访问当前范围内本人申请；管理审批仍需近期 MFA。实际字段、角色、时限、ETag/幂等和失效流程见[审批契约](access-request-contract.md)。后台到期与策略/设备/主体/成员及班级撤权联动已接入。

批准保存有界访问窗口和责任记录，状态为 APPROVED_PENDING_DELIVERY、executionState=NOT_ENFORCED。V15 已接入 CONFIGURE_ONLY 的签名窗口/撤回文档，固定原批准截止时间、单注册绑定、幂等下载、接收/保存/拒绝回执及历史隔离。设备执行和额度追加仍未实现，不能把成人决定或设备保存报告标记为应用已解锁。

| 方法与路径 | 输入 / 返回 | 认证与语义 |
|---|---|---|
| GET /device-api/access-requests | limit、cursor → ItemPage<Reference> | 当前设备 opaque 凭据；每轮从首页完整扫描，UUID 不是变更游标 |
| GET /device-api/access-requests/{requestId}/document | Document，含 signedDocument | 当前注册/主体/申请绑定；同审批版本重复下载相同 JWS |
| POST /device-api/access-requests/{requestId}/receipts | documentId、deliveryAttempt?、phase、reasonCode? → Receipt | RECEIVED/STORED/REJECTED；旧版本/尝试回执不确认当前尝试；省略编号固定属于第 1 次 |
| POST /device-api/access-requests/{requestId}/delivery-retries | documentId、failedAttempt → RetryResult | 设备独立凭据；同一失败仅一个后继、退避与最多 10 次、原期限不变 |
| GET /tenants/{tenantId}/access-requests/{requestId}/delivery | Summary | 沿用审批读取授权；区分未获取、已签名、设备自报阶段 |
| GET /tenants/{tenantId}/access-requests/{requestId}/documents | limit、cursor → ItemPage<History> | 范围内历史元数据，不向用户接口返回设备签名文档 |
| GET /tenants/{tenantId}/access-requests/{requestId}/documents/{documentId}/attempts | ItemPage<Attempt>，最多 10 项 | 按尝试编号倒序，含拒收原因与当前/历史标记 |

载荷、错误、锁顺序与当前限制见[审批签名文档交付契约](access-window-delivery-contract.md)。真实 MySQL 的专项证据与本机 V16 迁移已记录；`device_access` 已提供验签/事务恢复与有界 HTTP 同步，真实 Spring/Dart 跨进程回执、自动重试、撤回/到期及凭据撤销通过独立联调。宿主后台任务、真机离线执行和真实管理员 OTP 成功提交另行验收。

V16 将临时拒收恢复与不可变授权文档分开。只允许基础配置缺失或临时存储失败的新尝试，保留每次回执；撤销、到期与重试次数上限仍有效。当前摘要和设备文档返回尝试编号、拒收原因、恢复状态和最早重试时间。锁后关联读取使用当前读，避免 MySQL REPEATABLE READ 的旧快照导致并发误拒绝。

## 8. 正常退出与清理接口

新增 `/tenants/{tenantId}/devices/{deviceId}/deprovision/previews`、`/operations`、`/operations/{operationId}` 和 `/cancel`；独立 `/device-cleanup/signing-keys`、`/command`、`/receipts` 使用原注册密钥短时证明。实际字段、状态、配置、认证和数据后果见[设备退出契约](device-deprovision-contract.md)。

正常退出事务撤销普通业务凭证并使访问窗口失效，创建有界的本代理数据清理命令。本地回执为 DEVICE_REPORT_UNVERIFIED；取消不恢复普通凭证，也无法召回离线缓存命令。没有原生本地执行或受管解除/整机擦除成功证据，完整 END-01 仍待交付。

## 9. 共享额度接口

新增管理端 quota-pools 创建、查询、增减和账本，以及设备 quota-leases 发放、查询、累计结算协议。金额单位为整数秒，独立租约签名，跨设备事务预留，未知消费不自动返还，旧周期补报不增加新周期余额。实际字段、锁顺序、权限和边界见[共享额度契约](shared-quota-contract.md)。

管理修改需要近期 MFA。生产执行适配器尚未通过验证，当前硬额度发放明确返回 `QUOTA_EXECUTION_UNVERIFIED`；管理页面展示的是账本，不宣称设备已限制。

新增 quota-plans 创建、读取、次日修改/暂停/恢复、不可变版本历史和 calendar 预览。七日额度与日期例外由后台有界作业生成每日池，设备申请前也会在事务内补齐所有适用池；来源计划版本可追溯。手工池和已生成的余额不被计划修改覆盖。读写权限、MFA、强 ETag、幂等和准确路径见共享额度契约。

## 10. 设备观察授权与使用摘要

V20 新增注册周期绑定的观察授权、系统聚合使用摘要批次和回执头。以下路径均以 `/api/v1` 开始：

| 方法与路径 | 认证与语义 |
|---|---|
| GET /tenants/{tenantId}/devices/{deviceId}/observation-settings | 沿用 DeviceAccess.requireVisible；默认版本 0、两个授权关闭 |
| PUT /tenants/{tenantId}/devices/{deviceId}/observation-settings | 成人设备管理角色、近期 MFA、ACTIVE 设备、强 If-Match、幂等键、开关及原因 |
| GET /tenants/{tenantId}/devices/{deviceId}/usage-observations | 当前范围及注册绑定；limit/cursor 有界倒序分页 |
| GET /device-api/observation-settings | 当前注册的设备独立 opaque 凭据 |
| POST /device-api/usage-observations | 当前授权版本、报告标识、递增序号、系统聚合与有界载荷；重放严格一致 |

既有应用清单上报现在要求 `authorizationVersion`；旧客户端需升级协议，默认不采集。授权变化清空当前清单，关闭摘要或设备失效会清理关联服务端数据。设备自报不证明真实安装身份、系统阻止或精确额度消费。成人管理页面仅向 OWNER/GUARDIAN/ORG_ADMIN 开放；服务端 CHILD 的已有设备可见范围没有因此扩大。

协议见[设备观察契约](device-observation-contract.md)，集成快照、完整 V1–V20、真实 MySQL 与本机部署证据见[观察管理端集成记录](observation-console-integration.md)。

## 11. 站内审批通知

以下 V21 测试数字和本机部署描述保留为历史阶段记录，不能证明 2026-10-20 当前工作树或运行服务已通过；本轮状态见第 4 节。

V21 提供当前授权范围收件箱、未读数量、个人逐条已读及显式当前页批量已读。申请状态与最小通知同事务持久化，每申请版本唯一；儿童和教师仅可见本人申请，已读不会改变审批。接口、保留与故障语义见[站内通知契约](inapp-notifications-contract.md)，完整后端 269 项、MySQL 联动 24 项及非空完整迁移证据见[实施记录](inapp-notifications-plan.md)。本机 V21 已部署并通过真实管理员只读登录验收。

## 2026-10-17 家庭账号验收与收费门禁

2026-10-17 新增家庭账号验收准备聚合 `GET /api/v1/platform/identity-providers/acceptance-status`、最近五条登记 `GET /acceptance-runs`，新登记支持已确认发布操作和运行修订绑定、24 小时有效期及原编号恢复。独立平台权限、近期 MFA 和禁止缓存继续生效。生产微信支付增加独立服务端门禁，缺少真实验收时不能发起付款；查单、关单、退款、通知和日对账保留。真实验收仍为 0/12，详见 [验收入口与收费门禁](family-identity-acceptance-gate.md)。

## 2026-10-16 家庭支付运营增量

新增 `/api/v1/platform/family-subscription/refund-requests` 队列、详情、预览、带审核说明的 reviews 与原退款 verifications；独立售后 scope、近期 MFA、申请人不能自审。新增 `/api/v1/platform/family-subscription/reconciliation/tasks` 及任务详情、retries、differences、acknowledgements、verifications；独立财务 scope、近期 MFA、幂等短事务与永久审计。所有 verification 仅返回 `{queued:true,resourceId}`，不发起外层事务中的外部调用，不代表钱或账单已经处理完成。详见 [本轮交付说明](family-p0-commerce-operations.md)。
