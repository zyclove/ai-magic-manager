# Console startup log directory recovery implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 已激活的 1.0.0 控制台缺少运行日志目录时，普通启动可自行恢复该目录并完成原有启动流程。

**Architecture:** 继续使用主入口验证后的活动发布选择与独占运行锁。仅在确实需要启动、且 CheckOnly 和其他项目的端口冲突检查通过后，准备该发布的 `.local/deployment/logs`；所选发布脚本、环境恢复和健康验证保持原有职责。

**Tech Stack:** PowerShell 7、Python 标准库 unittest、真实文件系统及现有本地命令夹具。

**Spec:** `scripts/start-active-console.ps1` 的现有选择、检查、启动与环境恢复契约；2026-10-15 实测恢复记录 `.local/runtime/guardian-startup-recovery-20261015-evening.json`，SHA-256 `f7e64b2028a76751a5e048e8edad42245fc9ad6f4e86bc6cf120202ccbabfacc`。该记录显示会话 48393 因日志父目录缺失退出 1，人工补目录后会话 40285 正常退出 0；当时仍使用原已激活发布。

## Global constraints

- 按 1.0.0 开发，不引入历史兼容层、数据库迁移链或业务数据恢复。
- 本阶段只修复主启动入口的运行目录恢复行为，不发布新的前后端业务构建产物，也不替换活动发布选择。
- 使用基线 `3d1f459eb0ded43f53ae4be86d3942f2af62ea67` 加精确测试/计划覆盖冻结 RED；排除其他会话的界面及业务 WIP。
- RED 冻结后不改其输入。生产实现与 GREEN 使用新的不可变目录，并记录每份输入和终态结果。
- 只允许创建已验证 `selection.deploymentDirectory` 下的直接子目录 `logs`，不递归清理或替换现有目录及内容。
- `CheckOnly`、已健康的普通启动、无效激活信息、运行锁冲突和所选端口被其他项目占用时，不创建日志目录。
- `logs` 为普通文件、有效或失效的 junction / reparse point 时拒绝；不得调用发布的 start/verify，也不得写入链接目标。
- 所有操作继续受 `console-runtime.lock` 独占句柄保护；成功与失败均恢复原 `COMPOSE_PROJECT_NAME`、`EDGE_PORT` 并释放锁。
- 测试只运行真实主入口和元数据读取器，Docker、发布 start/verify 与浏览器边界为本地夹具；PATH 为空，不能退回真实 Docker。
- junction 及其目标仅存在于本用例拥有的 `.local/start-active-console-test-*` 临时目录；清理前验证绝对边界并先移除链接本身。创建失败必须显式失败，不能跳过核心用例。

## Review focus

- 缺失日志父目录必须在发布脚本首次真实写日志前创建；仅伪造 start 成功无法证明恢复行为。
- 已存在日志目录包含根级及嵌套历史记录时，普通启动保留这些记录并可写本次日志。
- CheckOnly 的健康和不健康分支，以及已有健康发布的普通启动，均只执行原有检查行为。
- foreign-port 冲突先于日志目录创建；不能因为修复日志而先改文件或触发启动。
- 失效 junction 的 `exists` 结果不足以证明路径安全；仍须识别 reparse 属性并拒绝，不重新创建链接目标。

## Owned files

- `scripts/tests/test_start_active_console.py`：添加可选 `write-log` start mode，用 `WriteAllText` 真实写入 `logs/compose-start.log`；扩展目录恢复、保护及链接夹具。
- `scripts/start-active-console.ps1`：主实现会话负责，位置固定在 foreign-edge / port guard 之后、调用所选 `start-deployment.ps1` 之前。
- 本计划及后续精确验证记录。保持所选发布的 `start-deployment.ps1`、元数据、凭据、业务源码和数据库文件不变。

## Tasks

### Task 1: 复现缺失目录并固定受保护分支

**Interfaces:** 继续调用 `StartActiveConsoleTest.invoke(...)`；新 `start_mode="write-log"` 不创建父目录，只尝试向所选发布写入 `Synthetic selected release started.\n`。

- [x] 添加八个行为用例：缺失目录恢复、已有内容保留、CheckOnly 双健康态不创建、健康普通启动不创建、foreign-port 不创建、logs 普通文件拒绝、有效 junction 拒绝且目标不变、失效 junction 拒绝且目标保持缺失。
- [x] 新用例同时检查真实文件结果、所选项目/脚本、运行锁覆盖与释放、宿主项目及端口变量恢复；保留全部原有回归断言。
- [ ] 主会话冻结基线加精确测试和计划，在冻结副本执行 `python -m unittest discover -s scripts/tests -p test_start_active_console.py -v`。
- [ ] 检查 RED 的断言及终态：缺失目录用例必须因真实 `WriteAllText` 的父目录缺失而失败；普通文件 / junction 用例应揭示主入口尚未在发布 start 前拒绝非法日志路径。不能将命令未启动、超时或夹具权限错误当作预期 RED。

### Task 2: 仅在真正启动前准备安全日志目录

**Interfaces:** 消费 `Get-ActiveConsoleSelection` 已验证的 `selection.deploymentDirectory`；输出可供原有发布 start 脚本写入的普通 `logs` 目录，失败时不调用发布 start/verify。

- [ ] 使用 `File.GetAttributes` 检查完整日志路径，包括失效链接；现有路径必须为 Directory 且没有 ReparsePoint。只有明确缺失才使用不带 Force 的 Directory 创建，随后复核目录属性。
- [ ] 将准备逻辑放在所选端口的 foreign listener 检查之后、现有 `start-deployment.ps1` 调用之前；复用原环境 finally 和外层运行锁 finally。
- [ ] 冻结新 GREEN 副本，执行 Task 1 同一命令；目录恢复与保护用例全部通过，原有启动、引擎恢复、环境及运行锁用例无回归。

### Task 3: 完整脚本回归与证据交付

**Interfaces:** 消费独立冻结的 GREEN 源码、终态测试输出和逐文件 SHA-256；输出可审阅的精确变更及验证记录。

- [ ] 在同一不可变 GREEN 源码执行 `python -m unittest discover -s scripts/tests -p 'test_*.py' -v`，审阅每个失败、错误或跳过原因，不以局部通过替代完整脚本回归。
- [ ] 独立复核日志路径 guard 的顺序、失效链接识别、既有内容保护、锁释放及环境恢复；静态检查 PowerShell 语法。
- [ ] 记录 RED / GREEN / 完整回归终态与输入哈希，核对工作区、冻结副本和提交字节一致，再协调共享索引进行精确提交。测试夹具结果不代表真实 Docker 或登录旅程验证。
- [ ] 如需现场检查，只针对原已激活发布另记实际检查证据；不借此阶段升级业务服务、数据库或其他会话的未发布功能。

## Current status

测试与计划已编写，尚未执行 RED、GREEN、完整脚本回归或现场命令；生产主入口尚未由本测试作者修改。整体专业化、易用性及完整功能目标继续保持进行中。
