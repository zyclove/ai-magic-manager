# 共享使用报表界面

基于 Flutter Material 与 `usage_reporting` 的只读组件。管理端和儿童端复用同一套趋势、当前规则与设备交付状态说明。

## 宿主契约

`DeviceUsageReportView` 放入宿主滚动容器，传入已认证的类型化 `load(window)`、本页网络取消函数、访问状态 `Listenable` 和 `available()`。页面不持有成人账号，也不持久化结果。

- 宿主必须在身份、注册周期、授权或可见性变化时更新访问状态；必要时使用新的组件 key 清除旧会话。
- loader 必须核对当前设备和查询条件。儿童宿主使用 `DeviceChildReports` 解析当前设备 access-context，再调用 `device_reports`。
- 页面离开、后台、失权、取消和新查询都会丢弃过期响应。后台恢复后需主动重新查询。
- `UsageTrendView` 保留区间和未知语义；`ReportConfigurationsView` 只表示配置与设备自报交付状态，不表示系统规则已执行。

完整接口和证据边界见仓库 `docs/usage-report-contract.md`。测试使用隔离数据；浏览器预览不证明真实 Android 采集或 TV 系统执行。
