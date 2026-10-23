# source409 r2 与 analyze r8：独立静态审核

**结论：静态无阻断。运行状态由 Root 独立验收；本审查没有运行 SDK、候选或授予执行权限。**

只读文件、Python AST和Git；没有候选导入/执行、native/进程API、网络、Main/Git/冻结件写入。自己的helper自然返回0。原封存UNRUN描述保留为准备检查点，未改写。

## 新源码

- source seal423份固定字节匹配。独立读取实际45950b88提交和当前7根Git树、409文件mode/OID及全部blob内容，重算SHA-1；frozen逐字节相同，Main自己的raw pins与完整成员也匹配。没有以manifest自报替代真实Git读取。
- 相对a558，仅observation_page.dart删除`observationRoute!.available`中的1个`!`，另408行完整源元数据不变，无删增。旧source r1全部固定字节保持。原quota_balance/pubspec两处CRLF差异仍分开保留；没有以规范化冒充原始字节相等。
- 全80 case、7 selectedSources、selectors、声明元数据及计数与旧版相同；70package仅7internal root重定向，63external和其余配置/历史seed资料不变。source tree为`f8666796ddd71389e022000754df0e4d81da75fe0cd186d6d7c894b1c51e4246`。

## r8 检查包

- 12 candidate、11 runtime、250 historical共273项实际文件摘要匹配，r7原212行完整记录仅按历史绝对路径保留；proposal/inputs/seal与交付值相同。
- controller/native同时与实际已验r6和未通过r7字节相同。worker全文仅FROZEN和INPUT_SHA256两处机械替换，独立AST亦只这两项赋值变化；source_check409及所有函数、预算、命令、guard、deadline、清理保持。完整机械diff独立重算相同。
- inputs只有10个已记录source/package/provenance/时间/说明字段变化，其余原proposal策略相同。命令仍是全Guardian analyze、no-pub、fatal-infos、fatal-warnings，无选择器；无自动衔接浏览器。
- 预算保留outer180/soft174/worker165/commandcap150/cleanup5/postflight25，动态最晚135/140。analysis projection与r6/r7字节相同，3536文件/633817159 bytes、70trees/32fixed。未将它冒充browser3537投影，也未重验全部3536实际运行时缓存内容。
- r7实际result、receipt、RED独立readback、formal release及修复来源保留：session1854，自然1，0error/1warning/0info，analysisAccepted=false。实际accepted控制基线仅r6/session35555自然0；两者都不向新源码传递运行通过。

## 审阅与实际运行的时间关系

开始核对r8时观察到attempt目录已出现。Root随后明确确认，这是其新授权`guardian-analyze-r8-root-20261023`下的独立实际运行，并要求本审查继续只读不可变文件。该目录不是本审查创建；本审查没有调用、写入或据此接受运行结果。

因此本报告只给出静态无阻断结论。Root的实际终端、完整前后hash、诊断、Job0、最终系统门禁与formal release需另行记录和验收，不由本报告替代。原UNRUN准备记录不改为通过；80项浏览器也没有在本审查执行。保留外部严格终端时限、新资源/SDK0/unknown0和独立授权契约，清理不能升级失败或超时。

proposal SHA-256：`f6f9a00027a9b070a2b289e5560a34d31c3314e2137a40cd75a8b1dd76e03ae1`；seal：`63cadf20e9245ae85b9124c30cab9fb3393966b3b51489c3e4cd9fffa334c736`；inputs：`53795ab6aedf4c0621516c4f2b54c638f11e646ee590d305f2383aac79e5e02c`。精确事实和已核对摘要见 `review.json`、`report-pins.json`。
