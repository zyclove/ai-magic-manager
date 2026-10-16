# 儿童端受管反馈：Android APK 集成验收

日期：2026-10-16。验收对象为 `94f23cbe279b451c99688a1f744ed8405cfca451` 的已提交儿童端和共享包；不含同目录其他任务的未提交家庭功能。

## 本次结果

完成一次完整 Android Debug APK 构建与产物静态检查。先前只完成 Dart 会话测试、Kotlin/JVM 测试及真实 AndroidX 类编译，本次进一步证明这些组件能共同进入 Android 安装包。

| 检查 | 实际结果 |
| --- | --- |
| 离线依赖解析 | `pub get --offline` 退出码 0，8.2 秒；提交的锁文件未变 |
| 完整打包 | `build apk --debug --no-pub` 退出码 0，85.5 秒 |
| APK 应用标识 | `com.aimanager.child.debug` |
| 产物大小 | 164,256,153 字节；Debug 包大小不作为正式发布包体指标 |
| APK 签名 | Android Debug 证书、v2 签名验证通过；不是机构正式发布签名 |
| 最低/目标 SDK | 实际 Manifest 为 minSdk 24 / targetSdk 34；项目 compileSdk 为 36 |
| AndroidX 清单 | `androidx.enterprise.feedback.action.APP_STATES` 查询已合并 |
| TV 入口 | LEANBACK_LAUNCHER 已声明；不代表电视厂商或遥控器运行验收完成 |
| 原生类 | `ManagedFeedbackHost`、`ManagedFeedbackProof`、`ManagedBindingClaims` 在 APK DEX 中定义 |
| 官方 SDK 类 | `KeyedAppState`、`KeyedAppStatesReporter` 在 APK DEX 中定义 |
| 引擎接入 | `MainActivity.configureFlutterEngine` 包含 host 构造；`cleanUpFlutterEngine` 包含关闭调用 |
| 源码一致性 | 每个已归档源文件在解析与构建后均与构建前哈希一致 |

APK SHA-256：

```text
1f3e5bd02469191c8ca393dd57f2d2bdd11e37cfc3a7732cfbe12e9b931a2361
```

Gradle 实际解析的 `androidx.enterprise:enterprise-feedback:1.1.0` AAR 与先前审查的官方 AAR 哈希一致：`1a731fd273014411c5044e71b0740648541a13d36baaf1e7508390b218eafb7a`。

## 验证配置与可复核证据

使用 Flutter 3.22.2 / Dart 3.4.3、Java 17、Gradle 8.13、AGP 8.13.1、Kotlin 2.1.0 及已安装 Android SDK。构建未升级框架、依赖或 SDK。为避免争抢本机资源，仅在隔离副本将 Gradle worker 数从 2 改为 1；构建结束后恢复原字节。运行数据、账号、部署实例及其他任务源文件未修改。

本次命令给本地 Debug 包传入 `MANAGED_FEEDBACK_ENABLED=true`，用于覆盖集成代码；产品默认值仍为 false，现有部署也未启用此开关。该定义不能绕过独立设备凭证、挑战、机构资格或服务端绑定核验。

```text
flutter pub get --offline
flutter build apk --debug --no-pub --target-platform android-arm64 --dart-define=MANAGED_FEEDBACK_ENABLED=true
apksigner verify --verbose --print-certs <app-debug.apk>
aapt dump xmltree <app-debug.apk> AndroidManifest.xml
apkanalyzer dex packages --defined-only <app-debug.apk>
apkanalyzer dex code --class com.aimanager.child.MainActivity <app-debug.apk>
```

实际 Flutter 命令通过固定 Dart 可执行文件与 `flutter_tools.snapshot` 调用。参数不是平台兼容证据：该 Debug APK 实际仍包含 arm64-v8a、x86、x86_64 的 Flutter 库；本阶段没有逐 ABI 安装或运行检查，也不据此承诺支持全部架构。

- [结构化产物检查记录](evidence/managed-feedback-apk-20261016.json)保留源版本、产物哈希、类及检查结果，不包含凭证、挑战证明或设备个人数据。
- 本机安装包：`.local/managed-feedback-apk-20261016/apps/child/build/app/outputs/flutter-apk/app-debug.apk`。
- 同一隔离目录下保留 `source.json`、`result.json`、`artifact-verification.json`、`dependencies.log`、`apk.log`、`signature.log`、`manifest.log`、`dex-packages.log` 和 `main-activity-dex.log`；二进制和大体积原始日志不提交 Git。

## 尚未通过的门槛

1. **运行验证：** 本次没有安装 APK 或启动模拟器；尚需确认原生服务回调、引擎重建、后台切换、进程重启及超时后的实际行为。
2. **机构提供方：** AndroidX 成功回调可能没有接收者，不能据此显示“已核验”或“系统权限已生效”；需合规 EMM 环境完成设备签名 → AndroidX → 提供方 → 后端的真实闭环。
3. **正式发布：** 尚未完成 release 构建、机构签名、当前发行渠道 targetSdk 要求核对、包体优化及供应商/样机验收。本次 targetSdk 34 是观察到的构建结果，不是对当前渠道要求的推荐。
4. **电视：** 仍需逐厂商、版本、受管模式和遥控输入验证，不能以清单中的电视入口宣称已支持全部电视。

本记录补齐[反馈运行设计](managed-agent-feedback-runtime.md)中的 APK 构建项。原有默认关闭、用户告知和受管资格约束继续适用；本阶段没有发布或启用系统强管控。
