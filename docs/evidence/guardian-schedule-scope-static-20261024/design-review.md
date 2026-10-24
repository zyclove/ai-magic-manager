# 时间计划操作范围：静态复核

结论：设计方向成立，无需等待 B6 或 SDK 窗口才能开始下一源码阶段。复用现有 `DeviceSubflowScope` 和 `Api.scoped` 即可；这一轮不需要重构策略编辑器、传输层、后端契约或选择器框架。以下是源码核对与实施建议，未修改产品代码，未运行测试，不计为功能验收。

## 最小修改点

1. **在打开窗口之前捕获范围。** `scheduleEditor` 当前在 editors.dart:28 只捕获 root/timeZone，State 的 current 在66仅判断路由，252的提交直接使用 session.api。入口先按 PolicyEditor:440 的模式检查 authenticated、canWrite、canOpen('schedules')，并在读取 `session.root` 前检查 tenant/context；随后捕获 DeviceSubflowScope，再 push OwnedDialogRoute。把捕获对象借给 State，入口 await presentOwnedDialog 后 finally dispose。直接构造 ScheduleEditor 的既有调用可由 State 建立自有 fallback，并且只释放自己拥有的 scope。
2. **业务范围与覆盖窗口分别判断。** State 的 current 加上永久 revoked 与 scope.current；interactive 继续在 current 之上要求 owner.isCurrent。保存和原内容重试都使用一次建立的 `scope.api.scoped(() => current)`。不要把 interactive 用作传输守卫：另一个窗口覆盖当前窗口时，原请求仍应在其原范围内完成，且只能关闭自己的路由。这是现有迟到成功用例保护的行为。
3. **Widget 替换也必须永久失效。** didUpdateWidget 遇到不同 Session 对象、root 或 operationScope 时 revoke，不自动为旧 State 重新绑定新会话。否则旧输入和捕获回调可能被新 widget 属性重新解释。初始 fallback 的 permitted 应独立检查 tenant 非空、root 匹配、写权限和 section 权限；不要在构造 scope 的 permitted 中递归引用 State.current/scope.current。
4. **同步禁止操作，安全时刷新和清理 UI。** revoke 先同步锁定永久失效；所有保存、重试、字段、选择器返回和请求后回调立即无效。UI 改为只显示范围变化和关闭入口，移除旧输入、错误与 pendingBody；保留一个“本次可能已有未确认提交”的布尔事实，用于提醒以后核对原记录。不要清理 Api 共享 pendingWrites，不把失效或关闭描述为取消服务器操作。借用的 client 不得关闭。
5. **不要在 build 中触发清理副作用。** controller.clear、setState 和 Navigator 的 finish 都可能通知/变更 UI。若失效发生在 persistentCallbacks，先同步 latch，再合并为一次 post-frame 刷新；回调检查 mounted/disposed，避免重复安排。普通安全阶段可直接刷新。已有 scheduler import 可复用；不必照抄 PolicyEditor 的规则目录和多层 lifetime 结构。
6. **失效后仍能准确关闭。** 关闭入口不能先依赖 current/interactive，也不能因旧 busy 阻塞。保留 closeOwnRoute 的准确 OwnedDialogRoute.finish 语义。revoke 时关闭自己持有的 exitRoute，且在安全调度阶段执行；如果它被无关窗口覆盖，finish 只移除自己的关闭确认，不 pop 顶层无关窗口。捕获的旧确认回调继续因 current=false 而无效。现有 dispose 对确认路由的善后仍要保留。
7. **独立处理服务端撤权。** Session 尚未更新也可能收到403、401且非 REAUTH_REQUIRED，或 WORKSPACE_CHANGED。按 PolicyEditor.privateFailure 的现有区分做 revoke；普通400校验失败仍允许修正，PENDING_OPERATION_UNCHANGED 仍保留未知结果，不能把所有409一并当撤权。迟到成功/失败在 current=false 时不显示为新范围结果、不关闭任何无关窗口；finally 也应避免为失效窗口重新更新交互状态。

## 已有模块能承担的行为

- DeviceSubflowScope:7-45 捕获 generation/subject/tenantId/role，监听 Session，同步且永久丢失；即使同一帧切走再切回也不恢复。Session.selectTenant:310-339 在 await membership 之前递增 generation 并通知；相同工作空间重选同样失效。
- Api.scoped:227-236 共用 pendingWrites，并在认证 client 获取前后检查。Api.send:245-318 对请求构造、传输完成、异常路径保留 scope 检查。ScopeBindingClient:51 起还覆盖 OAuth 等待后的实际发送、响应头和响应流；不需要新增平行客户端或重写这一层。
- OwnedDialogRoute:4-35 在被覆盖时只 remove 自己并完成原 Future；presentOwnedDialog 等待 route.completed。不要以普通 Navigator.pop 替换。
- PolicyEditor:595-649、666-729、1048 起提供 scope/替换/撤权/只关闭 UI 的参考。可以借其规则，不能机械复制其目录加载、规则子窗口、草稿读回等与时间计划无关内容。

