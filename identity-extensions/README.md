# 中国大陆家庭身份扩展

这是 Keycloak 26.8.0 的认证 SPI、令牌映射器与当前账号状态 REST SPI；Java 17 编译，依赖均为 `provided`，不把 Keycloak/Jackson/JPA 打进扩展 JAR。支持真实阿里云短信 SendSms、Android OpenSDK 微信授权码换取、原账号手机号换绑、微信绑定解绑与既有微信找回，默认全部关闭。没有测试验证码、模拟成功登录、成人认证或自动 MFA 声明。

## 构建与离线生成配置

```powershell
mvn -f identity-extensions/pom.xml verify
./deploy/keycloak/merge-consumer-realm.ps1 -InputPath ./deploy/keycloak/realm-template.json -OutputPath ./.local/ai-manager-realm.json
```

本机 Maven Central 曾返回 403，可显式使用 `-s identity-extensions/maven-settings.xml` 的阿里云 Central 镜像。依赖版本不随镜像改变。转换脚本仅写本地 JSON；保留管理端 `manager-browser` 与原有密码/OTP 流，给 `ai-manager-parent` 单独绑定 `consumer-phone-browser`，并增加受保护的手机号资料和可信令牌映射器。已有部署必须先导出当前 realm 再转换，保留当前 profile 和其他组件；启动时 `--import-realm` 不会更新已存在的 realm，应在发布窗口通过常规受控的配置迁移应用并保留回滚导出。

部署流程已接入扩展，无需手工修改 Dockerfile 或将 JAR 复制进源码目录。只为新的独立部署显式启用：

```powershell
./scripts/initialize-deployment.ps1 -Directory .local/family-deployment -ProjectName family-deployment -ConsumerIdentity
./scripts/build-deployment.ps1 -Directory .local/family-deployment -ConsumerIdentity
# 已缓存依赖时可追加 -Offline；本机缓存示例：-MavenRepository .local/m2
```

构建复制 SPI、部署脚本和主题到独立源码快照，执行 Maven `verify`（不允许没有测试），再把 JAR 暂存到唯一发布目录的 `keycloak/keycloak/providers/`。镜像在 `kc.sh build` 之前复制 provider；发布清单记录 `identityProviderSha256`，启动脚本核对 JAR 摘要、消费者模式与实际镜像构建上下文。失败时不更新此前发布清单或产物选择。源码中的 `deploy/keycloak/providers/` 保持为空；默认管理端部署不编译也不加载消费者 SPI。初始化和构建的 `-ConsumerIdentity` 必须一致。

消费者初始化仅从管理模板生成新的 `realm.json`，保留原管理流程为 `realm-management.json`。已有部署仍需显式导出、转换和受控迁移；转换脚本拒绝覆盖输入或已存在的输出文件。以上命令不启动服务，不修改已有 realm 或数据库。`ConsumerIdentity` 只表示打包和配置选择，不证明短信送达、成人身份、MFA、设备验收或商业准入。

## 服务端配置

|变量|要求|
|---|---|
|`CONSUMER_PHONE_ENABLED`|只有明确设为 `true` 才开放短信登录|
|`CONSUMER_ACCOUNT_SECURITY_ENABLED`|只有明确设为 `true` 才开放账号安全操作与当前身份状态接口；消费者业务会话校验启用时必须同步配置，未就绪时失败关闭|
|`CONSUMER_OTP_HMAC_KEY`|至少 32 字节独立随机密钥；所有 Keycloak 节点一致|
|`ALIYUN_SMS_ACCESS_KEY_ID` / `ALIYUN_SMS_ACCESS_KEY_SECRET`|中国站有 SendSms 权限的最小权限 RAM 凭据|
|`ALIYUN_SMS_SECURITY_TOKEN`|可选 STS 凭据；须按到期时间轮换实例配置|
|`ALIYUN_SMS_SIGN_NAME` / `ALIYUN_SMS_TEMPLATE_CODE`|已经审核的中国大陆短信签名与验证码模板；模板变量名 `code`|
|`CONSUMER_WECHAT_ENABLED`|只有明确设为 `true` 才接受原生授权码|
|`WECHAT_NATIVE_APP_ID` / `WECHAT_NATIVE_APP_SECRET`|已审核移动应用的同一对配置，APPSECRET 仅服务端保存|

