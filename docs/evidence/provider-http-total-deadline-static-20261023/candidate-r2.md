# 身份传输候选 r2：补强取消时的在途并发隔离

状态：**SOURCE_ONLY / UNCOMPILED / TESTS_NOT_RUN / INDEPENDENT_REVIEW_PENDING**。

r1两份独立静态审查指出相同P2：原并发用例先让B完成，再等A超时，只证明client可以复用，不能证明A取消时仍在途的B保持有效。r2只补强原同名测试及其自有夹具；另外4个覆盖层文件与r1逐字节相同。r1的15份交付固定值、历史test-first18与原4MiB RED材料均不改写。

## 真实交换时序（仅源码，尚未执行）

1. 使用一个真实默认JDK17 HTTP/1.1 client和两个自有调用线程。A进入原transport，记录单调时间；收到A响应头后，其正文保持为空。
2. 按A入口时间等到约第4秒，先确认A仍在途，再启动同client的B。B使用独立`/held`端点，返回已声明13字节的JSON响应头；正文由`releaseHeldBody`保持。
3. 确认B实际收到响应头、A尚未完成、B调用仍在途且正文未放行。B从自己的入口获得原本的5秒，产品timeout未调整。
4. 等A真实返回HttpTimeoutException，原测试仍要求A入口耗时约4.5–6秒、正文0字节。此时才放行A的独立关闭探针，最多2秒观察实际writer失败和handler终止，明确发生在fixture.stop/close前。
5. A关闭成立后，确认B的**原始JDK HTTP Future**仍未完成，B调用仍未完成，B正文latch仍关闭。然后才放行同一个B；要求它自然返回200及完整JSON、服务端写入成功且正常结束、无夹具错误，实际提交数精确为2。
6. 任意断言失败时，内层finally先释放A探针/B正文，再停止并收敛本测试拥有的caller池。外层fixture.close再次幂等释放两latch，再停止其server及executor。所有等待/休眠均有界。

计时安排为B避开与A同时到期：正常A约5秒超时后，B尚有约4秒；A取消观测上限为2秒。若调度或连接异常导致B在A超时前无法获得headers，或B到期/被误取消，测试应失败，不能提前释放B或扩大产品期限制造通过。

## 不变边界

- `ProviderHttpTransport.java`、`AliyunSms.java`、`WechatNative.java`、`ConsumerHttpClientReuseTest.java`四文件byte-exact保留r1。
- 新测试方法名仍22个且顺序相同；原76+新22=98、14类/35文件仍仅静态预期。
- observer直接返回`real.sendAsync`原Future，只记录B句柄；没有普通Future包装/映射改变取消语义。
- Factory/POM/部署/Main/Git/服务/依赖均未修改；没有编译、SDK、运行测试或网络调用。
- `out/r2-vs-r1-test.patch`只描述本测试文件delta；`out/candidate.patch`是完整5文件覆盖层针对未变Main身份模块的补丁。manifest记录r1全部15pins及保护输入。

原生产设计、UTF8规范化、Future取消契约和同步Supplier/sendAsync不可抢占的限制，继续以r1 README及设计报告为准；本轮没有新增产品行为或验收通过声明。
