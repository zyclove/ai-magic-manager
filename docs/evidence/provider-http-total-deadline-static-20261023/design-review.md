# 身份通道正文期限：静态调查与最小修复设计

状态：`DESIGN_ONLY_NOT_IMPLEMENTED_NOT_EXECUTED`。调查基于当前 `45950b88a270e2fded2409e333fb126851b6f861`；身份模块 Git 树仍为 `7796f5aaf6a38ff87b8a2ca77113bb8ef5ded321`，与原 body79 验证对应。没有 SDK、javap、Java、Maven、网络、真实提供方、Git 写或 Main 写；输出仅位于本目录。脚本只读文件、POM XML、ZIP 目录和 manifest/pom.properties，不解析 class 字节。

## 1. 已确认的问题及来源

`static-inputs.json` 固定了身份模块 33 文件、8 个相关代码/证据文件、14 份本地 POM、6 个本地 HTTP 候选 JAR，包含原 XML 和日志的独立读取。原始材料保持不变。

| 当前源文件 | 原始 SHA-256 | 相关行为 |
| --- | --- | --- |
| `identity-extensions/pom.xml` | `73c7fe28469d1a06e4278ec6e63317d8ae9bdb6ba070bb9b1fdc41a38f680722` | Java 17、Keycloak 26.8.0；没有 HTTP 第三方生产依赖 |
| `AliyunSms.java` | `6dcf7f9b7182f1800a81b407d9a373c0b6dfaaa8043d1d12e694dad32fb8da8b` | 47–54 行：同步 `send(...ofString(UTF_8))`，请求 timeout=5s |
| `WechatNative.java` | `459d446dc9c4a911f56b68b637aa6f9b6e5cda5c5a9cbec2635b885cc4541535` | 25–28 行：相同同步路径，正文未在传输阶段限制 |
| `ConsumerAuthenticatorFactory.java` | `a07e20a2a9c22f4eec75540380383d7f4c8ae870a519c9d3b21cf26099247a25` | init 创建一只共享 JDK client、连接期限 3s、禁止重定向；close 为空 |
| `ConsumerHttpClientReuseTest.java` | `3128eb0abaf10cc5123c64684f3e7cb27a7f5cc872ba64312f6d5acd422b5d54` | 四项客户端复用/未配置场景；同步 send mock 尚未覆盖正文取消 |

原 `ProviderHttpBodyDeadlineTest` XML 的 3 项为 1 通过、2 断言失败、0 error/skip；完整模块此前为 77/79。直接回读日志：

| 场景 | headers | 原调用返回 | 清理前 writer 失败 |
| --- | ---: | --- | --- |
| SMS delayed | 89ms | 6612ms，200，4,194,304 字符，无异常 | false |
| WeChat drip | 2ms | 7271ms，200，4,194,304 字符，无异常 | false |
| 调用方中断 | 5ms | 8ms，IOException，中断保留 | true |

据此可以确定“当前实现的 5s request timeout 没有满足完整正文期限”这一缺陷；不能从失败材料推出所有 JDK/协议的原因相同。`AliyunSms.send` 第 34 行和 `WechatNative.exchange` 第 20 行的 65536 检查发生在下载并解码完整字符串之后，且单位是字符，因此既非流式限额，也非字节限额。

身份模块实际是 Keycloak SPI，并非 Spring Boot 应用。应保留其工厂生命周期、构造注入与业务 transport 边界，不为了引入 Spring RestClient/WebClient 而增加另一套容器或响应式框架。

## 2. 本地成熟组件资格

选定缓存：`.cache/committed-validation-20261021-r1/execution-m2/`。以下均实际在场、摘要与包内版本匹配：

| 组件 | JAR SHA-256 | 字节 |
| --- | --- | ---: |
| HC5 client 5.5.2 | `5aec3f3447ec816e593e380b59fbe3e42083318af6b215bc177386f7742f6146` | 960897 |
| HC5 core 5.3.6 | `8fb4528d3e970aca440523a1bd698a389fa710ecfea4c5c6096698b86d1669ce` | 909490 |
| HC5 h2 5.3.6 | `479a8aa5e6f99030a2a446a68d1f62320698932746f811fc656a1ea06b94184d` | 242521 |
| SLF4J API 1.7.36 | `d3ef575e3e4979678dc01bf1dcce51021493b4d11fb7f1be8ad982877c16a1c0` | 41125 |
| HC4 client 4.5.14 | `c8bc7e1c51a6d4ce72f40d2ebbabf1c4b68bfe76e732104b04381b493478e9d6` | 785639 |
| HC4 core 4.4.16 | `6c9b3dd142a09dc468e23ad39aad6f75a0f2b85125104469f026e52a474e464f` | 327891 |

