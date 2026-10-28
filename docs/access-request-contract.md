# 临时访问申请与审批：实际后端契约

更新日期：2026-10-26。本文记录当前 `approval` 模块的实际接口，配合[功能规格](parental-control-functional-spec.md)、[完整实施计划](implementation-plan.md)和[实施记录](implementation-progress.md)阅读。

## 1. 已实现与执行边界

已实现儿童与教师范围内申请、分页/详情、近期 MFA 决定、限时窗口、取消/撤销、版本与幂等、冷却、到期作业、基础策略/主体/设备/成员及班级生命周期失效和事务审计。教师扩展的专项、MySQL、前端与运行验证见 organization-workflow-plan.md，不沿用旧阶段测试数字作为新功能验证。

当前批准结果为 `APPROVED_PENDING_DELIVERY`，`executionState` 固定为 `NOT_ENFORCED`。它保存管理员决定和有限期的授权意图，设备现可获取 CONFIGURE_ONLY 的签名窗口/撤回文档并报告收到、保存或拒绝，见[签名审批文档与回执](access-window-delivery-contract.md)。尚未启用可在设备执行的例外许可证，没有解除应用限制或增加使用额度。EMM/原生执行、规则级证据、通知和客户端仍需实现。

当前支持 APP_LAUNCH 的 DENY 规则，以及 TIME_WINDOW 规则的临时访问窗口。未选中的规则、其他策略流和必要恢复底线仍然有效。DAILY_QUOTA、系统权限、安装/卸载或域名规则不能通过该窗口接口放宽；额度追加须通过后续额度账本，不将窗口秒数解释为新增使用秒数。

## 2. 身份和对象范围

管理路径为 `/api/v1/tenants/{tenantId}/access-requests`，使用用户 Bearer JWT；设备 opaque 凭证不能调用。

| 操作 | 允许角色 | 附加约束 |
|---|---|---|
| 创建 / 选项 | CHILD/TEACHER | 当前绑定主体或教师班级范围、有效主体/注册与最新基础版本；仅 APP_LAUNCH DENY / TIME_WINDOW |
| 列表/详情 | OWNER/GUARDIAN/ORG_ADMIN/AUDITOR/CHILD/TEACHER | 儿童/教师仅当前范围内本人提交的申请；不返回审批人身份/联系方式 |
| 批准/拒绝 | OWNER/GUARDIAN/ORG_ADMIN | 近期 MFA、If-Match、幂等键；批准再次复核基础和绑定 |
| 取消 | CHILD/TEACHER | 原提交者的精确身份和当前范围；只能取消待决申请 |
| 撤销 | OWNER/GUARDIAN/ORG_ADMIN | 近期 MFA；原来确实批准且未到期；不能声称设备已收到撤销 |

TEACHER 不获得审批权限、策略修改或设备管理权限。教师仅提交范围内申请；管理员仍需近期 MFA 决定，且不能审批本人曾提交的申请。双人审批及其他成人手工发起授权仍待独立实现。

## 3. REST 接口

| 方法与相对路径 | 成功 | 输入/输出 |
|---|---|---|
| POST 根路径 | 201 + ETag | Create → AccessRequest |
| GET /options | 200 | 必填 deviceId、limit=1..100、UUID cursor；返回该设备可申请的当前策略、应用和规则身份 |
| GET 根路径 | 200 | limit=1..100、UUID cursor、可选 `state`（AccessRequest.State 枚举）→ ItemPage；仍按原租户/主体/提交者范围鉴权。筛选依据持久化状态，响应会再次按设备与主体生命周期协调，客户端应以响应中的实际状态决定是否展示待办。 |
| GET /{requestId} | 200 + ETag | AccessRequest |
| POST /{requestId}/decisions | 200 + ETag | Decision → AccessRequest |
| POST /{requestId}/cancel | 200 + ETag | 空正文 → AccessRequest |
| POST /{requestId}/revoke | 200 + ETag | 空正文 → AccessRequest |

所有创建/决定/取消/撤销必须有 `Idempotency-Key`。变更已有申请必须有强 `If-Match`，缺失 428、陈旧 412；不接受通配符/弱版本。未知字段、非规范 UUID、重复规则 ID、非法类型/范围拒绝。

选项页逐页扫描当前策略版本，只返回匹配设备当前注册周期的结果。页内可能没有可用选项但仍有 nextCursor，客户端必须继续允许加载。公共规则 commonRules 与各 applications[].rules 分开返回，避免重复膨胀；前端合并选择最多 20 条。选项不包含其他设备、完整草稿、签名身份、时间计划内容或其他申请理由。

