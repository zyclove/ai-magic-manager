# 简明部署入口

面向 **1.0.0 独立环境的初始化与恢复**。统一入口复用现有初始化、构建、来源核验和启动脚本，不清空旧环境，不自动安装软件或配置业务管理员。

## 选择入口

| 系统 | 命令前缀 | 当前支持范围 |
| --- | --- | --- |
| Windows | `scripts\manager.cmd` | 调用 PowerShell 7 核心入口 |
| Linux / macOS | `sh scripts/manager.sh` | 相同参数与核心；本批未做这两个系统的真实部署验收 |
| 已在 PowerShell 7 中 | `./scripts/manager.ps1` | 可直接使用全部动作 |

需要预先准备 PowerShell 7、Docker Engine/Desktop 与 Compose 插件。源码构建另需 Git、Java 17、Maven、Flutter/Dart；精确版本和完整安全要求以[部署手册](deployment-runbook.md)为准。入口不会下载或升级它们。`doctor` 的 `missingTools` 列出未找到的命令，仍需人工核对实际版本和环境。

下面以 PowerShell 7 为例；其他系统只替换命令前缀，参数相同。

```powershell
# 只检查命令是否可找到，不调用 SDK、连接服务或输出凭据
./scripts/manager.ps1 doctor
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

更换本机端口只需填写 `init -EdgePort 18120`，公开入口自动使用 `http://localhost:18120`。只填写 `-PublicUrl` 时，内部端口默认跟随 URL；使用 `-ExternalTlsProxy` 时内部端口仍默认为 `18090`，可单独指定。两项均显式填写时保留原值，由实际初始化校验其一致性；`-Plan` 展示相同的最终参数。

`init-ledger` 是显式的一次性数据初始化操作，仅用于完成构建后的**新账本**，会启动独立账本数据库、构建并运行初始化器及收紧运行账号权限；不会被 `start` 自动调用。正常重启与故障恢复必须保留账本身份和初始化记录，不重复执行此操作。

## 常用配置

| 需要 | 参数与说明 |
| --- | --- |
| 查看任一动作 | 加 `-Plan`（别名 `-DryRun`）；输出动作、非秘密参数和影响，不执行 |
| 获取帮助 | `-Help`；所有动作仅接受相关参数，避免静默忽略 |
| 恢复已创建环境 | `resume -Directory .local/demo -Plan` 查看计划；实际恢复仅启动同批已有容器，不构建、不创建、不重写原发布记录。TLS/身份配置参数沿用该环境原启动参数 |
| 查看当前已选环境 | `status -Active`；复用已提交的控制台选择，只读展示项目、公开入口与容器状态，无需记住快照路径 |
| 更换本机端口 | `init -EdgePort 18120`；使用新的独立目录与项目名 |
| 本地 TLS | `init -PublicUrl https://manager.example.com:8443`，端口自动取 `8443`；准备证书后 `start -Tls` |
| 外部 HTTPS 代理 | 初始化和启动均加 `-ExternalTlsProxy`；公开 URL 为标准 HTTPS，内部保持回环端口 |
| 家庭身份扩展 | 初始化和构建均加 `-ConsumerIdentity`，仍遵守身份提供方准入流程 |
| 指定源码或工具 | `build -SourceDirectory ... -MavenCommand ... -FlutterCommand ... -DartCommand ... -MavenRepository ...` |
| 已批准的身份配置 | `start -IdentityAdminDirectory ... -IdentityRuntimeDirectory ...`，保留底层完整核验 |

部署目录统一位于仓库 `.local/`。多个环境用不同目录、Compose 项目名与端口。显式 `Directory`、`SourceDirectory`、`MavenRepository`、`IdentityAdminDirectory`、`IdentityRuntimeDirectory` 的相对路径都按该入口所在仓库根目录解析，绝对路径保持其含义；`-Plan` 显示最终绝对路径，避免从其他工作目录执行时指向不同文件。

`MavenCommand`、`FlutterCommand`、`DartCommand` 若填写带本系统目录分隔符的文件路径，也按同一仓库基准解析；只填 `mvn`、`flutter` 等命令名时继续从 PATH 查找。路径规范化只处理参数字符串，不检查配置内容、不执行工具；实际文件、权限及 SDK 目标仍由对应动作校验。

`-FlutterCommand` 支持 SDK `bin` 入口及其文件符号链接，实际调用与 Dart／工具缓存定位使用同一解析路径。若 PATH 中是普通转发脚本，请改填真实 SDK 的 `bin/flutter` 或 `bin/flutter.bat`；入口不会猜测版本管理器的内部目录。

操作预览只展示动作与转发参数；证书、依赖和发布来源等完整校验仍由实际命令执行。

`start` 沿用现有 `up --build` 发布行为，会更新**指定项目**，不是仅恢复运行容器。已有环境的无构建恢复、TLS、管理员开通、密钥备份与故障恢复，请按[完整部署手册](deployment-runbook.md)处理，不能把启动成功作为业务验收。

`resume` 先校验目标服务均有持久容器、原发布记录、镜像和挂载，再使用 [Compose start](https://docs.docker.com/reference/cli/docker/compose/start/) 恢复并等待健康；前后核对同一原记录及应用容器编号。缺容器、记录不匹配或恢复失败都停止，不转成 `up`。需要 Compose 支持 `start --wait` 与 `--wait-timeout`；旧基础版本（如 [2.24.4 的实现](https://github.com/docker/compose/blob/v2.24.4/cmd/compose/start.go)）不具备此能力时，会在容器变更前明确拒绝新动作，不自动升级软件。该新动作目前完成静态接线，参数及受控传输回归尚未运行；使用前需完成[阶段记录](reviews/deployment-resume-20261026.md)中的验证。

`status` 只读取选定环境元数据并列出其精确 Compose 项目标签下的容器，不打印环境变量、命令行或密钥；同标签的容器状态仅用于运维定位，不证明发布身份。`verify` 保留实际发布身份及入口检查，但不执行登录后的业务旅程或真机管控。

已有控制台可用 `./scripts/manager.ps1 status -Active` 查看。`-Active` 仅用于只读 `status`，不能与显式 `-Directory` 同传；未选择环境时明确提示，不回退到其他项目。`status -Active -Plan` 只展示选择方式，不读取激活或部署元数据；构建、启动及验证仍显式指定部署目录，避免跨源码环境发布。

## 验证范围

初始入口已在 Windows 通过语法检查及 5 项计划/参数测试，见[初始记录](reviews/engineering-foundation-20261025.md)。新增 `-Active` 已单独通过计划与参数保护检查，并在当前选定环境实际查询成功；试用发现的 Windows 多 Docker 入口解析问题已修正为选择首个可执行入口。

初始化端口联动另通过 1 个定向用例，覆盖 10 组最终参数及端口 0 拒绝；仅执行计划/输入检查，没有新建环境或启动 SDK。

这些检查没有执行构建、初始化或发布，也不改变数据库结构、发布配方和产品授权。Linux/macOS、真实安装和全产品验收仍按实际环境单独判断。
