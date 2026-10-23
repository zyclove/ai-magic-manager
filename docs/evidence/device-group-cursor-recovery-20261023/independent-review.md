# 设备组批量选择器游标恢复：独立静态审阅

**结论：本单文件候选未发现静态阻断项。全部场景 UNRUN，未渲染；不代表 Dart 编译或行为验证通过。**

完整阅读 before/after、3242 字节补丁和作者说明，并读取实际 OwnedDialogRoute、DeviceSubflowScope、DeviceGroupsPage 的 present/批量确认、Api.page/send、scoped transport 与后端批量接口相关实现。候选原始摘要及 delivery 五条原件全部匹配；Main 当前与 before 原始字节相同。由 before/after 全文重建的 unified diff 与交付 patch 逐字节相同。

## 具体证据

- **失效游标只终止分页链。** after:218–225 仅在 append 且 ApiFailure.code=INVALID_CURSOR 时清 cursor 并置 cursorInvalid，不丢已加载 rows/selection。普通 append 错误不改原 cursor；after:184 拦所有 invalid 状态的普通 load，包括旧 FailureView retry 闭包，不会清空游标后悄悄从首页继续并保留旧选择。
- **明确重载同步清理后发读。** after:235–245 重新检查 current、!loading、cursorInvalid；同步清 selection/devices/cursor/error/invalid/onlySelected，然后调用 load。load 在首 await 前设置 loading=true 并增加 generation，因此重复点击不能并发发首页请求；失效标记清除后，旧 reload 回调不能在成功页上清新选择。搜索文本保留，不引入额外确认步骤。
- **旧 checkbox 无法重新插入已清理的旧注册。** reload 先清 devices；after:248–256 仍通过 current 和 selectable 检查。未到新页时 devices 为空；新页同 ID 不同 registrationId 仍不匹配。confirm:89–96 对每个已选项再次核 ID/registrationId/可选状态与 1–50 台范围。保持已加载选择继续确认是此候选的明确产品行为，不表示数据永不过期。
- **scope、owner、generation 未弱化。** _observeAccess 到 load 之前的完整源码区间与 before 逐字相同，覆盖 sticky _revoked、current 的 isCurrent+OwnedDialogRoute.available、关闭/确认、API/root/group 改变与 deactivate/dispose 撤销。load 请求/返回/catch/finally 的 mounted/_active/permitted/generation 检查保持；新 reload 同样必须 current。真实 present:105–113 将当前 Session scope、父 route active、child available 绑定到 api.scoped；ScopeBindingClient 在传输和响应流仍核该绑定。新逻辑未扩大 covered/closed route 的交互权限，也未改旧 route finish 行为。
- **提交协议仍是原确认事务。** DeviceGroupsPage:385–441 先完成选择，再生成一次 key 并展示完整设备清单；请求保留 deviceId+registrationId、捕获 group version 与同一 key。Api:276–277 保留 If-Match / Idempotency-Key。后端 addMembers:366–400 / removeMembers:452–486 保留权限、cap50、组版本、注册与状态/成员核验及原幂等事务；补丁未触及调用方或 API。静态源码核对不是服务端事务实际运行证明。
- **呈现变化限于恢复路径。** after:320–330 单 Notice 和“重新加载并清空选择”按钮替代已知 invalid 分支的 FailureView，其他失败保留原重试。加载更多在 cursorInvalid 时隐藏；列表、搜索、已选过滤、取消/核对操作保持。短屏、大字号、语义可达与实际布局仍需未来渲染验证，本轮未执行。

## 审阅界限

没有发现本补丁新增的旧回调绕过、跨 owner 操作或请求身份放宽。既有源码行为不因本次文本审阅而成为已验证功能。只进行了文件/字节/hash/文本差异核对与新 cache 报告写入；没有调用任何代码解析器、候选、SDK、测试、formatter、编译、WinAPI/进程查询或网络，没有改 Main/Git/候选原件。所有声明场景和既有测试仍 UNRUN；本报告不授执行权限。
