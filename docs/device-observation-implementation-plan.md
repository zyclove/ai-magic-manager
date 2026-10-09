# 设备观察与管理员授权实施计划

基线 9acbabb，2026-10-09。承接已批准总方案 Task 7/8/10，完整目标不缩减。继续使用 professional-product-engineering、executing-plans、TDD；新 Java 模块采用 Alibaba Java Coding Guidelines，保留项目现有 record/JDBC/领域接口风格。

## 设计与前置判断

- Ruling: 每设备注册周期独立 inventory / usage 授权，默认关闭；管理员近期 MFA + 强 ETag 修改，云端每次接收重新检查。Android 系统授权不是管理员授权替代。
- Ruling: 使用 Android 官方 PackageManager / UsageStatsManager / AppOpsManager，Pigeon 21.2.0 生成 Dart/Kotlin 通道。该版本官方 pub 元数据要求 Dart ^3.3，与当前 3.4.3 相容；不自行实现系统计时或权限服务。
- Ruling: 本轮使用量是 OS 聚合观察，保留系统实际区间与覆盖盲区，不宣称精确自然日统计，不用作额度账单/强制停止依据。精确可信租约计时继续实施。
- Ruling: 设备先在线取得当前授权版本，再读取/上传；离线不新采集、不延长授权。版本改变后旧快照不能被重放到新授权周期。
- Ruling: 撤回立即阻止新报告并删除当前观察载荷；仅保留必要审计。设备撤销由既有 DeviceAccess / DeviceCredentials 行锁串行化。
- Ruling: 应用清单仅当前 Android 用户可见的启动应用，明确不完整；不请求 QUERY_ALL_PACKAGES，不跨资料读取。SDK 包名/当前签名摘要只是自报观察，不证明安全或管理能力。

## 接口与并行边界

- 新 observation 领域 / V20__device_observation.sql；复用现有 device:operate 链，MFA、ResourceVersions、DeviceAccess、AuditService。
- 成人 GET/PUT `/tenants/{tenant}/devices/{device}/observation-settings`；GET `.../usage-observations`。
- 设备 GET `/device-api/observation-settings`、POST `/device-api/usage-observations`；现有库存上报增加 authorizationVersion 并校验当前授权。
- 本任务负责 apps/child、observation 新领域/测试/迁移、InventoryService/Controller 授权接点及相应原库存夹具、独立 guardian observation_page.dart。管理台设备详情链接由已获用户授权的并行任务协调接入，避免同时覆盖其 console_pages.dart。
- 不修改其他任务的组织、额度、成员、CatalogService、FleetReads 和共享交付文档。暂存/推送继续逐阶段协调。

## 实施步骤与验收

1. 后端 RED：默认关闭、MFA/角色/租户/设备边界、强版本、撤回清理、授权周期重放、报告幂等/重复和上限、凭据撤销；GREEN 后回归现有库存旅程。
2. 设备协议：严格模型、有界 HTTPS、授权版本、持久 pending/序号、原请求重放与服务端 ACK 校验；真实 HTTP/数据库互操作。
3. 原生 Pigeon：真实系统授权/锁定状态/TV检测，当前用户启动清单/签名；获准才查询 OS 聚合，返回实际系统时间边界，不能上报原始事件。
4. Flutter：监护人独立开关/近期重新认证/版本冲突/撤回后果；儿童端说明、未授权/未授予/撤回/无数据/失败/离线状态，平台设置只由明确操作打开。
5. analyze/test、后端迁移/模块/全量构建、真实 Android denied/granted/revoked 路径、实际 Chrome 手机/宽屏交互；每项只按实际证据记录，不推断真机/TV认证。
6. 自有阶段文件提交推送 dev；完整系统执行、可信计时、商业化与其他剩余功能继续。

## 官方依据

