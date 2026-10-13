# Android 1.0.0 HTTPS 退出清理验收

本轮验收入口用于新建的专用 Android API34 调试模拟器。使用临时 Spring HTTPS 服务、独立空白 H2 数据库、临时签名密钥和测试证书；当前运行的管理台与业务数据库保持独立。当前状态：负控和四个成功阶段已全部运行通过，后端验收1项实际执行、0跳过；子端178项、宿主12项通过，静态分析通过。

## 流程与判定

单个 APK 从应用私有文件读取阶段输入；每次启动后立即删除输入文件。注册票据和配对码只在短时私有交接中使用，不进入命令行、APK 常量、公开驱动报告或版本库。

1. negative：空白安装进入重启核对阶段，必须明确因缺少前序种子失败；任意连接或驱动错误不能代替该负控。
2. enroll：使用实际 AndroidKeyStore 密钥、原生加密身份存储和真实 HTTPS 注册接口；管理员通过已有测试身份夹具确认配对。
3. active：新进程执行真实心跳并确认注册激活，写入真实配置与加密访问数据库、各自单个 `~` 恢复文件及已知加密缓存，然后关闭数据库。
4. cleanup：管理员创建真实退出预览和操作；普通设备凭据必须返回401。生产 `ChildCleanupRunner` 使用原密钥读取服务端签名命令并发送两个回执，清理本应用缓存，最终删除身份和原密钥。
5. verify：再次启动，核对原身份和缓存仍不存在、原密钥不能签名、最终已确认日志仍存在；空身份恢复入口返回无操作，日志保留。

四个成功阶段均先验证默认 TLS 信任拒绝临时证书，严格要求 HandshakeException；随后将同一公有 DER 证书转换为 PEM 格式后加入本测试进程的信任。不得使用接受任意证书的回调。测试证书必须与服务端 PKCS12 中唯一密钥证书一致，具有127.0.0.1 SAN且处于有效期。

后端直接核对真实数据库的设备撤销、凭据停用、RECEIVED与AGENT_DATA_CLEARED两条回执、命令哈希、持久响应和CLEANUP_REPORTED状态。结果仍显示DEVICE_REPORT_UNVERIFIED，服务端回执不等于独立物理擦除证明。

宿主要求精确 AVD 名、emulator序列号、API34、主用户0，以及安装前由官方aapt确认的儿童端debug包。所有阶段使用同一APK和安装UID/首次安装时间，并具有不同PID。只使用本轮拥有的端口映射；失败保留诊断，不卸载、清空或自动重跑已产生状态的阶段。

## 执行入口

构建 `apps/child/integration_test/cleanup_https_test.dart` 为单个debug APK。宿主回归在 `apps/child/tool` 运行 `python -m unittest test_run_cleanup_https_android test_run_cleanup_android`。

后端 `AndroidCleanupHttpsJourneyTest` 默认禁用，需显式提供这些系统属性：

- `device.cleanup.android.owned=true`、`device.cleanup.android.runner`、`device.cleanup.apk`
- `device.cleanup.tls.keystore`、`device.cleanup.tls.certificate`（公有DER），可选测试证书库密码属性`device.cleanup.tls.password`
- `device.python.command`、`device.child.package`、`device.adb.command`、`device.aapt.command`、`device.flutter.command`
- `device.android.serial`、`device.android.avd`

该类启动随机端口的真实HTTPS服务，通过宿主驱动依次执行阶段；全部成功后才生成安全的`server-result.json`。编译或默认跳过不能作为原生通过证据。

## 范围

成人OIDC/MFA仍为MockMvc测试夹具，未覆盖真实管理员登录、正式证书部署或真实业务账户。设备注册、原密钥证明、TLS验证、清理命令与回执都经过真实网络和生产处理代码。数据库为H2，仍需MySQL/实体手机/TV、真实断电、后台调度、确认结果不明恢复和独立擦除验收。完整界面缓存持有者由既有测试覆盖，本入口显式关闭测试数据库，不认证整个儿童界面流程。全局擦除和正式发布仍需继续完成。

证书导入依据[Dart官方API](https://api.dart.dev/dart-io/SecurityContext/setTrustedCertificates.html)使用PEM；原始DER在本机与Android均复现BAD_PKCS12_DATA，格式适配后的真实SecurityContext回归通过。此适配不关闭证书或主机名校验。

## 本轮实测

最终五个进程PID不同，使用同一个APK和安装UID/首次安装时间；四个成功进程均通过未受信任证书负控。真实普通凭据401后，命令与签名公钥读取成功，RECEIVED和AGENT_DATA_CLEARED真实回执各一次落库。后端仍明确显示设备自报的DEVICE_REPORT_UNVERIFIED。最后重启确认原密钥不可用，身份与已知缓存不存在，已确认日志仍保留。模拟器已停止，所建端口映射已移除，诊断数据保留。

首次证书格式失败和第二次只读设备通信故障均保留；第二次已完成注册的安装没有被清空，最终验收使用另一个新建专用AVD。失败尝试未计为整流程通过。冻结基线、七份新增源码、1129个未改归档文件以及APK/日志/服务端回执摘要见[阶段证据](releases/stage-child-cleanup-https-verification.json)。本轮未更新运行中的管理台、业务库或正式安装包。

独立源码复核未发现Critical/Important/Minor问题，含只读查询重试修订。后续运行证据追加复核因模型服务容量不足未完成；本轮终态结果由实施者对实际报告、日志与摘要逐项核对，不将它描述为独立运行验收。
