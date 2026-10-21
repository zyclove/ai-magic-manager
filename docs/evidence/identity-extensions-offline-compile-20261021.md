# 身份扩展离线编译验收记录（2026-10-21）

## 结论与范围

**本轮仅签收 `identity-extensions` 的完整 `test-compile`。JUnit 测试、JAR 打包、Keycloak/MySQL 运行验收及全平台联调尚未签收。**

实际 Maven 退出码为 **0**；从前置核对到结束共 **26.914 秒**，满足本次 180 秒预算。编译器输入清单精确覆盖 **13 份主源码与 12 份测试源码**。没有筛选、排除或修改源码来缩小范围。完整机器记录见 [JSON 证据](identity-extensions-offline-compile-20261021.json)。

| 项目 | 已核实结果 |
| --- | --- |
| 固定源码提交 | `3b9117b000a10d082a8f7849c41de5f69c0baa62` |
| 当前提交核对时点 | `e0ac83aa5082fd6271505c1e3b4a5f875e3a1d5f`，仅核对身份模块 |
| 两提交身份模块 Git tree | 均为 `098c8e75a7107876bdf31aba106882ff65b7d2b3` |
| 模块输入 | 32 文件，含 13 主 Java、12 测试 Java、4 资源和构建/说明配置 |
| 工具链 | Java 17.0.14、Maven 3.9.7；Keycloak provided 依赖 26.8.0 |
| 原冻结缓存 / 隔离执行缓存 | 各 3,788 文件，文件集合和全部内容摘要均无漂移 |
| 编译输出 | 32 主 class、19 测试 class、4 资源，共 55 文件；class 数包含内部类 |
| 测试执行 | 未执行；12 份测试源码静态声明 71 个 `@Test`，不能视为 71 项通过 |
| 服务与外部供应商 | 未启动服务，未发短信或微信请求，未更新现有部署 |
| 资源释放 | 外层句柄自然结束；已启动的子进程确认消失，结束后的采样无 SDK 进程 |

## 执行方式与仓库来源

实际窗口为一次离线 Maven 调用，外层会话为 `1639`。Maven 于 `2026-10-21T04:42:52.343760Z` 启动，完整执行收据在 `04:43:00.425394Z` 生成。命令形态如下，具体路径与参数保存在 JSON 的 `actualInvocation` 中：

```text
mvn -V -o -B -ntp -s <独立任务>/offline-settings.xml
    -f <固定源码>/identity-extensions/pom.xml
    -Dmaven.repo.local=<独立任务>/m2 -DskipTests=true test-compile
```

任务专属 Maven profile 同时声明真实的 `central` 与 `aliyun-central` 来源，依赖仓库和插件仓库一致；配置含 `offline=true`，命令保留 `-o`。原项目 settings、POM、依赖版本和缓存元数据均未修改。

这是对混合缓存来源上下文的适配。Maven Enhanced LRM 会检查缓存所属的远程仓库；仅有文件并不足以保证当前上下文可用。[Maven 本地仓库说明](https://maven.apache.org/resolver/local-repository.html#enhanced-lrm)明确了这一行为；独立 profile 使用的是标准 [Settings 的 repositories/pluginRepositories](https://maven.apache.org/settings.html)。没有通过删除来源记录或关闭来源检查取得通过。

## 失败历史保留

| 尝试 | 实际结果 | 编译范围与解释 |
| --- | --- | --- |
| r1 | Maven 退出 1，完整 27.741 秒 | compiler-plugin 缓存来源为 `aliyun-central`，原命令上下文仅有 Central；未完成源码编译 |
| r2 | 前置检查拒绝启动，19.335 秒，SDK 调用 0 | 记录为 `Launch-time gate failed`；当时未持久化瞬时采样，不能补推为某一个内存、磁盘或 SDK 条件失败 |
| r3 | Maven 退出 1，完整 23.932 秒 | 原镜像 settings 解决插件来源后，两个 Jackson 依赖仍来自 `central`，在仅阿里云上下文下不可用；未完成源码编译 |
| r4 | Maven 退出 0，完整 26.914 秒 | 使用保留两个真实来源的任务配置，13/13 主源码与 12/12 测试源码完整进入编译 |

已有的失败收据与 Maven 日志全部保留；r2 因未启动 Maven，没有 Maven 日志。r3 起增加初始和启动前的不可变资源采样；r4 在复制输入、核对工具、配置与缓存之后再次检查 SDK、可用内存与磁盘。初始采样的 pins 状态为尚未检查，启动采样才是 `VERIFIED`，没有把前置资源检查当成全部输入已验证。

## 完整性和输出证据

所有原始日志和中间收据保留在项目忽略目录 `.cache/id17-20261021-r1` 至 `r4`；JSON 逐项记录了相对路径、字节数和 SHA-256。关键证据包括 `receipt.json`、两份 gate、`input-manifest.json`、编译日志、55 个产物的逐项清单及提交后源码观察。原始日志按字节保留，没有为便于展示改写日志内容。

工作区 POM 的原始字节与 Git 版本有一次 **CRLF checkout** 差异：106 行均为 CRLF，Git 与本次编译副本为 LF；BOM 一致。归一化后内容完全相同，模块 Git 状态为空，两提交模块 tree 相同。原始 mismatch 记录没有删除，解释另存于 `postflight-source-observation.json`；这里没有声称工作区每个原始字节都与 LF 副本相同。

实际日志仍有 `org.hibernate.annotations.FetchMode.SELECT` 注解类型缺失提示，以及 `AuthResult#getToken()/getUser()` 的弃用警告。编译成功不证明运行时 classpath 完整，也不免除 Keycloak 升级兼容性验证。

## 后续必须单独验收

1. 运行完整 JUnit 测试；按实际 XML 核对测试集合、数量、失败、错误和跳过项。上述 71 仅为静态声明数。
2. 执行打包并检查实际 provider JAR、SPI 服务声明、类文件和摘要。本轮没有产出可交付 JAR。
3. 在受控环境执行 Keycloak augmentation、真实 realm 资源请求、OIDC 登录/刷新/退出、旧会话撤销和用户资料保护验证。
4. 在目标 MySQL/Keycloak 组合验证锁等待、回滚、唯一性和多节点缓存语义；Mock/JPA 边界测试不能替代真实数据库结论。
5. 按审批环境验证正式短信、原生微信授权及客户端回调；本轮没有供应商送达或商业开放结论。
6. 后端完整回归及跨端端到端验收按各自记录继续。本记录不能覆盖此前后端 JVM 内存耗尽的失败，也不能替代 Android 验收。

历史任务目录带有防覆盖保护，不能直接重跑覆盖首轮证据。后续验证使用新的任务目录和独立资源窗口；临时目录继续遵循仓库 AGENTS 的目录与保全规则。

## 持久原始证据归档（2026-10-21）

11 项公开原件已按原始字节保存在 [归档说明](identity-offline-compile-20261021/README.md)，[映射清单](identity-offline-compile-20261021/inventory.json) 记录原路径、归档路径、字节数及 SHA-256。归档不包含缓存树、JAR/class 二进制或私有配置；原始机器记录 JSON 保持不变。本节为末尾追加，不改变前述编译结论和待验收范围。
