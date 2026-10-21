# 家庭成人通知契约与上线缺口

当前实现提供持久推送队列、真实设备与订阅提醒生产、成人安装注册和阿里云移动推送 Android 服务端边界。默认不启用服务商，也不运行发送及提醒扫描任务。本地测试没有发送真实推送。原生接入结果以本轮交付记录为准；代码或构建成功不等于国内真机推送已经验收，正式应用签名和目标设备收取、展示、点击仍须验证。

## 授权、同意与安装身份

所有接口使用现有已验证 JWT，租户路径必须为规范 UUID。只有当前 FAMILY 的 OWNER 或 GUARDIAN 可以管理自己的注册与偏好。CHILD、组织租户和其他家庭无权限。安装 ID 必须是设备本地新生成并保存在安全存储中的随机 UUID v4，不使用手机号、硬件序列号、孩子设备 ID 或服务商 token 充当安装 ID。

`PUT /api/v1/tenants/{tenantId}/push-installations/{installationId}`：

```json
{
  "provider": "ALIYUN",
  "platform": "ANDROID",
  "providerToken": "SDK实际返回的deviceId",
  "notificationConsent": true,
  "permissionGranted": true
}
```

只允许 ALIYUN Android；客户端不得上传虚构、占位或自行拼装的 token。两个授权字段必须明确为 true，表示成人已同意及设备通知权限已授权。服务端只证明“当前登录成人提交并占有此注册记录”，不能凭这个接口证明字符串确由 SDK 返回或手机收到推送。响应 `deliveryVerified` 永远不因注册成功而变为 true。安装 ID 的租户及成人归属不可被他人覆盖，同一活跃 token 不能被另一个安装接管。同一安装 token 的重复上报不改变版本；token 轮换、撤销后重新授权及成员版本变化会改变版本，让旧队列失效。当前每个安装及活跃 token 只绑定一个家庭，尚未支持同一安装同时接收多个家庭的推送；原生集成不能假定多家庭订阅已实现。

`DELETE /api/v1/tenants/{tenantId}/push-installations/{installationId}` 返回 204，清除该成人自己的原始 token 和 token 索引，撤销通知同意。退出登录应在清除登录凭据前调用此接口；关闭系统通知权限也应调用。成员撤权同步清除其所有注册 token 和偏好，未发送队列变为 SUPPRESSED。相同安装不允许跨账号重复利用；换账号应生成新安装 ID 并先注销旧注册。离线退出导致撤销调用无法上传时，客户端必须停止本地显示并在下次连网、凭据清除前重试；已被服务商接收的通知不能由本服务撤回。

客户端恢复注销优先使用 `DELETE /api/v1/notifications/push-installations/{installationId}`。它核对当前 JWT 成人身份对应的安装所有者，无需仍是旧家庭的成员：退出家庭、成员被移除或角色降级后仍能撤自己的注册。未知安装返回 204，其他身份访问已有安装返回 403，未登录返回 401；不返回 token 或旧家庭资料。操作只降低权限，清 token、索引、通知同意并抑制尚未发送队列，不能注册、转移或重新授权。响应禁止缓存；注册、通知偏好与就绪查询也禁止缓存。

`GET /api/v1/tenants/{tenantId}/notification-preferences` 默认所有字段 false。成人需明确调用 PUT 开启订阅：

```json
{"enabled":true,"requests":true,"deviceAttention":true,"ruleExpiry":true}
```

三个分类分别对应临时申请变动、设备注意事项及会员与作息到期提醒。开启系统权限、注册设备、修改其他类别不会自动开启此总开关。关闭总开关或对应分类会在发送前复核并抑制旧队列。

## 域事件、消息内容与深链

`com.aimanager.notification.FamilyAttentionEvent` 必须在业务写事务内同步发布，字段为 `tenantId,eventId,subjectId,deviceId,kind,occurredAt`；ID 为不透明字符串，时间为 epoch 毫秒。支持 `FAMILY_REQUEST_PENDING`、`FAMILY_REQUEST_DECIDED`、`FAMILY_DEVICE_ATTENTION`、`FAMILY_RULE_EXPIRES_SOON`，以及 `FAMILY_SUBSCRIPTION_EXPIRES_SOON`、`FAMILY_SUBSCRIPTION_EXPIRED`、`FAMILY_SUBSCRIPTION_SELECTION_DUE`。家庭请求服务负责前两种，会员事件不带 subject/device。投影与业务事务同成败。非 FAMILY 事件不会形成推送。

