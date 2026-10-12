# 1.0.0 注册与设备退出记录清理计划

> **For agentic workers:** REQUIRED SUB-SKILL: executing-plans；沿用已批准的主体删除契约直接实施，结束时一次独立最终复核。

**Goal:** 清理目标主体注册申请及已停止服务的设备退出副本，保护其他注册与仍可领取/确认的清理任务，持续明确终端实际清理未验证。

**Architecture:** 沿用 JDBC 事务、独立接受账本、恢复作业锁、租约与持久步骤检查点。新增内部 `DEVICE_LIFECYCLE` 步骤，不添加框架或增量迁移。每批最多删除 25 个物理行。

**Tech Stack:** Java 17、Spring JDBC、Flyway、JUnit、H2、MySQL 8.4。

**Spec:** `data-erasure-contract.md`、现有 `LifecycleService` 与 `EnrollmentService` 的关联及清理窗口契约，总计划 Task 10。

## Global Constraints

- 冻结已提交 `db7b10c` 加本阶段归属文件，包含已提交求助模块与其内部清理步骤；保护其他会话 WIP，不修改 V1 或存储清单。
- 四张退出记录表按接受的 tenant/device/registration 元组选择；注册申请和证明按明确的 tenant/subject 选择，绝不跟随设备 ID 删除其他主体申请。
- 当前主体设备必须全部在接受清单中且已 REVOKED；有效活动凭据或活动凭据范围阻断。
- 目标主体申请关联的非空 device_id 必须属于接受清单；空设备申请可清理。申请没有注册列，不推断其注册代际，也不修改设备主记录。
- 头、预览与操作的关联两端任一属于目标时，缺失操作或跨设备/注册链接必须阻断。空 operation_id 的头/预览允许清理。回执按操作关联选择。
- 退出操作的状态必须为既有支持状态、local_evidence 为 NONE 或 DEVICE_REPORT_UNVERIFIED。CLEANUP_REPORTED/CLEANUP_FAILED 必须有 DEVICE_REPORT_UNVERIFIED。
- 除 CLEANUP_CANCELLED 外，absolute_not_after 尚未到期的操作阻断；包括已上报的操作，保留确认重放窗口。期限经过仅允许清除服务器副本，不能证明终端清理成功。
- 先证明后注册申请，先预览/头/回执后操作；显式逐行删除并共享批次预算。与检查点同事务，提交前再次校验独立账本和租约。
- DONE 重入检查六表并保留 `unverifiedLocalRegistrations`，该值从独立接受范围确定，即使没有退出记录也不能推断本地已清理。步骤完成不完成全局作业、不解除维护。
- 设备主记录、受管供应方注册、其他缓存/事件/审计、共享策略与外部副本由完整后续编排处理；公开删除入口和自动 worker 继续保持未开放。

## Review Focus

- 旧设备 ID 重新注册到他主体，旧申请与退出记录可清理，新注册及他主体申请必须保留。
- 头/预览关联另一注册或缺失操作，两个方向涉及目标均在任何删除前阻断。
- 清理上报仍在确认窗口内、无回执、过期或取消：不能清除活跃确认窗口，不能把过期/取消/上报视为终端实际清理。
- 实际删除后发生存储失败或租约失效，数据与已有检查点一起回滚；并发和重建后预算与计数准确。
- 已明确属于目标主体但没有设备的注册申请，与非法关联未接受设备的申请，必须分别正确处理。

### Task 1：注册和退出域处理

Files: 新增 `backend/src/main/java/com/aimanager/retention/internal/ErasureLifecycleProcessor.java`、`backend/src/test/java/com/aimanager/retention/internal/ErasureLifecycleProcessorTest.java`，更新删除契约和阶段证据。

- [x] 创建真实数据库行为检查与非删除最小桩；执行 RED，预期缺失处理和守卫导致失败。
- [x] 实现六表有界事务处理、注册/主体/关联保护、清理窗口保护、未验证本地状态与持久检查点。
- [x] 覆盖六表残留、重新注册、其他租户相同 ID、多个注册、空设备申请、跨边关联、活跃状态、非法数据/检查点、重试、DONE 再现、真实删除后回滚、旧租约与并发；H2 专项全部通过。
- [x] 独立 MySQL 初始化及受影响领域全套全部通过，临时数据库与账号全部清理；完整后端构建成功并列出条件跳过项。
- [x] 一次独立最终复核；重要问题一次 RED→GREEN 修复，限定文件提交推送并保存全部实施取舍。

## 阶段验收

冻结 `db7b10c` 的 357 个后端文件保持一致，仅新增本阶段源码与测试。首轮 51 项缺失行为检查失败，实现后 51 项通过；H2、独立 MySQL 受影响领域各 218/218；完整后端 836 项中 816 通过、20 条件跳过，构建成功。三套临时数据库及账号已清理。一次独立最终复核 Critical 0、Important 0、Minor 0。

保留清理确认记录不保证当前全局维护期间接口可访问。此阶段仍为内部步骤，没有部署，也没有交付完整删除入口、目标隔离或终端实际清理证明。全部取舍、跳过原因与源码/日志摘要见[结构化验收记录](releases/stage-erasure-lifecycle-verification.json)。