创建和审批的幂等回放在复核当前权限后重新读取申请状态，已到期或撤回时返回当前事实及版本，不重放过时的有效批准。原始决定及绝对截止时间不改变。

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

管理台创建申请同样按“分钟＋可选秒”输入，默认15分钟、秒留空按0处理。分钟为0～60、秒为0～59，合计必须为1～3600秒；0分钟的短时申请、余秒和60分钟上界均精确保留，合计越界就近拒绝，不舍入或自动钳制。提交只包含原 requestedWindowSeconds 整数秒，不发送 minutes/seconds 控件分量。

创建窗口冻结原Map与ruleIds列表，未知重试跳过当前控件的校验和转换，继续使用原正文及同一次幂等键。原结果未知后，后续普通拒绝或近期认证要求不能解锁原内容；408与非API异常同样保留未知状态。结果过期／抹除或版本冲突停止旧提交并保留只读内容，允许关闭后核对申请列表，不据此宣称首次写入未执行。范围或配置变化仍限制原窗口继续提交，不能借刷新规则解除已有未知保护。

创建窗口复用原 DialogAccessBinding，在捕获所属路由后才启动首批设备读取。新交互要求原窗口仍置顶，异步续程只要求原窗口有效，通知覆盖不取消在途提交。设备／应用／规则选项、加载／刷新和提交入口同步防重并核对原规则代次；切换应用或重读目录后旧回调不能复活，不能通过旧控件改变已冻结内容。规则加载期间再次调用不发重复请求；设备分页返回继续按当前选择保留／失效处理，不误丢用户较新的选择。完成／停用永久退役本窗口；创建方必须提供所属 OwnedDialogRoute 的完成回调，组件只交还结果，不直接调用框架受保护的路由完成接口，也不能误关上层通知。

目录GET在原有效范围内返回401/403且不是REAUTH_REQUIRED，或明确WORKSPACE_CHANGED时，当前创建窗口锁存readDenied，清空设备／应用／规则、可见时长与理由、游标和加载标志，推进规则代次；只显示固定说明和关闭入口。其他目录的晚到成功、旧回调或loader短暂恢复均不能复活该窗口，须关闭后重新进入读取。规则GET先验证原代次，旧目标的迟到403不能影响新目标；设备分页仍属于整个窗口，不按规则代次过滤。普通网络／分页失败及安全验证要求继续沿原恢复路径。POST拒绝不触发目录读取失权；原pending、stopped与幂等正文保护保持，不把读取拒绝解释成原写入未执行。

管理台批准表单使用“分钟＋秒”，初始值完整保留申请秒数；两个分量校验整数范围，合计须为 1 秒至申请值。提交前转换为规范的 `grantedWindowSeconds`，不向后端发送表单分量或额外字段。子分钟与余秒申请均不取整，原幂等键、版本与未知结果冻结/重试机制保持。

拒绝：`{"decision":"DENY","reasonCode":"NOT_NOW"}`。reasonCode 可选，枚举为 NOT_NOW/NOT_ALLOWED/OTHER；不能带授予时长。

批准时固定 `issuedAt` 和 `absoluteNotAfter = issuedAt + grantedWindowSeconds × 1000`。截止时间从批准开始计算，重复请求、晚送达、断网和重新登录不会延长。

### 3.3 返回字段与 UI

AccessRequest 包含 id、subjectId、deviceId、registrationId、policyId、baseVersionId、applicationId、ruleIds、requestedWindowSeconds、reason、state、requestExpiresAt、grantedWindowSeconds、issuedAt、absoluteNotAfter、reasonCode、executionState、version 和 createdAt。

管理侧 `GET /access-requests` 列表在原授权范围内可额外返回 `subjectName`、`deviceName`、`applicationName`、`applicationPackageName` 四个可选展示字段；审计角色不获得这些名称。单条查询、写入响应和设备侧仍只返回核心字段。名称与包名是目录资料，不能当作安装证据、应用安全评级或规则执行证明。

管理台工作台提供“待处理 / 全部”切换。所有者、监护人和机构管理员默认优先待处理；儿童、教师与审计员默认查看全部。待处理模式调用既有 `state=PENDING` 服务端筛选，再按响应的实际状态接收待办；读取时已协调为过期或失效的记录不继续显示为待办，未知状态使该页失败，不把坏响应当成空列表。筛选后空页仍保留服务端下一页游标，由用户继续加载，不自动遍历所有页。切换筛选重建列表范围，旧页、旧游标及晚到结果不进入新范围。

