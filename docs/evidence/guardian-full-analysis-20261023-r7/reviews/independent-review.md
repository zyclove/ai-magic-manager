# source409 与 full Guardian analyze r7：独立静态审核

**结论：两部分均未发现静态阻断。当前409分析和80项浏览器用例仍 UNRUN；此报告不授予执行权限。**

审查对象为 `.cache/guardian-observation-current-20261023-r1` 和 `.cache/guardian-analyze-20261023-r7`。独立 helper 只读取文件、计算哈希、解析 Python AST、执行 Git 只读查询；没有导入/调用任何候选、原生或外部观察函数，没有启动 SDK、Dart 解析、分析、编译、浏览器、测试、网络或进程 API，没有写 Main、Git、原冻结件或原证据。

## source409

- 封存423项文件摘要和完整成员集合匹配；实际源码409份均以提交 `a55849d902b248fe02d06e23cd0bad3d28912a27` 的 Git blob 原始内容独立重算 SHA-1，并逐字节匹配 frozen。7个根树、当前 Main 完整成员与各自 raw pins 也匹配。
- 对比原408，只有 observation_page、observation_editor 两处修改及 observation_route_scope_browser_test 一项新增；没有删除，另外406行完整元数据相同。旧408 seal 的全部原文件和成员集合保持。
- Git raw/frozen 与 Main raw 分开检查。原 `quota_balance.dart`、`pubspec.yaml` 两处行尾差异仍明确保留，全部409仅 CRLF→LF 后相等；没有以规范化结果冒充原始字节恒等。
- 原67 case 及前6个 selectedSources 的全部名称、行号、loop binding、声明和源摘要元数据逐项保持。新增13个观察 case 的字面名称、声明行号、无loop绑定与源 Git blob/摘要独立匹配，组成80/7，计数8/4/19/7/8/21/13。没有调用候选名称提取器或进行 Dart 解析、运行时发现。
- 70项 package config 只重定向7个 internal root；63个 external 行及其他所有配置字段保持。dependency seed 也只改7个 proposed root，历史访问错误和 library metadata 原样保留；没有把这些历史资料说成新的运行时缓存检查。

source tree SHA-256 为 `ddf027a0292fb2e06ac069a60bc03c87676fbeb4efc3d6f4a23186da0c87110a`；manifest `a23441e3f91224f86296a1b5b3ada8c7b2a8d5189c2ce36bfb6510a7ed0347b5`；seal `700d75070f869bcc666f373394ec77b688bb1b48950f1390f4312be72022d1f7`。`source-review.json` 是先于r7交付完成的源码检查记录，所含 R7_PENDING 只描述当时的独立阶段；r7结论以之后的 `r7-review.json` 为准。

## analyze r7

- proposal的12 candidate、11 control runtime和189 historical metadata共212项都按实际文件字节验证。r6原156行仅将相对路径解析为历史绝对路径，完整记录和摘要均保留。
- controller/native与实际已验r6字节相同，两份机械diff为空。worker全文等于原文件仅替换 FROZEN、INPUT_SHA256和source_check三处408整数/一处文字至409后的结果；独立AST也只有这三个顶层节点变化。机械diff独立重算相同，其余预算、缓存、运行时、命令与清理节点没有变化。
- inputs仅11个已列明源码/封存/时间/说明字段变化；其余字段以及proposal所有保留策略字段不变。固定命令仍是全Guardian analyze、no-pub、fatal-infos、fatal-warnings，无文件选择器；工作目录精确指向新封存源码。
- 预算保持 outer180/soft174/worker165/commandcap150/cleanup5/postflight25，动态命令/清理最晚仍为worker相对135/140。cache projection与r6字节相同，70 trees、32固定项、3536文件/633817159 bytes。只核对投影元数据和固定proposal pins，没有重新验证3536份实际运行时缓存内容。
- r6实际result、receipt、launch、log、pre/postflight、原external observer及root-final-system-gate均被固定。原observer的AWAIT_FRESH_SYSTEM_GATE状态未改写；另一个原root gate保留session35555、自然0、SDK0/unknown0/Job0和formal release。历史408验收不传递给409。

proposal SHA-256为 `2c1c4e32c0255b3a3eaa4272058ef5eb5f2e5388e5eb58b45d5a1ceb6d37ef36`；inputs `1f6f40ba9dd55123bb3a7da37078224dc32c84e7d0694109fd5c21c55a10ff70`；seal `07f73d81f4e45f8501bad2a71e027904d1eef281376d9e6aa7131f51c128df0a`。

r7原16个交付文件完整，没有attempt。Root随后新增的root-static-review.json与external_observe_root.py依其明确说明，作为独立、未调用且不属于proposal的审查材料单独记录摘要；没有纳入候选或据此继承通过。

## 后续验收边界

本审核自己的两个 helper 均自然返回0。该结果只证明上述静态核对，不是409分析或80项浏览器执行结果。r7保留了原r6的外部真实终端时间验收契约：Root仍需新的资源与SDK0/unknown0窗口、明确授权、实际自然退出0/无诊断、严格完整终端时间、完整source/package/cache/runtime前后检查、所有Job0及最终新系统门禁。清理不能升级失败或超时结果；没有自动衔接到浏览器。

精确事实和固定摘要见 `source-review.json`、`r7-review.json` 与 `report-pins.json`。
