# 原32身份基线：已完成的离线全 verify 证据归档

本目录归档 2026-10-21 已自然结束的原32身份模块离线 Maven `verify` 原件。归档阶段只读写指定文件，没有启动 SDK、测试、浏览器、服务或网络，没有重新运行验证。所有 `r1/`、`r3/`、`control-probes/` 文件均按原字节复制；没有将脱敏或重写内容冒充 raw 原件。

## 可支持的结论和边界

- 冻结来源为 Git 提交 `3b9117b000a10d082a8f7849c41de5f69c0baa62` 的 `identity-extensions`，模块 tree `098c8e75a7107876bdf31aba106882ff65b7d2b3`，源清单32文件；本次不从 Main/WIP 取源。
- 成功原件是 `.cache/id17-verify-20261021-r3-root`。`result.json` 为 `FULL_VERIFY_PASSED`，`receipt.json` 为 `FULL_VERIFY_WORKER_PASSED`。13份 main 和12份 test 编译输入与冻结清单精确一致；12套/71项方法测试，失败0、错误0、跳过0。归档中的12份 JUnit XML、4份编译输入/输出文件名清单以及 Maven 日志保留审计依据。
- 原验收记录中的 JAR 为70,660字节，SHA-256 `19c3d692661077979239fed82ea1c0f43519d43505584913eb5b9d2ee73e8b4b`，包含32个 main class、4份资源，主载荷精确一致。此处只保留记录，不复制 JAR 或 class 二进制。
- 原结果记录双份3788文件 Maven 缓存、冻结源、工具及配置均无漂移；Root 外部记录确认12份控制元数据 pins 全部匹配。原运行已过滤21个固定 consumer/SMS/WeChat/provider 环境键；这里只记录键名，不读取私有凭据或 `.env`。
- 这仅证明上述旧32文件、71项测试基线，不能作为后续 `df342e` / `984ae0f` 等当前33文件、76项测试的验证；也不证明真实 Keycloak/MySQL、短信/微信链路或 Android 验收。

## 成功运行的自然结束依据

`r3/attempt/external-acceptance-root.json` 是协调者独立验收原件：实际执行 session `9114`，初始 chunk `c23149`，最终 chunk `2445cd`，外层自然 exit 0，总耗时37.592368099998566秒，预算180秒；worker `129512` 与 Maven command `128308` 已不存在。没有强制终止或 watchdog 超时，私有 Job 最终活动进程为0。该记录在 `2026-10-21T06:32:23.596359+00:00` 报告 SDK0、unknown0、可用物理内存2,503,548,928字节。以上是原运行和独立验收时的事实，不是归档阶段的新进程观察。

`proposal.json` 与候选 README 中的 `STATIC_CANDIDATE_ONLY`、未批准执行等文字是准备阶段的原始状态，故按原样保留。实际执行授权摘要见 `attempt/request.json`；完成情况以 `attempt/result.json`、`receipt.json` 和外部验收记录共同为准。`initial-gate.json` 的 pins 尚未检查与 `launch-gate.json` 的 pins 已验证分别对应原执行时序。

## 保留的失败与控制探针

- `r1/` 保存原失败候选六文件及原 `request.json`、`result.json`。r1 实际 chunk `793a8c` 自然 exit 1，耗时0.06098989999736659秒；`CreateJobObject(None, None)` 的名称参数触发 `TypeError: None is not a valid string in this context`，`workerPid` 为 null。没有把这次失败重写为成功，也没有复用它的 attempt。
- `control-probes/probe-id17-job-control-20261021.py/.json` 保存第一次纯 Python Job 控制探针：worker 自然 exit0，但即时 Job 计数仍为1，`accepted=false`，0.057325999994645827秒。
- `control-probes/probe-id17-job-control-20261021-r2.py/.json` 保存第二次探针：有界等待自然 Job 计数归零后 exit0、Job0、`accepted=true`，0.06862010000622831秒。两次探针均声明未启动 SDK，只覆盖私有 Python 子进程与 Job 控制，不代表身份模块验证。成功 r3 增加最多1秒的自然计数排空等待，仍受原180秒总预算约束。

## 文件映射与完整性

`source-inventory.json` 在复制任何原件之前记录44份所选原件的来源相对/绝对路径、归档相对路径、字节数、SHA-256 和原始 Git blob SHA-1。原始 Git blob 按 `blob <bytes>\0` 加原字节计算，不应用 Git 文本过滤。复制后再次读取源与目标，全部三项相符；`archive-review.json` 记录文件核对、12份 XML 的计数/方法集合和13+12编译输入集合核对。

为避免将缓存源目录或被全局忽略的 `target/` 带入档案，原 `target/surefire-reports/TEST-*.xml` 映射到 `r3/attempt/junit-xml/`，原 `target/maven-status/maven-compiler-plugin/` 四份 `.lst` 映射到 `r3/attempt/compiler-status/maven-compiler-plugin/`。映射只改变归档位置，不改文件内容；原件中的绝对历史路径保留。

XML 每份58个 properties 中未发现 password/secret/token/credential/authorization/access-key/api-key 类非空属性，两份日志的同类赋值扫描为0；没有读取 `.local/runtime/credentials.json` 或 `.env`。源、依赖缓存、临时目录、class 和 JAR 二进制均未复制或清理。目录本地 `.gitattributes` 使用 `-text` 保留原字节；本地 `.gitignore` 仅允许本档案两份原日志进入 Git。归档操作没有暂存或提交。

`archive-inventory.json` 列出本目录除其自身外全部文件的精确路径、字节数、SHA-256 和原始 Git blob；自身摘要另交协调者独立核对。`source-inventory.json` 是原件的复制前清单，`archive-review.json` 与本 README 是归档阶段新写的说明，不能当作原验证日志。
