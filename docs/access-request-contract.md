# 临时访问申请与审批：实际后端契约

更新日期：2026-10-09。本文记录当前 `approval` 模块的实际接口，配合[功能规格](parental-control-functional-spec.md)、[完整实施计划](implementation-plan.md)和[实施记录](implementation-progress.md)阅读。

## 1. 已实现与执行边界

已实现儿童范围内申请、分页/详情、近期 MFA 决定、限时窗口、取消/撤销、版本与幂等、冷却、到期作业、基础策略/主体/设备/成员生命周期失效和事务审计。

当前批准结果为 `APPROVED_PENDING_DELIVERY`，`executionState` 固定为 `NOT_ENFORCED`。它保存管理员决定和有限期的授权意图，**没有签发可在设备执行的例外许可证，没有解除应用限制，也没有增加使用额度**。正式例外交付、EMM/原生执行、规则级回执、通知和客户端仍需实现。

当前支持 APP_LAUNCH 的 DENY 规则，以及 TIME_WINDOW 规则的临时访问窗口。未选中的规则、其他策略流和必要恢复底线仍然有效。DAILY_QUOTA、系统权限、安装/卸载或域名规则不能通过该窗口接口放宽；额度追加须通过后续额度账本，不将窗口秒数解释为新增使用秒数。

## 2. 身份和对象范围

管理路径为 `/api/v1/tenants/{tenantId}/access-requests`，使用用户 Bearer JWT；设备 opaque 凭证不能调用。

| 操作 | 允许角色 | 附加约束 |
|---|---|---|
| 创建 | CHILD | 当前成员绑定主体、本人设备、有效主体/注册与最新基础版本 |
| 列表/详情 | OWNER/GUARDIAN/ORG_ADMIN/AUDITOR/CHILD | 儿童只能查看自身主体；不返回审批人身份/联系方式 |
| 批准/拒绝 | OWNER/GUARDIAN/ORG_ADMIN | 近期 MFA、If-Match、幂等键；批准再次复核基础和绑定 |
| 取消 | CHILD | 原提交者的精确身份；只能取消待决申请 |
| 撤销 | OWNER/GUARDIAN/ORG_ADMIN | 近期 MFA；原来确实批准且未到期；不能声称设备已收到撤销 |

当前 TEACHER 不获得审批权限，班级委派和双人审批待独立实施。成人手工发起授权也需要独立流程，不能伪装成 CHILD 创建申请。

## 3. REST 接口

| 方法与相对路径 | 成功 | 输入/输出 |
|---|---|---|
| POST 根路径 | 201 + ETag | Create → AccessRequest |
| GET 根路径 | 200 | limit=1..100、UUID cursor → ItemPage |
| GET /{requestId} | 200 + ETag | AccessRequest |
| POST /{requestId}/decisions | 200 + ETag | Decision → AccessRequest |
| POST /{requestId}/cancel | 200 + ETag | 空正文 → AccessRequest |
| POST /{requestId}/revoke | 200 + ETag | 空正文 → AccessRequest |

所有创建/决定/取消/撤销必须有 `Idempotency-Key`。变更已有申请必须有强 `If-Match`，缺失 428、陈旧 412；不接受通配符/弱版本。未知字段、非规范 UUID、重复规则 ID、非法类型/范围拒绝。

### 3.1 创建示例

```json
{
  "deviceId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "policyId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "baseVersionId": "cccccccc-cccc-cccc-cccc-cccccccccccc",
  "applicationId": "dddddddd-dddd-dddd-dddd-dddddddddddd",
  "ruleIds": ["game"],
  "requestedWindowSeconds": 600,
  "reason": "想和同学一起玩一会"
}
```

示例 ID 仅说明格式，实际使用已发布配置中本设备的引用。理由可选、最多 300 字符；没有默认截图、聊天或视频附件。窗口为 1～3600 秒；规则 ID 最多 20 个，重复或不属于该基础版本的引用拒绝。

