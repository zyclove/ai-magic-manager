# 策略规则输入简化：静态阶段

基线：`05e5e752d84e23ba9442c0381a71840a846af2ca`。本阶段仅静态实现，沿用现有 Flutter Material、FieldSpec 与编辑窗口，不引入依赖或更新运行服务。

## 变化

- 规则类型保留现有选择与名称，补充用途和装饰性图标，文字可换行。只有一种合法行为时直接说明并填入固定值，不再要求选择相同选项。
- 每日额度／使用提醒以分钟、秒输入；已有3661秒保持61分1秒，确认后仍提交3661秒。分量与合计均校验，支持1秒到24小时，秒可留空按0，不舍入、不截断或钳制。
- 可选目标应用明确显示“所有适用应用”，已有引用保留；本地按钮统一“加入草稿／更新规则”。新增规则也在回调入口检查100条上限，原作用域、规则锁和未知保存保护保持。
- 小型纯模块负责时长转换与小时／分钟／秒摘要；API仍只有整数 `seconds`，表单 `minutes` 不进入规则协议。SPEC、领域契约和项目记忆同步。

## 检查范围

| 范围 | 状态 |
| --- | --- |
| 限定差异、整数秒往返、固定行为、字段白名单、本地准备与原操作门禁 | 已静读；无新增可行动发现 |
| 限定 Git 空白检查 | PASS；仅空白，不代表编译、渲染或行为验收 |
| policy_rule_duration_test | NOT_RUN；2个聚合覆盖精确边界、不可变字段、无舍入与非法值 |
| policy_editor_lifecycle_test | NOT_RUN；新增1个聚合覆盖原提醒3661秒、空分钟／零合计后可修改、本地无写入、最终137秒额度与协议无minutes；其余旅程未改 |
| SDK／format／analyze／测试／构建／渲染 | NOT_RUN；按用户指示等待资源和串行验证窗口；不降低RAM／C盘／D盘各2GiB与SDK空闲门槛 |

只提交本阶段相关文件，保留其他会话改动；不推送、不部署。上述源码仍待受影响验证，不能据静态检查宣称整体功能验收通过。

## 源码 SHA256

| 文件 | SHA256 |
| --- | --- |
| apps/guardian/lib/core/api.dart | 04D3C03EE6EE77E6325228661BEEE801A91ED38CF7A42B4B252832C4CFE160E0 |
| apps/guardian/lib/core/policy_rule_duration.dart | 45C773AA41E5515EA4C5F0FF11262DB2D7123FCCC671419DC8D647D17FEF66A2 |
| apps/guardian/lib/pages/editors.dart | 9CE4A4366AAAD46952781159E7E76094777C839E84AD6484B4B96BAE00A00F12 |
| apps/guardian/test/policy_rule_duration_test.dart | 0E97C7F504C326FFFD2A45B2BBDA2553D5FE9D7CB5B456205C5EAF7C58C50A98 |
| apps/guardian/test/policy_editor_lifecycle_test.dart | B67A87C9BC412836504782F635FA4A14CBFE943DF6434D402A343FCFE186E165 |
