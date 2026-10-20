# Guardian 操作结果到期与本机恢复交互设计

日期：2026-10-20。状态：**用户已确认操作结果自服务端成功业务结果提交时起保留 90 天；本文为尚未实施的设计**。Guardian/shared 的 R4 候选保持冻结。本文没有修改产品源码、接口、数据库或测试，没有执行 SDK、测试、构建或服务操作。

## 1. 已确认选择与含义

- 操作结果保留期限为 **90 天，自服务端成功业务结果提交时起计算**，由服务端判定是否到期。前端不能用本机时间或 `PublicationIntent.createdAt + 90 天` 自行认定结果已到期。
- 服务端以 HTTP `410` 和精确错误码区分 `IDEMPOTENCY_RESULT_EXPIRED`、`IDEMPOTENCY_RESPONSE_ERASED`。两者都不能当成“从未执行”“发布失败”或“可以重发”。
- 用户确认后结束的是**本机恢复待办**：清除敏感恢复详情，保留最小终态防重标记。不取消已发生的发布，不删除当前策略或审计，不恢复已清除的响应内容。
- 重新发布必须从用户再次明确打开的当前策略流程开始，读取当前状态、生成新预览并重新确认。结束本机待办不自动开始该流程。

## 2. 当前真实恢复链

六个恢复实现文件如下，严格 DTO 位于另一个模型文件：

| 文件 | 现有函数或状态 | 当前行为 |
| --- | --- | --- |
| `apps/guardian/lib/core/policy_publication_repository.dart` | `PolicyPublicationRepository._read()`、`publish()`、`lookup()` | POST 使用原版本和幂等编号；GET 查询原结果。仅精确的 `404 POLICY_PUBLICATION_RESULT_UNAVAILABLE` 返回不确定的 `null`，没有 410 终态分类 |
| `apps/guardian/lib/core/publication_journal.dart` | `read()`、`reserve()`、`claimRetry()`、`markReauthenticationRequired()`、`removeIfSame()`、`cancelNotSubmitted()` | UNKNOWN 不能取消或重发；只有可信 POST 安全验证拒绝可以进入原提交重试 |
| `apps/guardian/lib/core/browser_publication_journal.dart` | `BrowserPublicationJournal`、`_transaction()`、`_verifyReservation()`、`_remove()` | IndexedDB 中按 owner/policy 原子占位，完整记录与 attempt 参与 CAS；每个 owner 最多 20 个待办 |
| `apps/guardian/lib/ui/policy_publication_controller.dart` | `submit()`、`check()`、`_requestFailed()`、`_restoredPhase()`、`reloadPending()` | 当前 410 落入通用失败并回到 `unknown`；恢复只读本机，不自动 GET 或 POST |
| `apps/guardian/lib/ui/policy_publication_dialog.dart` | `primary()`、`primaryLabel`、`instruction`、`failureMessage`、`content()` | UNKNOWN 只提供“查询发布结果”，没有到期/已清除的说明和结束本机待办操作 |
| `apps/guardian/lib/pages/policy_publication_entry.dart` | `showPolicyPublication()` | 只关闭自有 OwnedDialogRoute；返回 `true` 专用于显式重新预览，不能复用来表示到期待办已清理 |

`apps/guardian/lib/core/policy_publication.dart` 当前只有 `PublicationPhase.unknown`、`reauthenticationRequired`；`PublicationPending` 必须包含完整 intent。它不能直接承载已经清除 intent 的终态标记。

`ConsoleActions.previewPolicy()` 位于 `apps/guardian/lib/pages/console_pages.dart`：先 `journal.read(owner, policyId)`；存在待办则恢复原流程，空槽则允许创建新预览和新 UUID。清理时直接删除 UNKNOWN、将存储异常当成空槽，或者返回“重新预览”都会破坏此边界。

发布请求使用 `boundedJson()` 直接取得受限 client，并不通过 `Api.send()`。只增加 `ApiFailure.message` 文案不能实现到期恢复。`Api.send()` 的待写 key 清理也不是该流程的重放授权来源。

## 3. 最小用户流程

### 3.1 服务端已确认结果到期

标题：**原操作结果已到期**。

说明：“该操作的原返回结果已超过 90 天保留期限，不能再恢复。到期不代表操作未完成。请查看当前策略或相关审计记录。”

### 3.2 服务端已确认结果已清除

标题：**原操作结果已清除**。

