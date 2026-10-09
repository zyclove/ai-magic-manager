# Android 观察待发记录：真实进程恢复验收

承接 [观察客户端契约](device-observation-client-contract.md) 和 [成人与 HTTP 工作流](device-observation-guardian-contract.md)。本阶段补齐原生加密持久化的验证缺口，不改变生产采集策略或增加后台执行权限。

## 1. 验证对象与隔离边界

- 使用生产 `ObservationAgent`、`AndroidObservationStore`、FlutterSecureStorage 10.0.0 及既有原生提交屏障，没有明文文件、内存存储或 mocked MethodChannel 替代。
- 在本任务专用 `AIManagerChildApi34` 模拟器、`com.aimanager.child.debug` 安装执行。每次都核对 AVD 名称；各阶段结束后强制停止此测试包并确认 PID 消失，下一阶段重新安装保留数据并启动。
- 云端设置/回执与系统应用数据均为显式合成夹具，不发送网络请求，不查询真实应用使用，不申请系统特殊访问。实际 HTTP/MySQL 与实际 Android 系统查询分别在先前阶段验收，不能把独立证据相加称作生产端到端认证。
- 仅固定日志代码、阶段、PID、计数和布尔结果进入验收记录，不输出原始载荷、密钥、身份或设备凭据。加密偏好文件只在内存中检查合成标记是否以明文存在，不导出原文件。

## 2. 四次独立进程与负对照

| 阶段 | 必须成立的事实 |
| --- | --- |
| negative | 全新观察记录为空；直接执行 replay_inventory 必须因 pending 数量为 0 而失败，不能因环境错误假装负对照通过 |
| write_inventory | 合成清单只查询一次；实际加密记录先包含原正文，再返回未知回执；保留一份 pending |
| replay_inventory | 新进程从原记录恢复；不再查询清单，提交原序号/正文；清单 ACK 后摘要查询一次，摘要先落盘，再丢失摘要回执 |
| replay_usage | 又一新进程恢复原摘要 ID、序号和正文；不重新查询清单或摘要；ACK 后 pending 清空 |
| verify_cleared | 再次终止并启动后，pending 仍为 0，两种成功计数、接收时间和授权版本仍正确；本阶段不调用上传 API |

上传替身在返回 ACK 或未知结果前，都通过真实存储读回并逐字比较 pending 的 JSON；重放阶段同时与同步开始前独立读取的不可变原快照比较，包含原报告 ID。恢复阶段还断言系统源调用次数为 0，防止以重新采集、重新生成报告 ID 冒充重放。比较只输出布尔结果，失败时不会把载荷写入测试日志。

这证明的是正常系统进程强制停止后的存储恢复与重放，不证明断电原子性、系统崩溃、root 对抗、硬件不可导出密钥、卸载恢复、升级迁移或所有厂商设备兼容。主动停止测试包也**不代表产品能够阻止强制停止或开机自动运行**。

## 3. 清理与普通产品恢复

`observation_storage_cleanup_test.dart` 只在合成 scope、无 pending、成功计数全部吻合时，通过成熟 SDK 删除固定 `observation_record` 键，随后读取生产提交屏障确认清理。它不清除应用数据、不删除密钥偏好、不修改身份键；身份存在与否单独记录，不能把空身份未改变当成真实凭据恢复证明。

验收结束覆盖安装预先构建的普通 `lib/main.dart` 产品 APK并冷启动，避免把测试入口留在调试设备。APK 保存在本机忽略目录，不提交 Git；正式发布签名和商店目标 API 的门槛仍然保留。

## 4. 可复现操作

仅在自有空白 debug 安装上执行。`write_inventory` 拒绝覆盖任何已有观察记录；不得用清除用户数据的方式让测试通过。

先关闭本次专用模拟器，按序预构建各阶段，避免构建与模拟器同时耗尽宿主内存。示例在 `apps/child` 执行：

```powershell
$phase = 'write_inventory' # 随后依次 replay_inventory / replay_usage / verify_cleared
flutter build apk --debug --no-pub --target-platform android-x64 `
  --target integration_test/observation_storage_test.dart `
  "--dart-define=OBSERVATION_STORE_PHASE=$phase"
# 将每次 APK 保存为独立文件，防止后续构建覆盖前一阶段。
```

用 Flutter 官方预构建运行入口依次启动；首次用 replay_inventory APK 验证负对照，然后才运行 write_inventory：

```text
flutter drive --driver=test_driver/identity_storage_driver.dart --target=integration_test/observation_storage_test.dart --use-application-binary=<该阶段APK绝对路径> --keep-app-running --no-pub -d <自有模拟器>
adb -s <自有模拟器> shell pidof com.aimanager.child.debug
adb -s <自有模拟器> shell am force-stop com.aimanager.child.debug
adb -s <自有模拟器> shell pidof com.aimanager.child.debug
```

每次确认返回的实际 PID 与测试日志一致，且停止后的 PID 查询为空，才能运行下一阶段。不要并行运行阶段；驱动自带两分钟测试超时，观察到超时不等于进程已结束，应检查原句柄。

最后构建/运行 `integration_test/observation_storage_cleanup_test.dart`，同样确认清理结果与 PID；随后覆盖安装普通产品 APK。日常验证需执行 `flutter analyze` 与 `flutter test --concurrency=1`；模拟器资源不足时先停止本次模拟器再运行完整回归。

## 5. 最终验收结果

最终源码重建后，负对照驱动退出 1（精确的缺少 pending 原因）；四阶段和 cleanup 均退出 0。独立 PID 依次为 4215、4434、4649、4762，cleanup 为 4916。清单和摘要恢复均确认与同步前原快照完全一致，清单源不重复查询、摘要源不重复查询，ACK 后待发清理持久化。

两次待发阶段的实际偏好检查未发现合成正文标记以明文存在；这不是密码学认证。清理前身份记录不存在，只报告其未改变。普通产品 APK 安装成功，MainActivity 冷启动状态为 ok，随后关闭专用模拟器。产品 APK SHA-256：`08baab360e4c2199b4391fefd8e52db63dc5d7aba2f6eb7ee73aec4d45a246c1`。最终儿童端完整回归 22 项通过，静态分析记录见验证清单。

## 6. 验收记录

本阶段的实际退出码、进程 ID、构建指纹和覆盖边界在 [验证清单](design/observation-native-storage/verification.json) 中记录。此前发生过宿主内存不足和误用默认 Gradle 目录的网络下载等待，均未计通过；改为单并发、复用项目缓存、分离预构建与设备运行后重新执行。

摘要重放第一次运行中，模拟器日志出现 `UncheckedAllocate` 后实际退出，旧工具句柄也已不存在，未生成通过记录。确认原进程已结束后，保留同一 AVD 的磁盘数据重启再运行；新进程成功恢复原 pending，未清空或重建记录。此环境中断不计作产品或模拟器稳定性通过证据，也不等于断电恢复认证。

下一阶段继续推进有序后端交付、实际注册设备和运行服务联调、受管系统策略与 TV 认证。不能把本阶段的存储验证替代应用阻止、精准额度计时或内容安全功能。
