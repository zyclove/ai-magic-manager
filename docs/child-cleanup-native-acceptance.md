# Android 1.0.0 退出清理原生验收

只在新建专用 Android API34 调试模拟器上执行，使用合成身份，不在实际儿童设备或含真实资料的安装上运行。本轮没有迁移历史数据、更新本机管理台或发布正式 APK。

## 验证范围

真实组件：AndroidKeyStore 密钥生成与签名/删除通道、flutter_secure_storage、提交屏障、Sembast 主/恢复文件、目录同步、设备身份管理器、清理日志、AndroidAgentCleanupExecutor 和最后一步的 ChildCleanupRunner 恢复入口。

替身：注册/心跳云端、命令发行、回执确认。使用真实 ES256 命令验证；回执通过严格解析后写入真实加密日志，不经过生产 HTTP 接口。会话缓存关闭逻辑已有单元回归；本次原生测试在显式关闭数据库后调用执行器，没有运行完整儿童界面。

| 阶段 | 前置及必须结果 |
|---|---|
| negative | 使用 verify APK；没有种子必须以 `NATIVE_CLEANUP_MISSING_SEED` 失败，不能被任意驱动错误替代 |
| seed | 空白安装建立合成身份；实际 Keystore 别名；写入配置和加密访问数据库及各自 `~` 恢复文件、已知缓存和 RECEIVED 确认日志 |
| clear | 新进程读取原身份、密钥和日志；实际删除缓存，原密钥仍可签名；持久保存严格解析的合成清理确认 |
| finish | 新进程；固定时钟已超过命令期限；生产恢复入口从本地双记录匹配完成原密钥/身份删除，不重新取命令 |
| verify | 再次启动；原身份和已知缓存仍不存在，原别名签名失败；无关标记文件保留 |

各阶段之间强制停止本应用进程。五个 PID 必须不同，安装 UID/首次安装时间保持一致，每个安装 APK 的设备摘要与本机构建产物相同。保留清理回执日志与公开合成 oracle 供复现；本阶段没有实现最终日志留存清除。

## 复现入口

在冻结源码中准备依赖并完成 `flutter analyze --no-pub`、`flutter test --no-pub`。用以下形式分别构建 seed、clear、finish、verify 四个 APK，并保存到不同文件，避免覆盖后失去阶段对应关系：

```text
flutter build apk --debug --no-pub --target=integration_test/cleanup_storage_test.dart --dart-define=CLEANUP_STORE_PHASE=seed
```

对 negative（选择 verify APK）、seed、clear、finish、verify 依次使用宿主运行器；每次给出新的 `.local` 下输出目录：

```text
python tool/run_cleanup_android.py --phase seed --app <frozen-child-directory> --apk <seed.apk> --artifacts <workspace/.local/run/seed> --aapt <Android-SDK/build-tools/34.0.0/aapt.exe> --adb <adb.exe> --flutter <flutter.bat> --serial <owned-emulator-serial> --expected-avd <exact-owned-avd-name> --allow-owned-debug-avd
```

运行器先通过 Android SDK 的 aapt 解析安装包，只接受唯一的 `com.aimanager.child.debug` 包名及调试标记；不符合要求时，在调用任何设备命令和创建输出目录前拒绝。随后要求精确 AVD 名、模拟器序列号、API34 及主用户0；使用 `adb install -r`，然后官方驱动附加当前进程，不调用 Flutter 的卸载重装回退。安装异常、结果字段不一致、进程变化或缺少前序数据都会停止。失败目录和安装必须保留诊断，不应直接重跑 seed 或清空数据来让结果变绿。完成后停止本轮拥有的模拟器。

宿主运行器回归：在 `apps/child/tool` 执行 `python -m unittest test_run_cleanup_android`。

## 实测及边界

本轮已完成负控及四阶段（五个不同进程、同一安装）；儿童端177项、清理SDK74项和两套静态分析通过。原生 APK 构建和运行日志、摘要及异常尝试见[阶段证据](releases/stage-child-cleanup-native-verification.json)。

此结果不证明实体手机/TV 厂商兼容、硬件背书、闪存安全擦除、真实断电、跨进程并发清理、加密文件的独立取证、生产网络鉴权、后台/开机调度、未确认回执的真实断网恢复，或整个设备退出产品已完成。模拟器报告仍是受控测试证据，不能替代设备自报之外的独立擦除证明。

复核后补充了安装前包名保护：拒绝错误包、正式包、缺失或含糊的 manifest 信息，并用本轮四个实际 APK 完成只读预检。宿主回归增至6项。原生五阶段运行使用修复前运行器；本轮未重复安装，两个运行器摘要及各自验证范围分开记录。最终阶段尚未直接断言清理日志仍存在，该项回归补强已列为待办，当前产品实现保留该日志。
