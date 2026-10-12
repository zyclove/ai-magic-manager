# 家长端纳入发布检查计划

> **For agentic workers:** Use executing-plans; one final scoped review.

**Goal:** 发布构建不能遗漏已提交的家长 Android 工程，缺失或检查失败时保留当前发布选择。
**Architecture:** 沿用 PowerShell 冻结源码、依赖准备、静态分析、已有测试、发布清单流程。明确三个应用为必需工程；只有 guardian 生成 Web 部署产物。家长原生签名、APK 和实机准入仍按原生交付契约处理。
**Tech Stack:** PowerShell 7、现有 Flutter/Dart/Maven 编排、Python unittest 控制编译器边界。
**Spec:** `deployment-runbook.md`、`parent-android-delivery.md`、用户要求全部前后端完整稳定可用。

## 约束与复核重点

- 未发布 1.0.0；不引入历史兼容或数据库迁移。
- 只改发布编排、编排测试与相应文档；家长端源码由另一会话维护。
- parent 的 pub get/analyze/已有 test 必须使用相同冻结快照；缺失 pubspec 在任何编译器启动前失败。
- 任意家长端检查失败，不更新发布清单或服务产物选择，不调用 guardian release build。
- 无测试时清单如实标明 not-present，不能将 SDK 替身测试称为实际 APK 或应用功能验收。
- 此工作不修改求助阶段正在全量构建的候选输入。

### Task 1: 完整应用构建门槛

Files: `scripts/build-deployment.ps1`, `scripts/tests/test_deployment_build.py`, `docs/deployment-runbook.md`, this plan and stage evidence.

- [x] 测试夹具加入 parent；新增必需工程缺失、家长分析/测试失败保留旧发布、仅 guardian Web 打包的断言。
- [x] 运行真实 PowerShell 编排测试观察失败；集中应用列表供必需检查、快照复制与项目验收复用。
- [x] 运行全部部署脚本测试；记录替身边界与检查数量。
- [x] 一次独立最终复核；仅提交本阶段文件，不发布 APK、不更新运行服务。

## 验收结果

初始8项构建编排用例中5项失败，纳入parent后全部部署/Helm22项通过。一次独立复核发现必需pubspec为同名目录时可被静默跳过；新增回归先失败（9项中1项失败），源文件及快照均改为必须存在实际文件，最终23/23通过。无Critical、无Minor，1项Important已按一次RED→GREEN修复。

编译器边界使用替身，实际执行PowerShell快照、清单和发布选择逻辑；不代表家长APK、真实身份、原生功能或生产运行已验收。详细取舍见[结构化记录](releases/stage-parent-build-gate-verification.json)。
