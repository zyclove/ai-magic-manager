# 中国大陆家庭订阅接口与核验边界

此文描述本地软件实现，不是商户交易、渠道准入或可收费验收证明。支付与销售开关默认关闭；缺少配置时明确返回不可用，不生成演示交易。

## 产品与权限

一档 FAMILY 会员有两个手动购买周期：初始 `FAMILY_MONTH` 为 1900 分 CNY，`FAMILY_YEAR` 为 19900 分 CNY，均覆盖 3 台儿童设备。报价在服务端有版本；运营人员提案、另一位具有相应权限且近期 MFA 的人员批准后才更新。没有自动扣款、自动续订或代扣签约。商业权益和设备真实技术能力独立；会员不会把辅助限制变为系统强制限制。

所有家庭接口都重新检查数据库中的当前家庭成员关系及租户类型。OWNER、GUARDIAN 可读取套餐、订阅、订单和退款请求；仅 OWNER 可创建订单、试用、支付、核验和退款。支付参数读取仅 OWNER。其他角色、已撤销成员和组织租户不可访问。订单与退款必须同时匹配路径租户和资源 ID。

## HTTP 合约

前缀为 `/api/v1/tenants/{tenantId}`。响应使用 `Cache-Control: no-store`；时间字段为毫秒 Unix 时间戳。

|方法|路径|输入与返回|
|---|---|---|
|GET|`/subscription-offers`|`{items:[{planKey,offerVersion,period,priceMinor,currency,childDeviceLimit,renewalMode,paymentAvailable}]}`|
|GET|`/subscription`|`{tenantId,status,periodStart,periodEnd,childDeviceLimit,renewalMode,paymentAvailable,trialEligible,billingTimeZone}`|
|POST|`/subscription/trial`|`{deviceId}`；经服务器激活核验后返回订阅。不得提交 `activated` 等客户端自授标志。|
|POST|`/orders`|必需 `Idempotency-Key`；`{planKey,offerVersion}`；返回订单。缺少报价版本只兼容初始版本 1，报价变化返回 `FAMILY_OFFER_CHANGED`，不能自动按新价购买。|
|GET|`/orders`|`limit` 1–100、可选 `cursor`；`{items,nextCursor}`。|
|GET|`/orders/{orderId}`|返回订单。|
|POST|`/orders/{orderId}/payment-attempts`|必需 `Idempotency-Key`；空对象；返回服务器生成的 APP 支付参数，未配置时 503。|
|GET|`/orders/{orderId}/payment-attempts`|仅 OWNER；`{items:[paymentAttempt]}`。|
|POST|`/orders/{orderId}/payment-verifications`|空对象；由服务器查询微信交易，返回订单。|
|POST|`/orders/{orderId}/refund-requests`|必需 `Idempotency-Key`；`{reason}`，1–200 字符；返回已持久化的退款请求。|
|GET|`/orders/{orderId}/refund-requests`|按原订单恢复退款，`{items:[refundRequest]}`，最多一个；读取失败时客户端不开放新的退款申请。|
|GET|`/refund-requests`|`limit`、`cursor`；`{items,nextCursor}`。|
|GET|`/refund-requests/{refundId}`|返回退款请求。|
|POST|`/refund-requests/{refundId}/submissions`|空对象；向微信提交原交易全额原路退款。|
|POST|`/refund-requests/{refundId}/verifications`|空对象；服务器查询退款最终状态，成功后撤销该订单来源权益。|

订单字段为 `{id,tenantId,planKey,status,priceMinor,currency,periodStart,periodEnd,createdAt,expiresAt}`。状态为 `CREATED`、`PAYMENT_PENDING`、`PAID`、`REFUNDED`、`CLOSED`、`EXPIRED`。`EXPIRED` 仅表示没有预约过支付、没有渠道交易号的本地草稿到期；不能代替微信关单。未付款订单 15 分钟后不能再创建支付请求；退款不会改写任何订单原定周期。租户存在未过期草稿或任意尚未核清的支付订单时，另一个购买返回 `FAMILY_ORDER_PENDING`，避免迟到付款通知与后续购买覆盖同一续费周期。支付结果不明确的订单须由服务器查询到微信 `CLOSED` 后才可释放。