### HC5 生产依赖图：仅由实际 POM 推导

- client5 5.5.2 的非 optional、非 test 依赖是 core5、h2 和 slf4j-api；父 POM 明确 core5=5.3.6、slf4j=1.7.36。
- h2 非 optional、非 test 依赖为 core5；core5 没有额外生产依赖。
- conscrypt 与 brotli 为 optional，不能当作必须下载的生产闭包；本方案不启用它们。
- 两个 HC5 父 POM 分别经 httpcomponents-parent 14/13 到 apache 27；这些本地父 POM，以及 slf4j-parent 1.7.36 均在场并已固定。
- 以上可证明候选的 POM 级基础运行依赖在本地，**不等于 Maven 已完成有效模型/冲突解析、所有插件闭包通过或 Keycloak 实际装载通过**。本轮没有运行解析。
- 选定缓存内 `*sources.jar` 为 0；6 个 JAR 内 `.java` 文本为 0。11 个候选 class entry 在场，但目录存在不能证明 `cancel`、hard cancellation、response handler 或构造器的公开签名/语义。未执行 javap，也不从另一版本记忆补齐这些事实。

### 打包边界必须先解决

`scripts/build-deployment.ps1` 第 182–186 行只复制 `consumer-identity-1.0.0.jar`；当前 maven-jar-plugin 不聚合依赖。`keycloak.Dockerfile` 在 `kc.sh build` 前复制 providers 目录。若采用 HC5，单改 POM 和 import 将产生“单元编译可过，真实装载缺类”的风险。

Keycloak services 的本地 POM 声明 HC4，不能据此推导它提供 HC5。Keycloak parent 含 SLF4J 属性和 Quarkus BOM imports，也不能把孤立属性视为真实发行包的最终 SLF4J 版本。不能直接向 providers 加入 SLF4J 1.7 JAR覆盖服务器日志类。

HC5 路线应选择一种受管理打包方式并固定验收：

1. 优先独立 provider 运行依赖清单/复制，HC5 三 JAR明确放 providers，SLF4J 使用已验证兼容的服务器 API，禁止复制重复绑定器；或
2. 经已有成熟 shade 工具和完整离线插件闭包资格后，私有 relocate HC5，保留许可证/NOTICE/服务元数据，仍不重复打包 Keycloak/Jackson/logging API。

当前没有执行二者；不能把候选复制清单、POM 推导或类目录当作实际装载证据。HC4也未核完整公共API/依赖闭包，且从旧客户端切换仍需总期限取消设计，不因服务器已有它而自动优先。

## 3. 推荐最小路径及另一条路线

### 路线 A：优先准备 JDK17 标准 API 的小型共用 transport 修复候选

本路径保留现有一个 client 的工厂所有权，不增依赖、HTTP 框架、定时线程或后台阻塞 Future 工作池；两个提供方共享一个包内 `ProviderHttpTransport`。使用现有标准 API 的 `sendAsync` 原始返回句柄、限额 subscriber，以及调用线程上的 `get(remainingNanos)`。这是一项候选设计，必须通过下文真实本机 I/O 检查才能取代原失败结论。

具体顺序：

1. transport 入口先检查当前线程已有中断，已中断时保留标志并拒绝派发；再记录 `System.nanoTime()`。5s预算从请求构造/提交前开始，公用方法可接受仅用于构造此请求的 Supplier，或由适配器把入口 startedNanos 传入；不能构造完整 request 后才开始计时却声称覆盖准备。后续用 `timeoutNanos - (now - started)` 计算余量，每阶段使用同一预算，不在收到 headers 或 body 时重置。
2. request 保留连接期限 3s、禁止重定向及 TLS 默认校验。`HttpRequest.timeout` 可保留作附加保护，但不再宣称它独立覆盖 body。
3. 直接保留 `http.sendAsync(request, limitedHandler)` 的原始 future；不要把 dependent future、`CompletableFuture.supplyAsync(client.send)` 或 `orTimeout` 当作可取消网络句柄。尤其不得先对原 future 用 `orTimeout` 完成异常，再试图 `cancel(true)`。
4. 限额 handler/subscriber以 **65536 实际收到字节** 为统一上限：检查 Content-Length 可以提前拒绝，但省略、chunked、伪造长度仍逐 ByteBuffer 计数；在复制前用 `remaining > limit - accumulated` 拒绝，避免临时分配超限缓冲。只有完整且在期限内的 body 才统一按 UTF-8 解码交给现有 JSON 业务。短信目前固定UTF-8；微信目前ofString可采用响应头charset，统一UTF-8属于明确的JSON编码规范化，应独立记录及测试，不能声称完全保留原charset行为。
5. 在原 future 上 `get(remaining, NANOSECONDS)`；get 返回后再次检查总预算，禁止在截止之后把已完成的晚到响应当成功。已耗尽预算时先取消原句柄和当前订阅，再抛固定消息的 `HttpTimeoutException`。到期和成功竞态必须单独测试。
6. `TimeoutException` 分支调用原 future `cancel(true)`；subscriber 必须暴露仅本次交换的幂等取消，若取消先于 `onSubscribe` 则记住状态，迟到订阅立即取消。关闭状态后不再 request、累积或成功完成。不能只 `completed.completeExceptionally` 而任 body 下载。
7. `InterruptedException` 同样取消本次 future/订阅，恢复当前线程中断标志后抛 IOException；不得吞中断或关闭共享 client。处理 `ExecutionException` 时保留 timeout/限额/IO类型，不把 RuntimeException 误包装成成功；用户提示仍走现有固定文案，不暴露 URL、响应正文、secret 或签名。
8. 不加自动重发。发送/兑换可能已被提供方接受，期限意味着本地结果不明；复用原业务流程、冷却/配额及恢复核对语义，不在 catch 中再次生成随机 nonce/新操作。