说明：“该操作的原返回结果已清除，不能再恢复。清除结果不代表取消了已发生的操作。请查看当前有权访问的策略或审计记录。”

ERASED 不使用“等待恢复”“稍后重试原提交”“超过 90 天”等替代说明，也不展示已删除的原响应或敏感恢复内容。

### 3.3 操作与确认

到期终态不显示“继续保存”“发布配置”“查询原结果”或“重新预览”。提供：

1. **清理并查看当前策略**。
2. **清理并查看审计记录**，仅在当前权限允许审计时出现。
3. **暂不清理，关闭**，不删除待办、不发出业务写入。

前两项先弹出一次明确确认：

> 结束本机恢复待办并清理恢复详情？系统将保留最小终态标记，防止原操作再次提交。此操作不会重新发布、取消发布或删除当前策略与审计记录。

确认后只进行本地原子事务。事务成功并核对终态标记后，关闭本窗口，等待自有 route 完成退出，再由仍有权限的父入口打开当前记录。双击、被其他窗口覆盖、父窗口消失或失权时不能重复确认或误关其他窗口。

如果 `_receipt` 已经可信确认过发布成功，仅本地清理尚未完成，则保留“此前已确认配置保存”的事实；后续 410 不能把已确认成功改写成失败或从未执行。终态仍区分原返回结果到期与已清除。

## 4. 状态与错误处理

以下名称为建议新增状态，当前源码尚不存在：

| 输入或动作 | 建议状态/处理 | 允许的下一步 |
| --- | --- | --- |
| 完整可信 HTTP `410 IDEMPOTENCY_RESULT_EXPIRED` | `resultExpired`，持久标记原 pending 的终态 | 关闭；显式确认本地清理并查看当前记录 |
| 完整可信 HTTP `410 IDEMPOTENCY_RESPONSE_ERASED` | `resultErased`，与过期原因分开保存 | 同上，不尝试恢复已清除响应 |
| 用户确认清理 | `clearingTerminal`，同步 busy，执行一次 CAS | 等待本地事务，不发 GET/POST |
| 清理提交和复读核对成功 | `terminalAcknowledged` | 清除视图中的恢复详情，关闭自有窗口，再导航 |
| 终态标记或清理存储失败/冲突 | 保持已知终态并阻断提交；单独记录本地存储错误 | 显式重试本地核对/清理，不重新查询或发布 |
| 404、网络错误、5xx、畸形/截断 410、未知 410 错误码 | 原 `unknown`，不清除待办 | 用户显式 GET 原结果 |
| 查询要求 MFA | 原 `queryReauthenticationRequired` | 用户显式安全验证；返回后仍不自动写入 |
| 失权、账号/租户/角色或作用域代际变化 | 原 `revoked`，隐藏私有内容 | 关闭；不清除旧 owner 的待办，不导航至旧资源 |

`PolicyPublicationRepository._read()` 应将 `onHttpError` 的完整响应证据用于 GET 和 POST：只有证据与实际抛出的 failure 为同一对象、状态 410、错误码在上述两项白名单内时，才产生绑定原 `PublicationPending` 的专用终态结果。可使用私有构造的 typed exception，避免通用 client exception 冒充可信终态。

`boundedJson()` 已有完整、限长、内容类型与响应流结束检查；只需在 repository 接收并分类其证据，不能放宽它。401/403、MFA 和作用域守卫继续先于内容展示生效。

Controller 的 `submit()` 与 `check()` 都需接收同一终态类型。`_restoredPhase()`、`canConfirm`、`canSubmit`、`canCheck`、`canCancelNotSubmitted`、`canRepreview` 和 `_scheduleExpiry()` 必须共同保证终态无重放路径。不能将终态映射成 `retryableNotSubmitted`、`fresh`、`previewInvalid` 或通用 UNKNOWN。

## 5. 原子清理和最小防重标记

建议保留现有 pending 槽，并增加独立 terminal 标记存储；不要将两个动作拆成先删除 payload、再写标记。

