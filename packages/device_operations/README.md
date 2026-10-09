# device_operations

可复用的 Flutter 设备退出组件。接入真实管理 API；认证客户端、OIDC 生命周期、当前租户和设备选择由宿主负责。

## 分层

| 文件 | 职责 |
|---|---|
| `src/models.dart` | 不可变快照、范围、后果与状态文案；严格协议解析 |
| `src/client.dart` | 成熟 HTTP 客户端适配、版本/请求键、响应绑定、有界分页、安全错误 |
| `src/journal.dart` | 非秘密恢复元数据接口及官方异步偏好存储适配器 |
| `src/controller.dart` | 显式确认、幂等核对、取消、失败与生命周期状态 |
| `src/panel.dart` | 标准 Material 交互、双状态、窄屏、焦点与可解释错误 |
| `example/` | 明确标识测试夹具的独立组件验收入口，未连接真实设备 |

完整接入、授权与恢复限制见[接口说明](../../docs/device-operations-ui-contract.md)。API 根地址需由部署配置提供；正式环境 HTTPS，开发例外只限显式授权的回环 HTTP。库不保存令牌、密码、设备密钥或清理命令；调用方拥有并关闭 HTTP 客户端。官方 `cupertino_icons` 字库随组件依赖提供，避免 Flutter 内部平台分支所引用图标在 release 构建中缺失。

每个会话、设备注册只创建一个控制器；切租户、角色或注册以及登出时销毁。初始化不会自动重放恢复请求。未知结果不能通过重新预览、换请求键或自动续期绕过。

## 开发与验收

```powershell
flutter pub get
flutter analyze
flutter test --reporter expanded
cd example
flutter pub get
flutter test
flutter build web --release --web-renderer html --no-web-resources-cdn
```

依赖由 `pubspec.lock` 锁定；当前在 Flutter 3.22.2 / Dart 3.4.3 验证。SDK 升级及 Android、iOS、桌面正式发布需独立验证。`shared_preferences` 的恢复信息为辅助数据，没有跨标签页原子锁，也不保证掉电后恢复；服务器幂等记录和审计仍为权威。
