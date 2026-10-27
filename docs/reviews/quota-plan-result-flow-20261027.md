# 额度计划原结果与资源租约：静态阶段

基线：`58ad8b4fd493b00888f7b89e6c6ded778bac916e`。复用后端既有结果接口、Flutter Material 与 ResourceActionLease；不新增依赖、数据库设计或部署产物。

## 改动

- 新建／更新使用固定UUID。未知后只查询原创建／更新结果，保留原正文与更新If-Match，不携带写入幂等头。QuotaPlanEditor必需只读恢复回调，普通保存和查询入口分开；旧保存回调不能悄悄查询或重放写入。
- 纯模型完整核对committed，current单独表示后来配置；UPDATE回执必须原version+1且资源身份／createdAt不变，同版本current须全等。列表接收前、详情、日历及保存结果严格解析日期、7天、60个例外、整数秒、安全版本及类型，并脱离原Map。
- 404／近期认证要求及坏回执保留原输入锁；后续修订仅提示核对当前列表，不误报当前仍是原配置。保留原停止、精确秒数、本地日期准备和独立关闭确认机制。
- 列表、详情、历史、编辑及HTTP共享原资源操作租约。普通取消／只读返回false，保留分页和搜索；已尝试保存及明确未知关闭返回需核对信号，不等于保存成功。
- 明确拒绝详情、编辑目录、日历、写入或结果查询时，当前页面／租约退役并隐藏旧内容，旧范围晚到失败不影响新页面；近期认证不据此撤销原未知。ResourcePage新增可选onReadDenied，只在有效读取代次清除拒绝状态后通知原回调，历史列表据此退役父范围，不改变通用分类。
- 只读空态提供可查看范围说明。SPEC、共享额度契约、重复计划说明和项目记忆同步。

## 检查范围

| 范围 | 状态 |
| --- | --- |
| 限定差异、既有后端接口、参数／身份／回执、租约与拒绝范围 | 已静读；修正明确详情读取拒绝仍保留旧列表的问题 |
| 限定 Git 空白检查 | PASS；不代表编译、渲染或业务验收 |
| quota_plan_change_test | NOT_RUN；3个聚合：严格快照／日历与深冻结、全回执、原结果／当前事实 |
| quota_plan_editor_test | NOT_RUN；原未知聚合改为单次写入＋404／401／成功查询，验证原正文和旧保存回调；既有日期／停止／关闭继续保留 |
| quota_plans_flow_test（browser） | NOT_RUN；生产Page／Api与HTTP夹具，覆盖取消／只读保留列表、保存／原查询／未知关闭核对、晚到范围与明确拒绝退役 |
| resource_page_resilience_test | NOT_RUN；扩已有读取拒绝通知次数、资源替换后晚到错误隔离，以及普通网络／写MFA不通知断言 |
| SDK／format／analyze／测试／构建／渲染／真实接口 | NOT_RUN；按用户要求等待资源和串行窗口，保留RAM／C盘／D盘各至少2GiB及SDK空闲门槛 |

只提交相关文件，保留其他会话改动；不推送或部署。现有服务未包含本次变更；历史结果不证明新源码通过。

## 源码 SHA256

| 文件 | SHA256 |
| --- | --- |
| apps/guardian/lib/core/api.dart | CB7675E0830996B4EE1EB9393C84B11AC64CF2D3ACA453C86EE86CC2B48F2A22 |
| apps/guardian/lib/core/quota_plan_change.dart | 5B48314F8EB4B07DE24CA835AE576A7F5D585634547EEF248A817B5E51BE5AE5 |
| apps/guardian/lib/pages/quota_plan_editor.dart | 230517BFBC9E16312725ACA51915E4DF50E69FFFFAEF90C7B1AAA6B731DCE717 |
| apps/guardian/lib/pages/quota_plans_page.dart | 8951FF6C6C390A13DF1F41288FD585ADEB7AA5FC735D26DFC4CC74767DF421AC |
| apps/guardian/lib/ui/resource_page.dart | 3A2A857757DACC939B19D8571C8485D8F1A2A57AE6146602CE7BF9240184A795 |
| apps/guardian/test/quota_plan_change_test.dart | 6BD5614B5CA3C27DE607D167069673067E12F9CF91C1796A3B50363022AA1853 |
| apps/guardian/test/quota_plan_editor_test.dart | 23328CCB996E93130D208F934D7CDC3FFD08E20503F235CC3A8BED58F90AD7F2 |
| apps/guardian/test/quota_plans_flow_test.dart | 0D9F3196137670E0D2513474C2ACC57A6F3190FBE672FDA5E6174BF936C04845 |
| apps/guardian/test/resource_page_resilience_test.dart | 40DA68D588C4AF603027103A7C0B8BB4129CF0062B36A8E5E57D2B616CA02B47 |