Compose 的家庭覆盖通过 `*_FILE` 传入秘密文件路径，容器入口只在进程内部读取文件后设置 SPI 所需变量。`CONSUMER_OTP_HMAC_KEY`、短信 AccessKey ID/Secret/STS token、微信 AppSecret 分别来自 `secrets/consumer_otp_hmac_key`、`consumer_sms_access_key_id`、`consumer_sms_access_key_secret`、`consumer_sms_security_token`、`consumer_wechat_app_secret`。初始化仅生成独立 HMAC，供应商文件为空；所有入口默认关闭。签名、模板号和 AppID 使用非秘密环境配置，完整模板见 [`deploy/keycloak/family.env.example`](../deploy/keycloak/family.env.example)。秘密不能放进客户端、提交到 Git、`.env` 或部署日志。

缺少短信配置时界面提示服务未开放，不发短信；微信缺少配置时拒绝授权码。服务端仅访问 `https://dysmsapi.aliyuncs.com/` 和 `https://api.weixin.qq.com/sns/oauth2/access_token`，无可由请求修改的远程地址，不跟随重定向，连接/请求有超时。

`start-deployment.ps1` 对消费者部署自动添加 [`compose.family.yaml`](../deploy/compose/compose.family.yaml)，为身份服务与后端增加出站网络，内部数据库仍不公开端口。覆盖将 SMS/微信登录、AI、推送及 worker、支付、销售和设备验收开关全部默认设为 `false`。首次准备空账本和启动仍按主部署手册执行；不要用初始化脚本给已有部署轮换配置。

## App 与令牌契约

手机号：`PHONE_LOGIN_ENABLED=true` 后发起原有 Keycloak OIDC 授权码 + PKCE S256；消费者认证器不是外部 IdP，无需 `kc_idp_hint`。认证流没有 Cookie 短路，普通手机号登录和敏感操作重新认证都要求新短信。

微信：Android 构建提供 `PARENT_WECHAT_APP_ID`，与服务端移动应用 ID、正式包名 `com.aimanager.parent`、发布签名一致，并通过微信开放平台移动应用登录审核。App 调用 `com.aimanager.parent/auth` 通道的 `wechatLogin`，使用原生 `SendAuth.Req(scope=snsapi_userinfo)`。回调在内存中校验 32 字节随机 state、单次消费与 2 分钟单调时钟超时，然后返回短期 code。App 将 code 作为 `family_wechat_code` 传入正常 Keycloak OIDC 授权请求；服务端用固定 APPID/APPSECRET 换取 openid。没有 QR 网页登录替代。首次授权必须完成短信验证；已绑定账户可通过微信登录。

账号以已验证中国大陆手机号唯一用户名创建。微信身份按 `APPID + openid` 绑定，完全忽略 unionid，不跨账号合并。已有微信或手机号绑定冲突会拒绝；不能通过客户端资料更改验证状态。认证器启动每次检查 `consumer_phone_number`、`consumer_phone_verified`、`consumer_identity_revision`、`consumer_last_operation_id`、`consumer_last_operation_action`、`consumer_last_operation_at` 共六项在 Keycloak User Profile 为仅管理员可写，配置不安全时拒绝登录。令牌由服务端认证会话 notes 产生 `phone_number`、布尔 `phone_number_verified=true`、正整数 `consumer_identity_revision`、真实 `auth_time` 与 `amr:["sms"]` 或 `amr:["wechat"]`，并与当前用户手机号及版本核对。陈旧消费者会话直接拒绝签发，不降级为无消费者标记令牌。短信和微信都不是 MFA，不能用于管理端 MFA 绕过。

## 账号安全与恢复

App 继续使用系统浏览器中的正常 OIDC 授权码 + PKCE，不新增客户端密码或身份管理权限。固定入口参数为 `family_account_action`、UUIDv4 `family_account_operation`；已登录操作另带 `family_account_actor` 和正整数 `family_account_revision` 作为预期范围。这些参数不能代替身份验证，服务器在认证会话首次进入时固定操作、账号、原手机号和版本，表单不能覆盖。

