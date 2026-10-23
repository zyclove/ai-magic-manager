# 身份传输候选 r2：P2 delta 独立复核

结论：**r1 的 P2 在测试源码设计层面关闭，未发现新增确认静态阻断。UNCOMPILED / TESTS NOT RUN。**

审阅了 r2 完整测试差异、对应固定测试源码、README 和 manifest。没有运行 Java、javap、Maven、编译器、Java parser、测试、进程 API 或网络；没有改候选、Main、Git 或原 r1 审查材料。

## P2 关闭依据

- 同一共享真实 JDK HTTP/1.1 client 上，A 入口记录单调时间；约第 4 秒才启动 B `/held`。在继续等待 A 前，要求 B 的实际 headers 已到达、A 尚未完成、B caller 尚未完成、B 正文 latch 未放行。
- A 仍必须在原约 4.5–6 秒范围返回 `HttpTimeoutException`，正文保持 0 字节；此后才放行 A 的关闭探针，并在最多 2 秒内要求实际 writer 失败、handler 结束且 fixture 未关闭。
- A 的取消观测成立后，继续要求 B 的**原 JDK Future**及 B caller 均未完成，正文仍未放行且未写入；然后才释放同一 B，要求 200、完整 `{"Code":"OK"}`、B handler 正常结束、写入成功、无错误，实际提交数恰为 2。
- observer 只记录 B 的原 Future，直接返回 `real.sendAsync` 的同一对象，没有映射/包装改变取消路径。B 使用生产原有每次入口 5 秒预算；启动错开约 4 秒以避免同时到期，未扩大产品期限。若调度导致 B 来不及收到 headers、到期或被误取消，断言会失败。
- 失败 finally 先释放 A/B 两 latch，再 shutdownNow 并有界等待自有 caller 池；外层 fixture.close 再释放两 latch、停止自有 server/executor。没有以 fixture.close 制造 A writer 关闭通过。

因此，该场景现已要求 B 真正跨越 A 的取消阶段，修复了 r1 “先完成 B，再取消 A”的覆盖缺口。以上只评价断言与所有权设计，不能证明实际 JDK 取消、网络收敛、资源无泄漏或 98 项通过。

## 独立回读

实际 chunk `4f9086`，自然 exit 0；明细见本目录 `readback.json`、`input-pins.json`。

- r2 manifest 28864 字节，SHA-256 `f5ae94c4b15a80870063bd954c48cd4b58864d404a8a4c14a7d2f89f9f3d8358`。
- r2 delivery 17 份全匹配，SHA-256 `ae0f4af03c85dcbea6aefcce5685485c2af148dbace84d5493887300e6bce475`。
- 测试 delta 9841 字节，SHA-256 `9e6d354fdd17f5c0679cb3d85eb7b1d0f48b17e3570ef3ba2124be57e76f1575`，只涉及该测试文件。
- 最终测试 31874 字节，SHA-256 `cb9b8131eedb97c0b76005ba4593c72b0c57344105e3698ca0b51a8090858164`。
- 另外 4 个覆盖层文件与 r1 原字节相同；5 个 raw Git blob 固定值均匹配；Main 仍为 3 个 before/2 个 absent。
- r1 全部 15 份固定交付、r1 manifest/delivery、61 份枚举保护输入原字节保持；重复回读无漂移。未遍历全缓存。
- 22 个新测试名称及顺序保持；原 76 + 新 22 = 98、14 类/35 文件仅为静态声明投影。原 test-first 18 的历史 checkpoint 与原 77/79 两项 RED 保持，未改为 GREEN。

下一步仍需新的独占窗口实际编译及完整回归。此审查不授予 SDK 窗口，也不构成部署验收。
