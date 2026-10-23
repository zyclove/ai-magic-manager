# Shared EditDialog：412 并发冲突恢复候选

仅修改 `apps/guardian/lib/ui/design.dart` 内 `_EditDialogState`，基线为 7cf2b2b。Main 未写，等待独立审阅。所有场景 **UNRUN / 未渲染**；未运行 SDK、测试、AST、编译或格式化。

## 最小方案

- 明确 HTTP412 与未知写结果分开：412 后 `save()` 在验证/清错/调用 onSubmit 前同步拒绝，持有旧保存回调也不能再次提交过期 version。没有读取新 version、自动刷新数据或重放旧草稿。
- 在原 pendingValues 被已知 HTTP 错误清理前，保留本次实际提交的字段快照（不可修改 Map）。冲突时替换编辑控件为 Material SelectableText，按原字段标签/选项显示，允许核对、选中文字复制；不增加系统剪贴板调用。持有的旧下拉事件也检查冲突状态。
- 412 只显示一个原 FailureView（保留错误码/关联编号）与说明，不再展示保存按钮；提供实有的“关闭表单”按钮，仍走原 cancel→finish，返回 null。提示关闭后刷新原页面再重开，不宣称自动刷新或自动保存。原失权分支仍先隐藏包括草稿在内的全部内容。

## 调用合同与保留行为

`formDialog` 返回 Json?，真实 Subject 等调用者把非空结果当保存成功。不能复制 ClassActionDialog 的 `{'refresh': true}` 返回协议，否则可能误报保存、误关父详情。此次只关闭表单并明确人工刷新/重开步骤，不新增参数、不改任何调用者。若未来需一键自动刷新，应另行设计区分 saved/cancelled/refreshRequired 的返回合同；本候选未假装具备该能力。

未知结果（网络0、5xx、非ApiFailure）仍原 pendingValues、原 onSubmit closure/key/version/body 重试；保留原 UI 锁定、重试说明及“重试原提交”。已知验证错误仍可修改后重试；401 的原重新安全验证路径不变。Api._pendingWrites/If-Match/Idempotency-Key、formDialog 生命周期、hasAccess、route capture/finish/cancel、已接受保存被覆盖后的所属 route 完成均不改。

## 静态作者核对

- before 字节等于当前 Main 和基线 Git raw blob；完整补丁重建 after 字节一致。整个 EditDialog State 外逐字不变。
- 原访问检查、生命周期、finish/cancel、请求内容构造与成功完成路径未重构。新增冲突门槛只在明确412成立。草稿是供人核对的字段摘要，不是可重新导入的 JSON 导出包；空值以“（空）”显示。
- 已阅读真实 ClassActionDialog、Api.send、OwnedDialogRoute 与 Subject 的结果分支。现有相关测试源码仅作为未改指纹记录，未新增或运行用例，静态文本核对不等于 Dart 编译或行为通过。

## 后续验证窗口（全部 UNRUN）

明确412保留实际提交内容且旧save不再调用；关闭返回null、不误报保存/关闭父详情；0/5xx/未知错误使用原内容与key重试；400验证可更改、401重新验证；失权隐藏草稿与旧动作拒绝；合法成功只完成原所属路由并保留覆盖窗口。
