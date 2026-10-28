# 设备组明确拒绝后的页面退役：静态阶段

基线：`e7d14a1781430741b770ddd8e2d1d6494f30bb68`。只改页面拒绝处理与既有回归，沿用DeviceSubflowScope、ResourcePage和OwnedDialogRoute；无新依赖或后端协议。

## 变化

- 原有效列表、详情、成员分页或子操作收到403、非近期认证401、服务端WORKSPACE_CHANGED后，页面单向锁存失权，清空组资料、成员、摘要和筛选，推进原视图代次并关闭自有路由。相同本地Session通知或旧按钮不能复活页面；重新进入才重新读取当前授权。
- 子流程的私有Api委托原send/page/all/scoped，保留同一传输、pending写入、期限与分页；拒绝处理取本次isCurrent和原available的交集，不把原捕获已失效后产生的本地错误当成新视图失权。
- 列表捕获原归档筛选与代次，筛选改变在下一帧前同步退役。旧列表／成员页的迟到拒绝不影响新筛选；近期认证及普通网络错误维持原恢复语义，未扩展刷新缓存逻辑。
- SPEC、领域契约与稳定项目记忆同步。保留其他会话的工作区改动。

## 检查与待验证

| 范围 | 状态 |
| --- | --- |
| 限定页面、Api委托与原scope／代次／自有路由 | 已静读；不更换HTTP客户端、不改变写入或只读原结果协议 |
| 限定Git空白检查 | PASS；含新增记录，不代表编译、渲染或行为验收 |
| device_group_flow_test（browser） | NOT_RUN；现有3聚合保留，新增第4聚合覆盖真实列表／成员分页迟到403跨筛选、当前拒绝清理、同Session不复活、重新进入读取，以及三类query拒绝后旧回调不能操作 |
| 本轮资源准入 | 一次获准只读复核为RAM7.27／C5.47／D14.88GiB；Go进程PID35668仍在采样中出现，未确认SDK空闲，未启动或停止任何验证进程，未继续轮询 |
| 离线依赖准备 | 只读确认Guardian锁及package_config尚未纳入已声明的本地schedule_contracts；包和源码路径存在，下一窗口先受控离线解析，不手写生成配置、不下载依赖 |
| SDK／format／analyze／测试／构建／视觉／真实接口 | NOT_RUN；未重做工具资格，已有私有Job工具可复用，后续使用新的输出绑定保留旧证据 |

本阶段仅提交6个相关文件，不推送、不部署、不清缓存或干预其他进程。现有服务不包含本阶段增强；其他仓库结果及历史通过不证明新源码已验收。

## 源码SHA256

| 文件 | SHA256 |
| --- | --- |
| apps/guardian/lib/pages/device_groups_page.dart | 06A49D8EFD22C389D7B72E916A74801CB3C30B3A4E9A0C18A0E7691C897C075D |
| apps/guardian/test/device_group_flow_test.dart | A8933C1621F5295E4E29447241723EBFE1035D2F47A98466FF8B7C321E4ED8FE |
