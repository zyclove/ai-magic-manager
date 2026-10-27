# 策略完整草稿保存与原结果查询：静态阶段

基线：`75e191dc160368689be5506182abba1a2924269a`。本阶段只修改源码与契约，未更新服务、数据库或部署产物。

## 改动

- 完整草稿 CREATE／UPDATE 统一通过 `policy-draft-changes` 保存；固定 UUID、原版本和规则，复用 PolicyService 的授权、引用、编译、审计与事务。原结果与业务变更同事务记录，无新增建库或迁移。
- 未知结果只查询 `policy-draft-operation-results/{key}/query`，不重发写入。共享模型完整验证 committed；current 单独表示当前草稿，较高修订可包含合法回滚来源变化，同修订须完全一致。
- “查看当前内容”展示版本与是否符合原输入，不能证明原请求执行、解除停止状态或关闭编辑器。缺失／近期认证要求保留未知，408按未知处理，版本冲突／到期／清除保留只读原输入。后续修改提示核对当前列表。
- 详情复用共享草稿／规则 parser，两个编辑器共用深冻结函数。SPEC、API 契约和项目记忆同步；没有新增依赖、轮询或目录请求。

## 检查与待验证

| 范围 | 状态 |
| --- | --- |
| 限定差异、接口对应、权限／事务／原回执与当前内容边界 | 已静读；修正后续回滚来源变化的误拒绝 |
| 限定 Git 空白检查 | PASS；仅空白，不代表编译或行为验收 |
| Guardian `policy_draft_change_test`、`policy_editor_lifecycle_test`、`editor_submit_guard_test`、`policy_details_scope_test` | NOT_RUN；准备原回执、未知查询、并发修改、作用域与旧详情流程回归源码 |
| Backend `PolicyDraftChangeJourneyTest` | NOT_RUN；准备原子写入、防重复、授权、精确版本与90天终态集成源码 |
| SDK、编译、构建、渲染、端到端与运行环境验收 | NOT_RUN；按用户指示等待资源及串行验证窗口，保留 RAM／C盘／D盘各至少2GiB及SDK空闲门槛 |

只提交本阶段文件，保留其他会话改动；不自动推送或部署。现有服务不包含本阶段改动。

## 源码 SHA256

以下绑定用于恢复后的限定验证，不把历史结果追认为新源码通过。

| 文件 | SHA256 |
| --- | --- |
| apps/guardian/lib/core/api.dart | 42D74EB4FAF14FFD79A19CA1DAD019DEE94DCC003BCDAA686EA826413BDF9AC7 |
| apps/guardian/lib/core/policy_draft_change.dart | 423ACB5252CDDE9C84BD283EBA47206704B0211195EA2F21F3F569BD620CB2B6 |
| apps/guardian/lib/pages/editors.dart | FAD72BA97B82F8341918F89BB868C193B3BD28A22802FA81F65700A4C14DB0F5 |
| apps/guardian/lib/pages/policy_details_entry.dart | 37203E90928F53E98B8579CF37541A0478EE790D08EED32C6A36E875C747EE36 |
| apps/guardian/test/policy_draft_change_test.dart | A82F76502E05CFB36666518169F64E577A3B8A26653FF566B4A254707B27CBF8 |
| apps/guardian/test/policy_editor_lifecycle_test.dart | 67A70AF11A14642C9E9E96CA4D92391F9A3EC06600ADDD5063EF8C246D55123B |
| apps/guardian/test/editor_submit_guard_test.dart | 19D00D47E54BE5C02DB927E3E76604BAE16165ED8C0D8F9D842310E3A69A22E9 |
| apps/guardian/test/policy_details_scope_test.dart | 549214AADB2AF9E3D8E9C8C66C8C2DD3648F4809DFC05246D23D189391B5D4D5 |
| backend/src/main/java/com/aimanager/policy/internal/PolicyDraftChangeController.java | 5A8F1D19A9711A8FDE460EDF4D43F4E4F28410B0ECE12D5985EA775D04F8E6C6 |
| backend/src/main/java/com/aimanager/policy/internal/PolicyDraftChangeService.java | 555A3E43D524AF09C291DD648D04457A86EE196BBBAC3C4D1073074749E78047 |
| backend/src/test/java/com/aimanager/PolicyDraftChangeJourneyTest.java | 8EACEA2246001BAFBBF04283174955BB9A4E67EE5EA927CF74E62569F45622FB |