设备、注册周期、主体和基础序号由服务端复核并保存，客户端不能传入已批准、管理员、APPLIED、角色或有效期字段。

### 3.2 决定示例

批准：`{"decision":"APPROVE","grantedWindowSeconds":300}`。授予时长必须存在、1～3600 且不超过申请值，不接受拒绝理由字段。

拒绝：`{"decision":"DENY","reasonCode":"NOT_NOW"}`。reasonCode 可选，枚举为 NOT_NOW/NOT_ALLOWED/OTHER；不能带授予时长。

批准时固定 `issuedAt` 和 `absoluteNotAfter = issuedAt + grantedWindowSeconds × 1000`。截止时间从批准开始计算，重复请求、晚送达、断网和重新登录不会延长。

### 3.3 返回字段与 UI

AccessRequest 包含 id、subjectId、deviceId、registrationId、policyId、baseVersionId、applicationId、ruleIds、requestedWindowSeconds、reason、state、requestExpiresAt、grantedWindowSeconds、issuedAt、absoluteNotAfter、reasonCode、executionState、version 和 createdAt。

瞬时时间为 UTC epoch 毫秒，窗口时长为整数秒。审批人身份只在受保护的决定记录和审计中保存，不在该响应返回。DTO 的 toString 不输出儿童理由。

儿童页应显示“家长已批准，设备尚未执行”，并说明截止时间；不得显示“现在可以打开”。管理员页分别显示决定与设备结果。当前不存在 APPLIED/VERIFIED_APPLIED 成功响应或设备例外回执入口。

## 4. 状态和重试语义

| 状态 | 含义 | 允许后续 |
|---|---|---|
| PENDING | 未超过申请期限且范围有效 | 批准、拒绝、原提交者取消 |
| APPROVED_PENDING_DELIVERY | 有固定期限的管理员决定，未执行 | 撤销、到期、基础/范围失效 |
| DENIED | 已拒绝 | 不能对同申请重新批准 |
| CANCELLED | 原提交者撤回待决申请 | 不能对同申请决定 |
| EXPIRED | 申请期限或授权窗口已到 | 新申请，不延长旧窗口 |
| REVOKED | 原批准失效 | 新申请；恢复成员不复活旧决定 |
| INVALIDATED | 尚待决定的申请基础/范围失效 | 在有效的新基础上重新申请 |

决定记录以 `(tenant_id, request_id)` 唯一且不改写；撤销与到期修改申请生命周期并记录新审计。两个有权管理员并发提交旧版本时，一个完成，另一个 412，不产生两个决定。

同幂等键/同请求返回**原响应快照**，异载荷 409，重试仍先检查当前权限。原响应可能早于取消、失效或到期；客户端收到响应后以返回 ID 读取当前资源，不把重放响应当作当前有效授权。该行为与平台已有持久幂等契约一致。

GET/list 会在授权后执行有界的系统生命周期校验：发现到期/当前权限失效则持久化状态、增加版本并写系统审计。动态变化不继续复用旧强 ETag。该校验不是客户端的修改权限。

## 5. 生命周期与事务

- 新策略版本同事务失效该策略较旧序号上的待决申请/批准；重复或迟到旧事件不会失效较新序号。
- 设备注册撤销、儿童主体归档和成员撤权发出可信内部事件，同事务更新相关申请和审计。
- 请求人/审批人撤权、请求人转到其他主体、设备更换注册周期或改绑主体均不能保持旧例外有效。
- 批准复核锁顺序为成员 → 基础策略 → 主体 → 设备 → 申请。主体与设备关系变化时返回 ACCESS_TARGET_CHANGED 或范围错误，不发新决定。
- 撤销远程设备身份不等于本地清理；到期云端授权不等于真机已经恢复规则。设备后续必须独立验证原签名截止时间。
- 决定、申请状态、持久幂等响应与审计同事务；事务内没有 Broker/IdP/EMM 网络调用。

