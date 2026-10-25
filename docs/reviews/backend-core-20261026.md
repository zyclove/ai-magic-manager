# 当前后端编译与关键领域验证

日期：2026-10-26（运行跨越北京时间午夜）。基于 `d82a323` 后的共享工作树增量；675 份输入的摘要在原始结果 `sourcePins` 中。本次没有复制源码、清空旧产物、构建服务 JAR或更新服务。

## 交付

- Maven 新增可选 `backend.build.directory`，默认仍为 `backend/target`；本次实际使用 `.cache` 中独立目录，保留旧编译产物与报告。
- 模块边界测试按本次测试类 CodeSource 精确排除夹具，检查目录存在、生产输出不在测试根下；原有生产依赖 `verify()` 保留。没有按 `Test` 名称、整个包或违规列表放行。

## 实际结果

| 检查 | 结果 |
| --- | --- |
| 当前后端及全部测试 Java 源码离线编译 | 通过，约 35.1 秒；675 份输入前后不变 |
| ApprovalJourneyTest | 16 项通过 |
| NotificationJourneyTest | 13 项通过 |
| ScheduleTest | 7 项通过 |
| SchedulePresetJourneyTest | 1 项通过 |
| ModuleBoundariesTest | 首轮 1 错误；精准排除测试输出后单例 1 项通过，约 39.3 秒 |

按最后适用文件计算 **38 项通过，0 跳过**。业务批次约 72.6 秒，首轮整体退出 1 没有改写；其后仅模块测试源码变化，生产源码、资源、POM 和 37 项业务测试源码均保持相同，未重复业务检查。三次命令分别自然退出 0、1、0，无强制终止；后置 SDK/未知进程名计数均为 0。

ArchUnit 1.4.0 默认仅识别 `target/test-classes`、`build/classes/.../test`、`out/test` 等测试路径，未识别本轮 `out/test-classes`，因此把集成测试及其跨域夹具计入模块图。已核对实际 JAR 接口并采用 Spring Modulith 的额外类型谓词，仅排除当前测试输出目录；门禁复验后通过，不能将原失败隐藏为未执行。

使用现有 Java 17.0.14、Maven 3.9.7 与缓存，未联网解析或升级依赖；临时目录和内存设置只作用于测试进程。业务检查使用声明的 H2、MockMvc 与模拟 JWT，通知可覆盖的数据源显式固定为 H2，移除与本次隔离测试无关的外部配置，不连接业务库、真实身份或提供方。

原始记录位于[证据目录](../evidence/backend-core-20261026/)：`compile-result.json` / `compile.log`、`first-tests-result.json` / `first-tests.log.gz`、`module-rerun-result.json` / `module-rerun.log`；四份业务 XML 及两轮门禁 XML 一并保留。首轮日志和门禁 XML 含大量重复依赖图，使用标准 gzip 保存，并已解压逐字节比对原件，其余记录没有重写。

共享工作树含其他会话未提交内容，结果绑定实际输入，不代表本阶段提交包含这些工作。上述检查不证明全量后端、真实数据库/身份/设备、容量、恢复或新发布已验收。