|操作|身份服务内的实际证明与结果|
|---|---|
|`CHANGE_PHONE`|用户输入当前手机号且必须与原账号一致 → 原号短信 → 新号短信 → 同一用户原子更新用户名和受保护手机号|
|`RECOVER_PHONE`|服务端交换微信 code → 必须找到既有绑定原用户 → 新号短信 → 同一用户换号；未知微信拒绝，不新建账号、不合并账号。带预期账号/版本时必须全部一致|
|`BIND_WECHAT`|服务端交换原生微信 code + 当前手机号短信 → 绑定该原用户；拒绝微信已属另一账号或覆盖另一微信|
|`UNBIND_WECHAT`|当前手机号短信 → 移除当前 AppID 的微信绑定；保留已验证手机号登录|

每次成功操作增加身份版本并在同一事务保存操作编号、类型与时间；家庭、孩子、设备和订单仍使用原 Keycloak subject。操作期限从第一次进入固定为 30 分钟；原号证明和恢复用微信证明各为 5 分钟，不通过重复渲染延长。验证码按登录、操作编号、类型、账号、版本和阶段隔离，错误/耗尽验证码不获取数据库全局锁。成功消费后若数据库锁或最终版本核对失败，需要重新验证。

成功操作撤销原用户在线与离线会话，再签发当前新会话。已经签出的旧 JWT 必须由业务端通过当前身份接口核验，不能只依赖会话注销、客户端标志或 JWT 验签。未知结果、取消及回调丢失时查询真实当前状态，不复用已消费验证码铸造新会话；旧号不可用且没有绑定微信的用户需通过支持流程处理，不能仅凭新手机号认领原账号。

`GET /realms/{realm}/consumer-account/status` 仅接受 `ai-manager-parent` 的有效 Bearer 和在线客户端会话，并核对当前启用用户、手机号、会话版本及令牌版本。返回当前 subject、掩码手机号、真实微信绑定、正整数身份版本、可用操作和最近操作回执；不返回 openid、完整手机号、验证码或供应商响应。旧账号无版本/旧会话无版本仅允许当前版本仍为 1 且无操作回执的兼容状态。响应为 `Cache-Control: no-store`；过期/陈旧身份返回 401 `ACCOUNT_SESSION_STALE`，服务未开放返回 503 `ACCOUNT_SECURITY_UNAVAILABLE`。

REST SPI 使用空 `META-INF/beans.xml` 与 `@Provider` 注册。资源类提供安全的公共无参构造，避免 Keycloak/Quarkus CDI 将配置 Map 误判为注入依赖；此构造不读取秘密、不接数据库且保持关闭。真实 realm 子资源仍由工厂显式传入当前 KeycloakSession 和受限配置。必须同时验证 `kc.sh build`/augmentation 和实际子资源请求，不能只以 Java 编译或 JAR 资源存在作为运行证明。

认证 SPI 与 REST SPI 使用同一个固定配置加载器，可直接读取已知的 `*_FILE` 秘密项，每个文件最多 8192 字节、单行 UTF-8；不会读取任意名称的环境文件。文件缺失、格式错误或过大时关闭所有消费者入口，HMAC 少于 32 字节不宣称可用。容器入口继续保留原来的秘密文件读取，不打印秘密内容。

**日志要求：** 网关、WAF、浏览器诊断与 APM 不记录 `/identity/` 的请求查询字符串或表单正文；短期微信 code 会经过 OIDC 授权 URL，出站微信 token 请求也含服务端 secret/code。阿里云 SendSms 按官方 RPC 元数据将手机号及模板验证码放在出站查询参数中，因此供应商出站 URL 同样禁止日志/APM 采集。不能启用 HTTP 请求/响应正文及 URL 调试日志。本扩展不记录手机号、验证码、授权码、密钥或供应商响应正文。

## 防滥用与集群

验证码为安全随机 6 位数字，仅向已批准供应商发送；在 Keycloak `SingleUseObjectProvider` 中只保存绑定认证会话/手机号的 HMAC-SHA256 摘要、过期时间、剩余次数。5 分钟有效，最多 5 次尝试，原子 remove 成功仅一次；错误尝试重入剩余次数，验证中并发请求失败。每手机号 60 秒间隔、每天 10 次；每可信客户端 IP 每小时 50 次。供应商失败也保留发送限额，避免错误重试产生短信轰炸。反向代理地址配置必须正确，不能信任任意客户端伪造的转发头；生产另需 WAF/短信成本告警。

