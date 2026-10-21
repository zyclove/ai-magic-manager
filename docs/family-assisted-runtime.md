# FAMILY Android 应用辅助运行时

此实现用于普通 Android 个人设备，经设备使用者明确同意后，用使用情况访问与无障碍服务帮助执行家庭安排。它是可被系统停止的应用层辅助，不是 DPC、设备所有者、系统应用锁定、防卸载或防强制停止；所有状态与回执的 `systemEnforced` 始终为 `false`。

## 启用与签名边界

既有认领、公钥与注册协议保持原路径。`SignedRuleReceiver` 先从 Flutter journal 恢复并验签，再经过 `AndroidAssistedRuntime.acceptVerified` 重新验签 compact JWS，才交给原生。已授权的原生服务也可独立拉取配置。两条入口均使用安装包构建时固定的 `CHILD_API_ROOT`、`CONFIGURATION_ISSUER`、`CONFIGURATION_JWKS`；原生再次核验 ES256 签名、类型、租户、设备、注册、版本与序号。通道不接收可执行的无签名规则，也不接收调用者提供的信任密钥或远程可修改的 API 地址。

普通 `CONFIGURE_ONLY` 配置不能启用辅助。服务器必须在已签名 document 中明确加入以下扩展；原有文档字段仍需保留：

```json
{
  "familyAssistance": {
    "schemaVersion": 1,
    "mode": "FAMILY_ASSISTED",
    "enabled": true,
    "dailyAllowanceSeconds": 3600,
    "timeZoneId": "Asia/Shanghai",
    "meteredPackages": ["com.example.game"],
    "allowedWindows": [
      {"daysOfWeek": [1, 2, 3, 4, 5], "startMinute": 1020, "endMinute": 1200}
    ],
    "validUntil": 1792620000000,
    "exceptionUntil": null
  }
}
```

示例包名与时间仅用于说明，不能直接作为生产安排。额度是每台设备的目标应用合计额度，范围为 0–86400 秒；0 表示无额度。空可用时段表示不限时段，空目标列表无执行能力。星期按周一 1 至周日 7；首发服务端开始、结束分钟范围为 0–1439，开始包含、结束不包含，跨午夜窗口归属于开始日。有效期不超过签发后 7 天，临时放行不超过该有效期。`enabled:false` 是已签停用；不能继续保留旧限制。

原生同时要求应用内知情同意、系统使用情况授权和实际连接的无障碍服务。初次配置或注册身份变化会关闭本机同意，需重新选择。关闭本机同意始终可用。权限不能由应用自动授予。

## 家庭临时申请

辅助面板的申请入口使用独立家庭接口，不依赖通用受管规则申请的候选列表。`POST /api/v1/device-api/family/access-requests` 仅发送原 UUID、60–3600 秒的申请时长及最多 300 字的可选说明；`GET /api/v1/device-api/family/access-requests/{requestId}` 核对同一申请。

提交前使用既有 Android 加密请求存储与持久提交/读回屏障保存 UUID、原始请求体和注册作用域，使用独立 `family-access-v1` 哈希命名空间。设备退出会通过已有请求缓存清理规则删除它。丢失响应、进程重建或网络失败后不自动创建新申请：先按 UUID GET；只有明确的 404 和使用者主动重试才重发相同 POST。未知查询结果保留原申请。操作串行，前后台代际及身份切换会拒绝旧响应与旧确认框；不把说明或凭据写入日志。

页面区分“云端已收到”“云端已批准”和本机执行状态。批准回执只触发原有签名配置同步，再读取真实原生状态；不会把无签名的批准 JSON 直接转成原生例外。服务器必须重新签发包含原始绝对 `exceptionUntil` 的家庭安排。传输重新签发时，已经过去的绝对例外不影响基础额度/时段配置的恢复，也绝不延长放行。家庭功能 403 不会撤销仍有效的其他设备功能凭据，认证 401 才处理被拒绝的原凭据。

## 观察、计时与恢复

无障碍仅接收 `TYPE_WINDOW_STATE_CHANGED`，读取包名。`canRetrieveWindowContent=false`，不读取节点、页面文字、聊天、输入、截图或通知。使用情况访问仅查询包名及前后台事件，与无障碍前台包名交叉核对，不采集页面内容。

