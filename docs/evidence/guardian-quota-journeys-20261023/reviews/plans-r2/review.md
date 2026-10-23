# QuotaPlansPage r2 独立静态复核

## 结论

固定单文件与 r1→r2 的最小清理差异未发现静态阻断。结论仅覆盖本文件；必须与实际最终 Editor、Root Page、ResourcePage 和 ViewLifetime 接口联合应用。所有场景 UNRUN，未渲染、未编译，不授执行资格。

## 实际差异和生命周期

完整 r1 源码/补丁审核已保存在前一独审目录；本次逐字证明 r2 仅有三个表达式变化：187 editorChanges、231 detailChanges、311 historyChanges 均由 merge([changes, access.changes]) 改为该 flow 的 access.changes。其他每个源码字节与 r1 相同。

已重读 160–365 三个完整 flow。每个 DialogAccessBinding 仍在异步预检前一次订阅原 page changes，并由该 flow route Future 之后的 finally 释放（216–218、293–295、361–363）。surviving root UI 只重新订阅仍活着的局部 binding 通知，避免直接重新 add 已销毁 page scope/lifetime 的通知对象。原 page 的稳定 merge 保留，原 owner/context/ancestor availability 仍通过 binding 的 sticky permitted 同步失效。局部 binding 最后移除旧订阅符合本机 ChangeNotifier.removeListener 允许 disposed 后调用的文本契约。

accepted 与 top-route 的区分、原 preflight/current 检查、covered 合法读写完成、详情/历史祖先、关闭原窗口、原 key/version/path/calendar/body 均逐字保持。没有新增权限路径或重试设计。Editor 仍须消费传入 accessChanges/hasAccess 并只完成自己的 Owned<void> route；本报告不把其尚在制的 r2 预填通过。

## 字节复核

六件成员精确；5 delivery、4 metadata 文件、8 baseline dependency、helper 和 3 个历史 r1 pin 全部匹配。完整 Main→r2 3-hunk patch 已逐行检查 context、位置和计数并逐字重建 after：16151B SHA256 9abbb08efcb075ba451190ba0dcc678c5682018f18611a1eade65b1f651b5191。Main before 与 HEAD bb93c0b 的 raw Git blob 52557a0205392eec97cc4d1e9f104abc9dd735a4 相同。

## 范围

这是文本数据流与字节审核；不是 Dart 编译或运行证明。原 r1、r2、Main、Git、测试均未修改。未执行候选、业务谓词、SDK/测试/AST/解析器/formatter、进程/WinAPI 或网络。页面被销毁且子窗存活时的实际重建、通知/卸载时序、布局及整个六文件集成仍 UNRUN，后续应在授权窗口验证。