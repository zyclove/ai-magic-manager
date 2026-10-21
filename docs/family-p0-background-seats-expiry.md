# 家庭 P0：后台同步、设备名额与会员到期交付

2026-10-15。本轮继续沿用普通 Android 安装、家庭手动订阅和已有浅色家庭界面。销售开关保持关闭；开发包不能替代真机、正式身份、真实收退款及发布准入。

## 本轮行为

|范围|实现结果|
|---|---|
|儿童端后台|已授权且仍绑定的原生辅助服务拉取签名安排、核验后持久保存、发送配置回执、实际健康报告及心跳。临时放行沿用签名中的绝对截止时间。系统反馈中断不再误停整个服务。|
|凭据与日志|前后台共用 FlutterSecureStorage 的同一份加密身份记录和原生锁；精确字节 CAS、身份代际、轮换未知结果恢复阻止旧回包覆盖新身份。原生和 Dart 使用相同的 OAEP/AES-GCM 配置与持久屏障。|
|用量报告|后台读取服务端观察授权与系统权限，授权先持久化，再查询当前 Android 用户的可见应用日桶。前后台共用 `observation_record` 和发送序号，原报告 UUID、窗口及载荷保存后才上传；未知结果重发原批次，成功后十五分钟内不重复采样。|
|设备名额|按家庭聚合免费一台、有效试用或会员三台；有效预约占名额，认领及成人最终确认均检查。取消、预约过期及撤销释放；归档孩子不释放仍连接设备的名额。|
|到期选择|依据不可变商业来源区间及真实退款时间推导结束时间，从结束起计算七个上海日历日。家长可提前选择一台，确认立即结束窗口；未选择则稳定默认最早连接设备。已失效的注册不会自动继承给重装或其他设备。|
|到期恢复|未保留的设备保持原身份与既有安排，仍允许必要放行、放宽、解除和退出。后台续签保留各设备自己的规则，放宽操作也按每台原规则比较，不缩短既有绝对放行。续费恢复高级服务。|
|报告与 AI|免费保留上海当天报告；成人、儿童设备和导出任务的历史读取均检查当前权益，已生成的历史导出到期也不能继续下载。续费恢复读取。AI 生成与读取已有草稿都核对当前会员。|
|家长界面|今日、会员和连接名额不足均可进入“设备名额”。展示孩子、设备、剩余名额和选择截止；一次明确确认。断网保存原选择，只读查询不创建操作，重试沿用原幂等键与版本；切账号、前后台变化和近期验证使旧确认失效。家庭报告默认进入“今天”。|

## 接口与存储

- `GET /api/v1/tenants/{tenant}/family-device-access`：返回 `tenantId/version/status/effectiveDeviceLimit/activeCount/graceEndsAt/selectedDeviceId/selectedRegistrationId/devices`，禁止缓存。读取可建立或推进服务端投影，因此使用普通事务。
- `PUT /api/v1/tenants/{tenant}/family-device-access/selection`：`{deviceId,registrationId}`，必需 `If-Match` 和 `Idempotency-Key`；OWNER/GUARDIAN 及近期手机验证由服务端检查。
- 状态：`FREE|PAID|GRACE|EXPIRED`；设备资格：`BASIC|MEMBER|GRACE|RECOVERY_ONLY`。`PAID` 包含有效试用。`GRACE` 保持已连接设备的恢复窗口，不增加新连接名额。
- 设备选择绑定设备 ID 与当前注册 ID；仅当前有效设备可选，归档及未确认设备不可选。失效选择在接口显示为空，内部保留旧绑定防止自动转移。
- 新表 `family_device_access_accounts` 纳入初始化基线和保留目录。删除儿童数据时仅解除该注册的选择关联，保留到期锚点及金融记录，不重置试用资格或七天窗口。
- 商业写入与家庭准入共用账户锁；家庭主体、预约、设备按稳定顺序加锁。影响准入及续费的查询显式使用当前锁定读，避免 MySQL REPEATABLE READ 下等待后仍读取旧快照。
- 家庭首页直接聚合设备资格，家长端不另发一次名额请求。选择接口的幂等响应关联全部返回主体，主体删除后不能重放私人副本。

## 运行边界

原生限制评估与网络同步独立。网络超时、报告故障及慢请求不能占用辅助计时线程；请求固定 HTTPS 服务根及路由、不跟随重定向，限制请求和响应大小并设置总超时。

