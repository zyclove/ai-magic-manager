# 设备应用核验闭环 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 管理员在当前设备关联详情内完成应用选择、状态读取、显式核验和异常恢复，不再被预览提示引向不存在的页面。

**Architecture:** 沿用 Flutter Material 3、现有 Api、DeviceSubflowScope、有界响应读取和受控弹窗。应用身份使用同租户应用目录的服务端 ID，关联版本固定在本次操作上下文；提供方报告和执行授权继续由服务端校验。只实现 1.0.0 当前契约。

**Tech Stack:** Flutter 3.22 / Dart、ChangeNotifier、现有 HTTP 客户端；现有 Spring/JDBC 应用证据接口。

**Spec:** 用户关于 1.0.0、流程简化和完整可用的要求；`docs/managed-application-control-plan.md`、`docs/managed-application-control-evidence.md`；以 HEAD `b96b3e477be298c796fa41038b0511e4fc51afe6` 的 Controller/Store 为接口事实。

## 当前状态

2026-10-18：本轮设备应用核验前端闭环按最终冻结候选完成验收（仅在Root已完成下列实际门槛后应用本段）。439源/32路径的99个正式测试文件全部通过：VM 1117项、Chrome 340项，正式唯一总数 1457项；基础170复跑及290定向回归不重复加入。完整分析、HTML生产构建的32个实际产物，以及独立440源视觉驱动的5项/5图均通过，Root已逐图ViewImage检查；原生退出、自然进程树0、源码/runner/产物哈希一致，32个本轮源码路径已精确提交为 45cc0394675b69bcd7ddb45947beebf0c258d96a，439个已提交源码blob已与冻结候选逐哈希核对，证明见 .cache/application-evidence-release/source-commit-r2/committed-source-proof.json。此计划随后进入独立文档提交；最终文档提交及两提交push结果由外部交付证明记录，避免本凭证自引用。最终公开凭证为 `docs/evidence/application-evidence-console-20261018.json`，SHA256 `1e4b98500a8f0fc722d7c780dfe2f26b2f6839f4234ee064d92d3d94fb22d4ee`。历史失败保持原分类。本轮候选未据此部署，不代表全产品、后端ENFORCE全链路或真实EMM/Android系统操作验收完成。

## Global Constraints

- 不增加顶层菜单、新框架或依赖；不新增历史兼容分支、迁移或设备自报事实上传接口。
- 仅当前 OWNER/ORG_ADMIN 可以打开；AUDITOR 不读取此应用证据接口。已核验的关联必须仍具备有效 DEVICE_OWNER 服务端上下文。
- 目录声明只用于选中服务端 applicationId，不代表安装、签名或系统控制已经核验。包名只协助查找，自报签名不建立信任。
- GET 与 POST 的 If-Match 均为父关联版本；不使用应用证据 version 作为请求版本。
- GET 不触发提供方读取、不续期。POST /refresh 无事实请求体，要求近期多因素认证；无自动刷新 POST 或自动重发。
- 现有多人共享工作树只修改分工内文件。SDK 和 Git index 分别明确交接；验证快照和临时输出放仓库 .cache，保存原始退出码及证据。

## 精确接口

Api 相对路径：`/tenants/{tenant}/managed-android/agent-bindings/{binding}/applications/{application}/evidence`。

- GET：读取状态；POST 后缀 `/refresh`：显式核验。
- 响应 12 字段：bindingId、applicationId、state、reasonCode、version、profileScope、systemControlAvailable、reportedAt、retrievedAt、expiresAt、nextRefreshAt、controlOperations。
- 时间为可空毫秒整数；数值必须在 JavaScript 安全整数范围内。ABSENT 的 version 为 0，其他证据记录版本为正。
- 对外状态：ABSENT、PENDING、WAITING_REPORT、FAILED、REJECTED、STALE、VERIFIED_IDENTITY。不能把库内 VERIFIED 当成接口状态。
- controlOperations 元素精确为 kind/effect/permission 三字段，唯一，最多 128 项。复用已审查的操作校验及 39 项权限显示词表，不扩大规则编辑器权限选择。
- 只有 VERIFIED_IDENTITY、MANAGED_APPLICATION_CONTROL_VERIFIED、PRIMARY、true 及完整有效操作/时间组合才展示当前可尝试范围；它不代表已执行。
- 目录 GET `/tenants/{tenant}/applications?limit=50[&cursor=…]`，按用户操作加载下一页，校验重复 ID、重复游标及页结构。搜索标明范围为已加载目录，不伪称全库搜索。

