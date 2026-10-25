# 简明部署入口

面向 **1.0.0 全新独立环境**。统一入口复用现有初始化、构建、来源核验和启动脚本，不清空旧环境，不自动安装软件或配置业务管理员。

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

`init-ledger` 是显式的一次性数据初始化操作，仅用于完成构建后的**新账本**，会启动独立账本数据库、构建并运行初始化器及收紧运行账号权限；不会被 `start` 自动调用。正常重启与故障恢复必须保留账本身份和初始化记录，不重复执行此操作。

## 常用配置

| 需要 | 参数与说明 |
| --- | --- |
| 查看任一动作 | 加 `-Plan`（别名 `-DryRun`）；输出动作、非秘密参数和影响，不执行 |
| 获取帮助 | `-Help`；所有动作仅接受相关参数，避免静默忽略 |
| 更换本机端口 | `init -PublicUrl http://localhost:18120 -EdgePort 18120`；使用新的独立目录与项目名 |
| 本地 TLS | `init -PublicUrl https://manager.example.com:8443 -EdgePort 8443`，准备证书后 `start -Tls` |
| 外部 HTTPS 代理 | 初始化和启动均加 `-ExternalTlsProxy`；公开 URL 为标准 HTTPS，内部保持回环端口 |
| 家庭身份扩展 | 初始化和构建均加 `-ConsumerIdentity`，仍遵守身份提供方准入流程 |
| 指定源码或工具 | `build -SourceDirectory ... -MavenCommand ... -FlutterCommand ... -DartCommand ... -MavenRepository ...` |
| 已批准的身份配置 | `start -IdentityAdminDirectory ... -IdentityRuntimeDirectory ...`，保留底层完整核验 |

部署目录统一位于仓库 `.local/`。多个环境用不同目录、Compose 项目名与端口；相对路径按仓库根目录解析，避免从不同工作目录启动到错误环境。

操作预览只展示动作与转发参数；证书、依赖和发布来源等完整校验仍由实际命令执行。

`start` 沿用现有 `up --build` 发布行为，会更新**指定项目**，不是仅恢复运行容器。已有环境的无构建恢复、TLS、管理员开通、密钥备份与故障恢复，请按[完整部署手册](deployment-runbook.md)处理，不能把启动成功作为业务验收。

`status` 只读取选定环境元数据并列出其精确 Compose 项目标签下的容器，不打印环境变量、命令行或密钥；同标签的容器状态仅用于运维定位，不证明发布身份。`verify` 保留实际发布身份及入口检查，但不执行登录后的业务旅程或真机管控。

## 本批验证边界

新增的是统一调度和多平台入口，不改变数据库结构、发布配方或产品授权。Windows 本机已通过 PowerShell 语法检查及 5 项入口测试，覆盖动作计划、参数、路径、输入保护和预览不执行；没有运行实际构建、初始化或发布。Linux/macOS、真实安装和全产品验收仍按实际环境单独判断。详情见[本批记录](reviews/engineering-foundation-20261025.md)。