订阅状态为 `NONE`、`TRIAL`、`ACTIVE`、`SCHEDULED`、`EXPIRED`。订阅是现存商业来源的投影，接口没有客户端确认购买或自授会员路径。

`childDeviceLimit` 现返回实际准入上限：有效试用/会员3台，免费或到期1台。原订阅状态与到期选择状态分别展示：新增 `GET /family-device-access` 和带 `If-Match`、`Idempotency-Key` 的 `PUT /family-device-access/selection`（`{deviceId,registrationId}`）。七日选择窗口依据实际权益结束时间计算；选择需近期手机验证，其他设备的必要放行、解除与退出不受欠费阻断。并发预约、确认、退款及续费共用商业账户锁。完整字段及规则见 [后台、名额与到期交付](family-p0-background-seats-expiry.md)。

支付尝试字段为 `{id,orderId,status,parameters,createdAt}`，状态 `INITIATED`、`READY`、`PAID` 或 `CLOSED`。调用微信前先提交 `INITIATED` 与固定商户订单号；超时也保留可核验的订单身份。`READY` 的 `parameters` 是微信 OpenSDK 的 `{appId,partnerId,prepayId,packageValue,nonceStr,timeStamp,sign}`，`packageValue` 固定为 `Sign=WXPay`。SDK 返回成功只表示需要服务器核验；不得据此开放权益。

退款字段为 `{id,orderId,status,reason,priceMinor,currency,createdAt,paymentAvailable,reviewNote}`，状态为 `AWAITING_REVIEW`、`REQUESTED`、`DECLINED`、`PROCESSING`、`REFUNDED`、`CLOSED`、`ABNORMAL`。家长申请和提交渠道前需要近期受信手机号验证（原有 MFA 也可）；新申请先进入人工审核，不能直接向微信提交。关闭或异常状态不能显示退款成功，原付费来源保留。请求持久化后再提交，网络结果不明确时仍可使用同一退款 ID 核验；`REQUESTED` 表示审核通过待渠道提交，不表示钱已退回。只能原交易全额退款，不接收客户端金额、银行卡或替代收款地址。

人工审核接口位于 `/api/v1/platform/family-subscription/refund-requests/{id}`：`GET /preview` 读取冻结金额、对应来源及保留续费订单，`POST /reviews` 提交 `{decision:APPROVE|DENY,previewHash,note}`（`note` 为家长可见的 1—200 字审核说明；兼容旧客户端省略） 和 `Idempotency-Key`。两者均要求单独授予的 `family-refunds:review` 权限及近期 MFA，申请人不能自审。预览变化须重新核对；批准只转为 `REQUESTED`，不会执行外部退款。此权限默认不授予消费者，需要在正式身份服务为指定售后人员单独配置。用户详细原因仅保存在本系统，微信使用固定的会员全额退款说明。

同一当前用户、同一租户的同一幂等键返回原资源；相同键更改套餐、订单或退款原因返回 409。验证请求本身幂等；已确认交易不会再追加同版本权益。

## 试用与周期

`FamilyAssistedActivationGate` 是服务器内部 SPI；默认拒绝 `TRIAL_ACTIVATION_NOT_VERIFIED`。可信实现必须核验设备注册、真实签名运行观察和已验收机型策略。普通入网、配置送达或客户端布尔值不能开始试用。服务还核验 Android 设备当前状态、注册 ID、设备创建时间和激活证据摘要。

试用以核验过的实际激活瞬间起算 7 个日历日，同一家庭仅一次，重复请求不重置。请求者 JWT 必须包含由受信身份提供商核验的 `phone_number_verified=true` 和规范中国大陆手机号。账号身份摘要与手机号摘要分别在 `family_trial_claims` 中以固定顺序加锁和认领，领取记录不设置租户外键；更换家庭、更换手机号或换账号复用同一手机号都不能重新领取，删除家庭也不重置记录。接口不返回手机号或摘要。

套餐的 `paymentAvailable` 还取决于该家庭是否有服务器验证过的当前 Android 激活或有效的已核验试用；商户配置齐全也不能让未验证家庭进入可付费订单。创建可付费订单和新支付尝试时再次核验。未配置商户时仅可保存不可付款的本地订单草稿。

