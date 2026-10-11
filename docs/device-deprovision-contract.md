# 设备正常退出与清理契约

更新：2026-10-11。本文描述已有 `lifecycle` 后端、管理台退出组件和 Android 儿童端的本代理数据清理链；本地清理尚无真机/电视验收或独立证明，EMM 解除与整机擦除尚未交付。完整功能仍按[实施计划](implementation-plan.md)推进，管理端交互边界见[设备退出组件契约](device-operations-ui-contract.md)。

## 1. 能力与产品状态

当前只接受 `AGENT_UNENROLL`：管理员请求当前 BYOD 注册退出云端业务，并向原注册密钥持有者提供限时、签名的**本代理数据清理**任务。支持 ACTIVE 和已紧急撤销的 REVOKED 注册；尚未确认的注册应走注册取消流程。重新注册创建新设备/注册周期，不恢复旧凭证。

| 结果 | 已有证据 | 管理端应显示 |
|---|---|---|
| 云端业务访问撤销 | 设备状态、凭证域和凭证在事务内撤销 | 远程业务访问：已撤销 |
| 已有访问窗口失效 | 设备撤销领域事件在原事务内使审批失效 | 此设备的旧访问窗口已失效 |
| 清理任务已取走 | 原密钥认证的 GET，记录首次取走时间 | 清理命令：已提供；执行情况待回执 |
| 代理自报数据已清理 | 有效密钥证明、准确命令哈希及幂等回执 | 本地清理：设备自报，尚未经独立验证 |
| 到期未报告 | 固定截止时间与持久状态变更 | 本地清理：未确认，任务已到期 |
| EMM 解除 / 整机擦除 | 无正式适配器 | 当前不支持，不创建执行任务 |

`CLEANUP_REPORTED` 不是“经验证已退出系统管理”，不证明磁盘安全擦除、其他 App 数据删除或密钥物理删除。服务端没有 `DEPROVISIONED`/`WIPED` 成功状态。云端使用记录、审计、订阅和席位不会在本操作中删除或退还，后续由相应领域按授权处理。

退出恢复通道是基础安全流程，不能因未来套餐欠费而被隐藏。当前没有计费或权益拦截实现，也没有正式商业套餐能力交付。

## 2. 端到端流程

```mermaid
sequenceDiagram
    actor A as 管理员
    participant M as 管理 API
    participant DB as MySQL 事务
    participant D as 设备代理（清理执行待接入）
    participant C as 独立清理 API
    A->>M: 近期 MFA + 当前设备 ETag + 后果预览
    M-->>A: 精确注册/版本、后果、限制、哈希、期限
    A->>M: 确认哈希 + If-Match + Idempotency-Key
    M->>DB: 撤销业务凭证、使访问窗口失效、保存签名命令与审计
    DB-->>M: 同事务提交
    M-->>A: REVOKED / WAITING_FOR_AGENT / 本地证据 NONE
    D->>C: 原注册密钥签发 READ 证明，发现当前任务
    C-->>D: public-only 公钥 / 固定期限的签名命令
    D->>D: 验签、检查目的/注册/范围/截止时间；仅清理本代理数据
    D->>C: RECEIPT 证明 + 命令 ID/哈希 + 自报结果
    C-->>D: 幂等确认
    D->>D: 确认后移除原注册密钥（待原生实现）
    A->>M: 查询当前操作
    M-->>A: 云端已撤销；本地自报/失败/未确认
```

业务凭证失效可能是过期、紧急撤销或正常退出；**收到业务 401 不构成本地清理授权**。客户端只有在得到可验证、绑定自己的清理命令后才能执行清理。设备离线时不能声称撤销命令已送达；本地恢复、计时、断电与重启需要原生专项验收。

取消只停止服务端继续提供该任务或接受新回执，不恢复业务凭证，不撤销已执行清理，也不能召回设备离线时已经缓存的有效签名命令。确认页必须在提交前说明此后果。

## 3. 管理 API

统一前缀：`/api/v1/tenants/{tenantId}/devices/{deviceId}/deprovision`。用户使用 OIDC JWT；当前数据库成员关系是授权权威。

