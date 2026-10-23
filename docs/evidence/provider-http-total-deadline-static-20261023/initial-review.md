# 身份 HTTP 传输候选：独立静态审查 r1

状态：**STATIC REVIEW / NOT COMPILED / TESTS NOT RUN**。

审查对象为 `.cache/identity-transport-candidate-20261023-r1` 的 5 文件覆盖层、README、3 份局部补丁与固定输入。仅审阅文本、核对固定文件摘要及文本声明数量；没有启动 Java、javap、Maven、编译器、Java parser、测试、进程 API 或网络，也没有修改候选、Main 或 Git。

## 结论

生产路径未发现确认的静态阻断；Java 17 的 `BodyHandler<byte[]>`、`CompletableFuture<HttpResponse<byte[]>>`、`CompletionStage<byte[]>` 接合在文本层面一致。**有一项 P2 测试覆盖缺口，建议在冻结最终运行候选前补足**。这不是生产运行通过、真实取消已修复或可部署结论。

### [P2] 并发测试在取消 A 前已完成 B，未覆盖仍在途的另一交换

文件：`src/identity-extensions/src/test/java/com/aimanager/identity/ProviderHttpTransportTest.java:334`。

`timingOutAConcurrentRequestDoesNotCancelSharedClientsOtherRequest` 在 347–348 行同步完成 `/ok` 请求 B，349–351 行才等待慢请求 A 的超时。A 被取消时 B 已结束，所以该场景只能证明 A 等待期间允许另一请求成功，不能证明取消 A 不会取消仍在途的 B。294–331 行的中断测试在取消后重新发送 `/ok`，则证明后续复用，两者均不能代替此缺失时序。

最小修正：在同一受控 loopback 夹具中给 B 单独的 headers/正文放行 latch；确保 A、B 都已收到 headers，B 的结果仍未完成；先观察 A 超时及其 cleanup 前 writer 失败，再放行 B 并要求 B 成功。保持同一共享客户端、一次应用提交、夹具自有资源收敛和既定时间预算。无需改生产路径或删除现有断言。若仍采用当前测试，交付描述须明确“并发在途取消隔离尚未覆盖”。

## 生产状态机审阅

- `ProviderHttpTransport.java:29–74`：一只借用的客户端、每次独占原始 `sendAsync` Future 与正文订阅者；准备、同步提交、等待及解码后使用同一个 `nanoTime` 起点和 5 秒余量。只有一次应用层提交，没有 `orTimeout`、timer、executor、应用重试或共享 client 的关闭。
- 失败收尾先尝试 `pending.cancel(true)`，再 `body.abort`；等待中断恢复标志，已有中断不派发，已完成 Future 仍经过中断/期限检查。`get` 超时、原 IO 错误、取消均不返回部分正文。
- `LimitedBodySubscriber` 的终态、缓冲和订阅身份在同一锁内更新；Future 完成与上游动作在锁外。重复订阅取消，取消前尚未发布的订阅在稍后到达时取消，迟到正文不再累计。锁外 `request` 与取消交错的边界在 README 中明确，并未宣称动作完全原子。
- 声明长度只做提前拒绝，所有实际 buffers 在复制前按剩余 **65536 字节** 检查；UTF-8 完整解码在有界正文结束后进行。SMS POST、签名/headers/URI/body 和 WeChat GET 的业务构造保持局部补丁范围。WeChat 统一 UTF-8 是 README 明示的规范化。
- 同步 `Supplier.get()` 和自定义 `sendAsync()` 的任意阻塞无法被此实现硬抢占；这里只能在它们返回后扣除余量并拒收迟到结果。README 已清楚限制此结论。JDK 真实网络取消仍待实际证明；未声称底层绝无隐式重试或 HTTP/2 已验收。

## 测试夹具审阅

- 22 个新增 `@Test` 名称与 manifest 完全一致；原模块 13 个测试文件的文本声明为 76，投影为 98。没有 Java 解析、编译、JUnit discovery 或运行，因此均不计为通过项。
- SMS slow / WeChat drip 在总耗时 4500–6000 ms、header 已到达、实际正文不超过 10 字节且探针尚未启动时，先断言 `HttpTimeoutException`，随后才放行 4 MiB 关闭探针。因此该探针不是通过 64 KiB 超限来替代期限。
- chunked 超限为独立场景，要求非 `HttpTimeoutException` 的 IO 拒绝。writer 失败仅在实际 `write/flush` 抛 IO 错误，且 fixture 未 closing、handler 未中断时计入；主要测试在 try-with-resources 关闭前断言该事实。
- 真实客户端限定 127.0.0.1 随机端口、无代理、HTTP/1.1，观测包装直接返回真实 Future。测试的 server、小型 executor、调用线程均为 fixture 自有；未运行，不能据文本宣称没有泄漏或物理取消有效。
- `test-first-receipt.json` 的 18 是早期测试先行 checkpoint，最终新增 22 在 manifest/README 已区分；历史 receipt 保持原字节。

## 独立输入核对

实际只读回读：chunk `025436`，自然 exit 0；详情见同目录 `readback.json` 和 `input-pins.json`。

- manifest：22167 字节，SHA-256 `71fee61888ebb51ce46771f157e0c09ac9745b26fe109b299d47a0ffe4bc326d`。
- delivery：15 份固定文件，SHA-256 `ebeafcd2e5b6a857f30f42cb9ae515b72da8d4463f41da473a9f332b571ba16e`；全部长度/SHA-256 匹配。
- 61 份枚举保护输入全部匹配；只核这些固定输入，没有全缓存遍历。读前后重核 delivery/protected，未发现漂移。
- 5 份候选的原始 Git blob SHA-1 都匹配 manifest；Main 的 3 个修改目标仍是 before 原字节，2 个新增目标仍不存在。
- 原 RED 的源码、XML、日志原字节保持；原特定套件仍为 3 项、2 失败、0 错误、0 跳过。原全模块 **77/79 与两项整次正文时限失败仍为 NOT_ACCEPTED**，没有改写为 GREEN。

下一步先补上 P2 的 B 在途时序并重封存，再在新的资源/独占验证窗口中核对最终 Java 17 编译、98 项完整发现、限内总期限、cleanup 前真实 writer 停止及客户端隔离；当前不启动这些工作。
