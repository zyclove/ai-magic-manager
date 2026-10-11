# 1.0.0 完整发布构建计划

**Goal:** 让标准发布入口覆盖当前全部 Dart/Flutter 工程以及后端已有的桌面 HTTP 联调，使用同一份隔离源码生成可追溯的前后端产物。

**Spec:** `version-1.0.0-initialization.md`、`deployment-runbook.md`。沿用 1.0.0 空库初始化；既有运行环境保留。完整产品目标仍按 `implementation-plan.md` 执行。

**执行：** executing-plans，当前会话实施。共享工作区中的其他未提交变更不进入发布快照。使用已提交源码归档隔离构建，构建运行期间不修改其输入。

## Task 1: 完整发布构建与真实构建证据

**Files:** `scripts/build-deployment.ps1`、`scripts/tests/test_deployment_build.py`、`docs/deployment-runbook.md`；真实构建暴露的修复还涉及策略预览编号校验及其回归、儿童端会话关闭及其回归，以及管理端 26 个文件的官方 Dart 导入/语法风格自动修复。完整文件清单随阶段证据记录。

**Interfaces:** 输入初始化目录、完整首版源码和 Maven/Flutter/Dart 命令；输出唯一产物目录、来源哈希和发布清单。失败不得更新上次可用的清单或环境产物路径。工程依赖必须先于后端跨 SDK 联调准备完成。

1. 写真实 PowerShell 编排行为测试，仅在 Maven/Flutter/Dart 外部工具边界使用替身；覆盖完整工程、联调参数、依赖顺序、隔离快照、缺失儿童端和构建失败保留旧发布。
2. 执行 `python -m unittest discover -s scripts/tests -p test_deployment_build.py -v`。
   Expected: 对现有脚本缺失工程/参数的断言失败。
3. 实现完整首版必需应用检查、包和嵌套示例发现与 Dart/Flutter 工具选择、先依赖后联调、所有工程分析/已有测试、可选离线依赖模式，以及清单的实际工程验证范围。
4. 执行 `python -m unittest discover -s scripts/tests -p test_*.py -v`。
   Expected: 全部部署脚本行为测试通过；无服务启动或数据库改动。
5. 从已提交源码加本阶段改动创建不可变候选，执行真实标准完整构建。处理真实错误后才记录通过，不把条件跳过的 Android 真机用例标成通过。
   Expected: 后端 verify、所有工程 analyze/已有 test 和管理端 release 构建成功，生成 1.0.0 清单。若现有工程自身存在阻断，应记录真实失败并修复后重跑，不能跳过检查伪造完整构建。
6. 一次独立最终审查；重要问题一次修复并验证。提交本阶段文件及真实证据，后续继续独立首版环境启动和浏览器交互验收。

## Review Focus

- 后端联调不得误用工作区或旧快照的客户端。
- Java 启动 Dart 使用直接可执行文件，Windows Flutter 路径符合现有进程调用方式。
- 无测试工程必须如实标注，不把缺少用例当成测试通过。
- 快照与失败发布保留现有环境；凭据不进入源码、产物或输出。
