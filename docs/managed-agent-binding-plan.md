# 受管设备与儿童端可信绑定实施计划

2026-10-15。依据现有受管注册、设备密钥和策略发布实现继续推进完整系统执行；不把注册核验或配置保存替代 `ENFORCE`。

## 当前缺口与选择

`ManagedEnrollmentService` 已校验提供方注册来源；`FleetReads` 仍把本地设备视为 BYOD，所有受管能力不可用；`PolicyService.publish(ENFORCE)` 明确拒绝。缺失的依赖是“提供方设备上确实运行着本地注册密钥所对应的、受信发布签名的儿童端”。仅把管理员输入的两个 ID 关联不能证明这一点。

采用双通道证明：服务器向已认证儿童端提供短期随机挑战；儿童端用当前注册私钥签名，再通过受管应用反馈交给提供方；服务器从已审核提供方读取同一设备、同一应用、受信发布签名下的证明，验签后才能建立关联。提供方反馈可能被其管理员查看，不放入儿童姓名、账户、租户或稳定设备 ID；证明仅携带短期随机挑战。

已有 Google 官方生成客户端包含 `ApplicationReport.signingKeyCerts`；使用 SHA-256 证书摘要，不采用已废弃的 SHA-1 指纹字段。现有 Nimbus 实现 ES256，不自研密码算法。后续 Android 侧优先采用 AndroidX Enterprise feedback SDK；合作 EMM 应实现等价的受信证据通道。

## 实施顺序与完成定义

1. **提供方证据与证明校验**：可替换网关读取目标应用反馈，限制响应体与集合大小，严格校验资源身份、应用签名摘要、安装状态、报告时间；Nimbus 验证短期挑战、当前公钥和固定用途；重复键、未知头、超长或过期证明拒绝。官方 SDK 的本地 HTTP 契约和真实 ES256 证明测试通过。
2. **持久化绑定工作流**：管理员近期认证、同租户/同学生的注册目标、独占绑定与乐观锁；挑战发放、设备领取、提供方核验、原子消费、撤销和到期；记录审计并覆盖并发/重放/跨租户与合同撤销竞态。所有首版业务表进入 V1，不原地修改现有运行库。
3. **客户端与交互**：设备独立凭证领取挑战，现有不可导出私钥签名；AndroidX 反馈适配、错误/等待/过期恢复；管理员选择本地设备并观察核验进度。没有正式应用发布签名及合规提供方时保持不可启用。
4. **执行接入**：可信绑定通过后，还需独立验证应用身份、支持的系统策略、策略分配/应用回执、失效与补偿，才能对相关规则开放 `ENFORCE`。绑定成功本身不授予全部能力。

阶段 1 不能被计为整个绑定流程或系统执行已经完成。验签器无数据库重放账本；消费一次、注册有效性、租户权限及关联关系必须由阶段 2 的事务完成。

阶段 2 的接口、状态、配置、事务与验证进度见 [受管儿童端绑定工作流](managed-agent-binding-workflow.md)。阶段 3 已交付 [管理界面](managed-agent-binding-experience.md) 及 [设备挑战领取与原密钥签名](managed-agent-device-proof.md)；AndroidX 自动反馈发送、生产会话调度与真机验证仍需完成。

## 证明 v1 约束

- 固定反馈键 `ai_manager.binding.v1`；固定 JWT audience `ai-manager:managed-agent-binding`。
- ES256、P-256、公有注册 JWK；JWT 头只允许 `alg`、`typ`。不接受上传 JWK、远程密钥 URL、证书链或算法切换。
- JWT claims 只允许 `sub`（随机挑战 ID）、`nonce`（随机挑战值）、`aud`、`iat`、`exp`、`jti`（随机证明 ID）。不携带稳定业务标识或儿童资料。
- 证明最长 1000 字符，挑战最长 10 分钟，证明必须在挑战窗口内生成并在窗口内核验。时钟偏差上限 30 秒。
- 目标应用必须已安装，提供方证书列表非空，所有报告的 SHA-256 签名均被显式信任；发布签名未配置不得视为通过。
- 提供方设备状态报告及反馈更新时间必须在挑战之后，不能来自过期设备快照或未来异常时间。反馈记录的时间与签名时间相互核对。
- 验签通过只返回短期证据摘要及时间，不日志输出 JWT、nonce、完整提供方响应或稳定设备标识。

## 官方依据

- [应用反馈与个人信息限制](https://developer.android.com/work/app-feedback/overview)
- [提供方读取应用反馈与上报开关](https://developers.google.com/android/management/app-feedback)
- [设备应用报告与 keyed app states](https://developers.google.com/android/management/reference/rest/v1/enterprises.devices)
- [应用签名 SHA-256 证书摘要](https://developers.google.com/android/management/reference/rest/v1/ApplicationSigningKeyCert)

Google 生产准入、目标地区限制和默认关闭策略继续遵守现有连接器设计。此路线不依赖未经批准的 DPC，也不通过普通应用伪造设备所有者身份。
