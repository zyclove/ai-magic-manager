# 公共使用报表模型

管理端与设备端共用的纯 Dart 模型：有界查询、严格响应解析、设备/注册/档案绑定、IANA 日历分桶、分类来源、当前配置交付状态和保守趋势比较。

公共入口 `package:usage_reporting/usage_reporting.dart`。通过 `UsageReport.parse(document, appliedQuery)` 校验响应；不要把未经解析的 JSON 展示为报表。成功解析的集合不可变。校验失败抛出仅包含状态和安全错误码的 `UsageReportFailure`，由各宿主映射为界面文案。

该包不请求网络、不读取凭据、不持久化私有数据，也不负责用户或设备认证。调用方须校验当前会话并在访问失效时清除已显示结果。模型说明见仓库 `docs/usage-report-contract.md`。
