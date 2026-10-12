# 1.0.0 支持授权与诊断副本删除

**Goal:** 补齐主体删除链中的支持授权和诊断包清理，保留其他主体与支持人员账号。

**Architecture:** 沿用已批准主体删除契约、Spring JDBC、独立接受账本及 `ErasureRecoveryJobs.applyBatch`。内部处理器逐批删除诊断包，再删除支持授权；数据和检查点同事务。步骤完成不改变全局作业或维护状态。

**Spec:** `data-erasure-contract.md`。执行方式沿用总计划的 executing-plans；实现前写失败行为测试。

## 约束与设计

- 按接受记录中的 tenant、subject 和不可变 device/registration 元组核对当前设备及两表历史范围。未接受的历史注册、已被其他主体占用的同一注册、诊断包与支持授权范围不一致均阻断。
- `diagnostic_packages` 的加密 artifact 与元数据同一行，整行删除覆盖各个状态及残留内容；先删子记录，避免外键阻断或未计数级联。每次最多删除 25 个物理行。
- 独立步骤 `SUPPORT_DIAGNOSTICS` 使用既有 DATA/DONE 阶段和 handler_version=1，无需新增表或迁移。批次验证当前存储清单、租约、账本及数据归属；DONE 重入发现目标数据再现则拒绝完成。
- 保留租户级计数/锁行及支持人员的全局配对资料。后者属于支持人员账号，目标关联路径随 grant 行删除；不将主体删除扩展为跨租户账号删除。通用幂等、审计、其他消息及已下载的外部副本仍需各自处理。
- 不开放尚未闭环的公开删除提交、自动 worker 或完成按钮。运行环境保持现有已验证版本。

## Task 1: 内部域处理器与真实存储回归

**Files:** 新增 `backend/src/main/java/com/aimanager/retention/internal/ErasureSupportDiagnosticsProcessor.java` 与对应测试；更新删除契约及本计划、阶段证据。

**Interface:** `process(ErasureRecoveryJobs.Claim, int limit)` 返回 phase、deletedRows、totalRows、batches；`Result.complete()` 仅表示本步骤 DONE。

1. 在隔离的已提交后端副本中编写失败测试，覆盖两表删除、他主体/租户保留、注册代际、缺失范围和错误授权关联、所有任务状态、批次上限及检查点重入。
2. 观察预期失败后实现范围校验、叶子优先删除、同事务检查点和完成重查。
3. 扩充实际回滚、过期租约、并发领取、损坏检查点、计数溢出和数据库覆盖检查；执行新处理器、已有处理器、恢复作业、初始化和模块边界回归。
4. 在独立 MySQL 业务库及账本库运行相同存储回归并清理测试库；运行完整后端 verify，逐项记录条件跳过。
5. 按 executing-plans 进行一次独立最终复核；重要问题一次 RED→GREEN 修复并跑回归。仅提交本阶段文件。

## Review Focus

- 诊断包与 grant 的 tenant/subject/device/registration 一致性及历史注册范围。
- 外键顺序、真实物理行数上限、跨租户/主体保留及全局配对资料保留理由。
- 数据与检查点事务、领取 fencing、DONE 重入、计数溢出、未知步骤版本。
- 不把这两个存储的处理完成宣传为完整隐私删除，不丢失通用幂等、审计及外部副本的后续义务。