## Review Focus

1. 同一帧切走又切回身份/租户/角色：旧弹窗永久失效，旧回调不能恢复权限或发送物理请求。
2. POST 超时或响应非法：先 GET 核对；冷却到期不能解除未知结果或 PENDING 状态。
3. 外层关联变化及 412：隐藏旧应用证据，重新读取父关联，由用户确认后重新进入，不能静默换版本 POST。
4. 开着弹窗跨过 expiresAt：操作列表、状态和主按钮同时更新，不保留“条件满足”的过期显示。
5. 硬 401/403 的响应体畸形、过大或读取中断：不能被通用 502/网络异常掩盖而继续使用旧私有数据；REAUTH_REQUIRED 是唯一明确的近期认证恢复分支。

## 文件边界

- Create `apps/guardian/lib/core/managed_application_evidence.dart`：类型、精确解析及固定上下文 repository。
- Create `apps/guardian/lib/ui/managed_application_evidence_controller.dart`：只管理该弹窗的选择、读取、核验、未知结果及永久失效状态。
- Create `apps/guardian/lib/ui/managed_application_evidence_dialog.dart`：目录选择与状态就地展开。
- Create `apps/guardian/lib/pages/managed_application_evidence_entry.dart`：复用 Session/DeviceSubflowScope，绑定父关联生命周期。
- Modify `apps/guardian/lib/ui/managed_agent_binding_dialog.dart`、`apps/guardian/lib/pages/managed_android_page.dart`：仅新增当前有效已核验关联的入口和受控接合。
- Move 未提交的纯 Dart `ui/managed_control_summary.dart` 至 `core/managed_control_summary.dart`，更新预览及其测试导入；不保留转发兼容文件，不复制操作词表。
- Conditional modify `apps/guardian/lib/core/bounded_json.dart`：仅当实际 RED 证明硬拒绝被错误体处理掩盖时，保留原始拒绝状态；先检查共享文件分工并覆盖现有有界读取回归。
- Conditional modify `apps/guardian/lib/core/api.dart`：错误码和关联编号必须分别校验 String 类型；非法值采用 REQUEST_FAILED/null，保持原始 HTTP 状态，不让 TypeError 绕过撤权处理。
- Create 对应 repository/controller/dialog/entry 四个测试文件；修改既有绑定入口和预览提示测试。

### Task 1: 固定上下文读取与契约校验

**Interfaces:** `ManagedApplicationEvidenceRepository` 接收 Api、tenantId、不可变 ManagedAgentBinding、current 回调及拒绝回调；提供 `applicationPage({String? cursor})`、`read(String applicationId)`、`refresh(String applicationId)`。每次请求前后重新校验同一上下文，不借用设备清单包名作 ID。

- [x] 写实际失败测试：`evidence header uses binding version rather than evidence version`、`catalog id is required instead of inventory package`、`all twelve response fields are validated`、`hard denial survives oversized malformed body`、`non string error fields preserve hard denial`。断言 GET/POST 路径与 If-Match 精确、非法响应不暴露操作、拒绝后的物理请求数不增加。
- [x] 在冻结源码中运行，逐项区分行为失败、夹具失败和编译错误，保留原始日志；修正夹具后再次获得真实行为 RED。
- [x] 实现类型/repository；移动共用纯 Dart 操作模型并更新导入。非法 schema 隐藏结果；仅时效届满使用本地过期展示，不将其误报为网络错误。
- [x] 运行该测试及现有 bounded_json、Api、scope、执行控制器撤权、草稿提交、操作词表/预览测试，通过后独立审查请求边界与共享文件最小差异。

**已取得真实RED并修复，保留问题发现记录：** 早期bounded_json的长度超限及响应体中断会掩盖硬401/403；Api.send对非String errorCode/correlationId可能抛TypeError。实际回归证明后，已保留原硬拒绝状态、安全错误码及作用域失效优先级，并取消当前响应而不关闭共享客户端；成功响应超限仍拒绝，正常401 REAUTH_REQUIRED保持主动恢复。原真实RED、夹具错误和完整通过轮分别保留，不能用静态审查替代验收。最终439源完整候选已覆盖现有bounded_json、Api、scope、控制器撤权、草稿提交和操作词表等回归；实际Chrome、构建和可视检查结果以最终公开凭证为准。

### Task 2: 显式操作与恢复状态

