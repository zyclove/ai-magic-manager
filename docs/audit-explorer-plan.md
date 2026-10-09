# 审计查询工作台实施记录

依据：既有 implementation-plan Task 7/10 与 RPT-01。当前阶段完善只读审计调查，不代表异步加密导出、删除治理或完整报告交付。

## 合同与裁定

- 保留旧 `/audit-events` 的 ID 游标合同。新增 `/audit-events/search`，按发生时间、事件 ID 倒序分页；每次请求重新检查当前成员权限（OWNER/GUARDIAN/ORG_ADMIN/AUDITOR）。
- 必填 from/to 为毫秒时间戳，左闭右开，最多 366 天；limit 1–50。可选 action（规范大写操作码）、resourceId（规范 UUID 或既有 64 位小写 actorKey）、correlationId（规范 UUID）。筛选与租户绑定的版本化游标只能续查同一条件。
- Ruling: 本轮不提供操作者文本搜索 — 身份标识大小写必须精确，当前跨数据库排序规则未统一；详情保留服务器返回的原始操作者标识。
- Ruling: 复用现有 Flutter Material 设计体系 — 已有 12ui 外部服务地域拒绝，不重试或绕过。默认最近七天，支持日期范围、操作、资源和关联编号，明确本机时区，最新记录优先，详情可复制。
- 查询不创建业务记录。显示刷新/加载/空/失败/无权限状态；换工作空间后隐藏旧记录与详情；查询和详情均重新授权。既有运行 V21 服务保持在线直至候选验收。
- 只读查询不是事务快照；明确查询时间上界，刷新回第一页，游标不是授权凭据。
- 不改动正在并行实施的儿童宿主和设备接入文件，不代替用户提交或推送。

## 任务

1. 后端真实 HTTP 测试先复现缺失接口；实现验证、过滤、倒序游标、详情、权限隔离。
2. 前端模型和响应验证、筛选列表与详情、过期响应和权限变化保护；组件测试先行。
3. 独立候选验证、一次独立审阅、运行更新和真实账号只读确认；记录证据与限制。

## 进度

- 2026-10-10：确认 3000/8082 为 200；V21 运行版本未变。开始任务 1。
- 后端首次 6 项因缺路由 404 失败，`.local/audit-backend-red.log`。实现后发现测试将 BIGINT 写入成员撤权 TIMESTAMP 字段，修正夹具为 Timestamp；最终 6 项通过，`.local/audit-backend-green-final.log`。
- 前端首次因缺模型/组件失败，`.local/audit-frontend-red.log`。翻页失败重试检查真实复现 `[null,next,null]`，`.local/audit-retry-red.log`；保留原目标游标和方向后完整 76 项通过，分析无问题、HTML release 构建通过。
- MySQL 6 项通过，`.local/audit-mysql.log`；独立随机库与用户已清理，无业务库写入。浏览器 1440/390 布局、详情、翻页原请求重试、筛选、掉线、撤权、教师拒绝通过，`.local/audit-browser-second.log`。首次脚本未聚焦 Flutter 输入导致筛选未输入；改为真实聚焦/键盘输入并等待筛选响应后通过，没有修改产品来迎合脚本。
- 一次独立源码审阅发现 P2：旧事件以 actorKey 为资源，UUID-only 筛选拒绝合法值。接受此发现；补前后端 64 位资源回归。前端真实 RED，`.local/audit-resource-frontend-red.log`。审阅未执行测试，未评价 MySQL 容量性能、服务器主动撤权推送、完整屏幕阅读器或儿童宿主。
- 后端 actorKey 专项真实 RED：期望 200，实际 400，`.local/audit-resource-backend-red.log`。修复后最终前端 77 项通过，分析无问题；37.5 秒 HTML release 构建成功。最终浏览器含真实键盘输入 64 位资源，`.local/audit-browser-final.log`，无页面异常。
- 最终隔离 MySQL 7 项通过，0 跳过，2026-10-10 03:24:37，`.local/audit-mysql-final.log`；随机库和用户清理成功。原始完整后端 275 项通过，`.local/audit-backend-full.log`，但该产物早于审阅修复，不能作为最终发布证据；正在重新验证修复后的完整候选。
- 211 个本阶段后端/前端主源码与候选一致；明确排除并行 DeviceAccessContextController/Service，本轮没有把未纳入验证的儿童上下文实现覆盖到运行后端。校对输出 `.local/runtime/audit-source-hashes.json`。
- 后续基线更新：`08a0e1ac3d2245103be94439d47b6eb711da7888` 已提交儿童访问上下文与加密存储基础。为保证候选包含最新已提交后端，识别并停止旧候选自身的四个验证进程；未停止 3000/8082 运行服务。中断日志保存在 `.local/audit-backend-full-superseded.log`，不计作通过。
- 纳入该提交的两个后端主文件、上下文测试与扩展 HTTP 互通测试后，213 个主源码全部与工作区一致，无排除项。审计 + 设备上下文在 V21 下真实 MySQL **14 项通过、0 跳过**，03:27:51，`.local/audit-mysql-final.log`；临时库和用户清理完成。重新执行最终完整集成回归。
- 最终完整后端 **283 项通过、0 失败、0 错误、0 跳过**，03:33:37，`.local/audit-backend-full-final.log`。显式启用四类 Spring/Dart 设备 HTTP 互通；基线 08a0e1a + V21 通知 + 本阶段审计查询。

## 已部署与收尾（2026-10-10 03:34）

- 前端 `http://localhost:3000/audit`；后端 `http://localhost:8082`，PID 29028。原运行 JAR 与 Web 已备份到 `.local/runtime/backend-before-audit-20261010-033402.jar`、`.local/runtime/frontend-before-audit-20261010-033402`。
- 后端候选/运行 SHA256：`B8DD940723E226CE50B10B09C68F466CC558FA87E9AE9063A7494725F37AB30E`。
- 前端候选/运行/HTTP 实际文件 SHA256：`CB3F5F26AE568A9A141DB53DF62E6D6D84F47739483EAB9F295F1C8052F91D48`。
- 本轮无迁移；运行库 V1–V21 连续成功。旧通知阶段数据库备份信息保留在原 metadata 中，不冒充本轮新备份。
- 真实管理员密码登录为 OWNER；三个工作空间分别读取到 1、1、5 条既有事件，列表、详情、资源+操作+关联筛选均 200 且匹配，无业务写入。`.local/audit-live-admin.log`。既有数据没有被演示数据替换。
- 运行 3000 再次通过桌面/手机隔离浏览器场景，`.local/audit-browser-deployed.log`；真实账号与响应夹具是两类分开的证据，均无页面异常。
- 一次独立源码审阅指出的 P2 已通过前后端 RED→GREEN、完整回归及真实 MySQL 消除。没有声称审阅者复查了修复或运行过测试。
- 本阶段只读审计查询交付完成。异步加密导出、报告、删除/保留、设备端完整执行及其他总计划范围继续进行，整体目标未完成。
