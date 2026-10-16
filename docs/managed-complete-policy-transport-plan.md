# 完整策略传输与核对实施计划

2026-10-16，接续 `a74668c`。保持真实 EMM 准入和执行入口关闭，补齐完整文档到官方 SDK 传输的可替换适配器契约。

## 实施范围

1. 增加默认不支持的完整文档写入/只读核对接口；传输输入包含固定文档与摘要、管理应用及可信设备模式/API。输入本身不证明授权。
2. Google 适配器复用已有完整编译器恢复验证；仅接受执行账本使用的随机候选资源 ID。对已存在资源拒绝写入；缺失时一次 PATCH 明确的四个字段。官方 API 是 upsert，GET 404 不构成原子创建或独占权证明。
3. 网络自动重试、重定向和正文日志关闭，响应体有界；按实际 JSON 类型核对完整语义、精确资源与版本。允许已知默认空列表/false 省略和集合反序，不能忽略额外权限或设置。
4. 明确区分未发送与写入结果不明；不明结果先只读核对，不产生第二次写入。提供方状态匹配仍不代表设备已执行。
5. 补上已知浮点到整数转换边界，先 RED 验证，再关闭 Jackson 对应开关。
6. 采用官方 SDK 对本地 HTTP 夹具验证，回归已有发布、完整编译和执行账本。无真实提供方请求、无 Android 验证。

## 官方依据

[Policy 资源](https://developers.google.com/android/management/reference/rest/v1/enterprises.policies) 定义应用、权限和只读版本；[PATCH 方法](https://developers.google.com/android/management/reference/rest/v1/enterprises.policies/patch) 同时支持创建和更新，通过 updateMask 指定字段。于 2026-10-16 核对。

## 记录

- RED：462 个源文件摘要不变，42.0 秒，Maven 退出 1；2 个预期断言失败、0 错误/跳过。外层程序因失败消息标签与 AssertJ 实际行为不同退出 1；原始结果不改写，独立 XML 核对记录保留该差异。
- 静态审查后明确内容匹配只保存观察、账本继续人工复核；补齐异常及超大预读零写入、非 404 查询错误的负向回归。
- GREEN：464 个源文件摘要不变，116.2 秒，13 套 402 项全部通过，0 失败/错误/跳过；外层程序和 Maven 实际退出 0。
- 浮点模式版本 `1.0` 与 `1.5` 均被拒绝。生产执行、设备分配与中国大陆提供方门槛保持关闭。
- [实现说明](managed-complete-policy-transport.md)及[可核对证据](evidence/managed-complete-policy-transport-20261016.json)。
