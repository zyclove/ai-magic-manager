# Quota 跨文件最小合同审核清单

## 当前结论

ViewLifetime 实际候选 after.dart（1068B，SHA256 c68c7457f2cd212df0b8d34b727c8e07364b6605832c41dc133d70355d719815）已全文只读审阅，未见 helper 自身静态阻断。下面是三方接合清单，不是尚未交付的 Page/Plans/Editor/ResourcePage 候选验收，也不新增业务发现。基线 Main 为 bb93c0b0bacfea622e50828e635aa61d738f342b；所有场景 UNRUN。

## 1. ViewLifetime 与通知/清理顺序

- 13–19：invalidate 先同步令 active=false，且只排一次通知 A；接口/API/旧回调必须实时读取 active，不用延后才改变的 notifier.value，也不缓存一次 true。
- 22–32：dispose 幂等，先 invalidate 注册 A，再注册销毁 B。_disposed 只在 B 内置 true，故“请求 dispose”不会提前跳过 A。先前已 invalidate 时无需重复通知；监听器中再 dispose 也只会排一次 B。
- A、B 均有 ensureVisualUpdate，按注册顺序发布失效后销毁 notifier。失效本身不 notify，不在 deactivate/树锁期间同步引发 UI 重建。
- 独立 root dialog 不会随原页面的元素树一起移除；它们的稳定 accessChanges 必须包含原 ViewLifetime.changes。只有 DeviceSubflowScope.dispose 不会发布失效事件，不能替代页面 lifetime 通知。
- inactive 后不再创建新 flow/绑定或给原 notifier 新增监听；每个 flow 的 changes 合并对象应捕获并保持稳定。监听器先检查自身 live/mounted，收尾移除自己的监听。通知延期只负责界面传播，不能成为权限延期。

## 2. owner 有效性、用户交互、已接受完成分开

| 条件 | 用途 | 覆盖时 |
| --- | --- | --- |
| 原页面/lifetime + 固定 Session/actor/tenant/role/generation + 原祖先 active/available | 持续 scope/API/界面数据归属 | 合法子窗覆盖仍有效 |
| 上述 owner + 自己 route.available/isCurrent + busy/pending 规则 | 新的点击、保存、取消、重认证、日期/override 入口 | 拒绝旧控件动作 |
| 原 owner + 自己 route.available/操作身份 | 已合法发送操作的返回、保存成功收尾 | 可以 finish 自己的 Owned route，不弹覆盖窗 |

isCurrent 不可被统一塞入 Api.scoped 或 onSubmit 的写后检查：自己打开 child 会使祖先不再 current，错误使用会让表单立即失权，或吞掉覆盖中的合法成功。原 owner 真正撤销时则立即屏蔽旧动作/结果；已经发送的业务请求不因此被称为取消。

## 3. 新 ResourcePage.canInteract 接合（Root 已定方案）

- 可选 canInteract 只约束所有组件生成的 UI 事件及 clearSearch/action 的新入口；未提供时保持已有调用行为。
- isCurrent 继续表示 owner 有效。load、API 和内部成功动作后的必要回读不套 canInteract；旧 action 已合法进入后被 cover，仍应按 owner 完成并回读。
- history/ledger：isCurrent 绑定原 scope、DialogAccessBinding 和自己 Owned route.available/isActive；canInteract 只检查自己 route.isCurrent。
- canInteract 是可随 cover 暂时 false、返回后 true 的交互条件，不把这种变化粘性记为撤权。真正 owner 的失效仍遵守旧不可复活合同。
- held UI 必须在任何 widget!、setState、控制器/焦点、reauth、load/action 副作用前检查；同时保留 captured owner/handlers 及 busy 复查。该候选尚待 Root 交付后独审。

## 4. 页面与原祖先关系

- console host key 与 page scope 固定原 Session/actor/tenant/role/generation，不能只以可重复的 root 字符串代替身份。
- Plans required parentCurrent/accessChanges 必须由生产 QuotaPage 传入原父身份；自身 State 的 ViewLifetime 在 deactivate/dispose 同步失效。父页面仍 mounted 不代表当前子视图仍有效；切换 daily/plans 等使原视图结束时，应失效原视图绑定，不能动态读重建后的新 lifetime 复活旧流程。
- 每个详情/history/editor flow 捕获原页面、原实际 launch context/route。不能从详情动作传入页面祖先 context，却误以为 helper 已绑定了该详情窗口。
- DialogAccessBinding.permitted 已核 parent.isActive、OwnedDialogRoute.available、context.mounted 并粘性失效；普通 cover 不撤销。
- formDialog:267–274 的 parent 检查只有 isActive，没有 Owned.available。调用方 hasAccess 因而必须补实际祖先 owner.available 和原 lifetime，封住 finish→dispose 过渡；不能仅等待元素卸载。
- OwnedDialogRoute.finish 只处理自己：current 时 pop 自己，covered 时 didComplete+removeRoute。presentOwnedDialog 等 popped 结果和 route.completed；局部 flow 的 finally 清理要跟随该 Future，不能误等永不完成的 raw covered route 或提前释放 scope。

## 5. Plans 与 Editor 接口和业务合同

- 当前生产仅 quota_page.dart:48 构造 Plans；新增 required parentCurrent/accessChanges 应同步该调用。当前生产仅 Plans:122 构造 Editor；optional hasAccess/accessChanges 在生产必须传原 scope，而现有纯表单测试可沿用 optional 默认。最终仍核实际所有调用。
- Editor 的 calendar 既核原 owner/route，也核 subject 与请求 generation；晚结果/晚错误不更新新选择，不滚动旧 errorAnchor。
- override/date await 前后分别核新交互条件；child form 的持续 hasAccess 核 editor 原 route.available 和 owner，允许自己被合法 child 覆盖。child 关闭、editor 关闭或父页面撤销后，不合并旧结果。
- 保存前核当前可交互、owner、表单和 busy/pending；发送后的成功按完成条件 finish 原 Owned route，保留 cover，并完成原调用 Future。取消是当前用户交互条件，不能用任意 Navigator.pop 关闭当前覆盖者。
- 每个操作固定原路径、subject、version、requestId/key；未知结果保留原 pending payload 和重试合同，不因本轮 scope 改造重生成 key、改 If-Match 或自动重复提交。
- 更新/重认证/错误重试均核原 owner 和当前交互，不把 parentCurrent 的纯动态 bool ABA 声称成已解决。当前方案没有要求切后台就丢弃编辑，也没有新增通用路由框架。

## 边界

只读共享实现及现有配额调用关系，核 helper 文本/hash。未执行 helper、候选函数、谓词、AST/解析器、SDK/测试/formatter、进程检查/WinAPI/网络；未改 Main/Git/测试。最终作者候选、所有渲染和运行行为仍待对应独审/验证。本清单不代替任何执行授权。
