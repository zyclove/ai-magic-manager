# 审批详情与精确时长：静态阶段

日期：2026-10-26。基础提交：`c85c084bf55f2930afdd3a79fd880da619a7d82b`。状态：源码与规格收尾；离线依赖解析、Dart 格式化/分析、测试与实际交互验收均未运行，未推送或更新服务。

批准申请时，管理员现在可在详情及表单看清对象、设备和应用；名称缺失时保留完整编号。列表展示上下文先复制为独立字符串，只有与新读取的请求、主体、设备、应用及提供的注册周期引用全部匹配时才能带入名称。审计视图不捕获名称。当前状态、时长、版本和操作目标以通过校验的单条响应为准，请求编号不符或核心字段非法时拒绝打开操作。

新增纯领域模块 approval_decision，集中七种状态、不可变申请快照、精确时长展示和规范批准正文。列表和详情不再把余秒向上取整；95 秒显示为“1 分钟 35 秒”。批准表单以“分钟＋秒”完整回填申请值，通用 FieldSpec 可选整数上下限就近报错，合计在 HTTP 前校验为至少 1 秒且不超申请值。只向原接口发送不可变的 decision 与 grantedWindowSeconds 两字段，保留原版本、幂等键、近期 MFA 和未知结果输入冻结/重试机制。

待处理详情不再等待交付摘要读取；其他状态保留原摘要及交付历史。继续说明当前仅保存限时窗口、设备尚未执行，不改变后端协议、批准截止计算或设备执行能力。界面沿用既有 Material 表单与对话框，没有新依赖。

## 检查事实与最小接续

- 已静读类型边界、决定表单与现有恢复机制，核对相关差异、空白和本地文档链接；独立静态接线审查未发现可证明的问题。nullable 交付分支、提交前范围/合计校验、原作用域和请求冻结机制已核对，不能据此声称运行通过。
- 新增 4 个待运行回归：上下文脱离原行及完整引用绑定；精确秒数转换和越界拒绝；通用整数范围失败后可修正提交；批准操作从 90 秒初值拒绝 91 秒，再只提交 45 秒规范正文。既有列表分页用例增加余秒显示断言；既有批准/拒绝/撤销及通知详情夹具补齐真实必需的应用引用，并区分待处理不读取交付摘要。全部未运行。
- 遵循用户静态完善安排，没有启动 SDK、格式化器、分析、测试、构建、真实 API 或资源采样。既有 2 GiB 门槛未降低，本次源码检查不证明编译、渲染或业务验收通过。

窗口恢复后先接续已有离线依赖解析，再格式化/分析本批 10 个 Dart 文件；运行新增定向用例及受影响的既有决定、工作台和通知作用域旅程，不重复无关后端或全仓库套件。权威业务语义见[访问申请契约](../access-request-contract.md)。

本次源码摘要（静态候选定位，不代表运行通过）：

- `apps/guardian/lib/core/api.dart`：`d9159472d382e9154f82ab51680867ce0bb752bfca7df92e132af04399177a3e`
- `apps/guardian/lib/core/approval_decision.dart`：`2ec30a964a5128fae1e14b4a12474e0802e5193a870bfea4cb40e2342a9ce0ba`
- `apps/guardian/lib/pages/access_requests_page.dart`：`fcd5e05ece2bbc428090babee83e8c5bf819dd8e200208e28c4af50fe89b1205`
- `apps/guardian/lib/pages/console_pages.dart`：`32797701cd496b378a94e568a4059de6dd9f918c3467153be549082d53a59f5e`
- `apps/guardian/lib/ui/design.dart`：`fb77a0be0443335363d3fde5f45e864630a490abc2fbe367b1c7ebad3a80aecf`
- `apps/guardian/test/access_requests_page_test.dart`：`5aca03ff6b32826b9f4349f1e33ec018cfaca5b6fdc32e0d08cc7040f5742728`
- `apps/guardian/test/approval_decision_test.dart`：`03a900e12fd0c29037d98adaff29f5768675a0f926f04709724587553724d4f8`
- `apps/guardian/test/approval_help_flow_browser_test.dart`：`35e717f215965edf31adc8e6c69be92de72728f2e769afa7f3901bf0f5fc09aa`
- `apps/guardian/test/dialog_submit_guard_test.dart`：`2ecad15570a9d5e104f4dcd8ad3d7451b443e4cc3d3ab43385a154007e3fcccb`
- `apps/guardian/test/notification_help_scope_browser_test.dart`：`a7fc747ac47a560f8c59c975d9a64e4cec863956264f8235947527ecd2a8736f`
