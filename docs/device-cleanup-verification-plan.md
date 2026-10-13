# 设备退出清理可靠性计划

> **For agentic workers:** Use executing-plans; one final scoped review.

**Goal:** 补齐设备清理 SDK 独立回归，确保未知响应、存储失败、并发调用时不会跳过确认或提前删除原密钥。
**Architecture:** 保留现有 JOSE/HTTP/持久回执模型；真实签名和协议解析用于测试，宿主删除仅用显式测试执行器。按注册隔离前台协调调用，避免重建协调器时重入本地清理。
**Tech Stack:** Dart、package:test、现有 jose/http/crypto/uuid。
**Spec:** packages/device_cleanup/README.md、docs/device-deprovision-contract.md、儿童端清理启动接线。

## 约束与复核重点

- 只处理本代理数据和原注册密钥，不改变服务端授权或增加系统删除能力。
- 不使用测试替身结果宣称 Android 真机、加密存储或系统擦除已通过。
- 发送前持久化；未知响应只能重放原回执；持久化确认成功后才能进入下一阶段。
- 同注册的重叠协调器应明确拒绝，不能等待后悄悄重复清理；独立注册不互相阻塞。
- 单 Dart isolate 的协调保护不等于跨进程锁；宿主仍须关闭缓存拥有者及提供幂等执行器。
- 不修改共享管理台/家长端 WIP；不更新运行服务或迁移数据库。

### Task 1: 清理协议、恢复和协调可靠性

Files: packages/device_cleanup/**, this plan, docs/releases/stage-device-cleanup-verification.json.

- [x] 添加 package:test 和真实 ES256 测试夹具；覆盖签名/绑定/期限及严格回执解析。
- [x] 覆盖日志恢复、持久化失败、未知响应、执行失败与最终密钥删除顺序。
- [x] 用明确闩锁复现同注册新协调器重入；观察失败后修复，覆盖独立注册及失败后释放。
- [x] 完成包分析/全部测试，以及儿童端受影响分析和全部现有测试。
- [x] 一次独立最终复核；记录能力边界，只提交本阶段文件。

Expected: 所有新回归及受影响现有测试通过；先确认真实失败再修复；本机服务保持不变。


## 本阶段验收

现有实现的行为回归为9通过/1失败：旧清理仍在执行时，新协调器已返回keyRemoved。按注册增加单isolate互斥后通过。最终清理SDK74/74、儿童端152/152、两者分析均通过；1096个未变归档文件及9个本阶段文件完成候选比对。一次独立复核0 Critical/Important/Minor，另重核9份源码与11份日志摘要。HTTP、证明认证、存储和本地删除使用显式替身；未部署或进行真机认证。详见[阶段证据](releases/stage-device-cleanup-verification.json)。
