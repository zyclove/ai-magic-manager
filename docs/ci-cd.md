# 自动化验证与交付边界

日期：2026-10-20。状态：**本任务静态检查和独立审阅已完成，待共同任务复核、环境前提补齐及实际运行**。尚未在 GitHub 执行。后端当前缺少条件用例的专用环境；保留零 skip 门槛时，默认运行预期会失败，不能将本配置称为已经可通过的完整验证替代。本轮只新增两个工作流和本文；没有修改产品源码、数据库、Flutter 依赖或本机 SDK 排程，没有提交、推送或触发远程任务。

## 1. 目的与实施选择

落实原设计中的自动化验证，让已提交的 Java/Dart/Flutter 源码可在独立 runner 构建，减少对开发电脑内存的依赖。继续使用 Maven、JUnit/Surefire、Dart/Flutter 的现有命令及 GitHub 官方动作；不另建构建平台、测试框架、环境控制器或部署服务。

现有用户需求和验证契约保持有效。当前代码存在未提交候选、缓存恢复内容和待运行用例；远程 `dev` 不等于当前工作树。工作流仅验证运行页面标注的提交，不能补签未提交源码或先前缺失的执行回执。

## 2. 两个入口与覆盖范围

| 工作流 | 实际配置范围 | 通过条件 |
| --- | --- | --- |
| `Backend verification` | `backend`、`identity-extensions` 两个独立矩阵作业 | 全源编译、项目测试依赖清单、默认完整测试及打包；有实际 Surefire 报告，测试数大于零，failure/error/skip 均为零；源码、编译结果及编译前捕获的项目依赖未改变 |
| `Flutter verification` | 三个 App、十二个共享包、`device_operations/example`，共十六个独立矩阵作业 | 格式、静态分析、各目标现有测试全部成功；guardian 另跑 Chrome 用例；两个已有 Web 目标可编译；所有已跟踪源码和锁文件未改变 |

Flutter 的默认 VM 运行和 guardian Chrome 运行是两次真实命令。VM 跑默认完整集合，包含使用 `dart:io` 的现有测试；Chrome 按文件既有的 `@TestOn('browser')` 元数据选择全部浏览器专用文件，不维护缩短的手工清单。`@TestOn('vm')` 文件由 VM 覆盖。新增复杂 browser 平台表达式时明确报错，要求更新选择规则；不删注解、不改断言、不以一个平台的通过代替另一个平台。某步骤失败会使该作业失败，后续默认步骤可能不执行；需读取每个步骤的实际结果，不能把诊断上传成功当作测试成功。

