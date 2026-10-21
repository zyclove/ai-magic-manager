# HTTP客户端复用：旧生产代码的反事实 RED 证据

本目录归档 `.cache/id17-red75-20261021-r1` 已自然结束的一次反事实离线 Maven `verify`。正常 runner 的 result 和 receipt 保持 `NOT_ACCEPTED`，Maven exit1、worker exit0、外层 exit1；Root 根据独立原件分类为 `RED_OBSERVED`，`fullVerifyAccepted=false`。这是观察到指定回归断言失败的证据，不能标成全 verify 通过。

归档阶段只读写指定公共文件，没有重新执行候选、SDK、测试、浏览器、网络或服务。`r1/` 下43份原件均按原字节复制，没有脱敏、改写、规范化 CRLF 或日志空格；相邻旧32与当前33两份档案没有修改。

## 有效33文件的明确来源

本反事实不是一个 Git commit/tree，`sourceCommit`、`moduleTree` 和输入 manifest 的 `commit` 均为 null。

- 基底是 Git `3b9117b000a10d082a8f7849c41de5f69c0baa62` / `identity-extensions` tree `098c8e75a7107876bdf31aba106882ff65b7d2b3` 的原32文件，保留旧生产代码及原71项测试。
- 唯一 overlay 是 `identity-extensions/src/test/java/com/aimanager/identity/ConsumerHttpClientReuseTest.java`，来自 Git `984ae0f9ab4354b16ba6834a836c55ca2351db27` 的 raw blob `875878539c3939d923aed709f39f532b30c5da01`，5,747字节，SHA-256 `3128eb0abaf10cc5123c64684f3e7cb27a7f5cc872ba64312f6d5acd422b5d54`。
- 两者组合成有效33文件、13份 main Java 和13份 test Java。该 overlay 不属于原32基底的 Git 内容，Main/WIP 也不是源回退。`frozen/` 只归档两份源/输入元数据清单，没有复制源本体。

归档核对了三份33项源 pins、两份3788项缓存元数据、14份公共候选元数据 pins，并以原32档案的清单只读比较全部32个基底 pins。proposal 的另外33个源文件 pins 仅与上述清单比较，没有在归档阶段读取源本体。Root 原独立观察记录确认所有54份 pins、双份3788文件缓存、原32与有效33源码全未变；这些原运行事实并非归档阶段重跑所得。

## 预期三项失败与实际观察

原 XML 完整记录13套/75项，恰有3项 Mockito assertion verification failures、0 errors、0 skipped，三项均在 `ConsumerHttpClientReuseTest`：

| 方法 | 旧实现观察到创建数 | 复用预期 | 原 failure type |
| --- | ---: | ---: | --- |
| `factoryReusesOneClientAcrossDistinctAuthenticatorInstances` | 2 | 1 | `TooManyActualInvocations` |
| `factoryUsesTheSameClientForWechatSmsAndOtpVerification` | 4 | 1 | `TooManyActualInvocations` |
| `injectedProvidersDoNotCreateClientsDuringPhoneChangeAndOtpVerification` | 5 | 0 | `NeverWantedButInvoked` |

创建数由 Root 独立观察原件记录；归档阶段核对其与事前 `expected-counterfactual.json` 的数量/类型一致，以及原 XML 的精确失败方法/类型、75项完整方法集合与声明清单一致。原71项全部通过；overlay 中 `disabledOrIncompleteProviderConfigurationDoesNotFailFactoryInitialization` guard 也通过，合计72项通过。没有其他失败、错误或跳过。

相邻当前新代码档案是在提交 `984ae0f` 上13套/76项全部通过；本反事实是旧生产代码加唯一测试 overlay，13套/75项预期三项失败。76与75的数量差来自当前快照额外包含 `ConsumerRuntimeSnapshotTest.failedProbesCloseStreamsAndOnlyTerminateTheirOwnLiveProcess`。归档阶段只读比较两份原 receipt 方法集合，确认唯一差异就是此方法，没有将两次运行当成相同测试快照。

Maven 自然在测试失败处停止，原 receipt 中 `jar.produced=false`。Root 的 RED 分类不要求失败构建生成 JAR，正常全 verify 接受规则仍要求零失败及合格 JAR；档案没有补造或要求失败 JAR。

## 自然终止和独立观察

`r1/attempt/external-red-observation-root.json` 是 Root 独立原件：实际 session `86358`，初始 chunk `e9623a`，最终 chunk `8d49f5`，外层自然 exit1，总耗时71.5325346999889秒，在180秒预算内；没有 kill、超时或强制清理，最终私有 Job 活动进程0，已知 PID `129300` / `126188` 不存在。记录在 `2026-10-21T07:09:40.355666+00:00` 报告 SDK0、unknown0、可用物理内存5,043,073,024字节。归档核对 result、receipt 及全部13份 XML 摘要与该记录一致，没有在归档时重新观察进程状态。

事前候选 README、proposal 和 `expected-counterfactual.json` 中的“静态准备”“预测未观察”“未批准执行”等状态按原样保留。实际授权摘要在 `attempt/request.json`；实际正常拒绝与独立 RED 分类分别见 result/receipt 与外部观察记录。没有把预测改写成观察，也没有把正常拒绝改写为通过。

此结果只说明三项回归断言能检出旧实现多余创建HTTP客户端的行为，不证明真实 provider/Keycloak/MySQL、短信/微信、UI、后端全量或 Android 验收。

## 原件映射和归档完整性

公共准备文件、机械diff、测试声明/提取、meta/delivery 原件位于 `r1/`，执行原件位于 `r1/attempt/`。原 `target/surefire-reports/TEST-*.xml` 映射到 `r1/attempt/junit-xml/`，原四份 `target/maven-status/maven-compiler-plugin/.../*.lst` 映射到 `r1/attempt/compiler-status/maven-compiler-plugin/`。位置变化不改内容，原历史绝对路径保留。源码、Maven缓存、tmp、class 和 JAR 二进制均未复制或清理。

本 README、`source-inventory.json`、`archive-review.json`、`archive-inventory.json` 及本地 Git 规则是新写的归档说明，不是原验证日志。source inventory 在复制任何原件前记录43份来源/目标精确路径、bytes、SHA-256 和 raw Git blob；复制后源与目标三项全一致。archive inventory 包含本目录除其自身外所有文件的精确绝对路径和三项摘要，其自身摘要另交 Root。raw Git blob 按 `blob <bytes>\0` 加原字节计算，不应用 Git 文本过滤。

所选公共 JSON 元数据、文件名、XML属性和两份日志经敏感命名属性/赋值扫描，没有发现 password/secret/token/credential 等非空值；未读取私有 `.local/runtime/credentials.json` 或 `.env`。本地 `.gitattributes` 的 `-text` 保留 CRLF 和日志空白，本地 `.gitignore` 只允许本档案两份原日志。归档操作没有暂存、提交或清理目录。
