# 简明部署入口

面向 **1.0.0 独立环境的初始化与恢复**。统一入口复用现有初始化、构建、来源核验和启动脚本，不清空旧环境，不自动安装软件或配置业务管理员。

## 选择入口

| 系统 | 命令前缀 | 当前支持范围 |
| --- | --- | --- |
| Windows | `scripts\manager.cmd` | 调用 PowerShell 7 核心入口 |
| Linux / macOS | `sh scripts/manager.sh` | 相同参数与核心；本批未做这两个系统的真实部署验收 |
| 已在 PowerShell 7 中 | `./scripts/manager.ps1` | 可直接使用全部动作 |

需要预先准备 PowerShell 7、Docker Engine/Desktop 与 Compose 插件。源码构建另需 Git、Java 17、Maven、Flutter/Dart；精确版本和完整安全要求以[部署手册](deployment-runbook.md)为准。入口不会下载或升级它们。`doctor` 默认使用 `-Toolset Build` 盘点源码构建命令；只运行或恢复已有环境时使用 `doctor -Toolset Runtime`，只检查 Docker，不把缺少 Java/Maven/Flutter 当成运行工具缺失。`missingTools` 仅表示所选档位中未找到的命令，不代表 Compose 插件、服务、SDK 版本或安装已验收。

下面以 PowerShell 7 为例；其他系统只替换命令前缀，参数相同。

```powershell
# 只检查命令是否可找到，不调用 SDK、连接服务或输出凭据
./scripts/manager.ps1 doctor
# 只准备运行已有环境时，可改用：doctor -Toolset Runtime
# 先看计划：不创建文件、不读取部署凭据、不启动命令
./scripts/manager.ps1 init -Directory .local/demo -ProjectName ai-manager-demo -Plan
# 确认计划后，创建全新环境；已有目录会拒绝覆盖
./scripts/manager.ps1 init -Directory .local/demo -ProjectName ai-manager-demo
./scripts/manager.ps1 build -Directory .local/demo -Offline
# 仅全新环境首次执行一次；初始化独立清除账本，会启动其数据库并运行初始化器
./scripts/manager.ps1 init-ledger -Directory .local/demo
./scripts/manager.ps1 start -Directory .local/demo
./scripts/manager.ps1 status -Directory .local/demo
./scripts/manager.ps1 verify -Directory .local/demo
```

默认入口是 `http://localhost:18090`，默认项目名是 `ai-manager-repro`，只绑定本机。`-Offline` 要求已有完整依赖缓存，缺失时失败；需要联网解析时由维护者明确选择移除此参数。每条命令单独执行，遇到失败先查看该环境的受限日志，不继续启动。

更换本机端口只需填写 `init -EdgePort 18120`，公开入口自动使用 `http://localhost:18120`。只填写 `-PublicUrl` 时，内部端口默认跟随 URL；使用 `-ExternalTlsProxy` 时内部端口仍默认为 `18090`，可单独指定。两项均显式填写时保留原值，预览与实际初始化共用地址、端口及 TLS 校验；明显冲突会在 `-Plan` 阶段直接拒绝并提示修正方式，不等到创建环境时才发现。

`init-ledger` 是显式的一次性数据初始化操作，仅用于完成构建后的**新账本**，会启动独立账本数据库、构建并运行初始化器及收紧运行账号权限；不会被 `start` 自动调用。正常重启与故障恢复必须保留账本身份和初始化记录，不重复执行此操作。

## 常用配置

| 需要 | 参数与说明 |
| --- | --- |
| 查看任一动作 | 加 `-Plan`（别名 `-DryRun`）；输出动作、非秘密参数和影响，不执行 |
| 按用途检查工具 | `doctor -Toolset Runtime` 用于已有环境；默认 `Build` 检查源码工具。Build 可复用 `-MavenCommand`、`-FlutterCommand`、`-DartCommand` 指定命令；Runtime 传构建覆盖项会明确拒绝 |
| 获取帮助 | `./scripts/manager.ps1 -Help`（其他系统替换命令前缀）；内置帮助包含首次部署完整顺序、离线缓存前提及恢复示例，完整要求见[部署手册](deployment-runbook.md)。参数不适用时列出当前动作的可用参数及帮助入口，不回显参数值 |
| 恢复已创建环境 | `resume -Directory .local/demo -Plan` 查看计划；实际恢复仅启动同批已有容器，不构建、不创建、不重写原发布记录。TLS/身份配置参数沿用该环境原启动参数 |
| 查看当前已选环境 | `status -Active`；复用已提交的控制台选择，只读展示项目、公开入口与容器状态，无需记住快照路径 |
| 更换本机端口 | `init -EdgePort 18120`；使用新的独立目录与项目名 |
| 本地 TLS | `init -PublicUrl https://manager.example.com:8443`，端口自动取 `8443`；准备证书后 `start -Tls` |
| 外部 HTTPS 代理 | 初始化和启动均加 `-ExternalTlsProxy`；公开 URL 为标准 HTTPS，内部保持回环端口 |
| 家庭身份扩展 | 初始化和构建均加 `-ConsumerIdentity`，仍遵守身份提供方准入流程 |
| 指定源码或工具 | `build -SourceDirectory ... -MavenCommand ... -FlutterCommand ... -DartCommand ... -MavenRepository ...` |
| 已批准的身份配置 | `start -IdentityAdminDirectory ... -IdentityRuntimeDirectory ...`，保留底层完整核验 |

