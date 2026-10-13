# 1.0.0 联合构建与本机更新计划

> **For agentic workers:** Use executing-plans; one final scoped review.

**Goal:** 将最新已提交的前后端与家长端纳入真实 SDK 联合构建，备份后更新本机 18101 环境。
**Architecture:** 冻结 Git 提交，独立源码与 Compose 项目，首次初始化全新数据库。保留原项目的卷、配置和独立删除账本作为回退入口。
**Tech Stack:** Maven / Java 17、Flutter / Dart、PowerShell 7、Docker Compose、MySQL、Keycloak。
**Spec:** 用户要求按未上线 1.0.0 初始化，已授权备份后更新服务和数据库；deployment-runbook.md。

## 约束与复核重点

- 仅包含冻结提交，不吸收共享工作区未提交修改；构建进行时不修改候选输入。
- 不迁移或清空旧数据库，不回滚删除账本；新项目使用独立数据卷及账本身份。
- 真实 SDK 构建通过、备份完成后才切换原 18101 服务；失败则恢复旧项目。
- 家长端分析及已有测试必须参加；本阶段不代表 APK 签名、真机、真实 MFA 或外部送达验收。
- 备份包含三个数据库、配置、密钥、发布产物，限制目录权限，不输出凭据。

### Task 1: 联合构建、备份、更新与验收

Files: this plan, docs/releases/stage-v1-current-runtime.json; baseline SQL, DatabaseInitializationTest; ignored runtime scripts and evidence.

- [x] 冻结当前提交，初始化独立部署配置并运行完整真实 SDK 构建。
- [x] 首次构建发现审批索引 V2 与供应商事件表 V2 冲突；将索引合入 V1 并补索引顺序断言，另建修复候选运行完整验收。
- [x] 记录后端、各应用与包的真实分析/测试结果及发布产物摘要。
- [x] 备份当前 integrated 项目；完成新项目镜像准备后切换 18101。
- [x] 初始化新独立账本与数据库，启动六个服务并配置已授权管理员。
- [x] 核对运行产物、schema、健康状态、真实登录及页面操作。
- [x] 一次独立最终复核，记录边界，只提交本阶段源码与文档。

Expected: 构建终态成功、六服务健康、运行产物与清单一致、首次基线存在、管理员真实登录成功；备份及旧卷仍可用。

## 执行裁决

冻结提交为 `2965813f2b791e1937eecaf80b22a6c906fe2af3`，后续并行开发提交及未提交内容不在本轮候选中。首次构建实际触发 `DatabaseInitializationTest` 的重复 V2 错误，随后明确中止失败构建并确认没有残留编译进程。修复候选基于同一归档，仅叠加 V1 索引、删除冲突脚本、增加索引列断言三个文件变更。旧环境不执行迁移。


## 本阶段结果

后端864项：856通过、8条件跳过；应用及组件713项通过，13工程分析完成，parent和device_cleanup无测试目录。实际运行六服务健康，MySQL首次基线及审批索引、JAR/JS摘要、管理员密码PKCE登录和桌面/移动操作均通过。原六服务停止，三个原卷保留。一次独立复核0 Critical/Important/Minor。备份未恢复演练，原生/正式身份/整体产品能力边界见[阶段证据](releases/stage-v1-current-runtime.json)。