| 方法/后缀 | 请求 / 响应 | 要求 |
|---|---|---|
| POST `/previews` | `{action:"AGENT_UNENROLL"}` → 201 DeprovisionPreview | OWNER/GUARDIAN/ORG_ADMIN、近期 MFA、设备 If-Match |
| POST `/operations` | `{previewId,previewHash}` → 201 DeprovisionOperation | 同一确认人、预览未用/未过期、当前设备/注册/版本、近期 MFA、If-Match、必填 Idempotency-Key |
| GET `/operations` | limit/cursor → ItemPage | 成人或 AUDITOR；默认 50/最大 100，UUID 游标 |
| GET `/operations/{operationId}` | Operation + 强 ETag | 成人或 AUDITOR；租户和设备均匹配 |
| POST `/operations/{operationId}/cancel` | Operation + 强 ETag | 当前成人、近期 MFA、操作 If-Match、必填 Idempotency-Key |

儿童、教师和外租户成员不能调用这些接口；儿童既有设备列表会看到 REVOKED，不提供管理员身份或退出审批信息。AUDITOR 只读。

预览包含 id、deviceId、registrationId、deviceVersion、action、consequences、limitations、hash、expiresAt。哈希由服务端生成并持久化，绑定确认人、租户、注册、版本、期限和精确后果。设备心跳也可能改变设备版本；提示重新获取预览，不能自动替用户确认新后果。

操作包含 id、deviceId、registrationId、commandId、action、state、remoteAccess、localEvidence、reasonCode、issuedAt、notAfter、version。管理响应不包含清理签名文档或设备私钥。创建返回操作 ETag；该 ETag 与设备 ETag 属于不同资源。所有 JSON 时间为 UTC Unix **毫秒**。

同键同载荷返回原响应快照，包括原版本和原状态；客户端随后 GET 当前操作。撤销成员或失去成人权限后，原键也不能读取缓存响应。不同键再次消费同一预览失败；取消或到期后可重新预览并创建新的操作/命令，普通设备凭证仍不复活。已自报清理完成的操作不能取消或作为自动续期依据。

## 4. 原密钥清理认证

独立命名空间 `/api/v1/device-cleanup`，Spring Security 第 0 顺序链；普通用户 JWT、普通 opaque 设备凭证均不接受。清理证明也不能访问管理和常规设备 API。该命名空间没有注册、恢复业务凭证或修改策略入口。

| 方法/路径 | action | 用途 |
|---|---|---|
| GET `/signing-keys` | READ | 当前有效任务的 public-only ES256 验证公钥环 |
| GET `/command` | READ | 当前任务 operationId、commandId、notAfter、compactJws；首次读取记审计 |
| POST `/receipts` | RECEIPT | 当前操作绑定的结果回执 |

`Authorization: Bearer <原注册密钥签名的 JWT>`；最大 8192 字符。Nimbus 验签，公钥来自原注册记录，不采信证明里提供的公钥。注册必须 REVOKED，公钥指纹须与任务绑定指纹一致。

| 位置 | 必须值 |
|---|---|
| JOSE alg / typ / kid | ES256 / `aimanager-cleanup-auth+jwt` / 当前 registrationId |
| iss / sub / aud | `device:{registrationId}` / deviceId / 仅 `ai-manager:cleanup` |
| purpose / tenantId / registrationId | AGENT_CLEANUP / 当前租户 / 当前注册；标识为规范小写 UUID |
| action | READ 或 RECEIPT；读取与提交权限分开 |
| operationId | RECEIPT 必填；READ 可省略以发现当前任务，提供时须与当前任务一致 |
| iat / exp / jti | 必填；exp > iat、未过期、最长 300 秒；iat 最多超前 30 秒；jti 为规范 UUID |
| nbf | 如提供，最多超前 30 秒 |

拒绝内嵌/远程 JWK、X.509 URL/证书链和未支持的 critical header。P-256 公钥不得包含私钥；存在 alg/use/key_ops 元数据时，必须允许 ES256/SIGNATURE/VERIFY。预览与认证共用同一 SDK 校验函数，避免先撤销后发现密钥不兼容。

