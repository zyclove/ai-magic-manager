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

设备注册、独立凭证、心跳与能力 API 已实现，详见[设备接入契约](device-registration-contract.md)。儿童/家长 JWT 不能代替设备凭证或系统权限。issuer 发现、公钥轮换、真实 MFA 映射与生产数据源仍需环境验收。

## 2. 已有管理路由

所有路径前缀为 `/api/v1`；集合 limit 默认 50、最大 100，cursor 是规范 UUID，按 ID 游标分页。游标本身没有授权能力。

| 方法与路径 | 输入 / 返回 | 授权和关键语义 |
|---|---|---|
| POST /tenants | name、kind、timeZone → Tenant | scope tenant:create；事务建立 OWNER；可选 Idempotency-Key |
| GET /tenants | limit、cursor → ItemPage<Tenant> | 仅有效成员租户 |
| POST /tenants/{tenantId}/subjects | nickname、ageBand → Subject | OWNER/GUARDIAN/ORG_ADMIN；可选 Idempotency-Key |
| GET /tenants/{tenantId}/subjects | limit、cursor → ItemPage<Subject> | 成人范围或 CHILD 仅绑定主体；不含归档主体 |
| GET /tenants/{tenantId}/subjects/{subjectId} | Subject、ETag | CHILD 仅自身；无匹配或外租户对象均拒绝 |
| PATCH /tenants/{tenantId}/subjects/{subjectId} | nickname、ageBand、If-Match → Subject、ETag | 成人编辑；强版本前提；不自动修改设备规则 |
| POST /tenants/{tenantId}/subjects/{subjectId}/archive | If-Match → 204 | 成人、近期 MFA；仅归档，不解除管理/删除数据 |
| POST /tenants/{tenantId}/invitations | recipientEmail、role、subjectId? → 邀请及一次性 token | OWNER/ORG_ADMIN、近期 MFA；角色/租户类型和主体范围校验 |
| POST /invitations/accept | token → tenantId、role | 已验证收件 email；非 CHILD 需成人资格/近期 MFA；邀请者仍有权 |
| DELETE /tenants/{tenantId}/invitations/{invitationId} | 204 | OWNER/ORG_ADMIN、近期 MFA；tenant 范围；取消幂等 |
| DELETE /tenants/{tenantId}/members/{memberActor} | 204 | OWNER/ORG_ADMIN、近期 MFA；不能移除 OWNER；提升管理员仅 OWNER 可撤 |
| GET /tenants/{tenantId}/audit-events | limit、cursor → ItemPage<Event> | OWNER/GUARDIAN/ORG_ADMIN/AUDITOR；无儿童入口 |

`Tenant.kind` 为 FAMILY/ORGANIZATION；时区是有效 IANA ZoneId。`Subject.ageBand` 为 UNDER_7、AGE_7_12、AGE_13_17，保留年龄段而非完整生日。所有输入拒绝未知字段，避免传 role 等字段被默默接受。

版本头示例：读取 `ETag: "0"` 后更新传 `If-Match: "0"`。成功返回 `"1"`；缺失版本 428，旧版本 412；不支持弱 ETag、通配符或多版本绕过。

邀请 token 默认 24 小时，一次使用；数据库存 token/email 标准 SHA-256 摘要，不存原 token。取消/到期/已使用返回失效，列表和审计不能恢复邀请秘密。邀请服务尚未对接邮件发送；当前管理员需安全传递一次性邀请，生产邀请 UI/通知待实现。

## 3. 写入、错误和日志

创建租户/主体的幂等记录按 scope、精确身份键、operation、key hash 唯一。同键同请求返回原响应，同键异请求 409；有效期 24 小时，过期键不静默重执行。业务变更、审计和响应落库同事务。只有无秘密的资源响应使用通用幂等日志。

`actor_key` 对单个可信 issuer 的精确 sub 做 SHA-256，避免默认数据库忽略大小写的排序规则合并身份。多 issuer 尚未开放，必须先建立 issuer 命名空间和关系迁移。