持久事件仅保存租户、随机事件 ID、类别与时间，刻意丢弃 subjectId/deviceId；outbox 不复制 token、姓名、理由、手机号。每个事件只投影给事件当时存在且明确订阅类别的成人安装，不会将旧事件补发给后来加入或后来开启通知的人。相同事件 ID、类别和时间的重放不增加队列；冲突重放拒绝覆盖。

服务端仅发送 `MESSAGE` 数据消息，Body 严格为四字段 JSON：`eventId`、`deliveryId`、`installationId`、`deepLink`，深链为 `aimanager://notifications/{opaque-eventId}`。不携带租户、孩子、申请理由、手机号或 token。原生必须核对当前本机授权与安装 ID，再自行建立通用通知，标题“家庭提醒”，正文“家庭中有待查看的更新，请打开应用查看。”。退出、账号切换、关闭本地通知会阻止旧安装消息的展示；不能用会绕过本地授权判断的 SDK NOTICE 或厂商离线通知代替。点击需要去重 deliveryId/eventId，打开当前家庭提醒入口并重新拉取数据；深链和缓存不是查看资料或处理申请的授权。

## 实际状态提醒与扫描

`FamilyReminderWorker` 默认为关闭。设备与会员扫描分别使用短事务、持久 keyset 游标和游标行锁，多实例不会各自生成同一个 episode；单轮每类最多 100 条，无一次加载所有设备或历史提醒。设备批次先按家庭及孩子顺序锁主体，再锁设备；会员批次使用商业账户锁顺序。扫描不是限制执行器，也不生成虚构心跳或修改家规与权益。

默认连接缓冲与失联阈值均为 30 分钟；首次无心跳从设备连接创建时间起算，已有心跳从最后一次真实接收时间起算。幂等心跳重放不刷新该时间。运行报告需匹配当前注册、当前设备配置与近期观察时间，且该设备自己的家庭辅助规则已启用；首次权限未开、初始化、无家庭规则不冒充执行异常。已有正常运行后发生权限丢失，或已选择启用且报告明确的原生存储、配置、时钟故障，才建立异常 episode。报告是设备自报，提醒不将其升级为服务端独立验证的强执行证明。

同一未恢复异常只生成一次事件；明确恢复后再异常可生成新事件。报告缺失或过期表示证据不足，抑制旧消息但不假定已经恢复；新的真实心跳可以证明失联曾恢复。设备退出、注册更换、规则关闭以及有效健康报告会撤销适用的未发提醒。发送前以独立 READ_COMMITTED 只读事务再次核对当前事实，避免外层旧快照造成误发；外部受理后的并发恢复仍存在不可撤回窗口。

会员事实复用不可变商业来源区间、真实退款/撤销及相邻续费合并，分别在到期前三日、真实到期和七日选择窗最后一日形成边界事件。续费或提前选定免费设备会使对应旧提醒失效；延迟启动扫描不重置起止时间，超过旧消息有效期的事件不发送。该类沿用 `ruleExpiry` 明确订阅，不补发给后来开启偏好或后来注册安装的成人。

## 队列、重试与结果含义

outbox 状态为 PENDING、LEASED、ACCEPTED、SUPPRESSED、DEAD。数据库条件更新领取 60 秒租约，多副本不会同时拥有同一个有效租约；崩溃后的过期租约可以被新 worker 领取。每次 dispatch 重新锁定成员关系、安装、偏好和队列；角色必须仍为成人、成员版本和安装版本必须仍匹配、租户仍为 FAMILY、同意与系统权限上报仍有效。权限撤销与有界发送按成员锁串行。超过一天的旧事件抑制发送。

默认最多 5 次，失败次数与下一次重试时间持久化，间隔为 1、2、4、8 分钟，最高 1 小时。明确不可重试的提供商拒绝及次数用尽进入 DEAD，未知运行时失败记为 PROVIDER_OUTCOME_UNKNOWN 并进入 DEAD。错误只存稳定错误码，不能把服务商响应或 token 写入日志。DEAD 不自动复活；运维调查后若确需补发，应创建经过授权的业务重发流程。

