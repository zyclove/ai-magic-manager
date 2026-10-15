# commerce_contracts

手机与管理台共用的纯 Dart 商业协议组件，无 Flutter 或网络依赖。

- `commerce_contracts.dart`：合同、报价差异、历史、能力声明与中文状态文案。
- `vocabulary.dart`：两端共用的地区渠道、设备模式、服务周期和功能词汇。
- 保留机构投影与平台投影的区别；机构数据拒绝平台审核人、内部原因和关联请求信息。
- 拒绝不安全整数、超出支持日期的时间、未知枚举、重复记录及乱序历史。
- 解析失败抛出 `ContractProtocolException`，两端仓储将其转换为各自的 `INVALID_CONTRACT_RESPONSE` API 错误，不改变传输层异常接口。
- `APPLIED` 表示该合同记录已处理。当前权益必须另外读取汇总接口；不能由历史合同状态推断当前服务或系统管控能力。

模型由原 `apps/guardian/lib/core/contracts.dart` 提取。管理台原入口文件继续导出模型，两端无需维护两份合同解析规则。仓库应用测试覆盖共享协议和各自的 HTTP/界面行为。
