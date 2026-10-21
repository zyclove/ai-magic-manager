# 当前33身份基线：已完成的离线全 verify 证据归档

本目录归档 2026-10-21 已自然结束的当前已提交33文件身份模块离线 Maven `verify` 原件，来源 `.cache/id17-current33-20261021-r1`。归档阶段只读写指定文件，没有启动 SDK、测试、浏览器、服务或网络，没有重新运行验证。`r1/` 和 `root-static-review.json` 均是原字节复制，未脱敏、重写或规范化换行、日志空格。

## 结论范围

- 冻结来源为 Git 提交 `984ae0f9ab4354b16ba6834a836c55ca2351db27` 的 `identity-extensions`，模块 tree `7796f5aaf6a38ff87b8a2ca77113bb8ef5ded321`。33份冻结输入来自精确提交的 raw Git blobs；Main/WIP 不作源回退。
- `r1/attempt/result.json` 为 `FULL_VERIFY_PASSED`，`receipt.json` 为 `FULL_VERIFY_WORKER_PASSED`。13份 main、13份 test 编译输入与冻结源清单精确一致；13套/76项方法测试，失败0、错误0、跳过0。13份完整 JUnit XML、4份编译输入/输出文件名清单和 Maven 日志保留完整审计依据。
- 原 JAR 验收记录为72,543字节，SHA-256 `7ce16dc23fb052085d7c55b95dda19fc7cbbbab100a4f199e37797bc36bdcff2`，33个 main class、4份资源，主载荷精确一致。这里保留原验收记录，不复制 JAR/class 二进制。
- 原结果记录冻结源、两份3788文件 Maven 缓存、工具与配置无漂移；Root 外部验收复核21份 pins 和33份冻结源。两份输入 manifest 的3788项缓存元数据及三份源清单中的33项源 pins 一致。归档不复制源码、缓存、临时文件或构建二进制。
- 此证据只覆盖上述身份模块、固定提交及本次离线 verify，不证明真实 provider/Keycloak/MySQL、短信/微信外部链路、UI、后端全量或 Android 验收。

旧32文件/71项基线单独保留在相邻 `identity-original32-offline-verify-20261021/`，本归档未覆盖或修改它。当前候选的公共机械差异、静态审查及测试提取元数据保留原件，可追溯新76项预期与旧71项方法的关系；不将两个基线合并为一次执行。

## 独立验收和自然终止

`r1/attempt/external-acceptance-root.json` 是 Root 的独立验收原件：实际执行 session `6447`，初始 chunk `37598e`，最终 chunk `596de8`，外层自然 exit0，耗时62.215007100006915秒，180秒预算内，无强制清理或 watchdog 超时，最终私有 Job 活动进程0。原 worker/Maven command PID `133824`、`15000` 已不存在。该记录在 `2026-10-21T07:02:39.582639+00:00` 报告 SDK0、unknown0、可用物理内存5,301,153,792字节。归档时核对 result、receipt 和全部13份 XML 的摘要与该外部记录一致；以上均为原验证和签收时的事实，没有在归档阶段重新观察运行状态。

候选 `r1/README.md`、`proposal.json` 及 `root-static-review.json` 中“静态准备”“没有 attempt”“testsRun=false”等是准备时的原始状态，故原样保留，不能解释为此后运行仍未发生。实际授权摘要见 `attempt/request.json`；完成情况由 result、receipt、外部验收共同记录。初始 gate 中 pins 尚未检查与 launch gate 中 pins 已验证分别对应原执行时序。原运行使用离线完整 verify、显式启用测试、进程局部512MiB JVM堆/临时目录和21个固定环境键名过滤，原全局环境未更改。

## 原件、说明和清单

- `r1/`：六份候选文件、公共 static-review/diff/workspace observation/test extraction/meta/delivery 原件、`frozen/` 两份 manifest，以及本次 attempt 记录。`frozen/` 这里只含元数据，不含源本体。`root-static-review.json` 是独立静态审查原件。
- 原 `target/surefire-reports/TEST-*.xml` 映射到 `r1/attempt/junit-xml/`；原 `target/maven-status/maven-compiler-plugin/` 四份 `.lst` 映射到 `r1/attempt/compiler-status/maven-compiler-plugin/`。归档位置变化不改内容；原绝对历史路径保留。
- 本 README、`source-inventory.json`、`archive-review.json`、`archive-inventory.json` 和本地 Git 规则是归档阶段的新文件，不能当作原验证日志。`source-inventory.json` 在复制任何原件前记录44份原件的来源/归档精确路径、bytes、SHA-256、原始 Git blob SHA-1。每次复制后重读源与目标，全部一致。
- 原始 Git blob 按 `blob <bytes>\0` 加未变更原字节计算，不应用文本过滤。`archive-inventory.json` 列出本目录除其自身外所有文件的精确绝对路径、bytes、SHA-256 和 raw Git blob；其自身摘要另交 Root。

公共 JSON 元数据敏感非空命名属性扫描为0，所选文件名无 password/secret/token/credential 等敏感元数据名称；每份 JUnit XML 的58个 properties 中同类非空属性为0，两份日志同类赋值扫描为0。未读取 `.local/runtime/credentials.json` 或 `.env`。本地 `.gitattributes` 用 `-text` 保留 CRLF 和日志空白，本地 `.gitignore` 仅允许本档案两份原日志进入 Git。归档操作没有暂存、提交或清理目录。