deliveryId 在本地事件与安装之间唯一，所有尝试使用相同阿里云 JobKey，服务商 MessageId 单独持久化。JobKey 是关联标识，阿里云文档没有承诺它是幂等键；网络超时或发送后提交前崩溃可能出现重复物理通知。因此这是持久的至少一次尝试队列，不能宣称端到端恰好一次。原生客户端必须按事件/投递 ID 去重。服务商明确返回 MessageId 才记 ACCEPTED；这只表示服务商受理，不能证明手机收到、显示或用户阅读。当前没有外部回调写入“已送达”的接口；未来回调也必须验签、关联 JobKey/MessageId，并将服务商受理、厂商受理、终端到达、打开分别记录，不能相互代替。

## 阿里云服务端配置

阿里云账号 RAM 最小权限、Android 应用 AppKey 和正式签名需要在控制台真实配置。服务端 POST 固定国内 `https://cloudpush.aliyuncs.com/`，RPC Action=Push，Version=2016-08-01，Target=DEVICE，PushType=MESSAGE，DeviceType=ANDROID，不支持广播、任意 endpoint 或选择其他应用。StoreOffline=false、AndroidRemind=false，不将离线数据转换为绕过本地授权检查的通知。MESSAGE 依赖阿里云在线通道；进程结束、厂商省电或网络断开时可能收不到，厂商离线推送本轮仍是收费前缺口。这个取舍不宣称已覆盖国内后台到达。

默认配置为：

```properties
manager.family.push.aliyun.enabled=false
manager.family.push.worker.enabled=false
manager.family.push.max-attempts=5
manager.family.push.lease-seconds=60
manager.family.push.worker.interval-seconds=10
manager.family.reminders.worker.enabled=false
manager.family.reminders.worker.batch-size=50
manager.family.reminders.worker.interval-seconds=60
manager.family.reminders.offline-seconds=1800
manager.family.reminders.connecting-grace-seconds=1800
manager.family.reminders.runtime-fresh-seconds=600
```

开启服务商时设置 `manager.family.push.aliyun.credentials-file` 为工作区及仓库外的受控 UTF-8 JSON 文件路径，限制为服务进程可读：

```json
{"accessKeyId":"实际RAM访问标识","accessKeySecret":"实际RAM密钥","androidAppKey":"实际数字AppKey","androidChannelId":"family_updates"}
```

文件不应进入版本控制、镜像、APK 或日志。缺失/无效配置保持不可用。`GET /api/v1/tenants/{tenantId}/push-readiness` 仅向当前成人报告 providerConfigured 与 workerEnabled，当前 nativeIntegrationVerified/deliveryVerified 均为 false；配置成功不会自动升级真机验收结论。

协议依据：[阿里云 Push 的 MESSAGE 与 NOTICE 参数说明](https://help.aliyun.com/zh/document_detail/2249916.html)、[RPC 签名规则](https://help.aliyun.com/en/sdk/product-overview/rpc-mechanism)、[JobKey 的回执日志语义](https://api.alibabacloud.com/document/Push/2016-08-01/PushMessageToAndroid)。服务端使用 HMAC-SHA1、RFC3986 编码、随机 SignatureNonce、UTC Timestamp，经 HTTPS 发送；测试独立计算签名，没有调用真实网络。

## 仍需真实交付验证的工作

家长端必须集成官方原生 SDK，在成人明确同意后初始化并取得实际 deviceId，建立 Android 通知 channel，申请 Android 13+ POST_NOTIFICATIONS，配置国内厂商通道，处理 token 轮换、登录切换、权限关闭和退出登录撤销。当前 Flutter 页面或普通轮询不能替代这一原生能力。

上线前需用华为/荣耀、小米、OPPO、vivo 等目标真机覆盖前台、后台、进程被结束、断网重连、撤权、退出登录和关闭通知权限；确认安装注册、请求事件、服务商受理、终端展示及点击后重新鉴权。没有这些证据时应将“国内真机推送闭环”标为待完成，不可把测试替身、SDK 回调或配置状态作为 P0 已就绪依据。
