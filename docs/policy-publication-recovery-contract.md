# 手机端策略配置发布与结果恢复

更新：2026-10-13。本文描述已接入的 `CONFIGURE_ONLY` 路径。当前后端仍拒绝 `ENFORCE` 发布；配置版本、设备接收与操作系统执行是不同事实。

## 操作流程

1. 成人在监护人 Android 客户端打开策略草稿，手动选择 1–50 台当前有效设备。选择器保存设备 ID 与注册周期；模板不能直接预览。
2. `POST /api/v1/tenants/{tenantId}/policies/{policyId}/previews` 携带草稿 `If-Match` 和明确设备 ID 列表。客户端核对返回草稿修订、目标集合、各目标注册周期和逐条规则结果。预览不产生设备执行。
3. 成人阅读目标和规则结果后选择“仅保存配置版本”，再次确认“不会执行系统限制”，并完成系统浏览器近期身份验证。
4. 客户端先将策略 ID、草稿修订、预览 ID/哈希、随机幂等键和创建时间写入 Android 加密存储，并等待原生持久化屏障确认。未确认落盘时不发送发布请求。
5. `POST /api/v1/tenants/{tenantId}/policies/{policyId}/publications` 携带相同草稿版本、`Idempotency-Key` 和 `{previewId,previewHash,mode:"CONFIGURE_ONLY"}`。服务端在事务内重新核对草稿、目标注册周期与快照哈希，成功后返回 `CONFIGURED_NOT_ENFORCED`。
6. 成功响应后删除本机待核对记录并显示配置版本序号、操作 ID 和未执行状态。请求传输或响应解析结果不明时保留记录，不自动重发；管理员返回策略中心查询原提交结果。

## 精确结果查询

`GET /api/v1/tenants/{tenantId}/policies/{policyId}/publication-results/{requestId}?mode=CONFIGURE_ONLY&revision=…&previewId=…&previewHash=…`

2026-10-18 客户端接合：结果查询显式携带与原发布相同的 `mode=CONFIGURE_ONLY`。后端候选的必填模式合同仍需联合验证与接合；此字段不会触发新发布或开放 `ENFORCE`。

- `requestId` 是原发布的 UUID 幂等键。查询要求当前成人写权限，且只能读取同一租户、同一操作者、同一操作名和同一原请求正文对应的已提交结果。
- 服务端使用现有幂等事务日志 `findCommitted` 查找原 `policy.publish` 响应，再核对版本确实属于该策略、草稿修订、预览哈希和 `CONFIGURE_ONLY` 模式，最后读取当前发布状态。查询不创建新版本、不续期幂等键、不触发发布。
- 命中返回 `200` 与 `PolicyPublication`，响应设置 `Cache-Control: no-store`。无可读取结果返回 `404 POLICY_PUBLICATION_RESULT_UNAVAILABLE`；这不证明原请求从未提交，可能是请求未到达、事务未提交或日志已过保留期。正文不匹配返回幂等冲突；无当前权限返回拒绝。
- 客户端只在查询到精确结果时显示“原提交已保存”；未命中时提示到完整管理台核对版本。无论查询结果如何，均不自动重复发布。成人核对后可显式清除本机提醒；清除不会改变云端配置。

## 状态与边界

- `PREVIEW` 只表示当前服务端预测；`CONFIGURED_NOT_ENFORCED` 只表示不可变配置版本已记录。`SUPPORTED_PENDING` 只表示能力检查通过且仍待执行。
- 当前没有受管 EMM/OEM 提供方准入和真实系统执行链路，客户端不能提供“应用已经被阻止/允许”的承诺。
- 设备组来源选择仍由 Web 管理台处理；手机端只支持明确设备快照，组成员后续变化不会自动改变本次配置。
- 真实身份服务、Android 真机进程回收、断网重连、幂等日志过期、并发草稿变更、设备注册周期变更以及分布式数据库故障恢复还需环境验收。静态检查与构建不等于这些运行验证。
