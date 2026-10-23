# 审计与额度编辑器：异步 context 最小修复候选

基线 abb2e016650cf579fc7ad1dbccdecc682072807a。实际r11分析报告命中这三处 use_build_context_synchronously；本候选只在两个文件三个既有早退条件最前增加 `!mounted ||`，不改Main。所有候选验证场景 **UNRUN**，未执行SDK、测试、AST、编译或formatter。

- QuotaPlanEditor.addOverride：await 所属日期窗口后，原 childPermitted/current 虽经 accepted 间接包含 State.mounted，但分析器不能把该自定义链当显式生命周期证明。调用 formDialog 使用的是该 State.context；在原条件最前直接检查同一 State.mounted。原 childAccess、operation/calendarGeneration/selected subject、日期OwnedRoute、两段await与finally dispose/unlock均保留。
- AuditView.open：await repository.detail 后，在 actionDetails(State.context) 前加同一 State.mounted；原 repository identity/current、ticket、openingOperation 条件不减。
- AuditView.dates：await showDateRangePicker 后，在后续 toast(State.context)/日期更新前加同一 State.mounted；原 eventCurrent、chosen非空、366天限制保持。两个方法没有builder参数遮蔽context。

原自定义门槛已包含mounted，因此这是显式恢复实际context的生命周期证明；不以mounted替代权限、scope、generation或route检查。不忽略lint，不改变API、请求key/payload/version/幂等、日期选择行为、合法完成或清理顺序。两文件行数不变，除三处前缀外逐字相同；before逐字等Main与基线Git raw blob，完整文本patch重建after一致。

ViewLifetime/import由Root另行处理，本候选没有修改或包含该文件。实际诊断已存在不代表这份after已通过分析；须在后续明确窗口检查。
