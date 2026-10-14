# 手机每日共享额度：实现与验收

2026-10-14，代码及本阶段定向验证已完成。依据已批准完整产品设计，补齐手机成人端每日额度工作流。

## 产品流程

策略中心 → 每日共享额度 → 分页目录 → 余额/账本 → 增减额度；新建时选择儿童、总额或单应用范围，由服务端提供该儿童的额度时区及当前日期，再选择日期与分钟数。复用 Flutter Material 控件和现有分页、安全存储、近期认证以及 Spring 额度领域，不引入新依赖。

余额将已结算、待确认预留、可分配分开展示；不将账本余额写成设备实际使用时间或系统已经执行限制。每日额度与每周可用时段是不同规则。重复额度计划仍属于完整目标，后续接入手机端；此阶段只交付每日池的完整操作。

## 安全与恢复契约

- 服务端继续用成员事实、主体范围、近期 MFA、强版本和幂等键约束写入。
- 写入前将原请求、操作类型、资源版本及 UUID 请求编号保存至安全存储；失败则不发请求。
- 同一租户/成人一次仅处理一项待核对额度操作。未知结果不自动重发，也不允许编辑原请求。
- 原结果查询返回 `committed`（原操作成功时的快照）与 `current`（当前账本）两份数据，避免把历史余额当成最新余额。
- 查询路径：POST `/api/v1/tenants/{tenant}/quota-pools/creation-results/{requestId}/query`；POST `/quota-pools/{poolId}/adjustment-results/{requestId}/query`（相同 tenant 前缀）。正文必须与原请求完全一致，调整还需原 `If-Match`。
- 查询不要求新的 MFA、不变更额度；仍检查当前成人成员和未归档主体，响应 no-store。原请求属于别的操作者不可恢复；正文不匹配为 409。404 只说明没有可读取结果，不证明原操作未提交。
- 已知 401 近期认证不足或其他失败，仍保留原请求用于核对。用户可重新安全验证，然后明确重试原请求；始终使用原幂等键及原版本，绝不自动生成新写入。
- 退出或换工作空间关闭旧页面；离开后不接受晚到结果。安全存储中的原操作留给原成人重新登录后核对。

## 验收范围

| 检查 | 结果和证据范围 |
|---|---|
| 手机及已有策略回归 | 42 项通过：`quotas_test.dart`、`policy_editor_test.dart`、`policy_creation_test.dart`、`schedules_test.dart` |
| 后端额度回归 | 14 项通过：`QuotaOperationRecoveryTest`、`QuotaJourneyTest`、`QuotaConcurrencyTest`；隔离快照为 `4334bf2` 叠加本功能后端文件，未混入另一任务正在修改的额度测试 |
| Flutter → Spring 真实 HTTP | `ParentQuotaHttpInteropTest` 启动回环服务并运行 `tool/verify_quota_http_test.dart`，通过；实际丢弃已提交创建/调整的成功回复，重建客户端控制器后恢复及重试，数据库最终仅 1 个额度池、3 条账本记录、4800 秒额度 |
| 本地记录 | 失败写盘不发请求；恢复操作固定原 key/body/version；原操作者独立存储；确认后才清除提醒 |
| 角色与界面 | 审计员只读且无写按钮；分页账本；同身份新会话代次也关闭旧确认弹窗；390×844、1.5 倍字体下的余额与调整控件交互无布局异常；创建流程在 1000×1900 验证 |
| 静态检查 | 新增模型、界面、策略入口、测试与 HTTP 工具的 Dart 分析无问题 |

后端测试使用 H2 MySQL 模式；真实 HTTP 测试使用显式 JWT/MFA 夹具和内存存储替身。只有网络、Spring 业务/事务以及生产 Flutter 控制器是真实链路，不能作为真实 IdP、OTP、Android Keystore 或实际设备计时/停止能力的证明。UI 测试为控件和布局检查，尚未进行此页面的人工视觉审查。

复现方式：

- `apps/parent`：`flutter test test/quotas_test.dart test/policy_editor_test.dart test/policy_creation_test.dart test/schedules_test.dart`。
- `backend`：`mvn -Dtest=QuotaOperationRecoveryTest,QuotaJourneyTest,QuotaConcurrencyTest test`。
- 真实 HTTP：指定 `parent.dart.command` 为本机 Dart 可执行文件、`parent.flutter.tool` 为 Flutter tools snapshot、`parent.package` 为 parent 目录，再运行 `mvn -Dtest=ParentQuotaHttpInteropTest test`。缺少显式参数时该可选旅程跳过，不得将跳过当通过。临时测试凭据只通过子进程环境传递，不落源码或参数日志。

本阶段未新增依赖、数据表或数据库迁移。原写接口继续写业务审计和账本；只读查询复用请求关联日志，不记录请求正文、姓名或 token。异常配置、未知字段和实际权限仍由后端再次验证。父母端支持失败重读、手工重试原请求、分页、中文错误说明及静态响应校验，异常数据不会被当成零余额。

## 实现文件

- `apps/parent/lib/core/quotas.dart`：输入/响应验证、余额模型、安全存储和原操作恢复控制器。
- `apps/parent/lib/ui/quota_center.dart`：额度目录、余额、创建/调整、分页选择器、账本和恢复面板。
- `apps/parent/lib/ui/policy_center.dart`：手机策略中心入口。
- `QuotaController` / `QuotaService`：两类只读原操作查询，保留已提交快照并单独读取当前账本。

不宣称真实系统额度执行、正式签名 APK、真实 IdP/Android 端到端、MySQL/OceanBase 生产验证或完整产品交付已经完成。

本轮没有替换已有本机运行服务或向业务库写入额度；需后续明确发布这批前后端产物，再验收实际安装环境。
