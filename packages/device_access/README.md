# Device access-window reception

## 设备发起申请（V23）

`DeviceAccessTransport` 提供 `submissionOptions`、`createSubmission`、`submissions`、`submission` 和 `cancelSubmission`，返回严格解析的 `AccessSubmission`。沿用现有设备 opaque 凭证，不构造儿童成员令牌。详情、列表和变更需传入当前 `AccessDeviceContext`，提交必须提供稳定的原始幂等键，取消还需原版本。

`AccessSubmissionInput` 只包含策略/版本/应用/规则、时长与可选理由。宿主必须在发送前安全持久化原输入与键，并在断网、超时、异常成功响应或 `outcomeUnknown` 后继续使用原值确认结果。SDK 不自动重发，也不代替宿主的持久申请队列。分页选项可能为空但仍有下一游标。

`AccessSubmissionJournal` 现提供上述持久队列基础：使用宿主加密数据库与完整 `DeviceAccessScope`，先 `prepareCreate/prepareCancel`，发送前 `markSending`，确认后 `complete`。同一范围只允许一条未解决变更；`inspect` 和重建 journal 不自动发请求。UNKNOWN 不可直接删除，只有未发送或明确拒绝的操作可以显式放弃。事实缓存有界并保护版本和原期限。详见[持久日志与儿童宿主契约](../../docs/child-request-workflow-contract.md)；过期键恢复已由 `recoverSubmission` / `recoverCancellation` 提供，Android 儿童会话和规则页界面现已接入，详见[申请交互契约](../../docs/child-request-ui-contract.md)。恢复沿用原正文/原键/原取消版本，不续期、不创建新变更；404 `ACCESS_RECOVERY_UNAVAILABLE` 仍是未知结果，不能删除原操作。只在当前授权范围及原服务端引用仍可读取时恢复，不保证无限期离线或数据丢失后的成功。

批准事实不是系统放行：`systemEnforced` 始终为 false，实际签名交付继续使用原有协议。理由和凭证不写入异常文字。接口、身份隔离、错误流程及迁移发布限制见[申请契约](../../docs/device-access-submission-contract.md)。

独立 Dart 审批配置接收组件，使用 `jose` 验证 ES256、`sembast` 保存事务、`crypto` 校验本地内容摘要。对应后端 V15/V16 协议。配置始终为 `CONFIGURE_ONLY`、`quotaEffect=UNCHANGED`、`systemEnforced=false`。

## 宿主接入

1. 通过已认证通道预置完整 issuer/tenant/subject/device/registration 和公钥环，创建 `AccessWindowVerifier`。必须提供可信毫秒时钟；系统墙钟本身不能保证不可回拨。验证器不下载 JWS 声明的密钥。
2. 打开受宿主保护的 Sembast 数据库，创建 `AccessWindowJournal`。必须提供同步、无副作用的 `baselineMatches`，核对当前已验证基础策略版本、应用和全部规则是否匹配。不要固定返回 `true`，不要在回调内请求网络或修改数据库。
3. 从已认证设备接口取得文档，调用 `AccessDocument.fromJson`，再 `journal.accept(document)`。每次接收都重新验证原始 JWS 与外层元数据。只有返回后才能发送返回值，或消费 `pendingReceipts()`；失败异常只作为本地诊断。
4. 使用回执 `requestId` 拼接该申请的回执路径，POST `receipt.toJson()`。请求必须由当前设备 opaque 凭据认证。解析成功响应为 `AccessReceiptAcknowledgement` 并调用 `acknowledge`。响应 `current=false` 可确认其对应历史回执，不能确认新尝试。
5. 每次重启、时间/基础策略/信任环变化后调用 `restore()`。结果只包含当前有效的配置输入，宿主必须在原截止时间重新检查并停止使用缓存；异常时关闭相关配置。返回值不是系统解锁证据。

数据库生命周期由宿主管理，journal 不关闭外部传入的数据库。多个 journal 可共享一个数据库对象；命名空间绑定完整设备范围。宿主更换注册后不得把旧命名空间迁移到新身份。

## HTTP 自动同步

`DeviceAccessTransport` 使用 `http` 1.6、AbortableRequest 和 `http_parser`。构造时提供显式 HTTPS `apiRoot`（以 `/api/v1` 结尾）和异步 `credential` 读取函数。每次请求读取当前设备凭据，不缓存轮换前的值；拒绝 JWT、URL 内凭据、外站明文 HTTP 和重定向。仅本机测试可显式启用 `allowLoopbackHttp`。注入的 HTTP client 由调用者关闭；transport.close 取消自身请求，包括仍在等待凭据的请求。

`DeviceAccessSynchronizer(journal: ..., transport: ...)` 由宿主前台、后台任务或可信通知调用 `synchronize()`。同一实例合并并发触发，不创建无限轮询计时器。默认每次最多 5 页，每页 10 个申请、128 次回执 POST；参数均有上限。每页逐项持久处理后，通过 generation/cursor 比较交换保存续点。崩溃重放当前页，完整扫描结束后重置到首页；旧申请随后发生的撤回仍可被下一轮扫描发现。UUID 游标不是增量变更水位。

