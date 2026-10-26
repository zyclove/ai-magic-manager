# 受控列表路由与申请待办直达

日期：2026-10-26。基础提交：`10300491eb84ac0dd53ad5c947e75ef3390debb0`。状态：静态候选；依赖解析、Dart 格式化/分析、测试、构建和实际路由验收未运行，未推送或更新服务。

设备连接筛选先前用独立布尔值穿过 Entry、Shell 与页面，访问申请仍在页面本地维护筛选；儿童/教师/审计员从待处理提示进入后会回到默认全部。本批统一为 ConsoleListView 与固定位置契约，工作台申请任务直达 `/approvals?state=PENDING`，切换全部使用 `/approvals?state=ALL`。普通无参数入口仍按角色选择默认视图；此视图不增加审批权或扩大本人/审计范围。

console_routes 集中三个固定过滤地址、严格的单键单值解析和角色默认，供路由与精确回跳白名单共用。设备组件仍只接收所需的布尔选择；Entry→Shell→ConsolePages 传递统一枚举，不继续增加每种筛选的专用路由字段。解析只适用于对应路径；空、未知、重复或附加参数回到自动视图，不能被当作已支持筛选。登录只放行明确字符串，不用 URI 解码/归一化扩大返回地址。

AccessRequestsPage 现在必须接收宿主的 pendingFilter 与筛选事件，删掉本地默认/受控双模式；唯一生产入口按路由持有选择，页面 key 包含视图，旧页及游标不会进入新视图。现有隔离测试迁移为受控宿主，原分页、只读、失权及迟到读取断言保留，没有为保留旧测试 API 留下重复生产状态。

UI 的 ALL 仅表示查看全部，后端读取省略 state，不发送不受支持的 ALL 枚举。现有 state=PENDING 接口、实际状态接纳谓词、近期 MFA、幂等与版本保护都未改变，没有后端或新依赖改动。

## 检查事实与最小接续

- 独立静态审查核对枚举贯通、两个设备/申请视图、工作台位置与精确登录回跳；再次核对成对筛选改为必填后的两个构造调用，未发现可证明问题。根会话核对控制权、原角色默认及只读请求约束。
- 新增恰好 2 个待运行用例：1 个纯路由聚合回归覆盖固定地址、角色默认、未知/空/重复/附加查询及路径不匹配；1 个使用真实 ConsolePages 的儿童浏览器旅程，从待处理提示进入 PENDING 再切换全部，断言只 GET、第二次省略 state、角色保持。已有回跳与任务用例扩充固定位置断言，原工作台/列表用例保留。全部未运行。
- 按用户安排没有启动 SDK、格式化器、分析、测试、构建、真实 API 或资源采样；2 GiB 门槛未降低。历史通过结果不覆盖本批，静态检查不证明可编译、实际显示或登录/路由验收通过。

窗口恢复后先接续既有离线依赖解析，格式化/分析本批 12 个 Dart 文件；运行新增定向用例与受影响的既有访问申请列表、回跳、概览和设备路由用例，不重复无关后端或全仓库套件。权威交互语义见[访问申请契约](../access-request-contract.md)。

本次源码摘要（静态候选定位，不代表运行通过）：

- `apps/guardian/lib/core/console_routes.dart`：`746f465a7476fb43d97f8fae36752fc75dc25127772087c1897d52ea8798ac8c`
- `apps/guardian/lib/core/console_modules.dart`：`8f9bee8cdb855cde655119502b7612d6df0e236cba7231efa9089c1468edd4f1`
- `apps/guardian/lib/core/overview_attention.dart`：`fa84a011599aa5e63330e9e070f9295a7a9437e923c316a46f39b01c36d3b260`
- `apps/guardian/lib/main.dart`：`580496ed7807f8bd39aee1fd6abb75c95476501e042c649f89530e9b6ea25da0`
- `apps/guardian/lib/ui/shell.dart`：`7e2d803fb4939bb77270e72a3e5d5d2885b7d2e02dcd1a816b81f77bc471dbcf`
- `apps/guardian/lib/pages/console_pages.dart`：`87846b100087de19220c998154120e0b470a966fae0cd5713799973ab5409395`
- `apps/guardian/lib/pages/access_requests_page.dart`：`7c1435b1924fb8567f0357102c28111224189e0f98fc26f3ac609dbf39e65e10`
- `apps/guardian/test/console_routes_test.dart`：`1c2633a9e14a409c4f626a30e078d514420dcf2273e59867eb14fa1cb47ec673`
- `apps/guardian/test/access_test.dart`：`9e1de98c905134b7cf2cf35c13379d76d72064675a6040bf915344ce2d77f4f7`
- `apps/guardian/test/overview_attention_test.dart`：`b5293075c8a6fd3d7b37fd02a72a7db7b50d118524a00880f39d5beab55e707e`
- `apps/guardian/test/scoped_overview_page_test.dart`：`48c8edbc1dc066222f41af505843c2a6bdda5455738289408849c89ae7f46af9`
- `apps/guardian/test/access_requests_page_test.dart`：`2088b28d84b2f61c22b9194b27043391082d0ff959886604bfa555d065645da8`
