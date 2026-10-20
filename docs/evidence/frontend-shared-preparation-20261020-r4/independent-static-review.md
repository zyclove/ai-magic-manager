# R4 冻结文本独立静态审阅

日期：2026-10-20。范围：源码文本及规格一致性。未执行执行器、SDK 或测试。

- 执行器 SHA256：`7be0d2cbd04b9ebbfcccea48d85cbe64d070ff918ba5212a910f5cbe0567f0bb`。
- 规格 SHA256：`ce761ca34712352c1f36cb124f3cfcc444ce891ca2caa54fa93062b85256f0c0`。
- 独立审阅者：本任务的 `workbench_finish_review` 子代理；Root 另行完成 AST、来源哈希和规格核对，实际静态回执见同目录 `root-static-review.json`。

审阅覆盖了启动前清除并读回 `KILL_ON_JOB_CLOSE`、不存在强制终止调用、预算到期的永久失败记录、同一 Popen/Job 自然观察、异常分支的 gate EOF、仅在 active0 时关闭 Job，以及生成插件链接的精确目录、双元数据目标一致性和禁止遍历规则。该范围内未发现新的确认 P1/P2 问题。

**已知限制仍在：** 外部强制结束执行器可能使匿名 Job 的观察句柄丢失。执行器退出、超时、连接中断或静态代码检查均不能证明实际子进程树已经结束。清除 kill-on-close 只防止误杀，不能解决观察能力恢复。Windows 进程竞争、Job 配置和新链接分支都未做动态验证。

结论为 **STATIC_REVIEW_ONLY / NOT_RUN**。保持 `acceptedForExecution=false`；旧 helper 的 canary 不覆盖 R4 新生命周期。这里没有 SDK 成功、功能通过、生产构建或部署验收结论。