Keycloak single-use 对象实现必须满足跨节点原子 `remove`/`putIfAbsent`，标准 Keycloak 集群提供此契约。短信限额数据为临时缓存，重启/缓存丢失后限额会重置；生产必须同时配置供应商每日预算、WAF 限流及告警，不能把缓存额度作为唯一计费控制。轮换 HMAC 密钥使尚未验证验证码失效，需所有节点同时切换。

账号唯一性使用 Keycloak 26.8 的真实 JPA `RealmEntity` 悲观写锁；原手机号注册、首次微信绑定、已绑定微信登录及新账号安全提交共用该短事务边界。微信交换和短信发送均在锁外。锁后手机号用户名/微信归属采用悲观锁定的当前读，用户与全部属性集合强制刷新，不能把 MySQL RR 快照、JPA 一级缓存或跨节点用户缓存当作当前事实。修改通过缓存感知的 Keycloak 模型广播失效；不能取得 JPA 锁时失败关闭。没有使用缓存租约保护身份唯一性，不依赖进程在租约时间内恢复。

该首发方案会串行同一 realm 的消费者身份提交，适合低流量首发；扩大流量前应评估独立的持久唯一身份 claim 与分片锁。锁等待提示不保证所有数据库驱动严格实现同一时限；上线须核验目标 MySQL/Keycloak 组合、事务超时及故障恢复。没有增加或执行任何已有数据库迁移。

## 验证与待验收

本地测试使用真实签名/HMAC/随机生成/原子消费实现及严格假 HTTP 边界，既不发送短信也不请求真实微信账号。覆盖官方阿里云 V3 已知签名值、发信目的地址/编码、服务未配置和错误、过期/尝试/并发消费、微信返回解析、绑定冲突、保护资料和实际短信注册会话 claims。Android 独立 state 测试覆盖回调替换、重放、超时和取消。

2026-10-15 历史本地验证：18 项 Java 测试与扩展 JAR 构建通过，Android state 的 5 项独立检查通过。额外使用没有网络和宿主端口的临时 Keycloak 26.8.0 容器加载当时的两项 SPI、导入生成 realm，真实渲染消费者服务关闭页面及原管理端密码登录表单；随后删除临时容器。日志位于 `.local/family-launch-20261015/identity-verify-final.log`、`identity-native-green.log`、`identity-runtime-http.log`。此历史运行不覆盖本轮新增 REST SPI、六项资料保护及数据库悲观锁，不能替代本轮运行验收。没有发送短信、请求真实微信账号或更改现有部署。

2026-10-16 账号安全本地验证使用真实 OTP/HMAC/消费和账号流程代码、Keycloak 26.8 JAR 编译，以及受控的用户/JPA/供应商边界。覆盖四条流程、原号输入固定、冲突拒绝、预期账号、过期不延长、用途隔离、陈旧会话、JPA 一级缓存属性集合、错误验证码不占全局锁、固定秘密文件读取及 SPI 资源打包；结果见 `.local/family-p0-account-security-20261016/identity-final-verify.log`。未启动 Docker、未连接已有身份库，真实 MySQL JPA 锁等待/回滚、多节点缓存、正式短信、微信及完整 OIDC 回调仍需发布前验收。

仍需在已审批环境真实验证：受保护资料 API 拒绝用户写入、完整 OIDC/刷新/退出/管理员 OTP 回归、多节点缓存语义、正式中国手机号送达、签名真机微信授权和绑定冲突。没有供应商资质/短信模板/微信移动应用审核/发布证书时不能开放这些入口或宣称上线成功。

来源：[Keycloak Authentication SPI](https://www.keycloak.org/docs/latest/server_development/index.html#_auth_spi)、[Keycloak 26.8 SingleUseObjectProvider 原子契约](https://github.com/keycloak/keycloak/blob/26.8.0/server-spi/src/main/java/org/keycloak/models/SingleUseObjectProvider.java)、[Aliyun SendSms](https://help.aliyun.com/zh/sms/developer-reference/api-dysmsapi-2017-05-25-sendsms)、[阿里云 V3 签名与已知值](https://www.alibabacloud.com/help/en/sdk/product-overview/v3-request-structure-and-signature)、[微信移动应用登录指南](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/WeChat_Login/Development_Guide.html)。本环境微信官方网页无法抓取；Android SDK 编译/API 检查和真实微信验收分别记录，不以网页可访问性替代资质。
