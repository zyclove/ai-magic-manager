# 工作台身份隔离与刷新恢复

日期：2026-10-25。基于 `dbe7203` 后的本批源码增量；最终输入由下列原始结果中的 `sourcePins` 固定。未更新运行服务。

只读工作台复用既有 `DeviceSubflowScope`，绑定 Session、账号、租户、角色与会话代际，离开页面后永久作废原请求与回调。普通刷新保留摘要并提示尚未更新，同批重复刷新只发一次请求；已授权入口不再依赖概览请求成功。窄屏和大字体下的指标卡按可用宽度排为 1–3 列。

管理员工作台的读取与操作失败统一处理：401、403、工作空间失效时隐藏旧指标、审计和读取时间，撤销原作用域；同上下文重建不偷偷重新授权。仍属同一身份的 401 可重新验证，新上下文再捕获作用域；普通 503 保留旧数据并允许重新读取。规格与项目记忆同步记录该边界。

| 定向检查 | 实际结果 |
| --- | --- |
| 两页面、两测试文件严格分析 | 首轮 1 条花括号规范提示；修正后只复查该页面通过。随后测试定位器改动只复查该测试文件通过；其余两文件沿用首轮无问题结果 |
| 管理员工作台 | 首轮 4 项通过：刷新拒绝、普通 503、操作拒绝、401 重新验证与新代际恢复 |
| 只读工作台 | 首轮 3 成功/4 失败；修正测试按钮定位器后，仅复跑本文件，7 项通过、0 跳过 |
| 两次浏览器之间的输入 | 仅测试定位器发生变化，页面及其他选定源码相同 |

按文件取最后适用结果，共 **11 个不同用例通过**，不能将重复运行相加。首轮 4 个失败均停在测试的按钮查找：当前 Flutter 的 `.icon` 工厂返回子类，改为类型谓词匹配，保留原业务断言。没有为测试通过修改产品行为或放宽取证。

**浏览器整体仍为 `NOT_ACCEPTED`**：复跑原生命令自然退出 0、无强制终止、终态成员归零、选定输入前后相同、后置 SDK/未知进程名计数为 0，但成员采样保留 `OWN_JOB_MEMBER_HARD_ERROR`、`OWN_JOB_MEMBER_IDENTITY_UNPROVED`。应用断言成功不能代替完整浏览器验收；不为追绿重复运行。

原始记录位于 [本批证据目录](../evidence/guardian-workbench-20261025/)：

- [首轮分析](../evidence/guardian-workbench-20261025/analysis-first-result.json)、[原始输出](../evidence/guardian-workbench-20261025/analysis-first.log)；[页面复查](../evidence/guardian-workbench-20261025/analysis-page-rerun-result.json)、[输出](../evidence/guardian-workbench-20261025/analysis-page-rerun.log)；[测试复查](../evidence/guardian-workbench-20261025/analysis-test-rerun-result.json)、[输出](../evidence/guardian-workbench-20261025/analysis-test-rerun.log)。
- [首轮浏览器结果](../evidence/guardian-workbench-20261025/browser-first-result.json)、[原始输出](../evidence/guardian-workbench-20261025/browser-first.jsonl)；[只读工作台复跑](../evidence/guardian-workbench-20261025/browser-scoped-rerun-result.json)、[原始输出](../evidence/guardian-workbench-20261025/browser-scoped-rerun.jsonl)、[完整取证](../evidence/guardian-workbench-20261025/browser-scoped-evidence.json)。取证已嵌入失败账本和终态记录，不重复归档。

本批没有执行全量测试、发布构建、真实账号/数据库联合流程或设备验证，不能代表完整产品验收。
