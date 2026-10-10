# Android 真实注册与申请实施计划

## 目标

把独立 HTTP 与原生存储验收推进为同一次 Android → Spring → 数据库旅程：真实注册凭据、Android ES256 认领、监护人确认、真实心跳、申请/取消、过期原键恢复及撤销后缓存隐藏。管理员 OIDC/MFA 仍是显式夹具，不声明商用认证或系统限制已完成。

## 文件分工

- `backend/src/test/java/com/aimanager/AndroidChildSubmissionJourneyTest.java`：真实 Spring 随机端口服务、管理 API、数据库断言与阶段编排。
- `apps/child/integration_test/submission_http_test.dart`：正式身份组件、会话和界面；原生加密存储；真实 HTTP。
- `apps/child/test_driver/submission_http_driver.dart`：官方 integration_test 驱动。
- `apps/child/tool/run_submission_android.py`：专用 AVD 校验、私有文件交接、精确 adb reverse、安装/PID/APK 核对和进行中终止。
- 验收文档与不含秘密的机器摘要放入 `docs`。

不修改并行报表候选的 main/ChildApp/pubspec、reporting/observation 或 V24/V25。

## 可观察验收

1. Android 表单提交真实一次性注册凭据，服务端验证真实 ES256 持有证明；设备与注册 ID 由服务端生成。监护人确认前不能获取设备业务数据。
2. 监护人通过管理 API 确认后，Android 原身份和原安装发起真实心跳；服务端能力仍如实报告 BYOD/LIMITED。
3. 正式申请页面提交后，主机在真实 201 已提交且客户端尚未收到完成结果时终止进程；新进程恢复原正文、原键与 UNKNOWN。
4. 管理员批准并令普通幂等重放过期后，儿童主动核对重试，专用恢复返回同一申请及原绝对期限，不再创建申请。
5. 第二应用正常申请后，在真实取消 200 已提交时终止；新进程按原 ID、原键、版本恢复取消。第一份申请只批准 60 秒，等待真实业务截止后重新获取 EXPIRED，再离线读取同一终态和原截止时间，不自动发送变更。
6. 服务端撤销设备后，真实心跳返回拒绝并隐藏私人数据；下一离线进程继续拒绝旧身份业务。
7. 只清理本次私有交接文件、原生身份命名空间及申请范围；不卸载、不清空应用数据、不改写原产品身份和其他范围。
8. 各阶段核对同一 UID/首次安装时间、实际安装包摘要和 PID；两项进行中中断不算普通驱动成功。结束恢复正常 main，保留 FLAG_SECURE，停止自建模拟器。

## 验证顺序

先冻结已提交基线，完成真实 H2 旅程和必要缺陷回归，再执行隔离 MySQL 旅程；静态检查、儿童端/SDK/后端回归、正常 Android 构建、精确范围审阅后提交 dev。发生失败只修复实际原因，不清空应用数据掩盖恢复问题；未完成的发布门槛如实列出。