原生每 5 秒及窗口事件发生时核对规则，在应用私有偏好中持久保存当天已用时长、墙钟、单调时钟、启动计数、前次目标包名、策略序号和累计时钟锚点。只有持久写入成功后才可执行限制决定；进程内的实际 HOME 返回结果另行记录。额度跨同日版本更新保留，跨日按已观察单调时长切分。临时放行不延长到期时间，也不重置已用时长。

时间倒退、累计墙钟漂移超过 2 秒、重启、观察中断超过 15 秒、数据损坏、权限缺失或过期配置都暂停辅助并返回明确健康状态。不会用未知运行时间继续阻止应用。恢复需校准时间、恢复系统授权，由监护人重新发布更高 `sourceSequence` 的签名安排，再由原生后台或儿童端前台同步；原序号不能清除时间异常。断网时，连续且可信的本机观察可继续执行尚未过期的缓存规则。

电话、默认与系统拨号器、紧急电话、系统设置、权限控制器、桌面以及本应用恢复入口被排除。可用系统入口还通过系统解析补充厂商包名。受控应用额度耗尽或不在允许时段时，辅助服务调用 Android HOME 动作返回桌面。动作失败会报告失败，不伪造成功。系统可能停止辅助，厂商差异仍需实机核对。

已确认的设备退出先持久清除原生辅助，再删除既有配置与缓存；清除失败不报告退出成功。普通关闭 Flutter 页面不会删除原生缓存或重置额度。

## 回执与试用依据

儿童端在前台核对本机状态，以及原生后台同步时，向 `POST /api/v1/device-api/family/assisted-execution-reports` 发送设备凭据认证的白名单数据：当前租户/设备/注册、策略/版本/序号、回执序号、观察时间、健康状态、决定、剩余额度、同意及权限状态；以及原生 `Build` 提供的厂商、型号、API 等级和 `interventionStatus`。不上传包名、页面文字或输入数据。发送前重查活动注册，拒绝跨身份与超过 5 分钟的快照；认证 401 会持久停用被拒绝凭据并清除辅助。通用心跳、凭据及配置接口的 403 也可表示注册已失效，按认证失效处理；家庭报告接口的功能 403 不会停用仍有效的机构设备凭据。

`HOME_RETURNED` 只来自实际 `performGlobalAction(HOME)==true`，绑定当前策略、版本、源序号和注册，且只在 5 分钟内有效。Android 返回 true 表示框架接受 HOME 动作；它不是硬件证明或实机长期稳定性证明。`ACTION_FAILED` 来自实际 false。无动作时为 `NOT_REQUIRED`。重启不会恢复内存中的成功动作证据。回执证据级别仍是 `AGENT_REPORTED_UNVERIFIED`，系统状态不能由展示文案升级。

无回执、过期回执和仅有注册/配置保存不代表已激活，更不能启动试用。服务器的受支持型号审核、销售开关与试用激活判定独立执行。

## 原生后台同步与同一身份协调

