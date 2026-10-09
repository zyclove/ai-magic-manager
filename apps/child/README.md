# 智能管家儿童端

独立 Flutter / Android 宿主，复用 `device_identity`、`device_policy`、`device_observation` 与 `device_access`。当前提供设备配对、原密钥恢复、权威心跳、凭据轮换、签名配置保存，以及需独立授权的可见应用/系统聚合观察客户端。**当前不执行跨应用限制**，配置回执仅为 `STORED`。部署依赖及实际验收见 [观察客户端契约](../../docs/device-observation-client-contract.md)。

## 环境与启动

- 已验证 Flutter 3.22.2 / Dart 3.4.3；Java 17、Android SDK 36、NDK 27.0.12077973。Android 最低 API 24。
- Gradle 8.13 官方 wrapper 附 SHA-256 校验；AGP 8.13.1 / Kotlin 2.1.0。首次构建需要访问官方 Maven/Gradle 仓库。
- 在此目录执行 `flutter pub get`。缺少部署地址时展示“设备端尚未配置”，不会连接默认生产服务。
- 使用交付环境提供的本地配置文件启动：`flutter run --dart-define-from-file=/absolute/path/child-deployment.json`。配置文件不应包含私钥、成人令牌或设备凭证，不要提交真实环境秘密。

部署文件的字符串字段：

| 字段 | 含义 |
|---|---|
| `CHILD_API_ROOT` | 固定 HTTPS 地址，以 `/api/v1` 结束 |
| `CONFIGURATION_ISSUER` | 与后端签名配置完全一致的发行方 |
| `CONFIGURATION_JWKS` | 公共 JWKS 的 **JSON 字符串**，只能包含获准验证公钥 |
| `ALLOW_LOCAL_HTTP` | 仅调试时可为 true，仅允许 localhost / 127.0.0.1 / ::1；release 拒绝开启 |

本地 Android 调试可通过 `adb reverse tcp:8082 tcp:8082` 访问主机 API，再使用固定 `http://127.0.0.1:8082/api/v1` 与明确调试开关。必须确认目标设备和端口属于当前开发环境。生产始终使用 HTTPS。

Web 构建是界面预览：不保存设备身份、不能注册或下发配置。iOS、Windows、macOS 尚未提供安全存储或系统管理宿主。

## 配对和维护

1. 监护人在管理端选择儿童档案、创建设备注册并复制完整凭据。
2. 在 Android 填写设备名称并粘贴四字段 JSON：`tenantId`、`id`、`token`、`expiresAt`（毫秒整数）。不能从凭据改写服务地址、公钥或角色。
3. 将设备八位配对码提供给监护人，由成人端重新认证确认；儿童不能自行确认。
4. 返回设备检查状态。只有真实心跳成功才显示身份确认；之后手动同步并验签保存配置。
5. 结果未知时恢复原连接；读取失败时先重新读取；凭据过期或认证拒绝时显示检查提示。不得通过重装/重新注册解决身份异常。

安全存储使用固定版本 `flutter_secure_storage 10.0.0`，启用其数据保留迁移并关闭错误自动清空。插件写入后调用原生提交屏障；不自行实现加密。当前 P-256 私钥仍是加密记录内的软件 JWK，**不是硬件不可导出签名密钥**。

## 验收命令

`flutter analyze`、`flutter test`、`flutter build apk --debug`。完整边界及实测记录见 [儿童宿主契约](../../docs/child-host-contract.md)。

真实存储检查仅用于专用空白调试安装。使用官方 `integration_test` 驱动，按顺序执行：

```text
flutter drive --driver=test_driver/identity_storage_driver.dart --target=integration_test/identity_storage_test.dart -d <owned-device> --keep-app-running --dart-define=STORE_CHECK_PHASE=write
adb -s <owned-device> shell am force-stop com.aimanager.child.debug
flutter drive --driver=test_driver/identity_storage_driver.dart --target=integration_test/identity_storage_test.dart -d <owned-device> --keep-app-running --dart-define=STORE_CHECK_PHASE=read
```

该检查使用真实 Android 加密存储和原生通道、受控云端替身；不证明生产 API 联调或系统策略执行。普通 `flutter test integration_test/...` 会卸载应用，不能代替上述进程恢复检查。测试会留下明确的测试身份；不要在实际儿童设备或含真实身份的安装上运行。

## 发布边界

debug 包名 `com.aimanager.child.debug`，release 包名 `com.aimanager.child`。release 必须外置 `CHILD_SIGNING_STORE`、`CHILD_SIGNING_STORE_PASSWORD`、`CHILD_SIGNING_KEY_ALIAS`、`CHILD_SIGNING_KEY_PASSWORD`，缺少时构建失败，不回退调试签名。商店目标 API、依赖漏洞与许可证检查、实体设备/TV 兼容、升级迁移和完整系统权限验收仍是发布门槛。

## 临时访问申请

已连接的 Android 设备可在「规则 → 临时访问申请」中选择监护安排和应用、1–20 条可申请限制、1–60 分钟及选填理由，核对后提交；支持状态与详情、强版本取消确认、分页和原操作恢复。请求发出前保存原正文/原键，未知结果不能删除或另起申请。重试由儿童主动确认，超过原键重放期限时调用专用恢复查询。

进入后台或设备身份范围改变时隐藏申请与私人表单。启动、恢复前台及检查连接只刷新事实，不自动发送新申请或取消。批准状态与签名配置同步独立展示，当前没有跨应用解锁能力。服务端需包含 V23 设备申请和已提交的过期键恢复接口；未部署时不能把客户端已构建当作联调成功。

公开交互预览入口为 `flutter run -t tool/submission_preview.dart -d chrome`；仅使用明确标识的合成内存夹具，不连接真实服务/设备，不输入真实私人资料。正式 `lib/main.dart` 不引用预览入口，Web 正式入口仍禁用设备身份和注册。流程及验收边界见[申请交互契约](../../docs/child-request-ui-contract.md)。
