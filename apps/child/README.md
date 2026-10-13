# 智能管家儿童端

独立 Flutter / Android 宿主，复用 `device_identity`、`device_policy`、`device_observation` 与 `device_access`。当前提供设备配对、原密钥恢复、权威心跳、凭据轮换、签名配置保存，以及需独立授权的可见应用/系统聚合观察客户端。**当前不执行跨应用限制**，配置回执仅为 `STORED`。部署依赖及实际验收见 [观察客户端契约](../../docs/device-observation-client-contract.md)。

「我的规则」可展开查看签名配置中的应用、时段、额度和网站规则意图，并解释设备能力缺口；规则项可聚焦并打开详情。它不显示系统执行成功，也不提供儿童修改入口。见[规则解释界面](../../docs/child-rule-explanation.md)。

「求助」页可在已连接的 Android 设备上提交固定类型的求助记录。原请求编号先写入加密存储；结果未知时先核对云端，再由儿童手动重试原编号。云端收到与管理员在管理台确认看到分别展示；此功能不提供紧急呼叫、即时通知或人工值守。接口、故障恢复和交付边界见[儿童求助记录契约](../../docs/child-help-request-contract.md)。

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

安全存储使用固定版本 `flutter_secure_storage 10.0.0`，启用其数据保留迁移并关闭错误自动清空。插件写入后调用原生提交屏障；不自行实现加密。新 Android 注册使用 AndroidKeyStore P-256 签名别名，私钥不经 Flutter 通道导出；Nimbus JOSE 9.37.4 负责标准 ES256 编码及本地签名自验。既有注册继续使用加密记录中的软件 JWK，直到按原注册周期正常退出，不静默换钥。AndroidKeyStore 不保证每台设备都有硬件安全模块；硬件背书、证明链和实体厂商兼容尚未验收。

设备退出协议使用 `AndroidCleanupRecordStore`：按原注册范围派生独立存储键，复用上述加密 SDK 和原生持久化屏障保存回执日志。日志意外丢失后，相同命令/阶段的回执编号仍可确定，但失败原因和本地实际清理进度无法从编号恢复；正式发布前仍需补充丢失记录的恢复/人工处理规则。

身份 SDK 已支持“清理中”阶段：在宿主确认签名命令后可删除普通业务凭证并保留原密钥提交清理回执，确认后的最终删除由 Android 加密存储显式完成。儿童界面会将此阶段显示为退出未确认，不再展示为正常连接。

Android 生产宿主启动时，在配置/访问数据库打开前，用原注册密钥尝试领取并验证当前清理命令。没有有效命令不会删除数据；设备离线或核对失败会保留身份和缓存，并在界面提示结果待核对。命令有效时，协调器先持久提交 RECEIVED，再让执行器停用普通凭证、删除本应用的配置数据库、访问/申请本地数据库以及加密使用记录和访问缓存；未知安全存储键或异常数据库文件会拒绝报告清理成功。执行器保留原注册密钥与回执日志，直到服务端确认 `AGENT_DATA_CLEARED` 后才删除原身份记录。所有删除只限本应用私有目录和本应用加密存储，不涉及第三方 App、系统账户或受管设备解除。

删除数据库文件后，Android 原生通道会检查目录规范路径确实位于本应用 `filesDir` 下，并对目录执行 `fsync`；加密记录删除复用安全存储持久化屏障。任一步失败都不发送 `AGENT_DATA_CLEARED`。不同 Android 文件系统/厂商对目录同步的支持仍须真机确认，失败时维持未确认状态。

这是前台有界尝试，尚无 Android 后台/开机任务保证；断网、到期、取消或进程中断后的继续处理依赖下次启动、回到前台或用户手动核对。若服务端已确认清理回执、但进程在最终删除原密钥前退出，启动时可用加密身份记录中的命令哈希与加密回执日志的已确认阶段相互核对，仅恢复原密钥删除；不需要重新领取可能已到期的命令，也不重新发送清理成功回执。未确认的日志绝不走这条恢复路径。新注册的 Keystore 别名在最终确认后显式删除并复查不存在；软件私钥仍随加密身份记录删除。API34 专用模拟器已验证跨进程缓存清理、原密钥保留及确认后的过期恢复删除；真实云端由明确替身代替。实体手机、电视、真实断电与目标服务联调尚未验收；完成回执仍是设备自报，不是独立擦除证明。最终回执日志留存和未知存储键仍需专门核对，当前按未上线 1.0.0 初始化，不提供历史迁移链。

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