付费月/年周期使用 `Asia/Shanghai` 日历计算并在订单创建时冻结；1 月 31 日购月度的到期日为 2 月末相同时刻。续费开始于当前付费/试用结束时间与当前时间中的较晚值，不用固定 30/365 天近似。

试用以 `TRIAL`、微信订单以 `WECHAT_PAY` 写入既有 `CommercialLedger`，每个付费订单独立来源。支付成功为 revision 1，核实退款为 revision 2 撤销。退款不撤销试用或其他订单；后续续费仍使用其已冻结的开始和结束时间，不因前一订单退款而挪动。

## 微信 v3 与配置

生产适配器只连接 `https://api.mch.weixin.qq.com`，使用 JDK HTTP 客户端，禁止重定向并设置连接/请求超时。商户 API 请求使用 SHA256withRSA；APP 调起支付另按四行字段签名；查询和提交响应都必须验证微信公钥签名。回调验证原始报文、配置的微信公钥 ID、5 分钟时间窗口，再以 API v3 密钥执行 AES-256-GCM 解密；支付绑定 appid/mchid，退款绑定 mchid、原交易、退款单号和全额。

配置通过外部 Spring 配置或对应环境变量提供，不提交密钥内容：

|属性|要求|
|---|---|
|`manager.family.wechat.enabled`|默认 false；启用经核验的微信集成。|
|`manager.family.sales-enabled`|默认 false；真实渠道、设备、商户及试点验收完成后才可开放新收费。关闭销售仍允许已配置集成核验和退款。|
|`manager.family.wechat.app-id`|已与商户绑定的移动应用 APPID。|
|`manager.family.wechat.merchant-id`|直连商户号。|
|`manager.family.wechat.merchant-serial`|商户 API 证书序列号。|
|`manager.family.wechat.merchant-key-file`|RSA ≥2048、PKCS#8 PEM 私钥文件。|
|`manager.family.wechat.platform-key-id`|固定的微信支付公钥 ID。|
|`manager.family.wechat.platform-key-file`|微信 RSA ≥2048、X.509 SubjectPublicKeyInfo PEM 公钥文件。|
|`manager.family.wechat.api-v3-key-file`|32 字节 API v3 密钥文件。|
|`manager.family.wechat.notify-url`|公网 HTTPS 地址，指向下述回调；不带查询串、用户信息或片段。|

缺少或无效配置会关闭支付，返回 `FAMILY_PAYMENT_UNAVAILABLE`。公钥轮换须部署受信的新公钥与 ID 并重启；当前实现不自动下载或信任未知证书。

唯一匿名入口是 `POST /api/v1/payments/wechat/notifications`，它不接受用户 JWT 代替微信签名。合法通知的 inbox、订单状态、权益来源事件和审计在同一数据库事务中提交，重复通知无额外权益；相同通知 ID 改变内容时拒绝。错误签名、错误金额、跨交易退款和事务失败均不能留下已消费 inbox 或权益。

本地测试使用临时生成的 RSA 密钥、AES 密文和替代 HTTP 传输验证协议，未请求真实微信商户。真实下单、微信客户端拉起、付款、回调、原路到账、关闭订单及长期对账/监控仍需商户沙箱或真实验收。已补齐持久后台查单、可信关单、已审核退款恢复与微信日账单任务，默认关闭定时执行；见 [支付维护](family-commerce-maintenance.md)、[日账单核对](family-wechat-daily-reconciliation.md) 和 [本轮交付说明](family-p0-commerce-operations.md)。

官方依据：[APP 下单](https://pay.wechatpay.cn/doc/v3/merchant/4013070347)、[APP 签名](https://pay.wechatpay.cn/doc/v3/merchant/4012365340)、[请求签名](https://pay.wechatpay.cn/doc/v3/merchant/4012365336)、[响应验签](https://pay.wechatpay.cn/doc/v3/merchant/4013053420)、[退款查询](https://pay.wechatpay.cn/doc/v3/merchant/4012791884)、[退款通知](https://pay.wechatpay.cn/doc/v3/merchant/4013070388)。

数据库片段位于 `backend/src/main/resources/family/family-subscription.sql`，由初始基线合并用于新空库；不是现存数据库升级脚本。上线必须按仓库部署约定创建/升级真实数据库，不能只添加应用文件。