部署目录统一位于仓库 `.local/`。多个环境用不同目录、Compose 项目名与端口。显式 `Directory`、`SourceDirectory`、`MavenRepository`、`IdentityAdminDirectory`、`IdentityRuntimeDirectory` 的相对路径都按该入口所在仓库根目录解析，绝对路径保持其含义；`-Plan` 显示最终绝对路径，避免从其他工作目录执行时指向不同文件。

`MavenCommand`、`FlutterCommand`、`DartCommand` 可以填写命令名或文件路径。命令名从 PATH 查找；含本系统目录分隔符的路径按仓库根目录解析。含空格的路径按所用 shell 的通常规则加引号，不手工改写文件名。诊断和构建共用工具定位逻辑，要求匹配所填名称或路径，不能用通配匹配出的邻近文件代替；显示保留原值，实际构建绑定已核对的完整路径。路径预览不执行工具；文件、权限与 SDK 目标由对应动作校验。

`doctor -Toolset Build` 返回工具名称、查询命令、可找到状态及用途。Maven、Flutter 和显式 Dart 支持文件型脚本入口；诊断只盘点，不执行工具或检查 SDK 内部内容。未显式指定 Dart 时沿用构建选择的 Flutter SDK，不另要求系统 PATH 安装 Dart。

最新工具定位修订尚待运行验证：此前特殊路径回归失败，当前候选因资源门槛未启动复验；完整构建与平台兼容也未验收。已运行的范围与失败记录见[诊断阶段记录](reviews/doctor-toolsets-20261026.md)。

若 `missingTools` 非空，`next` 先提示补齐哪些命令；可指定的构建工具会列出对应覆盖参数，然后提示重跑同一档位的 `doctor`。Runtime 只提示运行工具，工具齐全后才引导初始化或查看已有环境。入口不会自动安装工具，退出成功也只代表盘点完成，不能代替检查 `missingTools` 或真实部署验收。

`-FlutterCommand` 支持 SDK `bin` 入口及其文件符号链接，实际调用与 Dart／工具缓存定位使用同一解析路径。若 PATH 中是普通转发脚本，请改填真实 SDK 的 `bin/flutter` 或 `bin/flutter.bat`；入口不会猜测版本管理器的内部目录。

操作预览校验初始化地址、端口与 TLS 组合，再展示动作及转发参数；不读取部署凭据或检查服务。证书、依赖、目录是否已存在和发布来源等完整校验仍由实际命令执行。

`start` 沿用现有 `up --build` 发布行为，会更新**指定项目**，不是仅恢复运行容器。已有环境的无构建恢复、TLS、管理员开通、密钥备份与故障恢复，请按[完整部署手册](deployment-runbook.md)处理，不能把启动成功作为业务验收。

`resume` 先校验目标服务均有持久容器、原发布记录、镜像和挂载，再使用 [Compose start](https://docs.docker.com/reference/cli/docker/compose/start/) 恢复并等待健康；前后核对同一原记录及应用容器编号。缺容器、记录不匹配或恢复失败都停止，不转成 `up`。需要 Compose 支持 `start --wait` 与 `--wait-timeout`；旧基础版本（如 [2.24.4 的实现](https://github.com/docker/compose/blob/v2.24.4/cmd/compose/start.go)）不具备此能力时，会在容器变更前明确拒绝新动作，不自动升级软件。该新动作目前完成静态接线，参数及受控传输回归尚未运行；使用前需完成[阶段记录](reviews/deployment-resume-20261026.md)中的验证。

`status` 只读取选定环境元数据并列出其精确 Compose 项目标签下的容器，不打印环境变量、命令行或密钥；同标签的容器状态仅用于运维定位，不证明发布身份。`verify` 保留实际发布身份及入口检查，但不执行登录后的业务旅程或真机管控。

已有控制台可用 `./scripts/manager.ps1 status -Active` 查看。`-Active` 仅用于只读 `status`，不能与显式 `-Directory` 同传；未选择环境时明确提示，不回退到其他项目。`status -Active -Plan` 只展示选择方式，不读取激活或部署元数据；构建、启动及验证仍显式指定部署目录，避免跨源码环境发布。

## 验证范围

内置帮助已对齐本页首次部署顺序、离线缓存前提与恢复条件。本批入口校验、工具缺项建议及参数提示已完成静态语法和差异核对；受控参数回归尚未运行，见[本批记录](reviews/deployment-entry-feedback-20261027.md)。未执行初始化、构建或服务操作，下面的历史检查不证明本批新行为已通过。

初始入口已在 Windows 通过语法检查及 5 项计划/参数测试，见[初始记录](reviews/engineering-foundation-20261025.md)。新增 `-Active` 已单独通过计划与参数保护检查，并在当前选定环境实际查询成功；试用发现的 Windows 多 Docker 入口解析问题已修正为选择首个可执行入口。

初始化端口联动另通过 1 个定向用例，覆盖 10 组最终参数及端口 0 拒绝；仅执行计划/输入检查，没有新建环境或启动 SDK。

这些检查没有执行构建、初始化或发布，也不改变数据库结构、发布配方和产品授权。Linux/macOS、真实安装和全产品验收仍按实际环境单独判断。
