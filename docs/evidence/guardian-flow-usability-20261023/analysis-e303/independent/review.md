# Guardian r10 e303 分析准备独立静态审核

## 结论

既定 inputs、最终三控制文件、提案、Root启动器与 release 源码未发现新的静态阻断。先前 Git 启动接合缺口已关闭。后置 post 原件尚未最终审阅，端到端结果推导接口仍待该原件独审；本报告不能当实际可执行或应用通过结论。

当前无 grant、attempt 或 root-attempt。Root 最新报告可用RAM536850432B，低于保留的2GiB门槛；本审阅者未查询实时资源。全部当前应用分析/测试 UNRUN，无新增SDK授权或资格轮次。

## 输入与精确接合

inputs 13528B/35fb069ba0c9ddd86cc23a0c09f7f3bafab94e8764e787045e10712d80cfdcba 实际匹配。作者3文件交付、12项源/配置/历史元数据引用和26个独立runtime文件的实际size/SHA匹配；原control4+extra7前缀保留，r3六runtime在union中，psutil10代码成员准确。

cache projection 与旧r9逐字相同：70trees+32fixed=3536文件/633817159B；本次只读投影JSON，不重读633MB外缓存。410源绑定前一独审确认的当前r9-e303；181回归入口完整保留，80/7仅浏览器子集，额外28包测试仍在完整计划且在七-root快照外。runtimeClosureComplete=false、外缓存尚待未来pre/post验证均如实保留。

proposal 6463B/SHA 6ad444f0cc33b7d138a9bdfc74aa604a7393912cd63cf727f77e004dee177ad9：恰8keys、3固定相对controls、26unique runtime且均absolute=true，runtime集合与inputs一致，不接受任意命令/selector。原预算180/174/165/135/140/post25不变。

## 实际控制源码审核

已完整读最终host18928B/79b6e69e…46ca1、worker31761B/f7319e16…543c5。完整worker13-hunk及host1-hunk补丁逐行context/位置/计数重建每个字节；14个既有worker函数正文和runtime_check原循环之后的正文保持，owned_job13322B/f8b44764…c141b与已实际资格r3逐字相同。源代码仅作人工数据流/类型门槛审阅，不是语法/AST或运行证明。

- 固定完整Guardian analyze --no-pub --fatal-infos --fatal-warnings，无test/浏览器/selector/pub/download入口。当前HEAD/410 Main与frozen raw、七Git roots、包配置、3536cache membership/内容和runtime guards在完整pre/post中保留。
- Host/worker在其导入早期各记录原单调anchor；worker的135命令/140清理/165完整及host174工作/180终态截止均不重设。Root更早的180秒外层Stopwatch独立保留，实际宿主完整输出/退出仍须在其原截止前观察。慢预检会消耗余量，不扩预算。
- private kill-on-close Job、atomic suspended membership、retained身份保持。SDK root在写launch记录时仍暂停，再做剩余预算复查后resume；监控阶段不写普通stdout/fsync/hash日志。SDK与worker自然成功均要求完整Job0的post-accounting QPC严格早于原work截止与firstSignal+0.5的较早值；晚Job0、forced124、未知终态、close fallback、错误或报称/推导冲突都不能PASS。
- Host复核worker实际完整终态<workerStart+165，覆盖receipt/output尾部；Root再持同Process.Handle记录Start/Exit Filetime及首次WaitForExit信号，严格<180。外层超时仅精确own host Kill，单次最多请求2秒应急等待，绝非实时OS耗时保证；forced/error/tardy全RED。Root结果始终analysisAccepted=false，待独立post。
- worker.git仅对固定REPO/SDK使用-c safe.directory；SDK子进程有进程级COUNT=2及恰REPO/SDK两项，launch记录明确二者，未用通配或改全局。此项解决真实shared.bat裸git不经过worker helper的接合条件。Root Environment.Clear+固定白名单/PATH、本地TEMP，离线loopback与禁止override规则保留。
- Root SDK0/unknown0、RAM和双盘2GiB gate保持；worker门槛包括固定SDK名字、.test stem及None/空名处理。没有native内存硬上限或完整Python/SDK安装closure宣称。

## 启动器与释放边界

最终launcher9122B/SHA 74587554468edbf9c704d22220074aa7b407945d94485a62f5c865b219c169e2，反向仅替换expectedProposalSha一处便逐字恢复先审PENDING版本c95a2e24…8c072。单用目录、proposal/grant精确绑定、同句柄终态、失败RED、原资源/环境/预算逻辑无其它变化；当前grant文件仍不存在。

release4368B/SHA fba5876d82cc91eb34c72c65120b06d3e2e0da7942ceb08acdfb7a4c50a791e1 已全文读：只在既有同句柄signaled身份后读原结果及固定post，记录fresh完整进程/RAM/盘清单，要求SDK0/unknown0及已知host/worker/command PID均缺席，结合实际Root/Post工具exit0和固定post状态；无kill其它PID，无next SDK grant。

尚未最终审post原件，不能预填其typed schema/完整推导通过。release的固定接口要求 DERIVED_ANALYSIS_CONSISTENT_PENDING_ROOT_RELEASE +实际post exit0仅代表derived真且与报告一致；一致RED必须exit1。Root已接受并通知post作者。该待审接口明确保留，不为等待增加新轮次或改变当前候选。

## 指纹与限制

59项固定/历史/元数据/runtime引用末次size/SHA复核无漂移，详见review-pins.json。仅本地文本/hash/JSON、统一差异文本重建与自有报告；未导入/调用候选或其业务/资格谓词、未执行SDK/测试/AST/解析器/编译/formatter、WinAPI/进程查询或网络，Main/Git/候选/旧原件未写入。

任何后续源码提交均不由本e303快照证明。旧r9实际RED、原资格sdkAllowed=false及历史静态UNRUN不回写；本阶段准备不能代替181入口的未来完整验证。