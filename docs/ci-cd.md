# 自动化验证与交付边界

日期：2026-10-20。当前是 **30 个源文件中的 hosted 互操作配置静态候选，静态检查与独立复核已完成，待共同任务接收及阶段提交，尚未执行**。基线工作流已本地提交于 `6dbfab90044facc2a01cb088380354db94eac84f`，其父提交 `3b6c4178f87fdbcac1c4f448a4ef2ae962cfd35e` 保存 Guardian 阶段改进；两次均未运行 SDK、测试或构建，也未推送。本版仅继续修改后端工作流和本文，尚未提交或触发任务。

后端本版为三十个源文件中的现有 Dart/Flutter HTTPInterop/proof 与条件方法准备工具和参数；两类 Android、一类隔离 Keycloak 和三个专用 MySQL 测试文件的前提仍未提供。因此零 skip 门槛默认仍预期失败，不能将本配置称为已经通过或能够替代完整验收。

## 1. 目的与实施选择

落实原设计中的自动化验证，让已提交的 Java/Dart/Flutter 源码可在独立 runner 构建，减少对开发电脑内存的依赖。继续使用 Maven、JUnit/Surefire、Dart/Flutter 的现有命令及 GitHub 官方动作；不另建构建平台、测试框架、环境控制器或部署服务。

现有用户需求和验证契约保持有效。当前代码存在未提交候选、缓存恢复内容和待运行用例；远程 `dev` 不等于当前工作树。工作流仅验证运行页面标注的提交，不能补签未提交源码或先前缺失的执行回执。

## 2. 两个入口与覆盖范围

| 工作流 | 实际配置范围 | 通过条件 |
| --- | --- | --- |
| `Backend verification` | `backend`、`identity-extensions` 两个独立矩阵作业；backend 准备三十个现有源文件中工具互操作所需的已锁 SDK/依赖/入口 | 全源编译、项目测试依赖清单、默认完整测试及打包；有实际 Surefire 报告，测试数大于零，failure/error/skip 均为零；源码、编译结果及编译前捕获的项目依赖未改变 |
| `Flutter verification` | 三个 App、十二个共享包、`device_operations/example`，共十六个独立矩阵作业 | 格式、静态分析、各目标现有测试全部成功；guardian 另跑 Chrome 用例；两个已有 Web 目标可编译；所有已跟踪源码和锁文件未改变 |

Flutter 的默认 VM 运行和 guardian Chrome 运行是两次真实命令。VM 跑默认完整集合，包含使用 `dart:io` 的现有测试；Chrome 按文件既有的 `@TestOn('browser')` 元数据选择全部浏览器专用文件，不维护缩短的手工清单。`@TestOn('vm')` 文件由 VM 覆盖。新增复杂 browser 平台表达式时明确报错，要求更新选择规则；不删注解、不改断言、不以一个平台的通过代替另一个平台。某步骤失败会使该作业失败，后续默认步骤可能不执行；需读取每个步骤的实际结果，不能把诊断上传成功当作测试成功。