该证明是**短时可重用认证**，jti 不是一次性消费 nonce。必须走可信 TLS，不记录 Authorization，原密钥需由原生安全存储保护。截获证明可在其期限和限定命名空间内重放；回执 ID/哈希仅解决业务幂等，不能声称消除了凭证重放。设备身份 SDK 已提供原注册密钥的 60 秒 READ/RECEIPT 证明生成；独立清理模块已有预设 TLS 根、限时限量、拒绝跳转的命令领取、验签及显式回执客户端。儿童宿主接入、真实原生密钥保护与时钟可信程度仍待验证，单独生成证明或领取命令不会触发本地清理。

公钥响应只含公开材料且 key_ops=VERIFY；客户端必须验证服务端 TLS 身份/正式信任配置，不能信任任意地址返回的自签 JWK。根信任轮换、离线验证缓存和证书策略另需客户端验收。

## 5. 签名命令和回执

命令使用 Nimbus ES256 JWS：typ=`aimanager-cleanup-command+jws`，kid=外置签名密钥 ID。与普通配置 JWS 类型分离。负载为：

```json
{
  "schemaVersion": 1,
  "purpose": "AGENT_CLEANUP",
  "tenantId": "<当前租户 UUID>",
  "deviceId": "<当前设备 UUID>",
  "registrationId": "<原注册 UUID>",
  "keyThumbprint": "<原公钥指纹>",
  "operationId": "<操作 UUID>",
  "commandId": "<命令 UUID>",
  "issuedAt": 1791514800000,
  "notAfter": 1791601200000,
  "scope": "OWN_AGENT_DATA_ONLY",
  "actions": ["CLEAR_POLICY_CACHE", "CLEAR_USAGE_CACHE", "CLEAR_BUSINESS_CREDENTIALS"],
  "keyRemoval": "AFTER_SERVER_ACK"
}
```

设备仅清理自身代理保存的策略缓存、使用缓存和业务凭证；保留提交本次回执所必需的窄范围材料直到收到确认，再清除原注册密钥。第三方 App、个人媒体、系统账户、工作资料和整机存储均不在范围内。服务器不能独立证明设备实际执行或密钥删除。

设备端 `device_cleanup` 模块复用成熟 HTTP/JOSE/crypto，核对公钥环、JOSE 类型、ES256、设备/注册/原密钥指纹、固定清理动作与截止时间，给出绑定范围的命令哈希。模块提供显式回执提交、严格绑定响应解析和按注册隔离的持久回执日志；按签名命令与阶段派生稳定 UUID v5，发送前保存同一回执 ID/正文，未知结果只能重试原记录，写入不明后必须重新读取日志。Android 宿主已提供按原注册隔离的加密存储与私有数据清理执行器。日志本身若丢失，相同命令/阶段的回执编号可复现，但失败原因和本地实际清理进度仍需独立恢复/人工处理，不能凭编号推断清理成功。

设备 SDK 的显式协调器按已验签命令、待发回执重放、收到命令回执、本地执行、清理回执与最终原密钥删除的顺序调用宿主接口。清理回执只接受服务端返回的 `CLEANUP_REPORTED` 和相应未验证证据，不能把任意 200 响应当成清理成功。Android 生产儿童会话在启动、打开本地缓存前接入一次有界核对；退出待确认或核对失败时，回到前台会再次核对，页面也提供显式重试。常规设备页的“检查连接与退出状态”也会先核对签名退出命令，再发送心跳，避免应用持续打开时完全错过新命令。前台重试先暂停并关闭配置、访问、申请及使用数据持有者，等待数据库关闭完成后才拉取命令；任何关闭失败都会拒绝清理并保留“未确认”结果。协调器返回的本地清理失败会显示为失败；仅在收到服务端清理回执确认并移除原密钥后，本次会话显示本应用退出完成，不立即呈现新注册表单。只有真正验签的当前命令才会触发本应用私有缓存清理。执行器删除配置、访问/申请数据库，以及加密使用与访问缓存；普通设备凭证先停用，原密钥和日志留到最终回执确认。未知安全存储键或异常缓存文件会以失败回执停止，不静默忽略。其实现不涉及第三方 App、系统权限、EMM 解除或整机擦除。

