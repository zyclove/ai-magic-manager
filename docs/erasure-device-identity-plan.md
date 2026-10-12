# 1.0.0 设备身份附属数据清理实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: executing-plans；沿用已批准删除契约，内联实现及一次独立最终复核。

**Goal:** 清除已接受主体范围中的设备凭据、轮换记录、凭据范围、设备组关联和能力记录，保留重新注册设备和共享分组。

**Architecture:** 新增内部 `DEVICE_IDENTITY` 处理器，复用独立账本、`ErasureRecoveryJobs.applyBatch` 和已有 DATA/DONE 检查点。使用 Spring JDBC 真实事务，逐行显式删除，不依赖级联，不添加历史迁移。

**Tech Stack:** Java 17、Spring JDBC、既有 H2/MySQL 初始化与独立删除账本。

**Spec:** `docs/data-erasure-contract.md`、`docs/version-1.0.0-initialization.md`。

## Global Constraints

- 产品为未发布 1.0.0，结构进入全新初始化基线；本步骤无需新增结构。
- 只处理已接受的 tenant/subject/device/registration 范围。当前主体设备未全部纳入、已接受注册被他主体占用、当前目标设备未退出时拒绝删除。
- 目标的凭据范围仍 active，或存在 active 且未撤销且未到期的凭据时拒绝删除；已失效、撤销及未激活凭据进入物理清理。
- 轮换关系两端必须属于同一租户、设备和注册；涉及目标的跨租户/设备/代际关联必须在任何删除前阻断。
- 轮换记录先于凭据；每次总共最多删除 25 个物理行。能力记录没有 registration 字段，只通过当前设备的完整已接受元组选择。
- 保留 `devices`、`device_groups`、注册申请/证明、配置副本及其他域数据，由完整编排继续处理。设备删除前不得丢失确定其他域范围所需的身份关联。
- 处理器依赖已接受账本和已排空且暂停的业务入口；步骤 DONE 不结束全局作业，不恢复业务流量，不开放公开删除。

## Review Focus

- 轮换关系无 tenant 列，任意一端属于目标时都要检查另一端，不能删除他主体凭据。
- 不含 registration 的能力记录必须绑定当前设备代际，旧代际的删除不能影响重新注册设备。
- 设备组共享关系及多列键删除计数，不能级联删除分组或其他成员。
- 已撤销与过期凭据、未激活凭据、仍有效凭据/范围的处理差异及 DONE 数据再现。
- 中途存储故障、租约失效、并发领取、未知检查点版本及覆盖清单变化均不能留下部分删除。

### Task 1: 内部身份清理处理器与真实存储验收

**Files:** 新增 `backend/src/main/java/com/aimanager/retention/internal/ErasureDeviceIdentityProcessor.java`、对应测试；更新删除契约、初始化进度和阶段证据。

**Interface:** `process(ErasureRecoveryJobs.Claim, int limit)` 返回 phase/deletedRows/totalRows/batches；`complete()` 只表示 DEVICE_IDENTITY 步骤完成。

- [ ] 先编写行为失败测试：五表删除顺序、共享分组与他主体保留、代际、异常轮换、活跃身份阻断、限额、DONE 重入。使用现有真实业务库与独立账本夹具。
  Expected: 可编译的空处理器在行为断言上失败，不接受编译错误作为 RED。
- [ ] 实现范围检查、轮换一致性、叶子优先有界删除及原子检查点。
  Expected: 首批行为用例全部通过。
- [ ] 补齐跨租户、边界键、实际删除后故障回滚、租约与并发、未知版本/阶段、计数溢出、空范围及清单变化回归。
  Expected: 新处理器和恢复/其他处理器回归全部通过。
- [ ] 在冻结已提交源码加本阶段文件的副本中运行隔离 MySQL 回归和完整后端 verify；保存日志与跳过原因，清理仅本次创建的临时库。
  Expected: 测试零失败，明确列出条件跳过，产物版本 1.0.0。
- [ ] 一次独立最终复核；重要问题一次 RED→GREEN 修复，保留其他共享工作树改动，仅提交本阶段文件。
  Expected: 已验证的阶段提交与证据，不宣称全量主体删除完成。