`audit_client`、`commerce_contracts`、`notification_client` 当前没有独立测试目录和已提交锁文件，矩阵明确只做解析、格式和分析，并保存当次生成的锁与依赖图；它们也由 App 消费侧的已锁测试覆盖。这个安排不能证明三个包拥有独立单元测试，后续新增测试时须同时调整矩阵。其余目标强制使用现有 `pubspec.lock`，解析不允许重写锁或悄悄升级依赖。[Dart 锁文件校验](https://dart.dev/tools/pub/cmd/pub-get#enforce-lockfile)

每个 Flutter/Dart 目标在安装 SDK 前核对实际测试文件、锁文件及 browser 平台注解是否与矩阵一致；新增测试、锁或浏览器平台而未同步配置时明确失败，避免沿用过期的“无测试”标记静默漏跑。新增整个包或 App 时，仍须在本显式矩阵登记并审阅其平台要求。

现存十三份锁的 hosted 来源全部是 `https://pub.flutter-io.cn`，工作流因此显式设置同值的 `PUB_HOSTED_URL`。这会影响严格锁解析中的来源身份，不只是下载速度；不将锁里的镜像地址静默替换为默认 pub.dev，也不在下载失败时自动换源或升级。镜像不可达须如实保留失败；需要改源时另行评审、解析并提交锁文件差异。[Flutter 中国网络配置](https://docs.flutter.dev/community/china)

Web 构建只包含现有 guardian 和组件示例。parent/child 没有在这里新增 Web 平台。Android 编译、模拟器、真机和电视遥控器验证仍按既定计划单独安排。

### 2.1 后端默认环境的确定缺口

当前测试源存在下列显式条件。工作流没有填写这些 system properties/环境变量，因此默认 Surefire 会跳过对应类，最后的零 skip 检查应当失败。编译失败、网络失败也可能更早发生；这里是静态确认的环境缺口，不是实际运行结论。

| 条件 | 对应用例 | 仍需准备 |
| --- | --- | --- |
| `device.android.runner` / `device.cleanup.android.runner` | `AndroidChildSubmissionJourneyTest` / `AndroidCleanupHttpsJourneyTest` | 独立 Android runner、其要求的归属/证书/设备与状态；不得复用未知真机或凭空填 runner |
| `device.access.package` / `device.identity.package` / `device.dart.command` | DeviceAccess、DeviceIdentity、DeviceConfiguration、DeviceObservation HTTPInterop；ManagedAgent Dart proof | 对应已解析 Dart 包、现有生产工具入口和各测试要求的实际命令/工作目录，保持其合成身份与真实设备边界 |
| `guardian.dart.command` / `guardian.release.dart.command` | GuardianDeviceManagement、EnrollmentRecovery、IdentityProviderGuardian、ProviderReleaseGuardian HTTP 测试 | guardian 生产工具入口、已锁依赖及回环 HTTP 配置；不能由独立 Flutter widget 测试代替 |
| `parent.dart.command` | ParentAcceptance、Audit、Class、Help、Invitation、Member、Notification、Observation、Ownership、Permission、Quota、QuotaPlan、Subject HTTPInterop | parent 实际工具命令与各测试工作目录，保留服务端启动、实际 HTTP 和生产控制器调用 |
| `provider.runtime.boundary=true` | `ProviderRealRuntimeBoundaryTest` | 新隔离、已打包的 Keycloak runtime 及该用例的环境契约；不连接现有身份服务冒充隔离验收 |
| `LEDGER_STORE_TEST_URL`（匹配 MySQL JDBC） | `ErasureLedgerRuntimeTest` | 专用 MySQL 及其配套业务/存储凭据、迁移、隔离与清理责任；不是 runner 预装但未配置的数据库 |

每次 CI 根据该提交测试源保存 `conditional-prerequisites.json`，在 Summary 列出条件名和测试源；实际 XML 中的跳过类、方法和原因另存于 `test-summary.json`。静态清单只是定位信息，不替代 JUnit 的实际条件判定。保持全套默认测试和 `skip=0`，不通过删除、排除条件测试、伪造前提或放宽门槛得到绿色状态。hosted runner 能完成的工具互操作可继续按其现有契约补齐；原生、隔离身份和专用数据库环境须分别实现并验收。

## 3. 版本与来源

| 组件 | 固定选择 | 来源或复核方式 |
| --- | --- | --- |
| runner | `ubuntu-24.04`，GitHub 托管 | 系统镜像会更新；查看运行页面的实际 Image Version。它不是本地 Windows 环境的字节级副本 |
| Java | Eclipse Temurin Java 17 | 官方 `setup-java`，记录实际补丁/发行版本；没有声称固定 JDK 补丁 |
| Maven | `3.9.7` | 与当前本机 `maven-core-3.9.7.jar` 对齐；从 Apache 归档下载，执行前核对工作流内固定 SHA-512 |
| Flutter / Dart | `3.22.2` / `3.4.3` | 与当前 SDK 元数据和三端 lock 的 SDK 范围对齐；官方 `flutter/flutter` 提交 `761747bfc538b5af34aa0d3fac380f1bc331ec49`；启动后再次核对 machine 输出 |
| checkout | `v7.0.1` → `3d3c42e5aac5ba805825da76410c181273ba90b1` | [官方动作](https://github.com/actions/checkout/tree/3d3c42e5aac5ba805825da76410c181273ba90b1) |
| setup-java | `v6.1.0` → `b843ebf9b913146b38da2eaa7aeddf76074ae1ad` | [官方动作](https://github.com/actions/setup-java/tree/b843ebf9b913146b38da2eaa7aeddf76074ae1ad) |
| upload-artifact | `v7.0.2` → `cf430e030ddbb5b0abf93d22962f4752f3646cd9` | [官方动作](https://github.com/actions/upload-artifact/tree/cf430e030ddbb5b0abf93d22962f4752f3646cd9) |

动作的版本标签已经通过各自官方仓库解析为完整提交；工作流用完整 SHA，不使用浮动主版本标签。Flutter 也通过相同的官方 checkout 动作取得固定发布提交，而不是新增第三方安装动作；额外读取发布标签并核对它仍指向同一个提交，使浅克隆中的版本识别正常，标签变化即失败。Maven 使用[Apache 3.9.7 官方归档](https://archive.apache.org/dist/maven/maven-3/3.9.7/binaries/)，固定摘要为该目录发布的 `apache-maven-3.9.7-bin.tar.gz.sha512` 值。保留现用 SDK 是为了验证当前候选；SDK 升级仍需独立兼容和安全复核。

上述 GitHub 动作采用 MIT，Flutter 采用 BSD-3-Clause，Maven 采用 Apache-2.0；Temurin 的 OpenJDK 发行及组件按其随包许可处理，不能用动作的 MIT 许可替代 SDK 许可。升级时核对目标提交的许可证、运行时要求、输入和变更说明，再同步 YAML 与本文。[GitHub 动作安全用法](https://docs.github.com/en/actions/reference/security/secure-use)

## 4. 源码、依赖与结果绑定

1. checkout 固定到 `github.sha`，并核对 HEAD；保存仓库、完整提交、run ID、attempt、目标和所有已跟踪文件的 SHA-256。测试结束再次检查相同源码，包括已有锁文件。
2. 后端先运行 `clean test-compile dependency:build-classpath`，保存真实解析的项目 JAR 路径/摘要和全部编译文件摘要，再执行 `verify`；之后检查依赖和编译文件未改变。所有原测试保留，不用历史测试总数代替本次结果。
3. Surefire 原始 XML 与聚合数字同时保存。框架可能补充 JUnit launcher/provider：编译前项目依赖清单与 XML 中实际测试 classpath 分别记录，后者的 JAR 摘要明确标记为**测试后观察**，不冒充编译前绑定。
4. Flutter 保存 SDK machine 信息、Dart/Chrome 版本、Pub 依赖图、实际锁文件、测试和构建日志；有 Web 构建时保存产物摘要。未提交锁的三个纯 Dart 包允许生成新锁，只能声明本次解析结果。
5. runner、操作系统和 JDK 补丁不是全量不可变镜像。本配置可追溯源码和已观察依赖，不宣称完全可复现构建或供应链证明。

## 5. 启用和操作流程

当前仅 `workflow_dispatch`，没有 push、PR、定时或部署触发。按[GitHub 手动运行说明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)，工作流须先出现在默认分支；当前仓库默认分支为 `dev`。静态文件出现在本机并不表示 GitHub 已识别工作流。

1. 由负责 Git 的共同任务审阅文件，明确提交范围，保留其他阶段的工作。本阶段按用户授权完成本地提交；远端推送须取得明确授权后执行，不强推或覆盖他人修改。
2. 明确本轮执行授权后，在 Actions 选择工作流、分支并手动运行；核对最终页面的完整 `head_sha`。不以先前 `dev` 的结果证明随后新增的提交。
3. 等待两个 Java 作业或十六个 Flutter 作业实际结束。`queued`、`in_progress`、`cancelled`、超时、跳过、依赖下载失败及缺失报告均不构成验收通过。失败保留原报告后修复，再用新提交验证；不修改断言或缩小测试集来变绿。
4. 分别检查运行步骤、测试日志、汇总、artifact 中的 source/SDK/依赖摘要和实际结果。矩阵 `fail-fast: false` 允许其他目标继续，不能忽略已经失败的目标。Flutter 最大同时三个作业，避免无控制扩散。
5. 证据默认保留十四天。需要作为阶段交付依据时，在到期前保存所需报告、摘要及对应 run URL 到项目的正式交付目录，并说明覆盖范围；不把临时 artifact 链接作为永久唯一凭据。
6. 基线稳定后再评审 push/PR 触发、分支保护和必要检查。新增部署、签名、供应商密钥、生产数据库或云权限时分别设计和授权；本配置不隐含这些操作。

工作流不自动重跑，也不取消已运行的同分支验证；GitHub 并发组的排队/替换行为仍按平台规则处理。任何被平台或操作者取消的 attempt 均须如实标记，不能用历史 attempt 的通过覆盖它。[工作流语法](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)

## 6. 权限、日志与存储

- 全局仅 `contents: read`；checkout 不保留 Git 凭据。不给 `id-token`、仓库写、包发布、PR 写或部署权限，不引用业务 Secrets，不连接本机或生产服务。
- 只上传确定的 CI 证据目录与 Surefire XML；不上传整个工作区、`.git`、Maven settings、Pub credentials、环境变量列表或本机 `.local`。固定输入通过环境变量传给脚本，不把 PR 文本或任意输入拼进命令。
- Maven 只缓存标准依赖仓库。Flutter SDK 在忽略的 `.cache/ci-sdk/flutter`，Pub 和 Maven 下载/证据放在本次 runner 的临时目录；不创建盘符根目录任务，不修改用户机器配置。
- Artifact 和运行日志按仓库实际可见性管理；测试只能使用固定合成数据，不注入真实儿童信息、设备私钥或管理员凭据。发现日志泄露时按事件响应流程处理。

## 7. 与现有验收的关系

| 证据 | 能证明 | 不能代替 |
| --- | --- | --- |
| 本标准 CI | 对应提交的编译、默认行为测试、静态分析和所列 Web 构建 | 当前未提交候选、本机自然退出/OwnedJob、专用 RED15/GREEN15 接合门槛 |
| H2/Surefire | 实际运行的默认业务断言 | 八项真实 MySQL 场景、OceanBase 认证、数据库切换和恢复 |
| Chrome / Flutter VM | 合成接口与组件/浏览器逻辑 | 真实 OIDC、六服务联调、后台生命周期真机、电视遥控器与系统策略效果 |
| 打包/产物摘要 | 对应文件由本次构建产生 | 已部署、已签约、供应商准入或所有设备已受保护 |

本轮本机仍保留原资源门槛、180 秒双时钟和专用验证的来源/依赖约束；远程标准 CI 的三十分钟 job 超时是另一执行环境的上限，不能用于放宽旧验证。数据库夹具只有实际有效 RED 后才按既有分工接合两个 Java 文件。其余真实供应商、EMM、Android/TV、性能和商业门槛继续执行原规格。

## 8. 当前交付核对

已用发布摘要和官方 checksum 清单双重核对 `actionlint 1.7.12` 的 Windows 工具包（SHA-256 `6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9`）；工具仅位于项目忽略缓存，没有安装到系统。检查使用 `-shellcheck= -pyflakes=`，不调用缺失的辅助检查器；另用 Git Bash `-n` 和 Python AST 检查内联脚本语法。它们都是静态检查，不能证明命令、依赖下载、测试或构建已经运行。工具来源：[actionlint 官方发布](https://github.com/rhysd/actionlint/releases/tag/v1.7.12)。

本轮真实静态终态：actionlint 退出码 0；十六段 Bash 语法、六段内联 Python AST 均通过；十六目标与当前工作树中的目标/测试/锁文件/平台标记一致，十三份锁与明确配置的 hosted 来源一致，当前三十二个 browser 注解文件均纳入选择。共同任务恢复源码后重新检查了矩阵，数字属于该工作树时点，不能转写为远程提交的实际运行结果。独立审阅发现的镜像来源 P2 已修正并复核，无剩余确认的 P1/P2；先前发现的 job-env 上下文问题也已修正后重新检查。

- [x] 查明本机无现有 `.github` 工作流；远程 API 当时返回零工作流、零 `dev` 运行，Actions 已启用。
- [x] 核对当前 Maven/Flutter 版本、各包测试和锁文件、浏览器/VM 注解及动作官方提交。
- [x] 编写两个手动工作流与本操作说明，保留原测试与权限边界。
- [x] 完成本任务独立静态审阅及可用的标准 YAML/Actions 语法检查。
- [ ] 由负责 Git 的任务审阅并提交选定文件，获得本轮运行授权。
- [ ] 实际远程构建、测试、报告审阅及失败修正。
- [ ] 完成原产品全部独立验收门槛后再形成发布结论。