## 必须保留的现有行为

保留现有13个浏览器业务断言：重复捕获回调只提交一次；保存前深冻结原 body；同一次未知结果的 key/body 不变；network/server/unexpected 三类未知结果锁定内容并按原内容重试；已知校验拒绝可修正再提交；PENDING_OPERATION_UNCHANGED 继续为未知；未知结果返回需要明确确认；迟到成功只关闭自己的窗口并保留覆盖窗口；时间/日期迟到返回不能修改关闭的 owner。默认工作日、18:00–20:00、时区初值、日期例外去重及后端 payload 保持原有产品含义。

范围失效不应关闭共享认证 client，不能清除共享幂等记录来“解除锁定”。同范围当前成功路径仍应完成一次有效 POST；新开合法窗口不能继承旧窗口的永久失效。

## 有意义的新增用例

用真实 ScheduleEditor、Api.scoped/ScopeBindingClient 和可控 client/response Future 检查 UI 与最终传输入口；不要 stub `current=false`、断言调用了某个私有方法，或仅检查某个布尔字段。新例应先在缺少绑定的旧行为上复现。

| 场景 | 对外可观察断言 | 能发现的实际错误 |
| --- | --- | --- |
| 调用公开入口后、首个 dialog builder 前切换操作者 | 不展示原表单，旧窗口不发 POST，仅能关闭 | 把捕获推迟到 State 初始化，窗口错误采用新范围 |
| 保存正在等待 client 时同一帧切走再切回，再释放 client | 传输记录没有旧 POST；旧字段/保存回调仍失效；关闭可用 | 只检查最终 tenant 或按钮外观，没有永久 generation 绑定 |
| 真实 Session 相同 tenant 重选，membership 尚未返回 | 旧窗口立即失效，而非等新成员响应 | 未订阅同步通知或忽略 generation |
| 已有未知结果，捕获保存/重试/字段回调后撤权 | 不再发送第二次请求；原内容不可见；不能从捕获回调恢复 | 仅隐藏/禁用新按钮，旧回调仍能执行 |
| 同 key 的 widget 替换 Session/root，再恢复原 props | State 不接管新旧任一范围；旧输入不用于新请求 | didUpdateWidget 缺失或重新绑定使旧状态复活 |
| 服务端403但 Session 还没有 notify | 原输入和错误内容隐藏，仅可关闭 | 完全依赖本地 Session 的撤权通知 |
| 原未知关闭确认被无关窗口覆盖后范围变化 | 自有确认消失或不再展示旧内容；无关窗口仍在；旧确认回调无效 | pop 错路由、确认窗口仍保留旧范围内容 |
| 已发送后范围变化，再释放成功/失败响应 | 没有当前范围的成功展示，不关覆盖窗口，不重发 | 迟到回调或 finally 恢复失效窗口状态 |
| 失效通知发生在父 build，随后窗口立即 dispose | 不出现 build 中 setState/Navigator/controller 变更异常 | 只延迟 setState，却同步 clear/finish，或异步清理访问已 dispose 状态 |
| 新范围重新打开一个合法窗口并正常保存 | 一次正确新 root/body POST；原共享 client 仍可用 | 错误关闭共享资源，或把旧 scope 绑定回全局 Api |

客户端等待与 OAuth 刷新后的物理发送在 api_bound_scope_test.dart:134、186 和 scope_binding_client_test.dart:165 起已有底层覆盖；新增编辑器用例重点证明它确实接入该模块，不复制整个传输层测试集。device_subflow_scope_test.dart:421、438 提供公开入口与真实同范围重选的现有测试方式。

## 选择器范围要说清楚

当前 pickTime/pickClosedDate 在 await 返回前后都有 interactive/locked 检查；加 scope 后自然阻止失效结果写回，应保持旧迟到返回断言。默认 showTimePicker/showDatePicker 是独立路由：仅重建父表单不会自动隐藏其初始选择。如果本轮不接管选择器归属，就只能声明“返回结果不再写入失效表单”，不能声称所有已打开选择器里的旧内容也已立即隐藏。不要用盲目 pop 顶层来实现自动关闭；选择器的展示隐藏/精确关闭需要单独说明与补例。

无须为这项静态设计降低 SDK 门槛，也无须冻结下一阶段源码。完成代码与测试准备后可按用户要求阶段 commit；待资源/窗口恢复，再对新 HEAD 和新快照验证。B6/r16/旧运行证据保持原封，不将本复核计为执行结果。
