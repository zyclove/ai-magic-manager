# 本设备使用报表

设备专用、只读、无本地报表持久化的 Dart 客户端。依赖现有 `device_policy` 传输和 `usage_reporting` 公共模型。

```dart
final reports = DeviceUsageReportClient(
  transport: sessionTransport,
  target: UsageReportTarget(deviceId, registrationId, subjectId, deviceName,
      platform: platform), // 实际 ANDROID 或 ANDROID_TV
  current: () => hostSessionIsCurrent && isForeground,
);
final report = await reports.load(
  from: fromMillis, to: toMillis, timeZone: 'Asia/Shanghai', period: 'DAY',
);
// 退出页面/会话时立即清除界面数据，再使客户端失效。
reports.dispose();
```

目标绑定必须来自当前宿主注册会话。服务端只读取认证设备，不接受目标选择参数；客户端再次核对 deviceId、registrationId 和 subjectId。宿主必须在档案、注册周期、身份、前后台可见性或观察访问变化时使 `current` 返回 false。

- `UsageReportFailure`：本地查询、绑定、结构或会话校验失败；只含安全错误码与状态。
- `DeviceTransportFailure`：已有传输层的安全错误。401/403 应交给宿主处理会话/访问恢复，不能自动循环重试。
- 每个新查询应隐藏旧结果，并通过请求代数拒绝被后续查询取代的结果。`dispose` 丢弃在途结果，但不关闭宿主共用 transport。
- 授权关闭、无数据、无观测证据和零下界的范围不同。保存配置的设备回执不证明系统已经执行。趋势只比较符合公共模型规则的完整时段。

详情及当前限制见仓库 `docs/usage-report-contract.md`。当前包不包含儿童原生页面，也不提供设备采集或系统执行适配。
