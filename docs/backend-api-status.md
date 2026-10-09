# 后端接口与当前实现状态

> 更新：2026-10-09。本文只列现有代码接口；规划功能见[完整实施计划](implementation-plan.md)。自动化结果见[实施记录](implementation-progress.md)。

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

租户资料维护、成员/邀请查询、所有者交接、成员权限调整、班级名册及已有功能的 Flutter Web 界面已实现，见[管理端交付记录](management-console-delivery.md)。教师有限申请已接入专项、真实 MySQL、表单和浏览器回归，具体版本与证据见[机构工作流](organization-workflow-plan.md)。未完成的基础管理包含独立设备组、课堂会话、归档恢复、通知、速率治理、过期幂等清理与保留治理。后续还需正式设备受管执行、策略继承/规则级回执、真实消息链路、Android/TV、网站、审批执行、商业、AI、部署与完整环境验收。

本机真实 MySQL 已完成管理接口联调与额度专项并发验证；OceanBase、Broker、EMM、商店支付、电视与 Android 真机尚无成功证据，不能据此对外声明系统管控完整或百万设备容量已达到。

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

V21 提供当前授权范围收件箱、未读数量、个人逐条已读及显式当前页批量已读。申请状态与最小通知同事务持久化，每申请版本唯一；儿童和教师仅可见本人申请，已读不会改变审批。接口、保留与故障语义见[站内通知契约](inapp-notifications-contract.md)，完整后端 269 项、MySQL 联动 24 项及非空完整迁移证据见[实施记录](inapp-notifications-plan.md)。本机 V21 已部署并通过真实管理员只读登录验收。