JDK 源码交叉核对见 `jdk-crosscheck.md`（独立只读来源及精确行号）。标准取消契约是尝试取消、资源释放异步；因此本路径仍以 writer 停止的实际断言作为必要门槛。若真实取消或关闭约束不能满足，应转路线 B，不能删弱断言。

Java17 client 没有 close；本路径延续当前 JDK 管理资源事实，不新增归工厂关闭的 executor/timer。共享client不在一次交换失败时关闭。工厂若需要确定性销毁所有连接，则路线 B 的 CloseableHttpClient 更合适，不能假称 Java17 已有 close。

默认本机client异步调度和取消路径有本地源码支持，但`httpTransport(HttpClient)`也能被注入自定义子类；不能把该子类可能同步阻塞的sendAsync也宣称为硬5s返回。前后预算检查可以拒绝迟到结果，无法抢占已经发生的同步阻塞。候选以生产factory实际创建的默认client为契约，另用假client专门测试预算扣减与迟到结果拒绝，不悄悄引入无界后台线程解决任意实现。

### 路线 B：完成 HC5 资格后采用其经典客户端和请求取消

适合需要明确连接池/工厂 close 所有权的最终设计。先在新的单独许可窗口核对固定二进制公开API和实际装载；本报告不授权执行。

- 工厂拥有一只可关闭的 pooled client 和一只小型 deadline scheduler；两通道借用，request/response/订阅或实体流为每次调用独占。`factory.close` 关闭自己的 client/scheduler并拒绝新调用；不停止服务器共享客户端。
- caller 同步执行 HC5 classic 请求，deadline scheduler 仅取消这一次 request。无需另建阻塞 worker Future 池。需核精确 request cancel 公共入口与 hard cancellation 配置，确保不是只取消租借排队而body继续。
- 从 transport 入口启动绝对期限；连接获取、DNS、连接/TLS、headers、body、内部重试共享同一预算。3s connect/5s response socket timeout只是子保护，滴流可以绕过每次读 timeout；不能以设置它们替代绝对总期限。
- 明确关闭自动重试、redirect、认证挑战重发及不需要的解压/状态复用行为。短信 POST 与微信 code exchange 不具有可安全重放的通用假设；需对重置/5xx/302等记录实际出站次数。
- 仍逐流读取至64KiB；超限/到期/中断先取消交换再退出，不能让 response-handler 的自动 consume/close 优雅排空超大或持续正文。`EntityUtils.toString` 的长度参数与 response close 行为须核固定版本，未核前不作为限额/取消保证。
- deadline timer 与自然完成必须原子判定，成功前检查总预算；finally取消自己的定时任务，remove-on-cancel避免队列积累。scheduler shutdown和工厂 re-init/close要幂等，active调用终止和旧timer不得影响后续新request。
- 必须证明caller interrupt能取消socket，并保留中断标志；HC5同步阻塞读取不保证仅凭 `Thread.interrupt` 就结束。若需要额外工作池才能做到此点，重新比较路线 A 总复杂度，不叠加一层看似超时的 wrapper。

两路线都不替代以后官方 Aliyun SDK 接入：目前该 SDK 二进制/依赖不在选定离线缓存中，旧 master/文档不足以证明固定发布版整期限/取消/装载。不得下载或通过私有运行时 Map/反射/全局客户端缓存绕过接入资格。

## 4. 最小候选文件集合

路线 A 建议 3 个生产文件（2改、1新增），Factory仅在必要生命周期/API接合时成为第4个文件：

