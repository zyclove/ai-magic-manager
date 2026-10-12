# 1.0.0 权限观察初始化与删除覆盖实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: executing-plans；内联执行，最后一次独立复核。

**Goal:** 权限观察设置、快照和速率数据进入全新 1.0.0 初始化及主体删除覆盖，保留其他租户、主体与重新注册设备。

**Architecture:** 复用 Flyway V1 完整业务基线、V2 数据库事件表适配、人工审核存储清单和现有 OBSERVATION_REPORTS 原子批次处理器。将新增受管注册扫描索引也归入 V1，消除与事件表 V2 重号。

**Tech Stack:** Java 17、Spring JDBC、Flyway、H2/MySQL。

**Spec:** `docs/data-erasure-contract.md`、`docs/version-1.0.0-initialization.md`、用户全新 1.0.0 指令。

## Global Constraints

- 未上线 1.0.0 直接更新初始化基线；不升级、不清空现有业务数据库。
- 权限设置含个人理由、快照含应用权限、速率含设备注册关联；均属于 observation 域 DEVICE_DATA，逐列纳入清单。
- 删除按已接受的 tenant/device/registration，不能仅按设备 ID；授权关闭不能替代物理清理。
- 三张表共用 DATA 阶段总计最多 25 行的限额、同一事务与检查点，DONE 再检查不能遗漏。
- 独立账本与持续排空保护继续适用；内部步骤完成不代表全局完成，功能开关保持默认关闭。
- 使用提交快照加本阶段文件验收，保留他人未提交工作；本阶段不声明真机或部署已验收。

## Review Focus

- V1 合并保留新增外键、索引及列，公共目录不能再与数据库适配 V2 冲突。
- 旧注册删除与相同不透明 ID 的跨租户数据保持隔离。
- 设置授权关闭或只有速率残留也必须清除；三表任一数据再现均拒绝 DONE。
- 实际删除后检查点失败或租约失效必须回滚全部行，重启继续不能重复计数。
- 清单变化仍按未知结构拒绝继续，不能将完整删除入口或真机行为误报为完成。

### Task 1: 初始化与完整权限观察清理

**Files:** V1、删除公共 V2/V3 增量文件、subject-data-stores.json、ErasureObservationProcessor.java、DatabaseInitializationTest.java、新增 ErasurePermissionObservationTest.java、契约/初始化文档与阶段证据。

**Interface:** 现有 process(Claim, limit) 与 REPORTS/DATA/DONE 检查点不变；不加兼容分支。

- [ ] 扩展初始化空表和索引断言；运行现有全新建库测试，记录真实重复版本失败。
  Expected: 初始化因公共 V2 与 vendor V2 重号失败。
- [ ] 原样合入两个增量文件，移除增量文件，显式添加三张表的列和分类；运行初始化验收。
  Expected: 空库仅执行 V1/V2，重启执行零脚本且保留已有数据。
- [ ] 编写权限观察实际存储删除、隔离、限额、DONE 重入及回滚测试，先观察缺少处理表的行为失败。
  Expected: 数据未删除或 DONE 未拒绝的断言失败。
- [ ] 将三表纳入现有处理器；完成聚焦 H2、隔离 MySQL 和完整后端 verify。
  Expected: 零失败，明确条件跳过，1.0.0 构建成功，临时 MySQL 库及用户清理。
- [ ] 一次独立复核，重要问题一次 RED→GREEN 修复；仅提交本阶段文件并推送 dev。
  Expected: 保留可追溯证据，不宣称完整产品或运行环境已更新。