`audit_client`、`commerce_contracts`、`notification_client` 当前没有独立测试目录和已提交锁文件，矩阵明确只做解析、格式和分析，并保存当次生成的锁与依赖图；它们也由 App 消费侧的已锁测试覆盖。这个安排不能证明三个包拥有独立单元测试，后续新增测试时须同时调整矩阵。其余目标强制使用现有 `pubspec.lock`，解析不允许重写锁或悄悄升级依赖。[Dart 锁文件校验](https://dart.dev/tools/pub/cmd/pub-get#enforce-lockfile)

每个 Flutter/Dart 目标在安装 SDK 前核对实际测试文件、锁文件及 browser 平台注解是否与矩阵一致；新增测试、锁或浏览器平台而未同步配置时明确失败，避免沿用过期的“无测试”标记静默漏跑。新增整个包或 App 时，仍须在本显式矩阵登记并审阅其平台要求。

现存十三份锁的 hosted 来源全部是 `https://pub.flutter-io.cn`，工作流因此显式设置同值的 `PUB_HOSTED_URL`。这会影响严格锁解析中的来源身份，不只是下载速度；不将锁里的镜像地址静默替换为默认 pub.dev，也不在下载失败时自动换源或升级。镜像不可达须如实保留失败；需要改源时另行评审、解析并提交锁文件差异。[Flutter 中国网络配置](https://docs.flutter.dev/community/china)

Web 构建只包含现有 guardian 和组件示例。parent/child 没有在这里新增 Web 平台。Android 编译、模拟器、真机和电视遥控器验证仍按既定计划单独安排。

### 2.1 后端互操作准备与剩余缺口

完整扫描简名和完整限定名的 JUnit 条件注解，当前共三十九处、分布于三十六个源文件。其中三十二处 hosted 条件分布于三十个文件：四个 Device HTTPInterop、一个 ManagedAgent Dart proof、四个 Guardian/Provider 工具 HTTP 类、十五个 Parent HTTPInterop，以及提交、诊断、支持和使用报表六个 Journey 文件。部分文件在方法级重复声明条件，不能把注解数、源文件数当成测试数量。工作流没有新增测试、删改断言或用合成响应代替既有实际回环 HTTP；它调用原有生产工具入口，并保留原测试对身份夹具、存储夹具、真实设备和供应商能力的说明。**写入配置不表示这些类或方法已经启用运行或通过。**

| 条件 | 对应用例 | 当前配置及边界 |
| --- | --- | --- |
| `device.android.runner` / `device.cleanup.android.runner` | `AndroidChildSubmissionJourneyTest` / `AndroidCleanupHttpsJourneyTest` | 独立 Android runner、其要求的归属/证书/设备与状态；不得复用未知真机或凭空填 runner |
| `device.access.package` / `device.identity.package` / `device.dart.command` | DeviceAccess、DeviceIdentity、DeviceConfiguration、DeviceObservation HTTPInterop；ManagedAgent Dart proof | 已配置固定 SDK 的命令、对应包的绝对目录及严格锁解析；DeviceAccess 内部 child-host 子流程也配置，不把纯 Dart 部分当作完整子流程 |
| `device.access.package` / `device.child.package` | `DeviceAccessSubmissionJourneyTest` 的类级条件及两个方法级条件 | 同时准备 device_access 和 child 的原工具入口、命令与绝对目录，保留提交成功、冲突和重试的原始流程 |
| `device.dart.command` | `DiagnosticPreviewJourneyTest`、`DiagnosticPackageJourneyTest`、`SupportGrantJourneyTest`、`UsageReportJourneyTest`、`UsageReportJobJourneyTest` 中的条件方法 | 准备 guardian、device_reports 与 child 工具及其独立锁解析；显式设置诊断与报表目录，不依赖相对默认路径或运行时隐式解析 |
| `guardian.dart.command` / `guardian.release.dart.command` | GuardianDeviceManagement、EnrollmentRecovery、IdentityProviderGuardian、ProviderReleaseGuardian HTTP 测试 | 已配置生产工具入口所需的命令、Flutter snapshot 与绝对目录；调用原有服务端/工具流程，不能由独立 widget 测试代替 |
| `parent.dart.command` | ParentAcceptance、Audit、AuditExport、Class、Contract、Help、Invitation、Member、Notification、Observation、Ownership、Permission、Quota、QuotaPlan、Subject HTTPInterop | 已配置实际 Flutter 工具 snapshot、命令与包目录，保留服务端启动、实际 HTTP 和生产控制器调用 |
| `provider.runtime.boundary=true` | `ProviderRealRuntimeBoundaryTest` | 新隔离、已打包的 Keycloak runtime 及该用例的环境契约；不连接现有身份服务冒充隔离验收 |
| `LEDGER_STORE_TEST_URL`（匹配 MySQL JDBC） | `ErasureLedgerRuntimeTest` 及 `ErasureLedgerStoreTest` 的两个条件方法 | 专用 MySQL 及其配套业务/存储凭据、迁移、隔离与清理责任；不是 runner 预装但未配置的数据库 |
| `NOTICE_IT_ROOT_PASSWORD` | `ErasureAdmissionStoreTest` 的条件方法 | 独立 MySQL 管理凭据及该用例要求的存储/授权环境；不填占位密码或复用现有数据库来消除跳过 |

剩余七处未配置条件分布于六个文件：两个 Android 文件、一个隔离身份文件和三个 MySQL 文件。相应类或方法仍因缺少前提而预期被 JUnit 跳过，最后的零 skip 检查应当失败。编译、依赖下载、工具准备或互操作自身失败也可能更早发生；这里是配置与剩余缺口，不是实际运行结论。

每次 CI 根据该提交测试源保存 `conditional-prerequisites.json`，包括每处注解的源文件、行号、类型和条件名；同时识别简名与 `org.junit.jupiter.api.condition` 完整限定名。Summary 区分“hosted 准备已配置”和“未配置”，并分别报告注解数与源文件数。前者只描述工作流，不证明准备步骤成功，也不等同于 JUnit 实际执行范围。`test-summary.json` 另外记录准备步骤的实际 outcome、原始 XML 的跳过类/方法/原因和测试结果。保留全套默认测试及 `skip=0`，不通过排除、伪造前提或放宽门槛得到绿色状态。

### 2.2 Hosted 互操作的具体连接方式

backend 作业使用与 Flutter 工作流相同的固定发布提交，核对 tag、framework 与 Dart 版本；identity-extensions 作业不安装 Flutter。准备阶段严格解析八个现有锁：`device_access`、`device_identity`、`device_policy`、`device_observation`、`device_reports` 和 guardian/parent/child 三 App，保存各自依赖图与锁。App 对路径包的解析不会生成该包作为独立运行目录所需的配置，因此不能省略 `device_reports` 的单独准备。镜像来源保持 `pub.flutter-io.cn`，不改锁、不升级、不下载或调用本机 `.local` 脚本。

十九个系统属性以单独 argv 传给原 `mvn verify`，没有 `-Dtest` 白名单或测试排除：

| 属性组 | 实际值来源 |
| --- | --- |
| `device.dart.command`、`guardian.dart.command`、`guardian.release.dart.command`、`parent.dart.command` | 固定 SDK 的 `bin/dart`；它给纯 Dart 命令与 Flutter snapshot 调用提供同一 SDK 上下文 |
| `device.flutter.command` | 同一 SDK 的 `bin/flutter`，供 DeviceAccess 内部 child-host 流程调用 |
| `guardian.flutter.tool`、`parent.flutter.tool` | 已由 SDK 初始化产生且实际存在的 `bin/cache/flutter_tools.snapshot` |
| `device.access.package`、`device.identity.package`、`device.policy.package` | 当前 checkout 内对应共享包的绝对目录 |
| `device.child.package` | 当前 checkout 内 `apps/child` 的绝对目录 |
| `observation.device.package`、`observation.guardian.package` | 对应 `packages/device_observation` 与 `apps/guardian`，包括原代码动态读取的属性名 |
| `diagnostic.guardian.package`、`usage.report.guardian.package`、`usage.report.device.package` | 对应 `apps/guardian` 和 `packages/device_reports` 的绝对目录，供诊断、支持、报表原入口调用 |
| `guardian.package`、`guardian.release.package`、`parent.package` | 当前 checkout 内对应 App 的绝对目录 |

准备步骤检查三十六个原有工具文件并保存摘要，保存 `interop-system-properties.json`、逐参数 argv 文件、SDK 信息和 Pub 解析结果。参数文件只含工具/目录路径，没有身份 bearer 或私钥；临时夹具仍由原测试拥有，不能把含私有测试输出的整个 `target` 目录纳入上传。本配置仍只保存既定证据目录与 Surefire XML。

发布前必须把这些原工具及依赖的产品源码纳入实际候选提交：本机存在不等于已提交。远程 checkout 缺少任一所需工具、锁或 snapshot 时明确失败，不创建替代脚本或假冒成功结果。Host 级准备成功也不能证明 Android 安全存储、真实 OTP/MFA 或外部 EMM 已验收。

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
2. backend 作业先准备上述原工具互操作，记录实际 SDK/锁/路径，再运行 `clean test-compile dependency:build-classpath`，保存真实解析的项目 JAR 路径/摘要和全部编译文件摘要，最后给 `verify` 传入逐项系统属性；identity-extensions 保持原 Java 流程。之后检查依赖和编译文件未改变。所有原测试保留，不用历史测试总数代替本次结果。
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

上一版基线的真实静态终态：actionlint 退出码 0；十六段 Bash 语法、六段内联 Python AST 均通过；十六目标与当时工作树的目标/测试/锁文件/平台标记一致，十三份锁与 hosted 来源一致，当时三十二个 browser 注解文件均纳入选择。镜像来源 P2 已修正并复核；共同任务独立复核并将基线提交于 `6dbfab9`。原始静态记录及提交对象继续保留，不覆盖，不用于为本版新增配置签字。

本版两工作流的真实静态结果：actionlint 退出码 0；十八段 Bash 语法和八段 Python AST 通过。只读清单核对三十九处注解/三十六个文件，其中 hosted 三十二处/三十个文件，剩余七处/六个文件；八份锁、三十六个工具路径和十九项属性均与当前源码匹配。独立初审提出完整限定注解遗漏及 `device_reports` 独立准备两项 P2，修正后复审确认可作静态交接，未发现新增 P1/P2。后端 YAML SHA-256 为 `91b3748ca179265396b2ae31c8637239d807cdd49ad2fe4cf739877767f6d1a3`；Flutter YAML 保持 `827db7a798bed5fd0a8b88db9e6d5571c00569a6bbd6dffde5cecbbc54183556`。这些结果仅证明所述静态检查，没有实际执行依赖解析、互操作、业务测试或构建。

- [x] 查明本机无现有 `.github` 工作流；远程 API 当时返回零工作流、零 `dev` 运行，Actions 已启用。
- [x] 核对当前 Maven/Flutter 版本、各包测试和锁文件、浏览器/VM 注解及动作官方提交。
- [x] 编写两个手动工作流与本操作说明，保留原测试与权限边界。
- [x] 完成上一版基线的独立静态审阅、标准语法检查及本地阶段提交。
- [x] 只读映射三十个原有源文件中的互操作及子流程；修正初审发现的完整限定注解遗漏和 device_reports 独立准备缺口。
- [x] 完成本版语法检查及独立静态复核。
- [x] 共同任务接收本版静态交接，核对十九项属性、八份锁及三十六个工具；锁和工具均已跟踪且存在于基线提交。
- [x] 共同任务核对本版选定文件和[新的 actionlint 实际记录](evidence/ci-hosted-interop-root-static-check-20261020-r1.json)，固定本地阶段提交输入；提交对象以 Git 历史为准，实际运行另行授权。
- [ ] 实际远程构建、测试、报告审阅及失败修正。
- [ ] 完成原产品全部独立验收门槛后再形成发布结论。