1. 新增 `identity-extensions/src/main/java/com/aimanager/identity/ProviderHttpTransport.java`：只负责共享client借用、单次deadline、字节cap、原始取消句柄与异常边界，包内可测试；不签名、不解析业务JSON、不持久化操作。
2. 修改 `AliyunSms.httpTransport(HttpClient)`：继续构造原POST/headers/body，委派公用transport；保留Transport接口、签名、固定提供方端点及原操作身份。
3. 修改 `WechatNative.httpTransport(HttpClient)`：委派相同transport、显式UTF-8；保留原GET/兑换业务验证。
4. `ConsumerAuthenticatorFactory.java`：路线A应能保持原单client、3s connect、Redirect.NEVER与构造签名；若无需改则不加入变更。路线B才需明确工厂close实现。

测试至少新增 `ProviderHttpTransportTest.java`（独立契约，不覆盖原4MiB材料），并适配 `ConsumerHttpClientReuseTest.java` 的sendAsync mock/复用观察；原AliyunSmsTest/Wechat业务相关测试保持。路线 A 无需改pom/部署脚本。路线 B 另需POM、build-deployment、provider依赖/摘要及Keycloak实际装载边界测试，不能隐藏在这3文件补丁内。

## 5. 必须验收的矩阵（均未运行）

| 分类 | 必要断言 |
| --- | --- |
| 正常SMS/WeChat | 原方法/URL/query/header签名不变；正常JSON/status判断与复用一只client通过；失败不自动重发 |
| 期限内slow body | 实际body小于64KiB，headers先到、body直到5s后才释放；5s+固定调度余量内抛HttpTimeoutException，不能成功 |
| 限额内drip | 小于64KiB、每次间隔小于socket timeout但总计超过5s；同上，不因持续流量重置期限 |
| headers迟到 | 请求整体5s已耗尽，禁止在刚收到headers后重新获得5s正文预算 |
| 提交/连接排队 | 在提交前/已排队时消耗预算，余量到期取消；出站未启动或真实连接停止，不保留无限排队任务 |
| 迟到成功竞态 | success与deadline相邻，只有截止前完成结果可成功；到期后完成不覆盖timeout |
| 原4MiB迟到夹具 | 原RED及XML/log原样保留；新实现允许因明确超限提前失败，不把这种失败改称旧期限通过 |
| Content-Length超限 | headers已声明>65536时拒绝并取消交换；没有创建完整String/巨大byte[] |
| 无长度/分块超限 | 最多存65536字节，首个超限chunk拒绝且取消真实I/O；不能只靠长度头 |
| 边界与UTF-8 | 65536字节内可完整解码、多字节跨buffer正常；65537实际字节拒绝；所有提供方一致 |
| 错误/空/异常正文 | 非200、空JSON、非法JSON、微信errcode、SMS错误码继续业务拒绝，不输出body/secret到日志 |
| 真正I/O取消 | 本机自有exchange：timeout或cap失败发生后，先release writer，等待其写失败/退出，再关闭fixture；断言writer失败在cleanup之前；不能用future.cancelled代替 |
| 未订阅时取消 | deadline/interrupt先于onSubscribe，迟到subscription仍被取消；不继续request/body积累 |
| caller interrupt | header/body阶段中断，实际caller及时退出，中断标志保留，对端writer在fixture stop前失败 |
| 并发隔离 | A超时/超限/中断只取消A；同factory的B请求仍正常完成；失败不close共享client |
| 资源/生命周期 | 重复调用无新增自有线程/遗留timer；若HC5则factory close/re-init/部分init失败幂等且释放自身资源 |
| HTTP策略 | redirect不跟随；连接重置/5xx不自动重新发送SMS或兑换code；实际出站计数而非mock次数 |
| 装载（若HC5） | provider+实际runtime依赖摘要、许可证、Keycloak优化构建/启动装载成功，无日志API重复冲突 |

超时公开目标维持5s，调度余量仅用于真实测试观察，不得延长产品期限或靠缩小fixture掩盖。Future状态、日志中打印“cancelled”、静态源码与窄mock都不足以证明真实I/O退出。

## 6. 决策边界

建议先由Root判断路线 A 是否可以准备cache候选：它用现有JDK标准client与公用有界subscriber完成所需行为，避免未具备装载证明的新运行依赖。另保留HC5为有明确close需求或路线A真实取消未通过时的成熟替代，先做精确公开API/依赖装载资格；不能为赶进度删弱deadline/真实writer断言。

本轮未改生产源、未实现候选、未跑编译/测试、未安排新SDK或提交。原body79仍为NOT_ACCEPTED；本报告只提供下一项可审阅的修复设计。