debug 包名 `com.aimanager.child.debug`，release 包名 `com.aimanager.child`。release 必须外置 `CHILD_SIGNING_STORE`、`CHILD_SIGNING_STORE_PASSWORD`、`CHILD_SIGNING_KEY_ALIAS`、`CHILD_SIGNING_KEY_PASSWORD`，缺少时构建失败，不回退调试签名。商店目标 API、依赖漏洞与许可证检查、实体设备/TV 兼容、首次安装与恢复和完整系统权限验收仍是发布门槛。

退出清理原生验收使用独立 API34 AVD、真实 Android 加密插件/目录屏障/Keystore，以及明确的合成云端响应。缺失前序数据负控和 seed → clear → finish → verify 四次进程启动、安装保持及 APK 摘要要求见[原生清理验收契约](../../docs/child-cleanup-native-acceptance.md)。它不经过生产 HTTP 清理接口，不代表正式发布或物理擦除。

## 临时访问申请

已连接的 Android 设备可在「规则 → 临时访问申请」中选择监护安排和应用、1–20 条可申请限制、1–60 分钟及选填理由，核对后提交；支持状态与详情、强版本取消确认、分页和原操作恢复。请求发出前保存原正文/原键，未知结果不能删除或另起申请。重试由儿童主动确认，超过原键重放期限时调用专用恢复查询。

进入后台或设备身份范围改变时隐藏申请与私人表单。启动、恢复前台及检查连接只刷新事实，不自动发送新申请或取消。批准状态与签名配置同步独立展示，当前没有跨应用解锁能力。服务端需包含 V23 设备申请和已提交的过期键恢复接口；未部署时不能把客户端已构建当作联调成功。

公开交互预览入口为 `flutter run -t tool/submission_preview.dart -d chrome`；仅使用明确标识的合成内存夹具，不连接真实服务/设备，不输入真实私人资料。正式 `lib/main.dart` 不引用预览入口，Web 正式入口仍禁用设备身份和注册。流程及验收边界见[申请交互契约](../../docs/child-request-ui-contract.md)。

真实 Spring → 设备申请宿主 → 会话 → 规则页的跨进程验收覆盖提交/取消响应丢失、过期原键恢复、批准截止时间保持及撤销凭证后缓存隐藏。运行方式与测试夹具边界见[申请 HTTP 验收契约](../../docs/child-submission-http-acceptance.md)。该检查使用桌面 Flutter 测试引擎和合成文件密钥，不能代替 Android 真机进程恢复或系统管控验收。

Android 申请原生持久恢复使用独立入口 `integration_test/submission_storage_test.dart` 和官方 `test_driver/submission_storage_driver.dart`，通过保留安装、逐阶段终止进程验证原请求正文/键、取消版本、离线缓存、授权拒绝和密钥丢失行为。测试使用独立合成身份范围与受控云端，复用真实 Android 安全存储、持久化屏障和默认加密数据库；仅用于专用 debug 模拟器。阶段顺序、安全清理及证据要求见[申请原生验收契约](../../docs/child-submission-native-acceptance.md)，不得用卸载或清空数据代替恢复。

## 真实 HTTPS 退出清理联调

独立API34模拟器已完成真实注册、心跳、凭据撤销、原密钥认证的命令领取与两阶段回执、原生缓存和密钥删除，以及重启后的最终确认日志保留核对。使用单个APK、不同进程和同一安装；每个成功进程先验证未受信任证书被拒绝，再导入唯一公有测试证书。成人OIDC/MFA仍是明确夹具，后端使用独立H2；正式部署、MySQL和实体设备验收继续进行。复现入口及证据见[HTTPS清理验收说明](../../docs/child-cleanup-https-acceptance.md)。
