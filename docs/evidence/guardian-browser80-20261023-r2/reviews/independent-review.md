# Browser80 r2：独立静态审核

**结论：未发现静态阻断。80 项浏览器用例均 UNRUN，本审核不授予执行权限。**

审查相对已独审的r1完成。只读字节、元数据和Python AST，没有导入/调用任何候选、SDK、native、observer或reporter，没有进程、网络或Git调用，没有Main、Git、原包或冻结件写入。

- 实际核对19 candidate、11 runtime、351 historical共381项文件摘要，以及22项delivery。旧Browser80 r1全部23文件、原269行固定记录、r7 RED归档60文件保留，r7仍analysisAccepted=false，无旧结果升格。
- controller、native inventory helper、reporter、Chrome observer、budget-policy五件与已审r1字节相同。worker全文只替换FROZEN和真实INPUT_SHA256，独立AST仅这两项赋值变化；所有函数、source_check409、labels、80/7门槛、两成功状态和aux flags均保持。
- 因此已审r3的same-retained-child首次退出、有限hard和严格小于hard/finishBy门禁、所有phase前后截止、fsync后完整再资格、精确私有Job成员PID/FILETIME/image/handle/IsProcessInJob/TotalProcesses、SDK/unknown/漂移拒绝均保持。没有放宽完整80名称、7suite、无error/skip及成功done规则，也没有增加清理权限。
- 新source seal423项匹配，409份冻结原始字节均重算Git blob SHA-1并匹配manifest；Main各自raw pins与完整成员也匹配。相对旧a558，仅observation_page.dart将`observationRoute!.available`改成`observationRoute.available`，恰好少1字节，另外408行完整源元数据不变。原两处CRLF差异仍分开保留，没有把LF规范化当raw恒等。
- 全部80 case与7个selectedSources完整元数据、selectors和计数完全相同。70package仅7个internal root重定向，63个external及其余元数据/seed历史记录保持。新源码树/manifest/seal/inputs/proposal均绑定45950b88；本轮没有重新调用Git，正式运行前当前Git身份仍由Root独立确认。
- input仅13个已记录provenance/路径/摘要/时间字段变化；其余原proposal策略不变。完整3537 browser cache和Chrome pin未改，没有误用analysis3536。当前Chrome可执行文件摘要匹配；没有重验全部3537实际运行时内容。

数值预算仍为300/294/288、controllerfinal6、local285、command210、cleanup6、postflight45。controller/result的pre-I/O elapsed不能替代实际终端时间；SDK/unknown/deadline/Job close fallback/outer cleanup仍拒绝。没有attempt、grant或自动衔接执行。

自己的静态helper自然返回0，仅证明上述核对，不证明Dart分析通过、浏览器行为或原生时序。后续仍需新资源/SDK0/unknown0窗口、新明确授权、完整source/package/cache/runtime前后检查、所有Job0、实际Chrome及outer终端与最终fresh门禁。

proposal SHA-256：`a9951961c2d4a933567bd38446228bb177cc469cdbe23a8d9b42b816f11857be`；seal：`84cc8f6078337e2efa4e2ca41ddb8a6f4aac32518f14334f5e9af7ea5ab15e56`。精确事实和摘要见 `review.json`、`report-pins.json`。
