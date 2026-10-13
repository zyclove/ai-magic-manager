# 儿童端退出缓存清理验证计划

> **For agentic workers:** Use executing-plans; one final scoped review.

**Goal:** 清理所有本应用配置、访问/申请数据库及 Sembast 压缩恢复文件，防止退出完成后恢复旧缓存；补齐 Android 宿主清理和会话关闭顺序回归。
**Architecture:** 沿用现有签名命令、身份管理器、加密存储及目录持久化屏障。只扩展已知数据库文件白名单至 Sembast 3.7.2 实际使用的单个 `~` 前缀，未知相近名称/链接/目录仍失败，其他文件保留。不更换存储框架或改变清理授权。
**Tech Stack:** Flutter test、Sembast 3.7.2、现有 flutter_secure_storage、device_cleanup/device_identity。
**Spec:** docs/device-deprovision-contract.md §5；apps/child/lib/platform/cleanup_executor_io.dart；安装的 Sembast 3.7.2 lib/src/sembast_fs.dart tmpPath/tmpRecover。

## 约束及复核重点

- 按 1.0.0 当前数据模型实现，不新增历史迁移。
- 仅在全部缓存持有者关闭、命令已验签后清理自己的数据。
- 真实临时目录/Sembast 文件验证删除和恢复；Android 加密插件、fsync、身份云端使用明确测试边界，不据此声称真机、断电、物理擦除或 TLS 认证通过。
- 主数据库缺失时的孤立恢复文件仍必须清理；不能依赖先打开数据库来处理它。
- 匹配数据库名称但类型为目录/链接，或名称包含非标准后缀时，失败并保留回执材料。
- 原身份和当前清理日志必须保留至确认；未知加密键、持久屏障失败不能报告成功。
- 不修改共享管理台、家长端、后端或部署输入；冻结候选验证。

### Task 1: 补齐宿主缓存范围与顺序验证

Files: apps/child/lib/platform/cleanup_executor_io.dart; apps/child/test/cleanup_executor_test.dart; apps/child/test/cleanup_session_test.dart; this plan; docs/releases/stage-child-cleanup-storage-verification.json; docs/device-deprovision-contract.md.

Interfaces: consumes verified CleanupCommand, real DeviceIdentityManager and AndroidAgentCleanupExecutor; produces same public interfaces with complete known Sembast file cleanup.

- [x] 使用真实 Sembast 文件构造压缩恢复残留，确认原实现返回成功却遗留可恢复缓存的 RED。
- [x] 修改已知文件匹配，使主文件及单个 `~` 前缀恢复文件均删除；保留严格类型/未知名称检查。
- [x] 验证孤立恢复文件、不同注册缓存、无关文件、未知安全键、屏障失败、未关闭持有者、凭据停用与原密钥保留。
- [x] 验证会话启动检查在打开缓存前；重试等待持有者关闭、关闭失败阻止清理、同会话重入被拒绝、完成/失败结果准确。
- [x] 冻结本阶段源码，运行儿童端全部分析/测试及清理 SDK 分析/测试，记录原生环境能力边界。
- [x] 一次独立最终复核，处理重要问题，归档证据后按现有授权精确提交推送。

Expected: 行为 RED 后 GREEN；完整受影响测试通过，签名/确认/删除顺序不弱化；本阶段不宣称原生加密或硬件删除验收。

## 本阶段结果

真实Sembast恢复回归复现原实现遗留可恢复文件（0通过/1失败），精确文件白名单修复后通过。新增25项（宿主18、会话7）；冻结候选儿童端177/177、清理SDK74/74、两套分析通过；4份本阶段源码/契约与1107个原归档文件比对一致。一次独立复核0 Critical/Important/Minor，12项边界均已裁定；未部署原生包，真机持久性、全局擦除和整体产品目标仍未完成。详见[阶段证据](releases/stage-child-cleanup-storage-verification.json)。