V11 新表为 access_requests、access_request_slots 和 access_request_decisions；包含租户关联、基础版本、精确请求人/审批人身份摘要、时限与索引。Fleet/Subject/Policy 事实通过公开模块接口访问，不直接查询其他领域表。

## 6. 防重复、冷却和到期作业

同一主体/注册周期/应用最多一个有效待决申请，重复不同键返回 ACCESS_REQUEST_PENDING。已有未到期批准返回 ACCESS_EXCEPTION_EXISTS。冷却从创建时计算，即使立即取消或拒绝也不能反复骚扰管理员；紧急帮助属于独立流程，不使用此冷却。

| 配置 | 默认 | 合法范围 |
|---|---|---|
| ACCESS_REQUEST_TTL_SECONDS | 1800 | 60..86400 |
| ACCESS_REQUEST_COOLDOWN_SECONDS | 60 | 1..3600 |
| ACCESS_EXPIRY_JOB_ENABLED | true | true/false |
| ACCESS_EXPIRY_BATCH_SIZE | 100 | 1..1000 |
| ACCESS_EXPIRY_INTERVAL_SECONDS | 30 | 5..3600 |

到期使用 Spring Scheduler；每次按 limit 选择到期行并短事务锁定、转 EXPIRED、写审计。多副本以数据库当前行锁串行，不自研计时框架。后台作业不能代替设备本地精确到期，滞后清理不能延长权限。

后台边界 `ApprovalMaintenance.expireDue` 不暴露用户 HTTP。生产的锁等待、查询计划、作业公平性、保留和长期容量仍须真实数据库验证。当前冷却按资源而非全账户预算；账户级滥用治理仍待实现。

## 7. 错误、日志和隐私

稳定错误包含 SCOPE_DENIED、REAUTH_REQUIRED、VERSION_REQUIRED、RESOURCE_VERSION_CONFLICT、IDEMPOTENCY_KEY_REQUIRED/CONFLICT、BASELINE_CHANGED、ACCESS_TARGET_CHANGED、EXCEPTION_RULE_INVALID、EXCEPTION_KIND_UNSUPPORTED、SAFETY_BASELINE_PROTECTED、GRANT_EXCEEDS_REQUEST、ACCESS_REQUEST_NOT_PENDING、ACCESS_EXCEPTION_NOT_REVOCABLE、ACCESS_REQUEST_PENDING、ACCESS_EXCEPTION_EXISTS 与 ACCESS_REQUEST_COOLDOWN。

系统失效理由包含 BASELINE_CHANGED、SUBJECT_ARCHIVED、DEVICE_REGISTRATION_INACTIVE、APPROVER_SCOPE_LOST、REQUESTER_SCOPE_LOST、TIME_EXPIRED 和 ADMIN_REVOKED。理由不附带管理员联系方式、SQL 或其他儿童资料。

审计包含 ACCESS_REQUEST_CREATED/APPROVED/DENIED/CANCELLED/EXPIRED、ACCESS_EXCEPTION_REVOKED 及基础/生命周期/成员失效事件。服务生成 correlationId，系统联动共享原请求关联；原始儿童理由不写普通日志/审计。理由会存在申请表及幂等原响应中，保留/删除须覆盖两者，不能只删除主表。

## 8. 验证与完整待办

审批旅程验证真实 HTTP、SQL、事务和授权，使用受控 Clock 覆盖精确截止边界，使用两个独立监护人并发调用验证唯一决定。JWT 身份上下文和 BYOD 设备由测试夹具提供，不构成真实 IdP/EMM/设备执行证据。最新测试数量与构建时间见[实施记录](implementation-progress.md)。

完整待办仍包括：签名限时例外/撤销交付、规则级执行与离线证据、可信额度追加、双人审批/机构委派、待审批过滤/客户端工作台与通知、账户级速率、保留/删除，以及 SAF 紧急恢复、END 正常解除/擦除/清理流程。不能将本后端工作流标记为整个 Task 5 或完整产品已完成。
