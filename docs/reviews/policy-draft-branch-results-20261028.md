# 模板复制与历史回滚草稿：静态阶段

基线：`29474474812ffd58d339bddf521264339203b1a4`。复用既有 PolicyService、原幂等日志、Material、完整草稿解析与 EditDialog 恢复机制；不新增依赖、建库或发布能力。

## 变化

- 复制与回滚共用名称表单、UUID、完整回执校验和恢复流程。复制给出合法长度的副本名称建议；回滚默认当前名称并允许直接调整，只恢复草稿，仍须预览并发布。
- 未知结果仅查询原复制／回滚结果，固定原名称及 If-Match，查询不传写入幂等头。408或坏回执保持未知；404／认证要求不解锁；明确关闭后核对列表，不能据此显示成功。
- 新增两个只读结果端点，复用 policy.template.copy 与 policy.rollback-draft 日志。查询前校验当前写权限、原租户／操作者／UUID／正文／版本；查询不要求新近期 MFA，原回滚写入仍要求。90天到期使用既有 typed outcome，在事务外转 HTTP 终态。
- committed 匹配原名称、编号、类型、修订、来源版本和全部规则；current 单独表达后续变化，同修订必须完全一致。较新来源版本也可由后续回滚产生，界面提示核对当前列表，不把当前值当作原提交证明。
- 取消／只读仍保留原详情和列表位置；原授权、父窗口及资源租约继续约束子流程。旧 writer、creationResult、设备执行边界与无关工作区改动保留。
- SPEC、接口状态、领域契约和稳定项目记忆同步，并修正时间计划副本章节遗留的重放描述。

## 检查与待验证

| 范围 | 状态 |
| --- | --- |
| 限定页面／纯模型／控制器／服务与既有日志接口 | 已静读；查询无新业务写入，完整回执及后续修订分别处理 |
| 限定 Git 空白检查 | PASS；包含新增文件的限定暂存差异，不代表编译、渲染或行为验收 |
| policy_draft_branch_test | NOT_RUN；3个聚合覆盖九类规则、冻结／独立来源、精确原回执、后续来源与同版本篡改 |
| policy_details_scope_test（browser） | NOT_RUN；现有旅程改为只读恢复，新增1个复制／回滚聚合覆盖408→404→401→原结果、后续修订、原输入锁和保留回调不重放；保留原权限／窗口／取消断言 |
| PolicyDraftBranchJourneyTest | NOT_RUN；3个聚合覆盖真实复制及CONFIGURE_ONLY历史版本／回滚、授权与原正文隔离、到期／清除不复活业务 |
| SDK／format／analyze／Java／Maven／测试／构建／渲染／真实接口 | NOT_RUN；按用户要求继续静态完善，等待资源及串行窗口恢复；不降低既有门槛 |

仅提交本阶段13个相关文件，不推送、不部署。当前服务不包含本阶段增强；历史通过结果不能证明新源码已验收。

## 源码 SHA256

| 文件 | SHA256 |
| --- | --- |
| apps/guardian/lib/core/api.dart | F5F3E00C955751B2522BFF5536DD86F8E4A98A8088D689EA0BFB726FDEB2676C |
| apps/guardian/lib/core/policy_draft_branch.dart | A7F762C5413E9B14A1AA814ED9B6F39965F149A8094AE73D96D4FBBD920E147E |
| apps/guardian/lib/pages/policy_details_entry.dart | F38F3171E0B3D0A55F344A12BD7AB13F6F8ED155D7F777D5B8980A1C8A4885B4 |
| apps/guardian/test/policy_draft_branch_test.dart | 12C06A887E60C5169380B531941F59C8E91E2C2A81B64EC849D3F971135D450D |
| apps/guardian/test/policy_details_scope_test.dart | 10F306CDF912E59AA0C41D9B1BC79A00B3332815F10A404B25F1312AD106B4BA |
| backend/src/main/java/com/aimanager/policy/internal/PolicyService.java | 03319E43D56B461E1A6E0206239982E45CF8F7AC5C3BABA4B47A9990238EBFF6 |
| backend/src/main/java/com/aimanager/policy/internal/PolicyController.java | 7F0F999CFE592EEA16BD68E0384EEB72D74AE7BC4B46F2E220ED23EA69F58B1F |
| backend/src/test/java/com/aimanager/PolicyDraftBranchJourneyTest.java | 6F5BE63E5530DEAD2E0CA42BFB545DD6F002737E77B19BAE81F4D071E95226D6 |
