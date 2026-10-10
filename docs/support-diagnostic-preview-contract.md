# 管理员诊断预览接口与验收边界

本接口是诊断阶段的即时读取基础，不是远程支持授权或诊断包下载。完整计划见 [support-diagnostics-plan.md](support-diagnostics-plan.md)。

## 请求与授权

`GET /api/v1/tenants/{tenantId}/devices/{deviceId}/diagnostic-preview`

- 使用 OIDC 管理员访问令牌；数据库当前角色必须为 OWNER、GUARDIAN 或 ORG_ADMIN。
- 使用既有近期多因素认证规则。普通密码登录不能代替近期多因素认证。
- 当前成员关系、未归档档案、设备绑定与注册周期都要重新检查。撤销设备允许查看脱敏历史状态，不恢复设备凭证、采集或控制能力。
- 成员、档案、设备、配置头和当前下发记录保持事务锁，直到允许字段完成序列化并写入读取审计。提交成功后返回相同字节，避免提交后再次访问模型。
- 不接受客户端指定的 correlationId；沿用服务端生成的请求关联标识。

## 成功结果

HTTP 200，`Content-Type: application/json`，`Cache-Control: no-store`，`Vary` 包含 `Authorization`（可以同时包含 CORS 的其他项）。

| 字段 | 语义 |
| --- | --- |
| schemaVersion | 当前为 1 |
| generatedAt、correlationId | 服务端生成时间及本次请求关联标识 |
| scope | 租户、设备、当前注册周期的标识，不含儿童档案名称 |
| versions | 系统、Agent、服务端的严格数字版本；未知为 UNREPORTED，自由文本版本为 REDACTED |
| device | 平台、设备状态、管理模式、能力等级、心跳观察状态与时间 |
| capabilities | 已知能力键、设备自报支持、授权状态、证据来源与时间、限制码 |
| omittedCapabilityCount | 未知能力键的数量；不输出未知键的原文 |
| configurations | 当前注册周期的当前配置元数据、不可变策略哈希、配置哈希、收到／保存自报时间及允许的拒绝码 |
| evidenceStatus | DEVICE_REPORTS_NOT_EXECUTION_PROOF；这些数据不证明系统已执行策略 |

版本允许 1–4 段数字，每段 1–4 位。未知枚举转换为稳定未知值，未知拒绝码为 UNKNOWN_REJECTION；不返回原文。哈希必须为 64 位小写十六进制，否则不输出。异常观察时间不展示为有效证据。到期且没有保存确认、也没有拒绝记录的下发显示 EXPIRED_AWAITING_PULL。

数据库读取不获取配置正文、签名原文、回执正文或策略快照。响应不包含设备显示名、儿童自由文本、完整 URL、令牌、密钥或原始媒体。

## 容量和错误

原始报告能力最多 64 项，加入既有默认能力后最多 70 项；当前配置最多 100 项；最终 JSON 最多 512 KiB。超过上限明确拒绝，不返回部分诊断。

| 状态／错误码 | 客户端处理 |
| --- | --- |
| 401 REAUTH_REQUIRED | 引导已有多因素重新认证流程；不得保留旧诊断内容 |
| 403 SCOPE_DENIED | 清除当前结果，提示当前账号或档案已不允许读取 |
| 409 DIAGNOSTIC_SCOPE_CHANGED | 清除结果并重新加载设备绑定，由用户重试 |
| 413 DIAGNOSTIC_TOO_LARGE | 提示诊断范围超过容量限制，避免自动重试 |
| 502 DIAGNOSTIC_SOURCE_INVALID | 提示诊断来源不完整，展示稳定请求关联标识供排查 |
| 502 DIAGNOSTIC_SERIALIZATION_FAILED | 提示暂时无法生成诊断；不显示内部异常文本 |

成功读取记录 DIAGNOSTIC_PREVIEWED。拒绝、容量错误或序列化失败不会记录为成功读取。此文档不声称所有失败请求都有业务审计事件；请求日志仍遵循既有无敏感内容记录方式。

## 已取得的证据

- `.local/support-diagnostic-projection-red.log`：投影模型和读取端口尚未实现时失败。
- `.local/support-diagnostic-projection-boundaries-red.log`：已送达未保存的过期状态和空能力键，两项断言失败；修正后通过。
- `.local/support-diagnostic-preview-red.log`：接口未实现时，预期 200 实际 404。
- `.local/support-diagnostic-preview-boundaries.log`：24 项通过，包含 8 项投影、15 项 HTTP 权限／容量／并发集成、1 项模块边界检查。
- `.local/support-diagnostic-mysql.log`：相同 24 项在独立 MySQL 数据库通过；临时数据库和用户已清理。
- `.local/support-diagnostic-client-final.log`：Flutter 管理端模型／请求层 18 项通过。模型绑定租户、设备和注册周期，只保留允许的类型化字段；请求禁止重定向、限制响应为 512 KiB，丢弃过期工作空间结果，超时和超量时取消读取且不关闭共用认证客户端。
- `.local/support-diagnostic-client-analyze-final.log`：诊断客户端及其测试静态检查无问题。
- `.local/support-diagnostic-ui-client.log`：界面与客户端合计 25 项通过；新增 7 项覆盖显式读取、重复点击、前后台清理、晚到响应、权限变化、重新认证和 360 像素布局。会话弹窗已编写，尚未接入设备菜单。
- `.local/support-diagnostic-ui-analyze-final.log`：模型、请求、界面、会话弹窗与测试静态检查无问题。
- 完整后端第一遍的本次 Surefire 报告为 419 项、0 失败、0 错误、1 项原生门控跳过，但 Windows PowerShell 5 运行器把 JVM 环境提示当作终止错误，未保存 Maven 最终退出码。该次不作为完整门禁通过；已修正运行器，使用 `.local/support-preview-backend-full-final.log` 重跑并另存退出码。
- 最终 `.local/support-preview-backend-full-final.log`：419 项、0 失败、0 错误、1 项原生门控跳过，即 418 项通过；BUILD SUCCESS，完成时间 2026-10-10 13:47:31。`.local/runtime/support-full-exit.json` 保存真实退出码 0。
- 最新 `.local/support-diagnostic-ui-client-final.log`：26 项通过，在此前 25 项基础上增加失败响应请求标识的安全展示；对应静态检查仍无问题。尚未以真实浏览器验收，也未在当前 3000／8082 服务部署。