本机文件删除后，原生通道限制 `fsync` 目标为本应用 `filesDir` 内规范路径，并同步目录元数据；加密存储删除继续使用原提交屏障。同步失败时不能报告清理完成。此处是文件系统持久化措施，不是闪存安全擦除或独立取证，仍需各 Android/TV 厂商真机验证。

设备身份 SDK 已增加 `cleanupPending`：经宿主验证命令后持久删除普通业务凭证及未完成轮换/心跳意图，只保留原签名密钥、设备范围和命令哈希用于清理回执；该阶段普通设备接口不可用。最终删除需先持久确认清理回执，再删除加密身份记录与原密钥提供者材料。新 Android 注册的 Keystore 别名在最终阶段显式删除并复查，既有软件 JWK 仍由加密身份记录承载并在同阶段删除；这不证明硬件背书或闪存安全擦除。儿童端对该阶段显示“退出未确认”，不提供普通连接操作。当前没有后台/开机任务保证；前台重试只在用户重新打开应用后执行，也没有真机/电视联调或独立擦除证明；设备离线、服务端任务取消/到期和日志丢失都可能使退出停在未确认状态，不能把代码接线当作生产验收。

服务端已确认清理回执、但设备尚未删除原密钥时，任务可能已经到期。启动恢复可在不联网重取命令的情况下，将加密身份记录的设备范围/原密钥指纹/命令哈希与加密日志中的 `AGENT_DATA_CLEARED` 已确认阶段、`localDataCleared=true`、无待发回执严格匹配，**仅执行最后的原密钥删除**。日志缺失、损坏或阶段未确认时不得用此路径补报清理或删除原密钥；需联网重新核对或人工处理。正式发布仍需真机断电、文件损坏和密钥删除结果不明验收。

重复拉取同一持久 JWS，截止时间不延长；新任务使用新的 operationId/commandId。缺外置签名密钥时，正常退出确认返回 503，凭证不撤销；原有紧急 `/devices/{deviceId}/revoke` 仍可立即撤销访问，二者不混淆。

回执字段：receiptId、commandId、commandHash（compactJws UTF-8 的 SHA-256 小写十六进制）、stage、reasonCode。stage 为 RECEIVED / AGENT_DATA_CLEARED / FAILED；只有 FAILED 必须带 reasonCode（STORAGE_FAILURE、KEY_UNAVAILABLE、UNSUPPORTED_AGENT、USER_ACTION_REQUIRED），其他阶段不得带。设备身份/操作由认证上下文确定，正文不能改绑。

未取过命令不能确认；同 receiptId 同载荷返回原快照，异载荷 409。迟到 RECEIVED 不回退失败或已清理状态；FAILED 后可以重试并报告清理，已报告清理后的新 FAILED 被拒绝。到期、取消或被新任务替代后，不接受旧证明/回执，即使此前已提交过相同回执；设备与管理者需要保留“确认响应可能丢失”的不确定性。

```mermaid
stateDiagram-v2
    [*] --> WAITING_FOR_AGENT
    WAITING_FOR_AGENT --> COMMAND_SERVED: 原密钥取走命令
    COMMAND_SERVED --> COMMAND_RECEIVED: RECEIVED
    COMMAND_SERVED --> CLEANUP_FAILED: FAILED
    COMMAND_RECEIVED --> CLEANUP_FAILED: FAILED
    COMMAND_SERVED --> CLEANUP_REPORTED: 自报清理
    COMMAND_RECEIVED --> CLEANUP_REPORTED: 自报清理
    CLEANUP_FAILED --> CLEANUP_REPORTED: 重试后自报清理
    WAITING_FOR_AGENT --> CLEANUP_EXPIRED: 到期
    COMMAND_SERVED --> CLEANUP_EXPIRED: 到期
    COMMAND_RECEIVED --> CLEANUP_EXPIRED: 到期
    CLEANUP_FAILED --> CLEANUP_EXPIRED: 到期
    WAITING_FOR_AGENT --> CLEANUP_CANCELLED: 成人取消
    COMMAND_SERVED --> CLEANUP_CANCELLED: 成人取消
    COMMAND_RECEIVED --> CLEANUP_CANCELLED: 成人取消
    CLEANUP_FAILED --> CLEANUP_CANCELLED: 成人取消
```

