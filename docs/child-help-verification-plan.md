# 儿童求助行为验收与恢复修复计划

> **For agentic workers:** Use executing-plans. Existing approved child-help contract is authoritative; preserve all shared work.

**Goal:** 为已有求助功能补齐实际行为证据，并修复验证发现的权限、幂等和恢复缺陷。
**Architecture:** 保留 Spring/JDBC 事务、当前成员授权、设备 opaque 凭证和 Flutter 加密记录；测试使用真实业务实现，在身份发行、HTTP 传输和本机存储边界使用受控替身。
**Tech Stack:** Spring Boot / JUnit / MockMvc / H2 / MySQL / Flutter test。
**Spec:** [儿童求助记录契约](child-help-request-contract.md)。

## 全局约束

- 继续未发布 1.0.0，不新增历史迁移链；当前运行数据库不重建。
- 云端收到、成人已看到和实际帮助完成是不同事实。
- 请求先持久化后发送；结果未知保留原编号；不自动重发。
- 服务端按当前租户、注册周期、教师班级/直接学生范围重验。
- 只纳入本阶段文件；冻结候选避免并行开发污染。部署另行集成。

## 复核重点

1. 并发提交、刷新与重试不能覆盖尚未确认的请求。
2. 进程恢复、身份变化和存储故障不能制造发送成功的假象。
3. 教师转班/范围/成员版本变化应立即影响查询与确认。
4. 并发确认、原编号重放、限流边界保持事务和审计一致。
5. 不把受控 Flutter/MockMvc 测试当作真实 Android、正式身份服务或消息送达验收。

### Task 1: 儿童端持久化与并发恢复

Files: `apps/child/lib/core/help_requests.dart`, new `apps/child/test/help_requests_test.dart`.

- [x] 添加真实协调器的持久化先行、断线恢复、原编号重试、响应校验、状态不倒退、身份失效、并发操作测试。
- [x] 在冻结候选运行，记录实际失败；只修复已复现的根因。
- [x] 运行专项和儿童端完整测试、静态分析，保存结果。

### Task 2: 后端权限与事务专项

Files: new `backend/src/test/java/com/aimanager/HelpRequestJourneyTest.java`; only evidence-driven changes to safety implementation if needed.

- [x] 用真实 opaque 认证链、数据库和 MockMvc 覆盖提交/重放/冲突/限流、注册隔离、失效凭证、成人角色、教师动态范围、稳定分页、强版本与并发确认。
- [x] 运行 H2 与独立 MySQL；修复必须先有失败证据。
- [x] 汇总每项证据和未覆盖范围；一次独立最终复核，提交推送本阶段文件。

## 验收边界

实际 Android 进程/加密硬件、后台消息送达、响应值守、生产容量及最新家长端联合部署需要后续专项证据；本阶段不据此宣称整体产品完成。

## 阶段结果

儿童端新增28项专项，完整152/152通过，静态分析无问题。H2受影响40/40、真实MySQL求助28/28；完整后端864项中844通过、20条件跳过，JAR构建成功。MySQL先复现并发重放500和限额超发，再修复通过；两个临时库及账号均已清理。一次最终复核无Critical/Important，保留一项Minor：补不同成人同时确认的并发测试（当前测试使用同一成人）。

本阶段不部署。真实Android、身份发行、外部消息送达、实际响应、最新家长端联合验收及完整删除仍未完成。完整日志摘要、跳过原因与复核取舍见[验收记录](releases/stage-child-help-verification.json)。
