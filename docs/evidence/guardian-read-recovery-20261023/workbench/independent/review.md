# Workbench 常用操作 r2 独立静态审阅

**结论：所审单文件最终候选未见静态阻断。全部场景 UNRUN，未渲染，未进行 Dart 分析或编译。**

## 字节与范围

候选恰 6 件；5 条 delivery、4 条 metadata 和 3 项真实 Main 上下文指纹匹配。完整 2 段文本补丁重建 after 字节一致；before 等于 Main 与 7cf2b2b 原始 Git blob。只改 build；字段/构造/导入、所有辅助方法、权限过滤和动作回调逐字不变。最终 after 16807B，SHA-256 `198b85c003e310ab4fa1cd1cfbc7c77ab29ea8e6ecc007c8c4cb02d06ce5d5ce`。

## 具体依据

- `after.dart:123–126,165–168` 常用操作不再依赖 summary 成功读取。权限与 optional callback 条件仍在原 `_commonActions:334–378`；初读/失败不会构造数据计数或连接结论。
- `:123–125` error 或 refreshing 时不生成 `_nextAction`，因而旧计数既不产生主推荐，也不通过 shortcut 去重隐藏常用按钮；成功闲置时保留原主推荐与去重。
- `:150–162,169–177` 仅有真实 summary 才展示指标/活动/原读取时间。刷新或失败保留旧数据时，先显示“上次成功读取的数据，当前状态尚未更新”；失败用 warning。时间仍来自原 prop，没有伪造刷新成功。
- `:143–145` 当前忙碌/刷新 build 不向 FailureView 提供 retry 或 reauth。原 header 忙态门槛保持；常用操作继续按 actionBusy 禁用，可在普通 summary 读取期间使用。
- 对照真实 Dashboard：current 绑定原 scope/session；失效时同步清 data/error/refreshedAt；load 只接受 current+generation 的响应；perform 在新操作前 supersede 旧读，完成后重新读。此次没有改变这些宿主门槛。未声称修复所有外部持有回调的忙态语义，宿主回调合同保持原样。

相关既有测试源码只读，未新增或执行。未执行 SDK、AST/源代码解析器、候选/业务谓词、格式化、进程查询或网络；未写 Main/Git/作者原件。本结论是文本数据流与字节审阅，不是平台兼容或行为通过证明。
