# 身份 HTTP 整次正文期限：隔离候选 r1

状态：**SOURCE_PREPARED / UNCOMPILED / TESTS_NOT_RUN / INDEPENDENT_REVIEW_PENDING**。

只写本目录。未改 Main、Git、Factory、POM、部署、依赖或服务；未执行 Java/javap/Maven/SDK、网络或测试。原 4 MiB RED 材料保持原字节和原 NOT_ACCEPTED。此候选不能作为运行通过或可部署结论。

## 精确候选

`src/identity-extensions/` 是 **5 文件覆盖层**，不是完整独立 Maven 项目：

| 文件 | 作用 |
| --- | --- |
| 新 `ProviderHttpTransport.java` | 共用的单次总期限、有界正文及原请求取消 |
| 改 `AliyunSms.java` | 原 POST/签名头/body 构造保留，只委派共用层 |
| 改 `WechatNative.java` | 原 GET/兑换业务保留，只委派共用层 |
| 新 `ProviderHttpTransportTest.java` | 22 项新契约源码（未运行） |
| 改 `ConsumerHttpClientReuseTest.java` | 原4项复用/配置场景只接合sendAsync与byte[]响应 |

`before/` 仅保存3份被修改现有文件的原始字节。`out/candidate.patch` 为标准仓库相对路径补丁，另保留3份逐文件patch。`manifest.json` 固定覆盖层、before、保护输入、测试声明及所有边界。

身份模块当前原33文件没有变化，Git模块树仍 `7796f5aaf6a38ff87b8a2ca77113bb8ef5ded321`。若未来按覆盖层组装完整模块，将是35文件、14个测试类、98项@Test源码声明（原76+新22）；这只是静态声明计数，不是解析、编译或运行结果。

## 测试先行证据

`out/test-first-receipt.json` 在第一版18个新测试写入、生产候选尚不存在时记录原始SHA及时间，随后才实现生产候选。自审再补4个便宜边界场景并改进夹具部分初始化清理；原receipt不改写为最终22项。没有运行RED/GREEN，不能宣称已完成TDD闭环。待新的独占窗口恢复后，先核新测试实际编译/有效失败与原实现差异，再完成修复验证。

## 状态与所有权

- 生产仍借用Factory创建的一只默认JDK17 HttpClient，原3s connect、Redirect.NEVER及Factory生命周期不变。不新建timer、executor、线程池或HTTP client，不在单次失败时关闭共享client。
- 每次调用独占原 `sendAsync` 返回的pending及一个LimitedBodySubscriber；Supplier构造请求前开始单调5s预算，准备、提交、get及解码后都检查同一剩余值。不会在sendAsync返回/收到headers后再送5s。
- 先检查已有中断；等待期间中断恢复flag后报IOException。已完成future仍做前后中断/期限检查，不返回晚成功。
- 异常收尾先 `pending.cancel(true)`，再abort本次subscriber。没有 `orTimeout`，没有阻塞worker Future包装。不能先完成原Future异常而丢失JDK的取消传播。
- subscriber的 `terminal`、订阅身份和字节缓冲只在同一锁内修改；上游request/cancel与Future完成在锁外。自然完成、超限、错误或abort中先获得终态者固定结果；迟到回调不继续累计或翻转结果。
- 取消先于onSubscribe会保留terminal，迟到订阅立即取消；第二个订阅被拒绝。onSubscribe/onNext锁释放后可能与取消交错，Flow允许已取消订阅忽略迟到request；缓冲仍受锁和terminal保护。没有声称跨线程动作完全原子。
- Content-Length仅用于提前拒绝，实际所有buffers仍按65536字节累计，复制前检查余量。UTF8解码在有界完整body完成后进行。微信原ofString可按头选择charset，统一JSON UTF8属于显式规范化，不描述成全部历史charset行为不变。
- 一次sendAsync调用不加任何应用重试；不修改签名nonce、业务冷却、配额或发送结果不明确语义。尚未证明JDK底层在所有连接故障中完全不会隐式重试。

## 新测试源码范围

单元边界：UTF8分块、恰65536、声明超限、实际多buffer超限、UTF8字节与字符单位区别、非法长度、上游错误后迟到完成、重复订阅、原pending取消与迟到订阅、已有中断/等待中断/已完成Future中断、准备预算、提交晚成功、get晚成功、余量扣减、失败不应用重试。

真实自有HTTP/1.1：SMS限内慢正文、WeChat限内滴流、chunked超限、调用方实际中断、并发A超时不误取消B。测试使用明确绑定127.0.0.1随机端口、无代理的真实默认client；观察包装直接返回真实Future，不另包普通Future改变取消路径。不会连接真实提供方。

### 期限与关闭探针不能混淆

限内慢正文/滴流在transport返回HttpTimeoutException之前，只发送0或最多10个字节；断言原调用约5s结束且探针尚未开始。**随后**测试主动放行独立4MiB写探针，以使服务端在fixture.stop/close之前明确观察真实网络关闭。探针是取消后观测，不参与期限判定，也不把4MiB超限当作慢正文期限通过。

超限测试独立运行chunked大正文，要求IOException且不是HttpTimeoutException，并在fixture清理前见writer失败。只有实际write/flush抛IOException才计writer失败；header、等待超时、fixture中断/关闭的错误不作为该证据。夹具持有的server/小型有界executor只出现在测试源码，实际执行时必须由本夹具正常/失败路径收敛。

## 待独审与运行验证

1. 只读静态审核5文件、状态机、Java17语法与泛型、测试夹具不制造误通过。当前未做Java parser/编译。
2. 取得新验证许可后，保留固定原33文件+原失败材料，组装新35文件离线快照；不直接在Main试跑，也不更改原body79覆盖层。
3. 新98项全模块测试必须通过；明确两条限内正文返回时限、实际writer失败在fixture清理之前、共享client隔离及中断标志。必要时增加HTTP/2的stream取消与其他stream继续，不拿HTTP/1.1结论外推HTTP/2。
4. 全部源码、缓存、工具前后摘要、实际同一进程终态与资源/Job收尾仍由Root的现有调度流程负责。本目录没有新执行框架、grant或运行器。

JDK公开取消契约仅为尝试取消并可能异步释放；静态代码不能证明对端未收到请求、调用一返回网络就彻底结束或任意自定义HttpClient子类都硬5s返回。若真实取消断言失败，应修正方案或完成HC5资格后切换，不能删除writer断言/放宽期限。