后台同步依赖用户授予的无障碍服务仍被系统绑定。撤权、强制停止、系统休眠、厂商省电和网络中断均可能延迟或停止同步；不承诺绕过系统。系统解绑、退出或身份失效会停止旧执行器并清理对应缓存。普通功能拒绝不冒充设备凭据撤销；通用设备认证拒绝阻断旧身份。

使用统计是 Android 聚合日桶，覆盖说明和区间上下界继续由报告服务计算，不伪装逐秒精确观测。没有读取聊天、页面正文、输入、截图或通知内容。

## 验证记录

本轮证据集中在 `.local/family-p0-next/`。先保存源码基线，再在隔离数据库和构建副本验证，未清空现有数据库、未提交、未部署。

- 家长端完整 Flutter：401 项通过；`parent-full.log`。静态分析无问题；`parent-integration-analyze.log`。共享报告组件十八项通过；`report-ui-green.log`。
- 名额、退款、配对及规则专项：57 项通过；`seats-complete-targeted.log`。
- 报告完整两类：61 项，其中 59 项通过、2 项既有外部 Dart 互操作条件跳过；`report-history-green-recompiled.log`。四个新增权限回归在隔离副本禁用权益检查时均按预期失败，恢复并重新编译后通过。
- 观察日志共享 CAS：19 项通过；`observation-cas-final.log`。原生桥与退出清理定向 22 项通过；`child-observation-cas-green.log`。
- 家长端 Android `assembleDebug/testDebugUnitTest` 已通过；`parent-android-build.log`。截图为虚构样例，[到期选择](../.local/family-p0-next/ui-previews/device-access-GRACE.png)、[到期后](../.local/family-p0-next/ui-previews/device-access-EXPIRED.png)、[有效会员](../.local/family-p0-next/ui-previews/device-access-PAID.png)。
- 后端全套验收快照共1241项，1166项执行通过、75项条件跳过，零失败/错误，JAR打包成功；`backend-full.log`。并行受管 Android 源码随后有改动，又以当前源码建立独立副本，93项家庭/报告/保留/模块集成中91项通过、2项条件跳过，零失败/错误，重新打包；`backend-current-integration.log`。344个当前源码/资源摘要与该副本一致。
- 儿童端最终 Flutter 223项通过，静态分析无问题；纯JVM80项、Android原生81项通过，最新Dart及原生 `assembleDebug/testDebugUnitTest` 成功。137个生产源文件摘要构建后未变；`child-background-verification.json`。
- 家长端按最终冻结源码重新构建成功，原生2项通过；`parent-android-final.log`。两端均只生成debug开发包，未配置生产API/签名信任输入，不能直接作为正式交付包。

独立代码复查发现系统反馈中断会永久停止后台，已修复并加入生命周期回归；包含后台用量及共享日志的第二轮复查未发现新增确定的P0/P1。完整结果及产物摘要见 [最终验证清单](../.local/family-p0-next/delivery-verification.json)。

已保存固定产物，避免后续构建覆盖本轮验收版本：

|产物|SHA-256|
|---|---|
|[家长端开发包](../.local/family-p0-next/artifacts/parent-family-p0-debug.apk)|`03bff058ef02e321b5771081d0b950de763252cefbeaa813f3ea79ae7783fd15`|
|[儿童端开发包](../.local/family-p0-next/artifacts/child-family-p0-debug.apk)|`1f4951bc60bb586fa1ec5528b2ad7be33fbd62b25204c11a3138801eff6f8eb3`|
|[当前集成后端JAR](../.local/family-p0-next/artifacts/manager-family-p0.jar)|`b24ab6c195ce0fcd708212bc353b50ed55bcc14a103878ff2c51232d9ecd3b66`|

数据库并发用隔离H2验证，没有运行真实MySQL实例；实际MySQL锁与隔离行为仍须部署验收。本轮家庭改动未提交、未部署，保留其他并行开发工作。

## 收费前剩余事项

接下来按优先级推进国内推送客户端与到期/异常提醒、已验证手机号邀请及账号售后、自动关单/日账单对账与售后界面、AI 事务外调用和真实质量评测。仍须八台三品牌设备、七十二小时运行、真实手机和微信身份、付款退款到账、中国内地部署、正式签名及备案/渠道准入、家庭试点验收。当前不能开放正式收费。
