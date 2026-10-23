# 提交等待补丁：独立静态快审

**无静态阻断；仍为全部 UNRUN 的测试候选。**

核对两份 Main before、8份delivery pins及完整补丁。仅 reports3＋observation5 处有效HTTP提交改为现有_Invocation立即启动→现有flushReads→completed=true与failure=null断言。新增helper及8处替换反向还原后逐字节等于原文件，独立生成的diff也精确等于5589字节原patch。

全部原expect、503/428/202与401/503/412 fixtures、请求次数、draft/body、Idempotency-Key、If-Match与回调顺序保留；两份_Invocation未改。closed/invalidated/busy/form/terminal等直接await及无pump同步检查没有被替换。Future异常仍会使新增failure断言失败，完成也必须明确成立，没有静默丢弃后当通过。现有flushReads仍是8次real-zero runAsync＋50ms pump；生产25秒timeout、测试超时和生产代码均未改。

全部7套件的字面名称表达式与sealed80一致，两目标的循环和名称未改，因此保留原80／7命名范围。新增helper改变声明行号，未来必须重新封存源码位置合同。

这只是可审阅的调度修订：生产链经boundedJson等待client/send/stream，fixture直接提供MockClient，存在需要让既有drain前进的合理静态解释；没有运行挂起复现或取得堆栈，不声称唯一根因已证，也不声称这8处或80场景已通过。有界drain若仍不足，新完成断言会失败，需后续实际验证。

本轮仅新cache报告和文本/hash核对；未导入候选、运行SDK/formatter/test、调用进程API/网络/Git，未写Main、旧冻结件或候选。
