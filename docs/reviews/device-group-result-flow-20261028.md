# 设备组五类操作原结果恢复：静态阶段

基线：`20f20feb6e37c818dd821bc504eae5b1d99e4c98`。复用既有只读 operation-results、原领域服务、EditDialog 与 ResourceActionLease；无新依赖、后端协议、持久化或建库。

## 变化

- 新建、改名、归档、加入及移出统一固定UUID、原正文与原版本；未知后仅查询原操作，不重放写入。单台移出使用已有单目标removals，与批量维护共享同一日志恢复合同。
- 移除设备组专用确认状态机与ClassActionDialog引用，复用通用表单的408、未知输入锁、查询404／近期认证保留、终态停止及行内未知关闭确认。确认描述保留组编号、原版本及完整注册关联。
- device_group_change集中完整7字段、明确目标与冻结正文；区分committed/current，合法同名改名及加入全部已存在可完整无变化，实际新增／移出精确约束修订和成员数。归档后快照保持不变，当前后续修改单独提示并重读事实。
- 新建借用原资源操作租约，权限及列表来源失效后旧窗口同步拒绝操作并隐藏内容；普通取消保留列表位置／已加载页，明确需要核对才请求刷新。详情操作锁、原视图代次及OwnedDialogRoute继续约束全部子流程。
- SPEC、设备组契约、手机端契约的Web描述和稳定项目记忆同步；旧通用表单及其他模块不改。现有V06归档夹具仅补齐真实快照的两项时间字段，不放宽验证。

## 检查与待验证

| 范围 | 状态 |
| --- | --- |
| 真实writers／query DTO、日志namespace、MFA与no-op规则 | 已静读；现有查询在当前写权限校验后只读原日志，查询不需要新MFA；未修改后端 |
| 页面／纯模型／通用EditDialog／资源租约接线 | 已静读；查询无If-Match或写入幂等头，原版本在冻结DTO内；原回执与当前事实分开 |
| 限定Git空白检查 | PASS；含新增文件，不代表编译、渲染或行为验收 |
| device_group_change_test | NOT_RUN；3个纯聚合覆盖完整快照、五类冻结正文／精确回执、no-op与当前／终态关系 |
| device_group_flow_test（browser） | NOT_RUN；原2个操作流程聚合保留，新增1个循环五类408→query404→query401→人工查询成功，检查固定原值、无重放、MFA不自动操作及创建取消不刷新 |
| submit_direct_variant_test V06 | NOT_RUN；仅补齐createdAt/updatedAt，保留归档单写／原版本／空正文断言 |
| SDK／format／analyze／测试／构建／视觉／真实接口 | NOT_RUN；本轮按静态优先安排，待资源及串行窗口确认后执行 |

本阶段仅提交11个相关文件，不推送、不部署、不清缓存或干预其他进程。当前服务不包含本阶段增强；历史结果不能证明新源码通过。

## 源码SHA256

| 文件 | SHA256 |
| --- | --- |
| apps/guardian/lib/core/api.dart | 0520FF9DF67E00DBFA4CF228008BA90A932294E3D10C8914CD4B6F6E02C8FF37 |
| apps/guardian/lib/core/device_group_change.dart | 3CD7B122583E62D950517729DEC41BBD8CD967004A92D55EFAD34601EEFB0E70 |
| apps/guardian/lib/pages/device_groups_page.dart | 096DBADE4D0D0CC023854BE1C966C55883BBABBD9508FC818DB1F86EEDEB700E |
| apps/guardian/test/device_group_change_test.dart | AAAEB4499BC7E808053F453D05E11A630CDACC6786F5E34BE6FD33C51B3B3297 |
| apps/guardian/test/device_group_flow_test.dart | 3AB731ED6031C220CC3FC5C12FC51535EA81DF411BC0DB5C0A4B8DBEE2ADD71E |
| apps/guardian/test/submit_direct_variant_test.dart | 0DF4C57B85511D8FF6DE2C0229AD350759DE7E9AF7B876C1DB6D479E16DAE68E |
