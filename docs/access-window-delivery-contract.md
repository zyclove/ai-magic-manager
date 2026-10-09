# 签名审批文档与回执

更新：2026-10-09。现有访问审批的管理员决定、设备文档交付、系统执行分别记录。本协议补充[审批契约](access-request-contract.md)，不改变使用额度账本。

## 实际支持

设备可取得批准窗口及撤回文档，提交收到、保存或拒绝报告。当前文档的 `mode=CONFIGURE_ONLY`、`quotaEffect=UNCHANGED`，管理响应 `executionState=NOT_ENFORCED`。本协议尚未授权客户端执行解锁，也不增加使用秒数。正式执行模式、原生时钟/存储/执行适配器、规则级证据及真实设备验收继续保留。

## HTTP

前缀 `/api/v1`。设备路径只接受当前有效的独立 opaque 凭据；用户 JWT 不能替代。管理路径按照现有审批角色、租户和儿童本人范围授权。

| 方法与路径 | 行为 |
|---|---|
| `GET /device-api/access-requests` | `limit=1..100`、UUID `cursor`；只列本设备、当前注册周期和主体曾批准的申请，返回 requestId、approvalVersion、approvalState、absoluteNotAfter |
| `GET /device-api/access-requests/{requestId}/document` | 当前审批版本的不可变签名文档，附当前 deliveryAttempt、deliveryState、reasonCode、retryStatus、retryAfter；未批准返回 409，首次签名缺密钥返回 503 |
| `POST /device-api/access-requests/{requestId}/receipts` | `documentId, deliveryAttempt?, phase, reasonCode?`；记录设备报告，不改变决定或执行状态 |
| `POST /device-api/access-requests/{requestId}/delivery-retries` | `documentId, failedAttempt`；对临时失败创建一次有界后继尝试，返回 documentId、deliveryAttempt、createdAt、current |
| `GET /tenants/{tenantId}/access-requests/{requestId}/delivery` | 当前审批版本对应的文档动作、交付阶段、最后回执时间及证据状态 |
| `GET /tenants/{tenantId}/access-requests/{requestId}/documents` | limit/UUID cursor 分页，返回签发和回执元数据，并标明当前/历史版本；不返回 JWS 或儿童理由 |
| `GET /tenants/{tenantId}/access-requests/{requestId}/documents/{documentId}/attempts` | 最多 10 项，按尝试编号倒序返回 items、nextCursor=null；包含阶段、拒收原因、开始/回执时间和 current |

设备列表采用资源分页，每轮同步从首页开始完整扫描；它不是增量变化游标。发现未知/更高版本后下载当前文档；尚未成功保存或处于恢复流程的文档，即使审批版本未变，也必须重新读取交付元数据。分页期间的新申请可能落在已读游标之前，下轮完整同步会补齐。低延迟推送、增量游标、整体设备同步速率和保留治理仍待交付。

## 签名与约束

使用现有外置 ES256 密钥和 Nimbus，JWS 类型为 `aimanager-access-window+jws`，公钥读取沿用 `/device-api/signing-keys`。JWS 不得跨配置、额度租约或退出命令类型复用。

载荷包含 `schemaVersion=1, issuer, documentId, tenantId, requestId, approvalVersion, approvalState, subjectId, deviceId, registrationId, policyId, baseVersionId, applicationId, ruleIds, action, mode, quotaEffect, grantIssuedAt, absoluteNotAfter, documentIssuedAt`。

- `UPSERT_ACCESS_WINDOW` 仅用于当前仍有效的批准；`REMOVE_ACCESS_WINDOW` 用于撤销或到期。相同审批版本重复下载返回相同 ID、签名和签发时间。
- `grantIssuedAt/absoluteNotAfter` 始终采用原批准时间和截止，晚下载不会延长期限。文档签发时间只是交付事实，不能作为新的授权起点。
- 撤回文档可在原截止时间之后签发；客户端不能因为原窗口已过期而忽略更高版本的移除信息。
- 客户端必须核对类型、算法、密钥用途、issuer、全部设备/主体/注册绑定、基础版本和规则引用，并持久保存每申请最高审批版本。不能删除撤回水位后重新接受旧批准文档。
- 在最终原生执行实现中，离线仍受原截止时间约束；失去可信时间、基础策略或当前身份绑定时不能继续临时例外。紧急帮助保持独立。
- 载荷不含儿童理由、请求人和审批人身份。签名不能被当作已认证的系统执行证据。

## 回执

每次交付尝试的阶段为 `RECEIVED`、`STORED`、`REJECTED`。允许直接报告存储/拒绝，也允许 RECEIVED → STORED/REJECTED；同一次尝试的终态不能互换。相同尝试、阶段及正文重放返回原阶段和接收时间，不重复审计；已记录的早期 RECEIVED 重放也不使当前阶段倒退。

仅 REJECTED 必须携带 reasonCode：SIGNATURE_INVALID、BASELINE_MISSING、EXPIRED、UNSUPPORTED_SCHEMA、STORAGE_FAILED、WRONG_DEVICE、OTHER。其他阶段禁止 reasonCode，不接收自由文本错误堆栈。