`FamilyAccessibilityService` 连接后启动自己的单线程执行器，每轮完成后间隔 30 秒再尝试；Activity、Flutter 页面及 Flutter engine 销毁不拥有该执行器。服务解绑或销毁会取消执行器。[onInterrupt 只表示反馈被中断](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService#onInterrupt())，因此仅清除瞬时前台包名，不将它误作解绑而永久停止同步。每轮先恢复或推进凭据意图，再发送可重放的心跳，核对使用统计授权及批次，拉取至多 3 页签名配置并上传真实原生健康快照。心跳序号与原始请求体在发送前持久保存；丢失响应后重放同一序号，不伪造更新的权限事实。

原生使用已安装的 `flutter_secure_storage` 10.0.0 的初始化、加密及迁移 API，读取同一个 `aimanager_identity_v1` / `aimanager_identity_record`。显式配置与 Dart `AndroidOptions` 一致的 RSA-OAEP 密钥包装、AES-GCM 数据加密、`resetOnError:false` 和保留数据的迁移，避免依赖 Java SDK 不同的算法默认值。身份凭据仍只有一个加密记录，不另存明文、第二份 bearer 或另设原生凭据库。

所有生产身份读写、轮换和删除通过同一进程内原生锁；写入同时比较精确原记录，网络工作另持有内存 epoch。Flutter manager 将每次读出的 state 绑定其原始序列化记录，CAS 冲突后重新读取并报 `IDENTITY_STATE_CONFLICT`，不重试旧变更。网络请求不持锁；旧响应、旧 401、退出后的响应与服务重建后的旧日志均不得覆盖新状态。加密 SDK 的数据、配置和包装密钥均有同步 commit 与读回屏障。原生主线程仅使用已确认且可即时取得的身份快照，不等待加密初始化；存储结果不确定时暂停执行。

后台在凭据过期前主动轮换：持久保存 `rotationRequested` 后请求新凭据，保存 `rotationPending` 后才进入 `activationUncertain` 并用 pending bearer 激活。激活响应丢失会重放原 pending bearer，不把未确认 bearer 当普通活动凭据；超过原 `activateBefore` 后也只允许恢复已开始的激活，绝不修改绝对截止。未开始且窗口已过的轮换、或 rotate 响应丢失，则使用仍有效的原 bearer 取消原轮换后恢复。短期凭据按其剩余寿命安排下次轮换，避免每轮重新轮换。断网超过凭据有效期且无法恢复时停止云端请求，不生成或换用另一个注册身份。

独立原生配置日志仅存签名文档、作用域、游标和 `STORED` 回执，采用同一身份锁及精确日志比对。签名、传输 ID/游标/有效期、同策略版本、源序号和容量验证全部通过后，先持久保存，再交给运行时及发送回执。ACK 丢失保留原 UUID 和 envelope hash；非家庭的合法 `CONFIGURE_ONLY` 文档可保存和回执，但不能启用家庭辅助。前台旧配置不会回退已经更新的原生规则。身份变化、清理和认证失效在锁内清除原生规则及后台日志。

家长批准后，原生可通过上述配置拉取接收包含原始绝对 `exceptionUntil` 的新签名安排，儿童端无需保持申请页打开。无签名批准 JSON 仍不能直接放行，重试或重启不会延长例外。

原生网络仅允许 APK 固定 HTTPS origin 与固定设备路由，拒绝重定向；连接与读取各有 5 秒超时，并用 15 秒整体截止主动断开包含写入阶段的请求。配置响应上限 2 MiB，其他响应上限 64 KiB；使用统计请求体上限 1 MiB，其他请求体上限 64 KiB。错误体仅保留固定白名单代码，并支持服务器的 `application/problem+json` 状态核验，不传播服务器正文。空或无效的构建 origin 不启动原生网络同步；调试明文回环地址也不会获得原生后台网络能力。

## 后台成长报告批次

后台使用统计与 Flutter 复用同一加密 `observation_record`、schema 1/2、`usageSequence` 和 `pendingUsage`，没有额外 collector、独立随机序号或第二份敏感日志。两端读取原始记录并 CAS 保存，原生还绑定当前身份 epoch。前台清单/权限观察字段保持原 schema，在授权变化或明确撤销时按既有规则清除待传数据；普通并发变化只让该轮停止，不覆盖另一端的新日志。退出和认证失效会清除该记录，清理阶段允许对精确原记录 CAS 删除，禁止旧任务写回非空内容。

每轮先检查系统使用情况授权、当前 Android 用户及用户解锁状态，再向固定 `GET observation-settings` 核对同一设备、注册、授权版本和 `usageEnabled`。持久保存实时授权后才能查询 UsageStats。新采样以成功上传的持久时间为依据，至少间隔 15 分钟；未知结果只重放原批次，不重新采样。查询 Android 本地当天开始至当前时刻的 `INTERVAL_DAILY`，仅纳入当前用户可见启动应用；保留系统返回的桶起止时间和前台聚合时长，不把日桶伪称为精确的一小时或全设备完整覆盖。上传为已有 `ANDROID_USAGE_STATS`、profile、查询窗口、观察时刻、时区及最多 500 条应用聚合，不采集页面、聊天、输入或截图。

同一 `usageSequence`、report UUID、授权版本及完整窗口先加密持久保存，再次核对系统授权后才 `POST usage-observations`。ACK 必须绑定原注册、序号和 UUID；丢失响应、重启、429 或网络异常保留原批次。旧注册/旧日志的迟到 ACK 不得推进日志。云端授权版本回退被拒绝；版本改变、系统撤权、明确 `OBSERVATION_NOT_AUTHORIZED` 或 `OBSERVATION_AUTHORIZATION_CHANGED` 会删除敏感待传批次，保留序号而不偷换注册。前者是功能拒绝，不撤销仍有效的其他设备功能身份；未识别的通用注册 403 与 401 按认证失效处理。后台成长报告仍受服务连接、Doze、持续断网和强制停止边界影响。

这属于 Android 允许执行时的尽力同步，不是准时投递或后台常驻保证。官方说明 [Doze 和 App Standby 会延后网络](https://developer.android.com/training/monitoring-device-state/doze-standby)，且 [系统杀进程不保证调用 onDestroy](https://developer.android.com/guide/components/activities/process-lifecycle)。未新增后台权限、唤醒锁、省电豁免、自动授权或用 WorkManager 周期任务承诺限制时刻。重启后依赖 Android 重新连接仍获授权的服务；强制停止、撤权、厂商后台限制或持续断网仍会暂停同步，恢复后从持久意图继续。临时批准在这些情况下可能晚到或已过期，不能延长其原始截止。

## 验证与发售边界

本轮最新验证位于 `.local/family-p0-next/`：[后台同步验证索引](../.local/family-p0-next/child-background-verification.json)。儿童端Flutter223项、身份包47项、观察包19项、纯JVM80项、Android原生81项通过，静态分析无问题；包含最终Dart/原生的debug构建成功。137个生产源文件构建后摘要一致。APK与SHA-256见 [本轮交付](family-p0-background-seats-expiry.md)；以下旧数字作为首轮历史基线保留。

测试覆盖签名、作用域、显式停用、有效期、额度、日切、跨夜时段、临时放行、单调时钟、重启与观察中断、成功动作绑定、知情同意、缺失/陈旧本机状态、设备认证上报及退出清除。完整儿童端 Flutter 测试、静态分析和 Android debug 构建证据保存于 `.local/family-launch-20261015`。可通过 `apps/child/tool/run_assisted_native_tests.ps1` 使用已缓存 Kotlin/JVM 依赖重复纯原生测试。

2026-10-15 会话恢复后重新验证：完整儿童端 Flutter 回归 214 项通过（包含家庭申请与同期电视交互测试）；家庭申请的 13 项定向回归通过；Kotlin/JVM 39 项通过（包含过期绝对放行时间重新签发的回归）；`flutter analyze --no-pub` 无问题；包含最新 Dart 的 Android `testDebugUnitTest` 与 `assembleDebug` 构建通过。最新 APK 的路径、SHA-256、原生测试报告和日志索引记录于 `.local/family-launch-20261015/child-assisted-verification.json`。回归先验证缺失实现/实际缺陷失败，再验证实现通过；日志中带 `red` 的文件是刻意保留的修复前证据，不是最终验收结果。构建仍有既有 Gradle/第三方弃用提示，不属于实机兼容证明。

2026-10-15 后续后台同步核验：身份包 47 项、观察包 19 项、完整儿童端 Flutter 223 项、纯 Kotlin/JVM 80 项以及 Android app 原生 81 项全部通过，静态分析无问题。最终构建强制重新执行 Dart 编译与原生测试，`:app:testDebugUnitTest :app:assembleDebug --offline` 成功。81 项包含实际 FlutterSecureStorageConfig 的 OAEP/AES-GCM/迁移契约测试，80 项独立 JVM 测试可用既有脚本重复运行。最新源码清单、源码聚合哈希、APK SHA-256、JUnit 时间和日志索引位于 `.local/family-p0-next/child-background-verification.json`；该 debug 包未注入生产 API origin 或 ES256 信任环，不构成生产网络互通或实机授权证据。前一阶段记录保留为历史验证。

本次 `adb devices -l` 无附加设备。没有完成真实 Android 手动授权、前台应用返回桌面、电话/设置/桌面恢复、断网、重启、强制停止与厂商兼容验证；没有 72 小时稳定性证明。编译和单元测试不能代替这些验收。受支持型号记录与销售开关必须保持未就绪，直到实机证据与 72 小时验证满足发布要求。
