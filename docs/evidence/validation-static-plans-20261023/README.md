# 验证静态计划持久证据（2026-10-23）

状态：**静态计划，全部 UNRUN；不是完整执行包，不授予执行窗口。**

## 范围

| 计划 | 完整静态范围 | 平台/结构结论 |
| --- | --- | --- |
| Guardian 回归平台 r2 | 181 根 = 142 Guardian + 全部37个当前Git跟踪包测试（含example widget）+2个独立HTTP工具 | Guardian39浏览器/1VM/102中立；包11VM/26中立；HTTP工具2VM且须人工夹具预检 |
| identity current35 | 35精确Git/LF文件、14 main Java、14 test Java、4 SPI/CDI资源；14类98个@Test方法声明 | 43份直接依赖/插件/父POM的静态文本元数据；不是Maven有效模型或编译/运行通过证明 |

两个HTTP工具会真实修改Spring夹具业务状态，teardown不恢复服务端；需显式新夹具或外部重置安排，不能自动混入普通单元回归。平台中立仅表示本地必要导入未见内在限制，不等于外部包/插件已编译兼容。critical80只是完整181根的一部分。

identity的A2基线为a2b5ca6ef2398397e4208065090b7c1d65992358，模块树96ab1e0f33eb3696fd715bfe482b9708ce6869e4；归档前35份Main raw重新匹配原静态观察，身份源码仍是该基线。Main POM raw4713字节与Git/LF4607字节的差别仅106处CRLF；未回写Main或回滚POM。98名是静态词法提取，旧3个4MiB覆盖层不加入当前完整35；JAR35类只是待验证合同。

## 归档内容及边界

12份原始README/summary/expected/source-manifest/static-plan/control-addendum/POM及Main观察元数据/最终pins均逐字节复制。另新增本README和archive-manifest.json，共精确14个文件。archive-manifest.json逐项列原件、目标、字节数和SHA；精确暂存清单在项目.cache/validation-static-plans-archive-20261023-r1/stage-pins.json。

没有复制35份源码、43份POM正文、Git源tar、JAR、工具二进制、3788缓存、运行器或Guardian约2.7MB全图。r1 summary、351节点flat graph及全图均复核原SHA并在manifest引用；不复制图不代表这些引用已变成完整耐久执行输入。子目录README和原pins保留原文，它们提到但未随档复制的文件仍只位于原.cache路径，不能假定归档子目录自包含。

静态身份计划原180/174/60/6预算、512MiB及2GiB门槛、完整离线verify/无selector只作未来独立审查参数；没有新控件、修改旧审批或扩大预算。现有314秒r9故障诊断属于另一份证据，不因本静态归档升级任何运行结果。

Root须独立读回后自行精确暂存/提交。本归档步骤没有Git写入、生产源码修改、SDK、测试、网络或进程控制。
