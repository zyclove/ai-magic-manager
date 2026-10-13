# 儿童端退出原生存储验证计划

> **For agentic workers:** Use executing-plans; one final scoped review.

**Goal:** 在隔离 Android 模拟器上验证真实加密存储、应用文件、原生持久屏障和 Keystore 原密钥的退出恢复路径。
**Architecture:** 使用全新专用 AVD，不访问既有模拟器数据。合成云端注册/签名清理命令；运行真实身份管理器、清理日志、Android执行器及过期后启动恢复入口。官方 integration_test driver 附加已安装应用，各阶段明确停止进程并核对 UID/安装时间/APK 哈希。
**Tech Stack:** Flutter integration_test、Android API34、AndroidKeyStore、现有 flutter_secure_storage/Sembast 与 Python 标准库。
**Spec:** docs/device-deprovision-contract.md §5；已完成 child-cleanup-storage-verification-plan.md。

## 约束和复核重点

- 只允许显式授权的 emulator serial 与精确 AVD 名，独立本地目录；不卸载、重置或覆写其他安装数据。
- 缓存、身份、签名命令均为合成测试数据，不使用真实账户/业务库；输出只含布尔结果、PID、公开摘要，不输出密钥或 bearer。
- 初次缺失种子阶段必须失败；后续必须复用同安装并更换进程。
- 清理后原密钥/身份仍在，确认记录持久化后才允许最后删除；命令过期后已确认恢复不要求重取命令。
- 加密缓存、主数据库与单~恢复文件均清除；其他文件及恢复日志保留。
- 实际 Android 模拟器可验证平台通道，不等于物理手机/TV、硬件背书、真实断电或云端鉴权验收。

### Task 1: 原生多进程清理验收

Files: apps/child/integration_test/cleanup_storage_test.dart; apps/child/test_driver/cleanup_storage_driver.dart; apps/child/tool/run_cleanup_android.py; apps/child/tool/test_run_cleanup_android.py; this plan; docs/releases/stage-child-cleanup-native-verification.json; related README/contract evidence only after completion.

- [x] 编写 seed、clear、finish、verify 四阶段测试；finish/verify 无前序种子明确失败。
- [x] 编写严格 AVD/安装保持/进程终止/报告关联的宿主运行器及单元回归。
- [x] 冻结源码并创建专用模拟器，构建测试 APK，执行缺失种子负控与四个分离进程阶段。
- [x] 验证实际 Keystore 别名、加密存储和文件在重启前后的结果；真实产品恢复入口在命令过期后完成原密钥删除。
- [x] 完成儿童端和受影响 SDK 分析/测试，归档 APK/源码/日志/阶段报告摘要，停止本轮模拟器。
- [x] 一次独立最终复核，记录每项边界，仅提交本阶段已验收文件。

Expected: 负控因无种子失败；四阶段完成且安装保持、PID不同、已确认过期恢复成功；无真实账户或既有应用数据变更。

## 本阶段结果

负控及四原生阶段通过，五个不同进程保持同一安装；儿童端177/177、清理SDK74/74及分析通过。一次独立复核发现1项Important（安装前APK包名检查）和1项Minor（最终阶段缺少日志保留显式断言）。Important已RED→GREEN修复，宿主回归6/6、四实际APK只读预检及完整门禁通过；Minor明确延期。修复后未重跑原生安装，证据分别记录原运行器与修复后源摘要。没有发布正式包或更新运行服务，整体目标继续。