**Interfaces:** controller 接收固定 repository 与可注入时钟；公开目录分页、选择、当前证据、busy、unknownOutcome、hasAccess 和明确的 load/read/refresh/check 操作。失效为单向转换；同一时间最多一个操作。

- [x] 写实际失败测试：`post timeout permits only read reconciliation`、`pending remains locked after cooldown`、`expiry hides operations immediately`、`hard denial and role ABA remain revoked`、`version conflict never retries with replacement binding`。
- [x] 运行真实 RED 后，实现状态转换；更换选中应用时不显示前一应用结果，未决刷新期间锁定选择。GET 失败不解除未知状态；GET 确认非 PENDING 后才按 nextRefreshAt 允许显式重试。
- [x] 401 REAUTH_REQUIRED 显示主动安全验证；其余硬 401/403 清空私有内容并阻断当前代所有请求。412 交还父关联刷新流程，禁止在 controller 内更换绑定版本。
- [x] 运行全部 controller 回归，验证计时器/监听器释放及关闭后迟到回调无效果；独立审查控制器不产生执行/发布权力。

### Task 3: 就地应用核验与预览接合

**Interfaces:** `showManagedApplicationEvidence(BuildContext context, Session session, ManagedAgentBinding binding, {required bool Function() parentCurrent})` 由有效关联详情调用。借用父上下文，使用已经验收的弹窗归属关闭机制；返回时不修改任何旧预览快照。

- [x] 写真实失败测试：`verified binding exposes application check only to managers`、`select read refresh without leaving binding details`、`read is safe after uncertain refresh`、`covered dialog closes only its own route`、`narrow view and double text remain operable`、`preview prompt names an existing entry`。
- [x] 实现已核验关联内的“应用核验”入口；主体依次显示目录选择、当前状态/原因/时间、可尝试操作折叠区及单一主操作。未知结果主操作为“查询核验结果”；已有结果主操作为“重新核验”，明确不等于已执行。
- [x] PENDING 只允许查询；FAILED/WAITING_REPORT 显示可理解的原因及下次允许时间。缺少报告不能解释为未安装。429 后先 GET 获取 nextRefreshAt，不凭客户端倒计时盲目重发。
- [x] 更新预览提示为现有导航入口；完成核验后重新生成预览，由服务器重验，不能直接将旧规则状态改成支持。
- [x] 运行入口/弹窗/关联/预览定向回归；最终冻结集成源码，运行完整 Guardian 分析、测试、生产构建并查看宽屏/320px/双倍文字截图。全部通过并核对源码哈希后，精确提交已授权 dev；更新服务仍使用完整验收产物。

## 真实页面接合、重建与返回修复记录

- 早期432源完整浏览器D组实际55成功、2失败，已保留原轮。独立同生产源码的2项诊断证明确认后异步屏障不足，随后仅修正夹具等待，保留原断言；随后以最终完整候选重新验收，结果见最终凭证。
- 真实关联页面新用例暴露4次产品build异常，原3项控制用例成功。父builder每次新建repository使子绑定撤权；已将repository构造移出builder。核心授权撤权仍同步，仅界面刷新在build期间安排到postFrame。
- 独立构建期撤权最终取得1项完整真实TestFailure RED（12秒、自然树0），系统外部pop另取得1项完整真实TestFailure RED（26.9秒、自然树0）。成功pop回调现在仅标记closing/generation，不再次route.finish；host.popped撤权保持。
- 首次窄构建回归虽原生1、自然退出，但finally route.finish混入独立Navigator重入；原runner的VERIFICATION_FAILED保留，不冒充合格RED。更早父关闭首轮180秒超时和强清7进程同样保留为不完整失败，后续两项完整真实RED单独记录。
- 综合旧生产RED只变2个测试文件，437个产品/其他源与原green-r3相同；原dialog26项、entry23项字节保持。build finally使用生产等价的幂等宿主关闭，原新断言不变。
- 新真实page用例7处等待改为有界帧；全部四项断言及原三项用例字节保持。此调整的独立运行因果尚未单独验证，不能据此撤销原page4次产品build失败。
- 完整历史索引见 `.cache/application-evidence-release/history-spec-v4.json`；原始日志/收据/源码及runner哈希固定，原状态不改写。

## 完成判据

只有真实用户路径、异常恢复、权限生命周期、完整回归、生产构建及可视检查均通过，才标记此闭环完成。历史后端833项只记录当时隔离后端阶段；前端定向或完整冻结回归同样不能证明真实EMM提供方、Android真机系统操作或当前服务部署。
