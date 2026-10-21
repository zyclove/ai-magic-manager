# 家长端 Android 家庭通知集成

本轮接入阿里云移动推送 Android SDK **3.10.1**，默认关闭。开发包构建、SDK 注册回调、服务端接受安装登记，均不能证明手机收到通知。未用真实供应商账号发送消息；厂商通道、签名及目标真机仍需验收。

## 明确启用与本机权限

家庭通知页面分别展示服务是否开放、本机权限、设备登记和服务端订阅偏好。初次读取不申请权限、不注册 SDK、不改变偏好。成人主动点击开启本机通知后，创建 `family_updates` channel，在 Android 13 及以上请求 `POST_NOTIFICATIONS`，并检查应用通知和该 channel 是否实际允许显示。

SDK 配置由构建环境输入：

- `PARENT_ALIYUN_PUSH_ENABLED=true`，默认 false。
- `PARENT_ALIYUN_PUSH_APP_KEY`：正式 EMAS Android AppKey。
- `PARENT_ALIYUN_PUSH_APP_SECRET`：对应移动应用 AppSecret。

启用但缺失或无效输入会停止构建。AppKey 必须与服务端选定的 Android 应用一致；RAM AccessKey/Secret 仅属于服务端，绝不能放入 APK。这些移动应用参数编译进客户端后仍需按官方要求进行混淆与发布保护，不能把它们当作服务器授权秘密。

`ParentApplication` 只有读取到明确持久化的本机 SDK 同意，才在 `onCreate` 配置 SDK。首次同意由 Application 对象在主线程执行延迟初始化，再调用官方 `register` 与 `getDeviceId`；代码不制造 token，不将 token 复制到 Dart 安全存储。关闭本机通知或退出时清除此同意，后续启动不会初始化 SDK。SDK 日志关闭，厂商离线辅助弹窗不接入。

官方集成文档要求 `PushServiceFactory.init` 在 Application `onCreate` 主线程执行。本项目首次同意后的延迟路径由 Application 承载，并禁用 channel 子进程，但首次延迟初始化仍是**必须用正式 SDK 真机验证的接入条件**，编译通过不能替代验证。若该路径在目标系统不被支持，应调整首次授权后的初始化流程后再开放通知。

## 消息只作提醒

服务端采用 `PushType=MESSAGE`，Body 仅含下列不透明引用：

```json
{"eventId":"规范UUID","deliveryId":"规范UUID","installationId":"当前安装的规范UUID","deepLink":"aimanager://notifications/规范事件UUID"}
```

原生接收器严格检查四个字段、规范小写 UUID 和完整路由；多余字段、超长消息、不同安装、未授权通知或损坏安全存储均不展示。SDK 的 NOTICE 默认展示一律拦截；不会把 MESSAGE 通过厂商离线参数转换成自动 NOTICE。

本地只展示“家庭提醒”和通用正文，不包含孩子姓名、申请原因、手机号、家庭 ID。当前安装 guard 和最近 128 个事件/投递去重引用通过 Android Keystore AES-GCM 加密持久化，写入成功后才显示通知。普通进程重启保留已同意的 guard；退出和切换作用域先清 guard、已显示通知与点击候选，再撤销服务端安装。

通知点击只在内存保存不透明候选。恢复当前账号、家庭和安装后，点击携带的 installationId 必须与加密操作记录一致，才消费一次并打开当前家庭消息入口。必须重新拉取服务端待办；消息内容不会批准申请、修改规则或指定另一个家庭。

## 账号切换与未知结果

`FamilyNotificationCoordinator` 在整个应用共用一个实例。安装 UUID 与成人、家庭绑定，存入现有加密安全存储，并在提交服务端前确认落盘；每次切家庭或切成人创建新 UUID。API 成功后不自动开启通知总开关或任何分类。

恢复到前台时重新读取本机权限、订阅偏好和供应商可用状态；对已明确同意的登记重新获取实际 SDK token，并 PUT 同一安装以处理 token 轮换。权限撤销时先停本机显示，再撤销登记。关闭订阅总开关同样先停本机并撤销安装，避免偏好 PUT 结果未知时再次显示。

退出前使用 owner-only `DELETE /api/v1/notifications/push-installations/{installationId}`，该降权清理接口不依赖原家庭成员资格。云端 DELETE 失败或未知时保留原成人、家庭与安装引用，不保存 bearer token；本机已停止显示，可以继续清理登录凭据。原成人重新登录后再核对注销，旧安装未核对前不会把同一 SDK token 登记给另一个成人。**本地停显示自身失败必须阻止清凭据或切作用域，不能伪装为普通云端注销待核对。**

## 家庭邀请原生入口

独立 `com.aimanager.parent/links` channel 的 `takeFamilyInvitation` 仅接受 `aimanager://family-invitation?id={规范UUID}&token={43位base64url}`，拒绝额外参数、重复参数和片段。原生只在 RAM 保留一份、读取即消费，并清除 Intent data。Flutter 默认深链路由关闭，避免邀请密钥进入路由日志。接受页面继续校验当前登录成人与服务端验证手机号，不会仅凭链接加入家庭。邀请密钥与通知点击引用使用不同通道。

## 仍待发布验收

阿里云自有连接在后台存活、系统杀进程、省电、断网恢复和强停下的行为必须实测；强停后不能保证收到推送。国内厂商离线 NOTICE 可由系统直接展示，不能用本地 guard 在展示前可靠拦截，因此本版本没有宣称厂商离线送达已完成。该缺口需完成可验证的撤权边界设计及正式厂商接入，或在发布范围明确限制后验收。

真实家庭测试应覆盖首次同意、拒绝权限、关闭 channel、token 轮换、退出、切家庭、切成人、云注销超时、重复消息、旧安装延迟消息、暖启动/冷启动点击。服务商受理、终端到达、系统展示、用户点击分别记录，不能互相替代。

官方依据：[SDK 集成及初始化](https://help.aliyun.com/zh/document_detail/434660.html)、[固定版本关系](https://help.aliyun.com/zh/document_detail/434659.html)、[消息与通知回调](https://help.aliyun.com/zh/document_detail/434669.html)、[透传消息自建通知](https://help.aliyun.com/zh/document_detail/434789.html)、[厂商离线辅助弹窗边界](https://help.aliyun.com/zh/document_detail/434677.html)。