- [UsageStatsManager](https://developer.android.com/reference/android/app/usage/UsageStatsManager)：特殊访问、锁定状态限制，系统聚合区间可能扩展。
- [声明包可见性](https://developer.android.com/training/package-visibility/declaring)：按 intent 声明所需可见范围。
- [Pigeon 21.2.0](https://pub.dev/packages/pigeon/versions/21.2.0)：Flutter 官方通道生成工具；固定版本和生成源一起提交。

## 阶段记录：观察后端

- 提交顺序：先独立提交本契约与计划文档；后端代码/V20 已在工作区验证，等协作任务完整 V13～V19 合入后再提交，不将待提交接口标记为仓库当前可用。

- Ruling: 先交付可独立验证的观察后端阶段，再接入设备和界面；步骤 2～5 的客户端及真实数据库门槛保持未完成，完整目标不变。理由是用户要求按完成阶段提交，后端协议可供并行任务稳定对接。
- RED：新增 7 个观察旅程在接口尚未实现的快照中全部返回 404，确认缺失功能。
- 首次 GREEN 运行及一次命令行限内存重跑发生 JVM native memory 崩溃，均未算通过；后者受 POM 固定 argLine 影响，没有真正限制 fork 内存。
- 在已提交 HEAD 9acbabb + 自有 12 个源文件/迁移/测试的快照中，使用进程级 JAVA_TOOL_OPTIONS 限制 512 MB 堆和 2 个处理器，完成观察 7、清单 7、模块边界 1，共 15 项验证，失败/错误/跳过均为 0。
- 隔离快照不依赖协作任务尚未提交的生产修改。V20 的部署顺序仍须等待其完整 V13～V19 阶段合入，避免 Flyway 低版本迁移遗漏；已发送用户授权的协调消息。
- 同一快照后续完整现有后端回归退出 0：19 类、166 项，164 项通过、2 项跨语言 HTTP 互操作测试因未启用系统参数跳过；失败/错误均为 0。跳过项不算本轮互操作证据。
- 当时协作生产代码与 V1～V20 的集成快照中，观察/清单/模块边界 15 项再次通过，进程退出 0；独立基线打包也退出 0。自有 12 个代码/迁移/测试文件与独立验证快照哈希一致。
- 契约、兼容性变化、保留配置、发布顺序与未验证边界见 [设备观察后端契约](device-observation-contract.md)。
- 下一步：设备持久协议、Android 原生查询、管理与儿童 UI、真实数据库/系统互操作；本阶段不能宣称已具备系统使用管控。

## 阶段记录：观察 SDK、Android 与儿童界面

- Ruling: 观察敏感 pending 使用成熟 FlutterSecureStorage 单记录，而非现有明文 Sembast 配置库；复用固定 SDK 配置和原生持久屏障。原因是使用摘要/清单需要加密持久化；代价是 1 MiB 单记录上限与 SDK 升级/进程中断专项验证责任。
- Ruling: 先独立提交客户端阶段，服务端缺失时停止采集；后端 V20 继续等待协作 V13～V19 完整提交。原因是用户要求阶段提交且必须保持迁移顺序；代价是本提交尚不能独立完成端到端观察流程，必须明确部署依赖。
- 已实现设备协议 14 项、配置协议 60 项、儿童宿主 22 项，全量测试均退出 0；三处 analyze 无问题。新增宿主接入检查证明心跳/前台恢复只刷新、不自动采集，明确操作才查询并报告。
- Android 官方 Pigeon 通道在本任务自有 API34 模拟器完成未授予/授予/撤回三条真实路径，各次驱动退出 0；19 个可见启动应用，授予时 2 条实际聚合。不是 TV/真机或生产服务认证。
- 普通 lib/main.dart APK 重新构建，26.8 秒退出 0；公开组件 Web 39.5 秒退出 0。Chrome 手机/宽屏确认、取消、授权/离线/撤回、键盘焦点和页面检查通过，截图已人工查看。
- 观察加密存储通道检查是 mock；真实观察 pending 进程恢复、真实 HTTP/MySQL、成人管理页和系统执行保持未完成。完整细节见 [观察客户端阶段契约](device-observation-client-contract.md)。

## 阶段记录：成人观察模块与隔离 HTTP

- Ruling: 成人观察页只向 OWNER/GUARDIAN/ORG_ADMIN 开放；初始假设中的教师/审计员只读被撤销，因为实际服务端观察范围检查不允许这些角色。UI 与服务端边界一致，不扩展其权限。
- Ruling: 先单独提交可复用成人模块、工具与文档；设备详情入口归协作任务，V20 后端仍等完整 V13～V19 提交。不能把独立模块称作已发布全链路。
- 模型、编辑器、视图先以缺失实现确认 RED，再 GREEN；后续原因控制字符、实际聚合无障碍标签、错误自动滚动和锁定静态语义均有失败复现与修复。仅修改自有文件，协作任务提供的3项移动错误可见测试和滚动修复已接收。
- 最终独立管理台基线 65b02bd + 自有模型/编辑器/视图/测试，19 项通过。一次独立检查发现快照仍留着较早的教师/审计员角色模型，未算通过；同步最终3角色模型后重新验证。
- 完整工作区管理台 analyze 无问题，57 项通过；观察 SDK analyze 无问题、14 项通过。工作区完整回归含协作文件，独立阶段内容按提交白名单确认。
- 真实 Spring HTTP 夹具在 H2 与隔离 MySQL 8.4 各1项通过，0跳过；实际使用生产 Dart 协议、事务和 Flyway，显式 synthetic source / JWT decoder / 明文测试存储，不冒充真实 Android 加密进程恢复或 OIDC/MFA 登录。
- HTTP 独立快照只有 V1～V12+V20 共13迁移，不能发布到已有生产环境；MySQL 的 Flyway版本认证提示仍保留为发布门槛。生产源码与该快照一致，后来2份旅程测试增加数据库环境配置，不将旧结果冒充更新后的测试结果。
- 公开浏览器验收使用无凭证固定演示状态，实际 Chrome 两尺寸验证。曾因 Flutter canvas滚动、输入框尚未激活、Web引擎未映射只读语义而失败；最终使用观察到的字段位置真实聚焦和键盘输入，锁定原因以静态辅助标签展示，未修改业务数据绕过校验。
- 详细流程、接口依赖、复现与剩余门槛见 [成人观察工作流契约](device-observation-guardian-contract.md)。完整平台目标保持进行中。