域错误用 ProblemDetail，提供 errorCode、messageKey、correlationId；验证字段仅回显字段名/校验类型。认证/授权错误由 Spring Security 处理。服务生成关联 UUID，响应有 X-Correlation-Id；日志只记录方法、状态、耗时、异常类与关联 ID，不记录请求正文/凭据。

敏感响应由 Spring Security 默认安全头禁止缓存；生产代理/CDN 不得覆盖 no-store。数据库审计不是不可篡改归档，长期审计保护、保留、归档与支持授权还待实现。

## 4. 验证范围与未完成项

快速回归使用 H2 MySQL 模式和 MockMvc，真实控制器、事务、SQL、权限和审计链。多数旅程用测试 JWT 上下文；令牌校验回归另使用 Nimbus 真实 RSA 签名与同一生产 validator。两者都不能证明真实 IdP 发现/轮换已验收。

未完成的基础管理包含完整所有者交接、租户资料维护、成员/邀请查询与权限调整、机构组/班级范围、归档恢复、通知、速率/额度治理、过期幂等清理与保留治理。后续还需正式设备受管执行、策略继承/规则级回执、真实消息链路、Flutter/Android/TV、网站、审批执行/额度、商业、AI、部署与完整环境验收。

真实 MySQL/OceanBase、Broker、EMM、商店支付、电视与 Android 真机均没有本轮成功证据，不能据此对外声明系统管控完整或百万设备容量已达到。

## 5. 应用、时间与策略接口

新增 catalog/schedule/policy 模块的实际路由与数据契约见[应用、时间与策略契约](policy-application-schedule-contract.md)。覆盖应用身份声明、设备可见清单上报/查询、IANA 计划/计算、草稿/模板复制、能力/冲突预览、配置版本、操作状态与原策略内的回滚草稿修订。

仅 `CONFIGURE_ONLY` 可保存配置版本，结果为 `CONFIGURED_NOT_ENFORCED`；`ENFORCE` 不产生虚假执行成功。代理清单标为 `AGENT_REPORTED_UNVERIFIED`，不认证所有应用或安装签名。接口和完整系统执行的验收分开记录。

## 6. 签名配置与通知接口

实际设备 signing-keys/configurations/configuration-receipts 与管理端 publication deliveries 见[配置交付契约](configuration-delivery-contract.md)。签名配置仅包含本设备内容；没有外置密钥时明确 503。配置回执不改变系统策略生效状态。

Kafka/Artemis 通知适配层通过 Spring Modulith/JDBC 保留失败并重试；默认禁用。当前外部传输测试使用替身，真实 Broker、MQTT、EMM、客户端仍未验收。

## 7. 临时访问审批接口

新增 `/tenants/{tenantId}/access-requests` 创建/列表/详情，以及 `/{requestId}/decisions`、`/cancel`、`/revoke`。实际字段、角色、时限、ETag/幂等和失效流程见[审批契约](access-request-contract.md)。后台到期与策略/设备/主体/成员撤权联动已接入。

批准只保存有界访问窗口和责任记录，状态为 APPROVED_PENDING_DELIVERY、executionState=NOT_ENFORCED。当前没有例外签名/设备执行或额度追加，不能把成人决定标记为应用已解锁。

## 8. 正常退出与清理接口

新增 `/tenants/{tenantId}/devices/{deviceId}/deprovision/previews`、`/operations`、`/operations/{operationId}` 和 `/cancel`；独立 `/device-cleanup/signing-keys`、`/command`、`/receipts` 使用原注册密钥短时证明。实际字段、状态、配置、认证和数据后果见[设备退出契约](device-deprovision-contract.md)。

正常退出事务撤销普通业务凭证并使访问窗口失效，创建有界的本代理数据清理命令。本地回执为 DEVICE_REPORT_UNVERIFIED；取消不恢复普通凭证，也无法召回离线缓存命令。没有原生本地执行或受管解除/整机擦除成功证据，完整 END-01 仍待交付。