上述早期证据现由下列入口与真实 HTTP 联调补充。身份事实仍由隔离测试注入，不能作为真实用户已完成 OTP 的证明。限时接收人配对、支持授权、加密诊断任务、下载与过期清理仍待本阶段后续实施；完整阶段审阅也尚未进行。本次新增接口尚未部署到 8082。

## 设备入口与真实客户端联调（2026-10-10）

- 设备详情已接入“诊断预览”，仅 OWNER／GUARDIAN／ORG_ADMIN 展示；打开窗口不自动读取。会话主体、工作空间或角色变化会作废当前窗口；服务端每次读取仍以当前数据库授权为准。
- `DiagnosticPreviewJourneyTest.productionDartClientReadsRealHttpAndRechecksCurrentAccess` 启动随机端口的真实 Spring HTTP 服务，由管理端 `tool/verify_diagnostic_http.dart` 调用生产请求层与模型。初始读取、弱认证、外部成员、预期注册不符、撤销设备只读元数据、新注册不继承旧配置、档案归档和成员撤权均已覆盖，同时核对无缓存响应与成功读取审计数。测试使用受控 JwtDecoder，不冒充真实 IdP 多因素认证。
- `.local/support-diagnostic-http-red.log`：真实端点旅程首先因客户端工具缺失而失败；`.local/support-diagnostic-http.log`：完成工具后 25 项通过、0 跳过，包括 16 项旅程、8 项投影和 1 项模块边界。
- `.local/support-diagnostic-http-mysql.log`：相同 25 项在独立真实 MySQL 通过、0 跳过；运行器日志确认临时数据库与用户已清理。没有修改当前业务数据库。
- 浏览器检查发现 Flutter HTML 渲染下 SelectableText 的诊断值在辅助技术中呈现为空编辑框。已替换为 Flutter SelectionArea 包裹只读 Text，保留文本选择并暴露可读取的语义标签；`.local/support-diagnostic-accessibility-red.log` 留存失败断言，`.local/support-diagnostic-client-accessibility.log` 的 27 项客户端与界面检查通过。
- `.local/support-diagnostic-browser.log`：独立 3021 预览的 16 类检查通过，包括设备入口、显式读取、配置展开、重新认证提示、旧数据清除、错误注册、容量错误、防重复点击、关闭后的晚到响应、手机空态／脱敏／长指纹以及各角色权限入口；浏览器错误和未处理接口均为 0。接口响应为隔离夹具，不与上述真实 Spring HTTP 旅程混称为单一端到端登录验收。
- `.local/support-diagnostic-lifecycle-browser.log`：真实 Chrome `document.visibilityState` 前后台切换的 5 项检查通过，覆盖已展示结果与展开指纹清除、后台及回到前台后到达的旧响应丢弃、认证错误与请求标识清除、恢复后显式新读取。关闭了浏览器测试框架默认的焦点模拟，没有伪造页面生命周期事件。
- 手机截图还发现缺失配置指纹的占位文字相对策略指纹居中，`.local/support-diagnostic-alignment-red.log` 记录左边距 137.25／20 不一致；改为展开内容撑满行宽后，字段统一左对齐。最终 `.local/support-guardian-full-final.log` 为 184 项通过，`.local/support-guardian-analyze-final.log` 静态检查无问题，`.local/support-diagnostic-browser-build-final.log` 发布构建成功。
- 浏览器交互与真实前后台检查在最终构建上重跑，结果记录实际 HTTP 获取到的 `main.dart.js` SHA-256，并与本地构建比对。`.local/runtime/support-preview-integration-checkpoint.json` 汇总 21 个诊断源文件与验收记录；原 418 项完整后端回归发生在新增真实 HTTP 旅程之前，当前生产后端诊断源文件未变，新旅程及随机端口测试配置以本轮 H2／MySQL 各 25 项为证，不冒称已重新运行所有后端用例。
- 当前运行的 3000／8082 仍为原 V22 服务；以上诊断代码在隔离候选验证，没有替换现有服务、迁移业务数据库或生成支持授权。

## 当前服务恢复

2026-10-10 13:49 的检查发现原 3000／8082 进程已经停止，8081 身份服务与 3308 数据库仍在。核对原 V22 前后端文件 SHA-256 及数据库 V1–V22 连续成功后，依据用户既有启动授权恢复原版本；未替换产物，后端本次启动显式禁用 Flyway 迁移执行。恢复记录为 `.local/runtime/v22-restored-runtime.json`。

恢复后前端 HTTP 200、后端健康 UP、身份服务 HTTP 200。`.local/support-restored-v22-admin.log` 记录管理员真实密码登录成功、OWNER 身份及现有 3 个工作空间的只读审计访问成功，无浏览器错误；该检查没有业务写入，也不是 OTP 验证。新报表版本替换及 V25 数据升级仍保持待用户明确授权，不能把此次原版本恢复误记为新版发布。