- 先重放持久回执，再下载当前文档。严格核对列表、外层元数据和签名载荷的申请/版本/期限；列表读取后发生的更高撤回版本可立即接收。
- 成功 ACK 才删除对应队列项。POST 超时、5xx 或响应格式不明保留队列并标记 `outcomeUnknown`；不透明重试或推断已提交。一次运行内相同回执只发送一次；已确认的重复接收可复用同次 ACK 清除重复排队。
- 临时拒收只有在原截止仍有效、可信时间达到 retryAfter、当前基础匹配、实际 journal 可写且有队列空间后才请求后继尝试。REMOVE 恢复不依赖原批准期限或基础仍存在。新尝试或重试竞争都必须重新读取当前文档，不从旧响应推测授权。
- 单条非法文档和历史回执冲突转为明确 `issues`，允许本轮继续取得其他撤回；身份失败立即中止，宿主需停用该注册的全部缓存配置。宿主必须对 issues 对应申请停止使用缓存配置，不能忽略诊断后直接将 `restore()` 的结果用于放行。此包只提供配置，当前没有原生放行逻辑。
- `hasMore` 只表示这一轮扫描还没结束。`pendingReceipts` 表示仍有待确认回执，不能因为 hasMore=false 就宣布全部完成。诊断携带 HTTP 状态、是否可重试、结果是否未知和 Retry-After；宿主保留这些提示并管理失败次数。抛出的瞬态传输错误可使用 `retryDelay` 获取有抖动的有界退避；401/403、协议冲突不能盲目重试。
- 每轮仍需再次调用以发现后续变更；后台周期、网络恢复事件、安全时间与操作系统任务生命周期由儿童宿主接入。关闭 synchronizer 不删除文件库、水位或队列。

## 恢复规则

- 相同审批版本必须是同一份原始 JWS。同一申请后继版本不得改变基础、应用、规则或原期限；撤回后不能通过更高 UPSERT 复活。
- 交付尝试编号为 1～10，与审批版本独立。同一尝试的拒收是终态，恢复必须使用后端签发的新尝试；重试不延长期限。
- 文档/撤回水位、已观察时间和终态回执同一事务保存。重复接收重新排入原回执；旧尝试不能覆盖新尝试。没有任意清除水位的接口。
- 缺基础和首次过期可保存 `REJECTED`，分别为 `BASELINE_MISSING`、`EXPIRED`。无效签名不会产生从其载荷推导的回执。
- 服务端已拒绝的尝试沿用其拒绝原因；服务端已保存而本地验证失败时只产生本地诊断，避免矛盾终态。有效 REMOVE 即使晚到、时钟异常或服务端旧尝试拒收，也保存撤回水位；其回执仍遵守原尝试终态。
- 每次恢复重新验签、核对当前基础及原期限。观察到过期后保存时间下限，时钟回拨不能复活批准。有效撤回不依赖原批准截止时间。
- 默认最多 256 个申请水位、128 个待发送回执；可显式设置，分别上限 4096/1024。容量不足返回 `STORAGE_CAPACITY`，事务整体回滚，宿主需停止使用相关缓存并处理队列积压。不能以删除未过期/已撤回水位腾容量。
- `STORED` 只说明配置事务已提交，`DEVICE_REPORT_UNVERIFIED` 不代表云端证实设备执行。

## 诊断与边界

`SIGNATURE_INVALID`、`WRONG_DEVICE`、`UNSUPPORTED_SCHEMA`、`TRANSPORT_INVALID/MISMATCH`：输入或信任不匹配；不自动重试同一错误内容。`STALE_APPROVAL/ATTEMPT`：旧内容；读取当前文档。`APPROVAL_CONFLICT/GRANT_CHANGED/DELIVERY_CONFLICT`：关联或终态冲突；停止该同步流并诊断。`CLOCK_UNTRUSTED`、`BASELINE_UNAVAILABLE`、`STORAGE_FAILURE/CAPACITY`：本地恢复失败；不能上报保存成功。异常文本不包含原文档或原始异常。

该组件已有可触发的有界 HTTP 同步器，尚无操作系统后台任务、Android/TV 原生执行或儿童页面。Sembast 不提供静态加密、硬件防回滚或设备可信计时；摘要用于损坏检测，不抵御能重写整个数据库的攻击者。可信时间、公钥更新、安全存储、注册清理与有界水位保留需要宿主实现。多个数据库副本不能作为同一注册的独立写入者。

## 本地检查

```powershell
dart pub get --offline
dart analyze
dart test --concurrency=1
dart test --platform chrome test/verifier_test.dart test/journal_portable_test.dart test/page_test.dart
./tool/verify-nimbus.ps1 -BackendJar .local/runtime/backend.jar
```

最后一条脚本的 JAR 路径以仓库根为基准，也可传绝对路径。可通过 `-JavaCommand`、`-DartCommand` 指定运行时；Chrome 可通过 `CHROME_EXECUTABLE` 配置。系统临时盘空间不足时为当前检查进程设置项目 D 盘的 `TEMP`/`TMP`。

Nimbus 检查使用已构建后端的真实 `Envelope/Document/Receipt` 记录、Jackson 和 `ConfigurationSigner.signAccessWindow`。反射仅用于测试中构造私有记录；字段变化直接失败。临时测试私钥只存在受限工作目录，生成结束即删除。该检查证明序列化、签名与接收兼容，不代表真实 HTTP、MySQL、OTP 或真机执行验收。

真实后端 HTTP 联调是独立的 `DeviceAccessHttpInteropTest`，要求 Maven 属性 `device.dart.command` 指向 Dart 可执行文件、`device.access.package` 指向此包绝对路径。启动随机 loopback 端口，在 H2 隔离库中通过真实业务 API 产生两个批准，六次独立 Dart 进程验证缺基础拒收、自动恢复、确认中断后重启、撤回、到期和 opaque 凭据撤销。成人 JWT/MFA 声明、激活设备、基础匹配和可信时间是明确测试夹具；不代表真实 OIDC/OTP、MySQL、新设备证明、后台保活或原生执行。未传属性时 JUnit 会跳过，该跳过不能计为通过。
