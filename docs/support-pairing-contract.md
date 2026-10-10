# 限时支持接收人配对

承接支持诊断计划步骤 3。配对是接收人身份核对前置流程，不等于授予设备访问权，也不代表接收人是平台官方客服。

## 请求与权限

- 接收人必须是具有 IdP `tenant:create` 成人资格的当前登录主体，并通过近期 MFA。资格用于避免儿童成为支持接收人，不授予任何租户角色。
- `POST /api/v1/support/pairing-requests` 创建十分钟请求，要求 Idempotency-Key。服务端使用 SecureRandom 生成 256 位配对码，仅首次响应返回；数据库及幂等记录不保留原码。重复请求返回同一请求的当前状态及空配对码；原码遗失时取消并重新创建。
- `GET /api/v1/support/pairing-requests` 使用既有有界游标分页，只列当前主体自己的请求。`GET /{id}` 同样限定主体。读取与重试都重新要求资格与近期 MFA。
- `POST /{id}/cancel` 要求 If-Match 和 Idempotency-Key；取消者必须是接收人本人。已取消请求可以安全重放；已被授权消费的请求不能通过取消配对来伪装撤销支持授权。
- `POST /api/v1/tenants/{tenant}/support-pairing/resolve` 仅当前 OWNER／GUARDIAN／ORG_ADMIN 且近期 MFA 可调用，配对码在请求体中，不写入 URL。返回稳定主体标识、经 IdP 签名声明取得的显示名称／已验证邮箱和到期时间，供用户核对；不返回其他租户、设备或儿童信息。
- 不存在、过期、取消或已使用的配对码都返回同一个不可用错误。查询与取消不通过 UUID 猜测暴露其他主体的请求。

## 一致性和容量

- 明确状态 PENDING／CANCELLED／CONSUMED／EXPIRED；读取到期状态按服务端时钟计算，不延长期限。
- 每个接收人最多三项有效待配对请求，每分钟最多五次新建尝试；幂等重放不新建，也不额外消耗新建次数。
- 管理员配对码解析每分钟最多六十次，失败请求也消耗次数；计数在独立短事务中提交，防止业务回滚绕过限制。计数只保存主体摘要，不保存输入配对码。
- 配对身份在创建时快照保存，姓名／邮箱只用于显示，授权始终以精确 OIDC 主体为准。单一配置 IdP 通过既有 ActorKeys 区分大小写。
- 响应 no-store 并按 Authorization 区分。创建／取消事件仅记录请求 ID、主体摘要、动作和时间；客户解析成功按其租户记录审计。
- 创建互斥行与限流计数行分开。业务事务先用原子 upsert 取得接收人的创建写锁，串行化容量判断和三方幂等重放；独立限流事务只锁计数行。计数行同样直接取得写锁，避免 MySQL 重复插入共享锁升级造成死锁，不以无限重试掩盖并发冲突。

## 实现与验证记录

- 新增 `V26__support_pairing.sql`，仅在隔离测试数据库应用；当前业务数据库未迁移。四张表分别保存创建互斥、限流、配对请求及配对事件。配对码以用途隔离的 SHA-256 摘要保存，原码不进入幂等日志。
- `.local/support-pairing-red.log`：接口实现前 8 项断言因 404 失败。
- 初始 H2 组合 39 项通过；真实 MySQL 发现容量竞争时的锁升级死锁。`.local/support-pairing-lock-red.log` 重复复现，定位到 `support_pairing_heads` 的 `SELECT ... FOR UPDATE`；修复后 `.local/support-pairing-lock-fixed.log` 的 5 轮三方同键重放与容量竞争全部通过。
- 最终 H2 组合 `.local/support-pairing-h2-final.log` 为 44 项通过、0 跳过，包含 18 次配对旅程执行、既有诊断与模块边界 25 项及 1 项非空迁移。配对旅程覆盖失败解析也计费、四线程并发失败计数、本人隔离、成员撤销、弱认证、版本冲突、过期、已消费状态、未验证邮箱和有界分页。
- 非空迁移检查先建立 V25 的成员、身份显示资料及含加密报表分片的数据库，升级后逐表比对原数据，确认新增表为空，重复执行迁移不再执行脚本。真实 MySQL 的最终组合与独立迁移结果另存阶段检查点。
- `.local/support-pairing-mysql-final.log`：真实 MySQL 组合 43 项通过、0 跳过；`.local/support-pairing-migration-mysql-final.log`：另一独立 MySQL 数据库的非空升级检查 1 项通过。两个运行器日志均确认临时数据库和用户已删除。`.local/runtime/support-pairing-checkpoint.json` 绑定八个源文件、迁移与验证结果；不把这些聚焦检查称为整个后端全量回归或整个支持阶段交付。

## 后续授权边界

客户还必须核对接收人并确认具体设备、注册周期、诊断类型及授权期限，之后才能原子消费配对请求并创建支持授权。接收人读取时重新核对授权状态、授予者成员版本及设备生命周期。授权与管理界面现已实现，分别见 [support-grant-contract.md](support-grant-contract.md) 和 [support-collaboration-ui.md](support-collaboration-ui.md)。加密支持包及完整阶段审阅仍待完成，本文件不会将配对前置接口当成完整支持功能交付。