访问申请筛选由当前路由控制：`/approvals?state=PENDING` 显式查看待处理，`/approvals?state=ALL` 显式查看全部；不带筛选的普通入口仍按角色选择默认值。工作台的申请待办对管理者、儿童、教师与审计员都进入待处理视图，仍分别受审批、本人及只读范围限制。选择“全部”只省略后端列表的 state 参数，不把 UI 的 ALL 发送为后端状态枚举。返回、前进或登录回跳可以恢复固定视图，旧列表代际与迟到响应不进入新视图。

页面不再保存第二份本地筛选状态：宿主给出 pendingFilter 并处理筛选事件，统一路由枚举负责角色默认与精确参数解析。只识别相应页面的一个已支持键值，重复、未知、空值或附加参数不被解释成已支持筛选；登录回跳仍逐字匹配明确地址，不用解析后的 URL 扩大白名单。静态实施与未运行范围见[受控列表路由阶段记录](reviews/controlled-list-routes-20261026.md)。

列表直接消费已授权返回的对象、设备和应用展示资料；没有名称则显示完整核心编号，不额外查询目录。审计视图忽略这些名称与包名，即使响应意外附带也不展示。申请对象不被误写成申请人，名称不替代真实对象编号与后端授权。原详情、申请、决定及重新验证流程继续复用，列表切换不创建或审批申请。静态实施和当前未运行范围见[审批工作台阶段记录](reviews/access-request-worklist-20261026.md)。

进入详情前，展示上下文复制列表字符串，避免后续行变动污染当前窗口。详情验证单条响应的请求编号、核心对象编号、七种状态、1～3600 秒申请值及非负版本；名称仅在请求、主体、设备、应用与提供的注册周期引用全部匹配时带入，审计角色始终忽略名称，缺失或不匹配回退完整编号。状态、版本与提交目标只取当前单条响应。待处理申请直接打开详情，不读取尚不存在的交付摘要；其他状态保留交付摘要及历史入口。静态候选与未运行范围见[审批决定阶段记录](reviews/approval-decision-20261026.md)。

申请列表的详情与创建借用 ResourceActionLease，返回值只说明是否需核对列表。纯查看、交付／尝试历史及提交前关闭返回不重读，保留搜索和已加载分页；创建、批准、拒绝、本人取消或撤销已派发后核对一次，包含未知结果，不据此宣称决定成功。操作期间不能切换筛选，旧筛选回调不能在返回原选项后复活。

创建、详情和两层交付历史绑定原父窗口、账号／工作空间／角色／会话代际及原列表租约；历史只借用该作用域 API，不重新取得全局 API。原页面或父窗口退役后隐藏私有历史并只关闭自有路由，独立覆盖窗口保持；创建成功也通过自有窗口完成回调返回，不能关闭上层通知。静态改动与待验证范围见[成员、设备与审批流程记录](reviews/member-device-approval-flows-20261028.md)。

瞬时时间为 UTC epoch 毫秒，窗口时长为整数秒。审批人身份只在受保护的决定记录和审计中保存，不在该响应返回。DTO 的 toString 不输出儿童理由。

儿童页应显示“家长已批准，设备尚未执行”，并说明截止时间；不得显示“现在可以打开”。管理员页分别显示决定、文档交付与执行状态。已有签名文档接收/保存/拒绝回执入口；当前不存在 APPLIED/VERIFIED_APPLIED 成功响应或规则执行回执。

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

同幂等键/同请求不重复执行，异载荷 409，重试仍先检查当前权限。创建和审批决定使用原幂等结果定位申请，再重新读取、复核范围并协调当前状态与版本；已到期或撤回时不会把旧批准作为当前事实返回，原决定和绝对截止时间也不会延长。

取消和撤销沿用持久幂等的原响应快照；客户端可按返回 ID 查询当前资源，不把旧响应当作当前有效授权。通用幂等存储的快照语义与上述创建/决定的当前资源读取是两个步骤，不应混为同一种响应契约。

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

完整待办仍包括：正式执行模式的限时例外/撤销交付、独立客户端、规则级执行与离线证据、可信额度追加、双人审批/机构委派、通知、账户级速率、保留/删除，以及 SAF 紧急恢复、END 正常解除/擦除/清理流程。当前只读配置模式的文档与回执已接入，不能将本后端工作流标记为整个 Task 5 或完整产品已完成。