回执响应包含 `deliveryAttempt` 和 `current`。只有文档仍对应当前审批版本且尝试编号等于当前尝试时，current 才为 true。撤销后的旧 STORED 回执仍可追溯，但不会确认当前撤回文档。证据始终为 `DEVICE_REPORT_UNVERIFIED`。

省略 deliveryAttempt 的兼容请求固定属于第 1 次，绝不归到最新尝试。新客户端必须持久保存服务端返回的尝试编号，并连同文档 ID 写入待发送队列。恢复后旧队列不会确认新尝试；矛盾终态仍返回 ACCESS_RECEIPT_CONFLICT。

## 临时拒收恢复

授权文档、签名、审批版本、签发时间与原截止时间保持不变。交付尝试属于独立传输元数据，不能用作延长授权或新增使用额度的依据。传输仍要求经过认证的 TLS 连接；客户端独立验证 JWS 和原批准期限。

1. 仅当前文档因 BASELINE_MISSING 或 STORAGE_FAILED 被拒收时可创建新尝试。设备先排除故障，再调用 delivery-retries；没有自动后台替设备重试，也不需要管理员重新批准。
2. 每个失败尝试最多有一个后继，唯一关系与文档行锁保障并发和丢响应重放。相同 failedAttempt 重试返回同一后继的编号/开始时间；若后继也已成为历史，current=false。调用结果不能代替重新读取当前文档和当前阶段。
3. 从拒收回执接收时间起退避 30、60、120、240、300 秒，之后上限保持 300 秒；每份文档最多 10 次（含初次）。过早返回 ACCESS_RETRY_TOO_EARLY，达到上限返回 ACCESS_RETRY_LIMIT。
4. 原批准剩余时间不足以等待退避时，状态 WINDOW_ENDING，不能继续重试。已撤销或到期导致审批版本改变时返回 ACCESS_DOCUMENT_SUPERSEDED，客户端须读取当前撤回文档。撤回文档可在原批准截止之后重试。
5. SIGNATURE_INVALID、WRONG_DEVICE、UNSUPPORTED_SCHEMA、EXPIRED、OTHER 不自动重试，状态 NOT_ALLOWED。须排查密钥、设备绑定、客户端兼容性或期限；不能通过更新传输身份绕过验证。
6. 当前文档和管理摘要返回 retryStatus：NOT_NEEDED、WAITING、AVAILABLE、NOT_ALLOWED、WINDOW_ENDING、EXHAUSTED；WAITING/AVAILABLE 附 retryAfter（UTC epoch 毫秒）。重试不会提升执行状态。

## 一致性与运行

V15 增加文档、回执及设备扫描索引；历史批准可在第一次读取时生成当前文档，不需要伪造迁移前的交付记录。文档、阶段、审计分别在对应短事务中提交。签名/存储失败整体回滚；已经保存的管理员决定保留待交付。

V16 增加 access_window_attempts、access_window_attempt_receipts 和文档 current_attempt。已有文档及回执映射为第 1 次，原签名/时间/拒收原因均保留，V15 回执表作为迁移前历史保留。新回执只写入尝试表；新尝试、文档当前指针和重试审计同事务，任一失败整体回滚。

设备请求锁定主体、设备、凭据、审批和文档，锁后复核绑定；现有生命周期事件及读取校正保持审批状态权威。归档主体仍可获取撤回文档；注册撤销后普通业务凭据失效。无事务内 IdP/Broker/EMM 网络调用。

管理界面展示当前交付、拒收原因、尝试次数、恢复状态和最早重试时间；文档历史可进一步查看每次尝试。`SIGNED` 代表文档可交付且本次尝试尚无回执，重复尝试不会重新签名；`RECEIVED/STORED` 代表设备自报。审批状态的中文标签为“已批准 · 尚未执行”，不会在收到文档后继续误称“等待交付”。

## 独立设备接收组件

`packages/device_access` 使用 JOSE 与 Sembast 实现完整范围验签、事务文档/回执、原期限检查、撤回水位及重开恢复。宿主必须提供可信时间、已验证基础匹配函数和受保护数据库。回执始终关联原 document/approvalVersion/attempt/phase；同次拒收不转为保存，新尝试不延长期限。服务端已保存而本地基础丢失时，仅返回本地诊断，不能制造矛盾拒收。

撤回即使在原截止之后或时钟异常时到达，仍可持久保存水位；本地回执队列满时事务整体失败，宿主必须停止使用相关缓存并处理积压。每次恢复重新检查当前公钥、基础和原期限，不以已保存回执证明设备执行。完整接入约束见[组件说明](../packages/device_access/README.md)。

审批组件已有 `http` 支持的有界同步器：当前设备凭据逐次读取、严格分页/响应/ACK、单实例并发合并、完整扫描代次与事务续点、回执重放和临时拒收准备检查。历史回执冲突及单条非法文档以局部诊断保留，后续撤回仍能读取；宿主必须停用诊断关联的缓存配置。扫描结束、待发回执清空和原生执行是独立状态；原始期限不随重试变化。

真实数据库和浏览器证据读取[实施记录](implementation-progress.md)。真实管理员 OTP 敏感提交、审批宿主/操作系统后台任务集成、设备执行、真机离线/重启、通知、容量与高可用仍需继续完成。