1. 收到可信 410 后，按完整 expected record、owner/policy、原 key、phase 和 attempt 做 CAS，将 pending 标为 `RESULT_EXPIRED` 或 `RESULT_ERASED`。此时尚未得到用户清理确认，不自动删除恢复详情；重新打开时应恢复终态说明，不再循环 GET。
2. 用户确认后，在**同一个 readwrite 事务**中复核该终态 pending，写入最小标记，并删除含完整 intent 的 pending。提交后重新读取核对；只有两者一致才报告完成。
3. 最小标记只保留用于匹配的命名空间/策略定位、原请求摘要、终态原因和确认时间；已有可信成功事实可保留布尔标记。不得保留原 preview ID/hash、提交正文、目标设备列表、儿童名称、令牌、完整响应或异常原文。标识本身仍按实际隐私边界处理，不能称为匿名数据。
4. `reserve(intent)` 在授予 `maySubmit=true` 前还需检查同一原请求的 terminal 标记；旧 key 永不重新占位。`claimRetry()` 仍只接受精确 `REAUTH_REQUIRED`，不能从终态产生下一 attempt。
5. 多标签页中只有完整 CAS 匹配者能结束旧待办。旧确认、旧查询和旧清理不能删除或覆盖另一标签页的新记录；CAS 不匹配时重新读取并展示当前记录，不能当作已清空。
6. terminal 标记不计入“20 个未完成 pending”的额度；不能因额度、预览过期、解析失败或重新登录而驱逐未知 pending。terminal 的清理/保留规则必须与服务端防重复执行契约一起确定，不能再按客户端 90 天计时静默删除。
7. 事务失败或复读失败均 fail closed：不允许新提交、不进入空槽分支、不显示“已清理”。原正文和标记必须通过事务保持一致，不能用清库替代该转换。

可新增 `markResultTerminalIfSame(expected, reason)` 与 `acknowledgeTerminalIfSame(expected)` 两个 journal 操作，返回能够区分匹配成功、已被其他标签页改变和存储失败的结果。需要同步修改严格 DTO/codec 及 IndexedDB store/schema 校验，不能把 redacted marker 伪装成现有 `PublicationPending`。

## 6. 当前策略与审计入口

- 当前策略可复用 `openPolicyDetails(context, session, root: ..., row: {'id': policyId}, preview: previewPolicy)`。该函数会 GET 当前草稿并校验身份，不渲染旧恢复快照。策略已经不可用时显示当前读取结果，不把404解释为旧发布未执行。
- `showPolicyPublication()` 应使用独立退出原因或回调表达“查看策略/审计”。终态确认不得返回现有 `true` 或调用 `onRepreview`；该值会让 `ConsoleActions.previewPolicy()` 继续创建预览。
- 导航前重新检查父 route、自有 route 退出完成、当前账号/工作空间及 `canOpen('policies')` / `canOpen('audit')`。MFA 返回不自动查询、清理或发布。
- 真实后端 `PolicyService.recordConfiguration()` 写入 `POLICY_CONFIGURATION_RECORDED`，审计资源是 **`PublicationReceipt.versionId`**，不是 policy ID、publication ID 或幂等 key。不能将幂等 key 填成 audit `correlationId`。
- 有可信 receipt 时，可按 action 与 versionId 查审计。未知结果没有 versionId 时，按该 action 与原操作附近的时间范围查看，不虚构精确关联；审计缺失也不能作为未执行证据。
- `AuditView.resetRange()` 当前默认最近7天，`AuditExplorerPage`/`AuditView` 没有初始筛选参数。到期操作通常不在此范围内；需增加安全校验的初始查询/时间范围接入。`AuditQuery.validate()` 允许的单次范围最多366天，不能无限拉长或取消校验。

## 7. 后续最小修改范围与验证边界

实施需要前述六个恢复实现文件，以及：

- `core/policy_publication.dart`：终态枚举与最小标记/codec。
- `core/api.dart`：两个精确错误码的通用中文解释；不在此处授权重放或删除本地记录。
- `pages/console_pages.dart`：恢复入口识别终态、独立退出/导航，避免落入原重新预览循环。
- `pages/audit_page.dart`、`ui/audit_view.dart`：确需直达对应历史记录时接入初始查询，保留原权限与筛选校验。

现有测试已经约束 UNKNOWN 不重放、404不代表未执行、跨标签页单赢家、attempt CAS、MFA拒绝与通用异常分离、存储失败阻断，以及自有窗口退出。这些契约继续保留。后续应补充两个410原因、畸形410、终态恢复、两阶段CAS、多tab竞态、清理失败、失权/MFA、旧回调和导航筛选的验证；本轮没有新增、修改或执行这些测试。

本文只确认产品选择与待实施方案，不代表90天保留、终态清理、数据库接合或界面交互已经实现或通过验证。
