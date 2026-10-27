# 每日额度原结果与账本流程：静态阶段

基线：`6210b9e11e05e6c6c6347669ee266f5683322eba`。复用现有创建／调整结果接口、表单查询hook、Material与ResourceActionLease；未增加依赖、改变建库或更新服务。

## 变化

- 创建及调整均支持分钟＋可选秒，创建0合法，调整至少1秒且不超过24小时；减少前检查已结算＋预留下界。唯一儿童预选，日期就近校验，控件值仅转换为limitSeconds或带符号deltaSeconds／reason。
- 写入使用固定UUID，未知后仅查原结果；调整保留原If-Match，查询无写入幂等头。完整核对原回执，current独立表示后续账本变化，不以当前余额冒充原提交证明。
- 纯模型解析池的18字段与流水，校验余额恒等式、来源、整数／日期与展示时间戳范围，允许23／25小时DST周期。后端QuotaPool显式保留nullable关联字段，避免全局NON_NULL配置产生不完整事实。
- 列表、详情、调整表单及流水借用同一资源租约。取消／只读保留分页与搜索；已尝试写入或明确未知关闭仅请求核对列表，不代表保存成功。未知调整关闭后结束旧详情，避免继续使用旧版本。
- 页签选择同步推进viewGeneration，两分支权限／回调与key捕获原代际；下一帧前的旧请求也失效，晚到拒绝不影响新视图。有效范围内明确拒绝读取或操作时隐藏旧资料，近期认证保留原未知。
- SPEC、共享额度契约与项目记忆同步。现有QuotaBalance外部改动未编辑或提交。

## 检查与待验证

| 范围 | 状态 |
| --- | --- |
| 限定源码、既有后端参数／日志、余额与原结果、租约与视图代际 | 已静读；修正页签下一帧前旧操作有效及可空字段缺失误判问题 |
| 展示时间戳范围 | 只读本机SDK DateTime API范围，未执行SDK；纯模型拒绝超范围的JS安全整数 |
| 限定 Git 空白检查 | PASS；不代表编译、渲染或行为验收 |
| quota_pool_change_test | NOT_RUN；3个聚合覆盖池／流水／冻结与边界、创建／精确调整、原结果及后续余额 |
| quota_pool_flow_test（browser） | NOT_RUN；3个聚合覆盖只读／取消保留列表、创建／调整查询及未知关闭、页签同步退役／晚到目录／旧入口／流水拒绝。创建夹具使用近日期并按UTC正文计算一致周期；远期读取夹具仅用于固定可调整场景 |
| QuotaPoolJsonContractTest | NOT_RUN；纯Jackson单聚合覆盖全局NON_NULL下18字段齐全，手工池null及计划池关联值 |
| SDK／format／analyze／Java／Maven／测试／构建／渲染／真实接口 | NOT_RUN；按用户要求等待资源和串行窗口；保留RAM／C盘／D盘各至少2GiB与SDK空闲门槛 |

只提交本阶段相关文件，保留其他会话改动；不推送、不部署。现有服务不包含本阶段增强；历史结果不证明新源码通过。

## 源码 SHA256

| 文件 | SHA256 |
| --- | --- |
| apps/guardian/lib/core/api.dart | FF62243253AD7DF1D8A9063793C639463C4A76407BC51E2CAD88270F75C00A3F |
| apps/guardian/lib/core/quota_pool_change.dart | 929FDE0E906EA02C96CA7760DD165A22338D4343E13B696BAB72AB6E73741279 |
| apps/guardian/lib/pages/quota_page.dart | C60BCC24EFBC4D015782C6DB85AB19F1444B62D55D999906733B327E8193A294 |
| backend/src/main/java/com/aimanager/quota/QuotaPool.java | 6AD113449C406A0D7E3D1CD661853E826198D5823957E7BAA95AF55E15B61B6C |
| apps/guardian/test/quota_pool_change_test.dart | 9A9D55DD5AE38BE0972B574D4DE14BEF2D14B4A4FADF362129E18CFE4DAE7C09 |
| apps/guardian/test/quota_pool_flow_test.dart | EC61FCC141101C7019C243D84881FD0E163FF7AB11837130D7188CC30E366DE4 |
| backend/src/test/java/com/aimanager/QuotaPoolJsonContractTest.java | 5AE1D894A706321633518408B5A5314761D635A0B0A283846F833482EF20D457 |
