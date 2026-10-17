# 设备执行记录界面实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans. Preserve all shared changes and follow the existing SDK handoff.

**Goal:** 从设备详情直接查看执行进展、事件时间线，并安全取消允许取消的任务。

**Architecture:** 沿用 Flutter Material 3、现有 Api 和设备子流程。协作会话提供严格的模型/Repository 与设备入口；本会话提供界面控制器、弹窗和宿主上下文绑定。控制器统一处理加载、分页、权限失效和取消结果；弹窗负责布局与确认。

**Tech Stack:** Flutter 3.22、ChangeNotifier、现有 HTTP/boundedJson，无新增依赖。

**Spec:** [Flutter 契约](../../managed-execution-flutter-contract.md)

## Global Constraints

- 只显示服务端读取到的状态；只有 APPLIED 表示设备应用成功。
- OWNER/ORG_ADMIN 可管理；AUDITOR 只读；取消需要近期认证和所选版本。
- 切换账号、租户、角色、注册或关闭窗口后丢弃迟到结果。
- 不自动补发取消；结果不确定时本窗口内只读核对，旧 READY 不能证明取消失败。
- 保留其他会话共享修改；验证使用冻结副本；SDK 串行借还。
- 新验证源、输出和临时目录统一放在项目忽略目录 `.cache/managed-execution-ui/`；TEMP/TMP 等仅覆盖子进程。保留原 `.local` 证据；清理前盘点、哈希并检查链接，不删除唯一文件、活动目录或链接目标。

## Review Focus

- 确认期间权限变化：遮蔽私有内容，旧确认无效。
- 跨页重复：拒绝合并，保持已验证列表。
- 事件版本领先详情：保留真实事件，刷新详情后才允许取消。
- 412 和重新认证：清除原确认，读取后由用户再次确认。
- 窄屏、放大字体和键盘：标题/关闭入口可用，内容独立滚动。

## Task 1: 状态与取消边界

Files: 新增 `apps/guardian/lib/ui/managed_execution_controller.dart`、`apps/guardian/test/managed_execution_controller_test.dart`。

- [x] 写行为测试：分页重复、筛选重置、失效/迟到结果、历史注册、只读权限、双击、确认取消、412、近期认证、不确定结果、较新事件。
- [x] 在冻结副本运行 RED，保留实际退出结果。
- [x] 实现 `ManagedExecutionController(repository, registrationId)`，只通过现有 Repository 读写。
- [x] 执行定向测试、静态分析与独立审查。

## Task 2: 列表、详情与时间线

Files: 新增 `apps/guardian/lib/ui/managed_execution_dialog.dart`、`apps/guardian/test/managed_execution_dialog_test.dart`。

- [x] 写行为测试：加载/空/错误重读、筛选、进入/返回详情、窄屏/放大字体、确认、核对和安全验证入口。
- [x] 初始缺库、缺参数属于编译 RED；随后实现固定标题、单列卡片、按需分页、状态文字/图标和逐项事件时间线；编号折叠展示。行为 RED 以单独记录为准。
- [x] 取消确认绑定控制器和所选版本；关闭、替换控制器和 scope 信号使其立即失效。
- [x] 运行测试、渲染检查并记录限制，不将 HTTP 夹具当成真实设备反馈。

## Task 3: 宿主接入与交付

Files: 最小修改 `apps/guardian/lib/pages/console_pages.dart`；AUDITOR 复用 `pages/managed_android_page.dart` → `ui/managed_agent_binding_dialog.dart` 的现有只读关联入口。

- [x] 绑定 actor/tenant/role/generation/device/registration/弹窗生命周期，监听会话变化。
- [x] 审计员使用既有授权关联投影中的设备与注册身份进入只读执行记录。`FleetReads.devices/device` 与现有 access 测试明确排除 AUDITOR，不扩大设备页或档案的读取权限。
- [x] 复用既有 `reauth`，不建立新账号体系，不自动重放写操作。
- [x] 在干净基线上完成离线集成验证、发布构建及截图检查；本阶段不替换当前运行服务。
- [x] 已准备并核对本阶段21个精确暂存路径；共享 console 只加入两个插入块。真实提交及远端结果另存交付回执；区分定向测试、浏览器接通、真实提供方和实机验收。

## 2026-10-17 进度

- 用户已明确授权访问既有 Flutter 缓存锁并继续离线验证；未升级 SDK 或依赖，未更新本机服务。
- 已完成 controller/dialog/entry 与设备详情、只读关联入口接入。共享 console 的其他会话改动按当前原字节保留；冻结验证使用 HEAD 加本轮两个插入块的干净版本，不包含家庭 WIP 或无关格式调整。
- 保留 missing-library/parameter 初始 RED；不将其当作行为通过。事件最高版本保留和筛选列表更新三个行为回归已实际 RED 后修复。
- 浏览器加载超时已定位：Flutter3.22 的请求处理器匹配 `host.dart.js` 子串，将新应用模块误当测试宿主。浏览器日志实际捕获模块 undefined；将新入口改名为 `managed_execution_dialog_entry.dart`，未改 SDK。旧超时与资源前置失败记录均保留。
- 新增首次 builder 前父上下文失效/恢复的行为用例，实际 RED 出现一次不应发生的 GET 后，提前注册同步监听修复。修复独立静态复核 C0/I0/M0。
- green-r8 实际 VM48项（含键盘/320px/字体2）与浏览器宿主11项通过，0失败/错误/跳过；原生退出0，自然进程树归零，冻结421源未变。
- green-r9 最终精确421源：与 HEAD2284c25 比较，仅本轮十个文件不同；单文件格式只读检查与全量分析原生退出0、自然树0，No issues found。59项行为通过的生产字节保持一致，仅测试加13对规范花括号及共享入口的无关格式清理不同。
- SDK 已归还 Root，串行执行最终回归、发布构建和截图检查；索引仍 Root 且空。以最终交付证据记录实际结果。
- 当前服务检查实际退出0（会话89495），六容器健康；本轮未验证管理员再次登录、真实提供方或实体设备，不宣称全产品验收完成。

## 最终离线验收

- 按 1.0.0 设计实现，无新增历史兼容层、迁移脚本或依赖。
- 与当前 HEAD `2acf8d824094831af17448963cbcc83eef4d6c9b` 独立核对421个冻结源；差异只包含本轮9个完整文件及共享 console 的两个插入块（16增、0删）。家庭开发内容不纳入本轮候选。
- guardian 全部88个测试文件实际通过：745项 VM、214项 Chrome，共959项，0失败、0错误、0跳过。定向执行记录用例为59项，已包含在上述总数中。
- 全量静态分析退出0、No issues found；发布构建退出0。所有通过阶段的进程树自然归零，冻结源哈希未变。
- 原 browser-b 180秒超时保留，拆分后的 b1/b2/b3 全部通过；b3 首次缓存锁权限失败也保留，不记作业务断言失败。
- 独立合成界面驱动通过1项、生成7张原始 PNG，已逐张检查；包含桌面、320px两倍字体、时间线、取消确认和结果待核对。图像不证明真实设备执行。
- SDK 已移交安卓协作会话的两段验证窗口；Root 只整理精确提交及服务只读检查。
- 证据：[验收记录](../../evidence/managed-execution-console-20261017.json)、[图像与说明](../../artifacts/managed-execution-ui/README.md)。本轮未激活新构建。
