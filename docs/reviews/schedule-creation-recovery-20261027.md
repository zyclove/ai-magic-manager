# 时间计划原保存结果查询

日期：2026-10-27。基础提交：`040f32a4e6a4e59ce5b6ed052e761ca6ce681764`。状态：静态候选；SDK、格式化、分析、测试、构建与真实界面/API验收均 NOT_RUN，未推送或更新服务。

ScheduleEditor 原未知恢复会重发创建，首次HTTP成功也未核对回执。本批首次保存使用 UUID 请求键，未知后仅查询既有 schedules/creation-results/{key}/query，保留同一冻结正文且不传写入幂等头。首次写入与未知查询有双向状态门禁，旧保存按钮不能借恢复再创建；404/近期安全验证不解除输入锁，408亦视为未知。原私有读取失权、版本/结果不可恢复、退出确认及 ResourceActionLease 保留。

首次创建和查询均复用 requireScheduleCreationResult 核对完整回执，检查规范UUID、名称和全部 definition；空/坏/错配回执保留未知。helper复用 ScheduleCopy 解析、重组已知对象键后深比对，保持数组顺序、原时区、跨午夜、空每周安排及所有日期例外，每层返回不可变值，不另造日程解析器。后台使用字符串HH:mm并原样保存定义，原结果查询也比较完整定义；未改变服务端数据或授权。

未知窗口改为“查询保存结果”，退出说明同步。空闲且原窗口/权限仍有效时可进行安全验证，不自动提交；正常取消仍不刷新，未知明确关闭或已核对结果沿原信号核对列表。复制仍创建独立计划，不改源计划或策略引用。PolicyEditor 本批行为未改，没有新增依赖、后端或迁移。

## 核对事实与接续

- 静读 ScheduleController/Service/Definition、Parent 已有创建恢复及 ScheduleCopy：原查询使用UUID和原正文，返回不可变计划，时间字符串不会因序列化变为另一表示。根核对无查询幂等头、双向发送门禁、完整响应验证、安全验证入口及未知关闭说明。
- 新增3条纯核心聚合源码：非默认时区/跨午夜/仅例外与全关闭、对象键重排、任一结构/顺序/ID/内容错配及无效日期、每层不可变与源隔离。全部 NOT_RUN。
- 延长既有 editor_submit_guard_test 的 Schedule 分支，没有新增测试方法，Policy保存/重试断言保留。覆盖408/空首次回执、query404/近期认证/409、坏UUID/名称/定义回执仍锁、完整回执成功及412/410停止；查询逐字原正文/无写入键/只一次创建，失权及旧按钮保护继续检查。原{}成功替身改为真实完整回执，{}只用于坏回执或卸载清理；全部 NOT_RUN。
- 新增1条副本浏览器聚合：503→query404锁定→匹配结果，断言一次创建、两次查询、一次列表核对；副本编号独立，原计划和策略引用保持，打开详情继续核对原时区、跨午夜与全部例外。既有成功/取消/未知关闭断言保留。限定静读其他相关夹具，未发现额外保存回执需适配；所有执行 NOT_RUN。
- 限定差异、源码空白及新增本地文档链接已静态检查；未运行 SDK、测试、构建、真实浏览器/API或资源采样。静态检查不证明编译、权限集成或完整可用性通过。

窗口恢复后沿既有离线准备格式化/分析本批6个Dart文件，优先运行 schedule_creation_test.dart、editor_submit_guard_test.dart、schedule_copy_flow_test.dart；出现实际失败或扩大影响再补，不重复无关全量验证。契约见[应用与时间计划](../policy-application-schedule-contract.md)、[SPEC](../SPEC.md)与[项目记忆](../project-memory.md)。

源码摘要（仅定位静态候选）：

- `apps/guardian/lib/core/api.dart`：`7eb80e64e1bc5974033b743a83158d3839e1b30e7d73dacd698386ea847a7d72`
- `apps/guardian/lib/core/schedule_creation.dart`：`650c94e8ed492d18c147842c6f0e57ee42f901136e51e01c8859e95ae42447fa`
- `apps/guardian/lib/pages/editors.dart`：`d52c65142cb339995489ad35b9ab5fdd764dc2a4ea894d3bf1c55d33c9c7fa57`
- `apps/guardian/test/schedule_creation_test.dart`：`cb61c99e90e33d6f7b71a76872e779101f47716d0518e639d86eeabb9889bae5`
- `apps/guardian/test/editor_submit_guard_test.dart`：`c59599071f3799a7ebb48a85f21e24037143d1a117e5436a97ab412bd31cc4d7`
- `apps/guardian/test/schedule_copy_flow_test.dart`：`646d727cfc390589e2c9f62bdd622906f4b2a41c850a5ac48b450c95e862bf01`