所有操作 remoteAccess=REVOKED。未收到结果时 localEvidence=NONE；收到清理或失败报告时为 DEVICE_REPORT_UNVERIFIED。到期不清除历史报告，不转成执行成功。

## 6. 数据、配置和运维

V12 迁移：deprovision_previews、deprovision_operations、deprovision_heads、cleanup_receipts。租户复合键、设备/到期索引、命令唯一约束和回执外键；head 表串行化每个注册的当前任务，旧操作/回执保留用于审计。lifecycle 通过 Fleet 公开接口读取/撤销注册，不直接修改设备表。

管理员写入按成员 → 设备 → 预览/head → 操作；清理接口按 head → 操作，后台到期只锁操作，无逆向追加 Fleet 锁。幂等记录、源凭证撤销、审批失效、命令、预览消费与审计同事务。签名没有外部网络 I/O；真实 MySQL/OceanBase 锁等待、隔离、索引和死锁恢复仍需对应 profile 认证。

| 环境变量 | 默认 | 合法范围 / 语义 |
|---|---|---|
| DEVICE_EXIT_PREVIEW_LIFETIME_SECONDS | 300 | 30～900；预览确认期限 |
| DEVICE_CLEANUP_LIFETIME_SECONDS | 86400 | 300～604800；任务绝对期限，不靠拉取续期 |
| DEVICE_CLEANUP_EXPIRY_JOB_ENABLED | true | Spring 到期作业开关 |
| DEVICE_CLEANUP_EXPIRY_BATCH_SIZE | 100 | 1～1000；每轮上限 |
| DEVICE_CLEANUP_EXPIRY_INTERVAL_SECONDS | 30 | 5～3600；每轮间隔 |

复用 CONFIGURATION_SIGNING_KEY_FILE / CONFIGURATION_VERIFICATION_KEYS_FILE 外置密钥环，见[配置交付契约](configuration-delivery-contract.md)。非法期限/作业配置启动失败，不静默修正。

Spring Scheduler 通过数据库行锁、固定批次和状态条件持久到期；没有自研定时器。管理员详情/列表也会持久校验到期并增加版本。多副本可等待同一批次，数据库超时/失败交给作业后续轮次处理；这不构成百万设备吞吐认证。

审计记录预览、确认、云端凭证撤销、首次命令读取、每个新回执、取消和到期；复用请求关联 ID，不记录原私钥、证明、JWS 正文、儿童文本或 SQL 值。审计不可篡改归档、历史保留/删除和清理速率治理还未完成。

## 7. 页面、验证与发布门槛

管理台设备详情已接入共享退出组件：后果预览 → 明确勾选 → 近期 MFA → 提交或用原键核对未知结果；操作详情分开呈现“云端访问”和“本地清理”，取消前说明已缓存任务无法召回，不能写“恢复管理”。版本冲突需要重新预览；签名服务缺配置时不能继续正常退出。儿童端只显示联系监护人的恢复方式，不提供管理员操作。组件的界面和协议验证见[设备退出组件契约](device-operations-ui-contract.md)，这些验证不证明真实设备已执行清理。

设备详情也提供单独的“紧急撤销云端访问”入口，仅在 ACTIVE 注册对有写入权限的成人显示。确认框说明凭证撤销与临时访问窗口失效，并明确不发送本地清理命令。后端每次重新检查角色和近期 MFA；网络结果不明时，管理员应刷新设备状态，不据此推断本地清理或系统应用限制已生效。

已有测试使用 H2、MockMvc 和真实 Nimbus 签名/opaque 认证，覆盖成人/儿童、MFA、ETag/幂等、原密钥与用途、跨任务、固定期限、取消/新任务、乱序回执、全局有界到期、审批事务失效、无密钥配置和故意数据库失败后的整体回滚。

剩余发布门槛：真实管理员 MFA 的管理端退出写入联调；Android/TV 原生清理及密钥删除；离线/重启/丢失确认恢复；真实数据库并发和保留治理；正式受管解除/独立擦除预览与供应商/设备证据。上述功能和证据未完成前，不将完整 END-01 或整个产品标记交付完成。
