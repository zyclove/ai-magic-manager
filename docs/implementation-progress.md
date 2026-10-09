# 实施记录 — plan: docs/implementation-plan.md

## 当前状态

完整目标仍在实施。Task 1～5 基础后端与审批配置文档交付、Task 6 日期额度账本/租约协议和重复计划，以及 Task 7 已有业务的 Flutter Web 管理端已有代码。各项扩展、系统执行、紧急恢复/原生清理/受管解除、儿童客户端、Task 8～13 和正式环境验收保持待完成。没有把管理员批准、设备自报保存/清理或测试通过当作产品已完整交付。

## 环境证据与实施决定

### 设备观察管理端与 V20 集成（2026-10-09）

设备详情已接入成人“使用情况与隐私”，包含独立授权、报告分页、未知提交原样重试和版本冲突刷新。入口权限与后端设备管理读取范围一致；手机失败提示隐藏问题经三项 RED 后修复，关闭子页保留原设备详情。完整后端 V1–V20 的 255 项、真实 MySQL 的 64 项、前端最终 57 项均通过；analyze 与 HTML release 构建成功。

20:37 本机业务库在备份后升级到 V20，前后端运行产物哈希与独立验证版本一致。真实管理员密码登录成功，三个可见工作空间无实际设备。桌面和手机的填充操作由隔离浏览器响应提供，没有制造业务设备或报告；真实 MFA 成功写入与真机系统观察仍待验收。迁移顺序、兼容性、测试范围和实际运行记录见[观察管理端集成记录](observation-console-integration.md)。

### 2026-10-09 成员资料、权限调整与邀请交互

- 新增 V18：身份服务签名资料按精确账号哈希缓存，较旧签发时间不覆盖新资料；成员列表显示姓名、已验证邮箱、档案名称和权限版本，儿童邮箱不输出。资料更新不改变访问描述的强 ETag。
- 新增角色/范围编辑、稳定标识强版本撤销、版本倒序历史。禁止通过角色编辑交接 OWNER 或转换儿童/成人身份，只有所有者可管理机构管理员。旧 JWT 按当前数据库角色授权；撤销请求重放不撤销重新加入的新版本成员。
- 角色/范围变化、撤销、所有者交接按一致顺序清理邀请、策略预览、待确认配对、退出预览和临时授权。预览记录创建人，其他管理员的有效预览保留；旧未知创建人预览保守失效。MySQL 不区分大小写的候选查询再次进行精确 actor 比较，防止误清理不同账号。
- 管理端新增可识别身份、权限表单和历史查看。儿童/教师显式选档案，默认新邀请为只读审计员，机构管理员不能授予同级管理员。教师教学业务尚未开放，界面准确说明。未知权限提交锁定原内容重试；未知邀请创建引导查看记录和取消，令牌不写幂等日志。取消确认保留详情，邀请成功/未知结果后进入邀请记录。
- `.local/member-final-verify.log`：**225 项通过、0 失败/错误/跳过**，三组 Spring/Dart HTTP 联调均执行。新增成员专项 **13 项**（含故障回滚），与所有者交接 **14 项**在独立 MySQL 库再次通过，共 **27 项**；临时库与账号已清理。
- 全量构建曾因本机可用内存不足导致 JVM 原生内存分配失败；最终通过 JAVA_TOOL_OPTIONS 限制堆并逐类启动测试进程完成，没有修改业务逻辑绕过失败。失败日志/崩溃文件保留在忽略目录。
- Flutter analyze 无问题，**26 项通过**，最终 HTML release 构建完成。真实 Chrome 登录成功；真实成员列表、访问描述与历史均 200，强 ETag 正确，资料已同步；密码登录的敏感修改返回 401 REAUTH_REQUIRED，未伪造 MFA 或改变真实成员关系。
- 桌面 1440×1000/手机 390×844 的模拟编辑、同键原内容重试、教师范围、邀请令牌复制、取消返回、历史返回、未知结果恢复、版本撤销均通过，7 次模拟写入全部由浏览器夹具拦截，浏览器异常 0。日志 `.local/member-browser.log`，真实接口日志 `.local/member-live-browser.log`，截图使用 member- 前缀并区分 live/fixture。
- 本机业务库从 V17 迁移至 V18；后端 PID **162032**，前端 PID **104600**。运行 JAR、标准 backend/target JAR 与独立验证构建 SHA-256 一致，服务健康。没有提交或推送本轮代码；完整目标仍在实施，机构范围、教师业务、通知、恢复及后续产品阶段仍待完成。

### 2026-10-09 所有者交接与管理端更新

- 新增 V17、成员版本和成员控制行；现任所有者发起、目标成人接受/拒绝、原所有者撤销，24 小时截止、双方角色差异、唯一生效待办、强版本/幂等、租户隔离和完整审计。接受同事务失效原所有者邀请、待确认配对、临时授权及退出预览，并要求未发布策略重新预览；不撤销已提交的策略/退出事实。
- 成员被移除后重新加入不能恢复旧申请；租户资料变化使旧提案失效。监听器故障整体回滚双方角色与交接。MySQL 实测发现 tenants 外键父表独占锁与另一管理员审计写入产生死锁，已用共享控制行协调资料修改，交接只递增成员/交接版本；失败和修复证据见 ownership-transfer-plan.md。
- 管理端新增独立“所有者交接”入口，含原角色/新角色、完整账号标识、确认后果、错误保留、原提交重试与角色刷新。修复“发起后立即撤销”的列表刷新时序。注册弹窗新增导入 JSON 的一键复制；内容只含 tenantId/id/token/expiresAt。
- 最终后端独立构建 `.local/ownership-final-verify.log`：**212 项通过，0 失败/错误/跳过**，包含 3 项显式启用的真实 Spring/Dart HTTP 联调；其中交接 14 项另在独立 MySQL 库通过，临时库/账号已清理。Flutter analyze 无问题、**21 项测试通过**，HTML release 构建通过。
- 真实 Chrome 管理员登录及读取通过；仅密码认证交接写入返回 401 REAUTH_REQUIRED，未伪造 OTP。桌面/手机交接完整交互使用明确浏览器夹具，未改变真实所有权。截图与浏览器日志区分真实 API 和模拟结果。
- 本地 MySQL 已应用 V17，前端继续监听 3000，最终后端 PID 164904 监听 8082 并健康 UP。常规启动的 backend/target JAR、运行 JAR 与独立验证产物 SHA-256 一致；没有回退数据库、提交或推送本轮代码。
- device_access 的 http_parser 最低版本放宽为 ^4.0.2，以兼容 Flutter 3.22.2 固定 collection 1.18 的本地化依赖；独立 Flutter 依赖解析通过，无 overrides。原生宿主/系统执行仍由后续任务验证。
- Task 1 的成员角色编辑、可识别成员资料、机构细分范围、通知、恢复与治理仍待完成；完整产品目标保持进行中。

- 2026-10-08：开始实施时仅有四份设计文档，无源代码或 Git。当前新增 Spring Boot 后端及实施文档。
- 初始环境：Java 17.0.14、Maven 3.9.7、Flutter 3.22.2/Dart 3.4.3 可用；当时 Docker daemon 未运行。2026-10-09 已运行本机 MySQL/Keycloak 容器，见后续联调记录。
- Java 目标 17 LTS，使用 Boot 3.5.16 与 Modulith 1.4.0 兼容系列；springdoc 2.9.1 用于 OpenAPI 3.1。版本升级、安全扫描及部署 JVM 更新另需验收。
- 用户已授权完整实施，当前会话直接执行。本机服务已按用户要求启动；Git 已由另一获授权会话初始化并提交阶段版本，本会话不重复提交或部署到外部账户。
- Spring JDBC 显式约束租户与对象；授权取数据库事实，不能只靠 JWT 中的可变角色。
- 单可信 issuer 下，身份索引用精确 sub 的 SHA-256 标准摘要，避免数据库默认排序规则混同身份。多 issuer 是后续显式迁移，不隐式开放。
- V1/V3 迁移本轮整理了 actor_key：尚未发布/未有客户数据库，只有本地 H2 运行。已部署环境不应修改迁移 checksum，应另做 expand/backfill/contract。

## 已落地范围

| 模块 | 已实现 |
|---|---|
| 身份 | Spring/Nimbus JWT、issuer/audience/subject/expiry、近期 MFA、Bearer 无状态 API、显式 CORS |
| 租户/成员 | 创建/列表、OWNER 关系、角色/主体范围、邀请/接受/取消、撤销成员、保护 OWNER |
| 儿童主体 | 创建/列表/详情、强 ETag 编辑、近期认证归档；归档不伪装删除 |
| 幂等/事务 | 持久唯一键、异载荷冲突、并发串行、撤权后重试拒绝、业务/响应/审计同事务 |
| 平台基础 | Flyway、分页、稳定错误、关联日志、审计查询、默认安全头、鉴权 OpenAPI 3.1 |
| 设备接入 | 一次性票据、ES256 原密钥证明、管理员配对确认、独立 opaque 凭证、两阶段轮换/恢复/撤销 |
| 能力/观察 | 心跳序号/请求去重、完整快照事务批写、儿童范围、未知/过期/未验证状态；不提升系统权限 |
| 应用/时间/策略 | 声明身份、可见清单云端契约、IANA/DST 计划、规则/恢复豁免、预览、配置版本/幂等/回滚；没有系统执行成功 |
| 配置交付/消息 | 外置 Nimbus JWS、单设备拉取/游标/移除、回执/历史/过期、成熟框架通知登记与重试；真实 Broker/设备执行未验收 |
| 访问审批 | CHILD 范围申请、近期 MFA/版本/幂等决定、取消/撤销、冷却、限期与生命周期失效；CONFIGURE_ONLY 签名窗口/撤回文档和设备自报回执，不执行设备解锁 |
| 退出/清理任务 | BYOD 后果预览/确认、云端撤销与审批失效、原密钥限时认证、独立签名命令/公钥/回执、取消/新任务/到期；不伪装本地或系统执行 |
| 管理界面 | Flutter Web、PKCE、令牌刷新、工作空间/角色、已有业务表单和查询、宽窄屏布局、错误与版本冲突、未知结果原样重试 |
| 共享额度 | 日期与时区池、强版本增减、跨设备事务预留、独立签名租约、累计结算/去重、未知消费保留、跨日补报；生产硬额度执行门槛尚未满足 |
| 设计交付 | 增加产品闭环、商业目录/容量/账单异常、数据库落地、实际接口状态文档 |

## RED → GREEN 证据

本机命令统一使用项目内 `.local/m2` 依赖缓存；日志位于被忽略的 `.local/`。快速数据库为 H2 MySQL 模式。

| 阶段 | RED | 已确认 GREEN |
|---|---|---|
| 租户/儿童/审计 | 10 tests，9 failures（缺接口 404），0 errors | 10 tests 全通过 |
| 邀请/接受/撤销/近期认证 | 18 tests，7 failures（缺接口） | 18 tests 全通过 |
| 持久幂等/404 错误 | 22 tests，3 failures（重复资源/错误状态） | 22 tests 全通过 |
| MFA 组合 | 24 tests，1 failure（OTP 单因子被接受） | 后续套件中通过 |
| OpenAPI/排序规则隔离 | 27 tests，3 failures（404/身份误合并/响应误复用） | 27 tests 全通过，日志 task1-collation-green.log |
| 编辑/归档/邀请取消 | 32 tests，4 failures（缺路由 404） | 32 tests 全通过，日志 task1-lifecycle-green.log |
| 实际 RSA 签名校验 | 初次编译缺 helper；抽出原 validator 后 39 tests，1 failure（audience 缺失 NPE） | 最终套件全部通过 |
| 强制期限/声明边界 | 42 tests，2 failures（audience 缺失 NPE、expiry 缺失未拒绝） | 42 tests 全通过，日志 task1-verify.log |

Task 1 verify：2026-10-08 15:42:13 完成，42 tests / BUILD SUCCESS。设备模块的后续完整构建与当前总数见下一节。可执行产物 `backend/target/manager-backend-0.1.0-SNAPSHOT.jar` 证明打包通过，不代表已启动生产服务。

测试包含真实 HTTP 控制器、业务事务、SQL、审计与 Spring Modulith 边界。多数旅程使用测试 JWT 上下文；独立身份用例通过 Nimbus 真实 RSA 签名和同一生产 validator 校验。没有外部 IdP 发现/公钥轮换成功证据。

## Task 2 执行与证据

- 新增 fleet/deviceidentity 模块；Spring Security 独立认证链处理用户、设备和一次性注册路由。JOSE 通过显式 Nimbus SDK 依赖验证，未自研签名算法。
- V4～V6 数据模型覆盖设备注册周期、凭证域、两阶段轮换、能力快照及目的/jti 反重放。当前仅注册 BYOD，正式 EMM 未配置，其他强模式明确返回不支持。
- RED：首次 54 tests，12 failures 因注册路由缺失；首次实现 54 tests 有 1 error 来自 Mock JwtDecoder 默认返回 null，已改成模拟真实非法 JWT 异常。
- 轮换 RED：56 tests，2 failures，证明即时撤销旧凭证不能满足丢失响应恢复；改为 staging → activate，56 tests 全通过。
- 边界验证：61 tests 全通过，包含并发认领、证明用途/nonce/有效期、私钥输入拒绝、儿童权限、证据状态、凭证/暂存期限。
- OpenAPI RED：61 tests，1 failure（公开认领继承了 JWT 安全定义）；显式公开/设备安全方案后 61 tests 全通过。
- 恢复 RED：63 tests，2 failures（恢复路由未实现）；原密钥、独立用途、新 jti、期限/次数及配对失败保留实现后 63 tests 全通过。
- 2026-10-08 16:18:41：`mvn ... verify`，63 tests / 0 failures / 0 errors，BUILD SUCCESS，日志 `.local/task2-complete-verify.log`。
- 最终审阅构建：2026-10-08 16:22:48，63 tests / 0 failures / 0 errors / BUILD SUCCESS，日志 `.local/task2-reviewed-verify.log`。包含 JDBC 布尔类型映射与秘密响应 DTO 的安全 toString，已重新生成可执行 JAR。
- 21 项设备旅程测试使用实际 ES256 签名和 Spring opaque token + 数据库验证；没有 Android/TV 硬件证明、平台执行或真实 MySQL/OceanBase 证据。

## Task 3 执行与证据

- 新增 catalog/schedule/policy 模块与 V7/V8；跨模块只用公开目录/设备接口，Spring Modulith 边界校验继续执行。
- 应用与时间定义不可变；策略引用在预览中解析并保存。设备清单是凭证绑定的可见应用观察，不认证所有安装应用、更新签名或内容安全。
- 规则输入与冲突处理覆盖启动、安装、卸载保护、运行时/特殊权限、额度、时间、域名和提醒；清晰拒绝无关字段和不可覆盖恢复底线。
- java.time 使用运行时 TZDB，覆盖半开区间、跨午夜、日期例外、春季缺口、秋季重复、半小时切换和跳过日期。它不是设备可信计时或额度账本。
- 配置发布先复核草稿、预览、设备/能力证据与近期 MFA；版本/操作/outbox/审计同事务。当前 CONFIGURE_ONLY 仅配置保存，ENFORCE 拒绝不支持/缺适配器，不创建执行成功。
- 回滚修订原策略草稿，保留原 policyId 和版本编号连续性；重新预览、发布产生新版本，历史不改写。
- 初次 RED：71 tests，8 failures（应用/计划/策略路由缺失）；初次实现 71 tests 全通过，日志 `.local/task3-initial.log`。
- 边界扩展：85 tests / 0 failures / 0 errors / BUILD SUCCESS，日志 `.local/task3-edge.log`，含并发编号、不可变版本、撤权/MFA/过期/变化及 DST。
- JSON 契约/历史分页验证：88 tests / 0 failures / 0 errors / BUILD SUCCESS，2026-10-08 21:51:12，日志 `.local/task3-verify.log`。此构建之后又修订了回滚并新增应用清单，以最终构建为准。
- 应用清单 RED：3 tests / 3 failures（上报/查询路由 404），日志 `.local/task3-inventory-red.log`；实现后 91 tests 全通过，2026-10-09 04:54:47，日志 `.local/task3-inventory-verify.log`。
- 最终审阅：2026-10-09 04:57:36，`mvn ... verify`，95 tests / 0 failures / 0 errors / BUILD SUCCESS，日志 `.local/task3-reviewed-verify.log`。包含 19 项策略旅程、7 项时间用例、6 项真实 opaque 认证的应用清单用例，加已有 63 项回归；可执行后端 JAR 已验证打包。
- 本轮没有 Android/TV 采集或拦截成功证据、真实数据库并发/容量证据或 Broker/供应商回执；应用清单和 CONFIGURE_ONLY 的成功仅覆盖云端接口/数据流程。

## Task 4 执行与证据

- Ruling：先实现 CONFIGURE_ONLY 的真实交付链，ENFORCE 保持显式不支持/未配置；正式 EMM/原生/规则级回执仍是完整目标 — 普通 BYOD 不能提供系统级执行证明 — 当前不会宣称强管控完成。
- Ruling：采用 Spring Modulith 1.4.0 JDBC 事件登记与 Spring Kafka/JMS，不自研消息持久重试 — 只登记有界通知元数据；签名文档独立持久化 — 真实 MySQL/OceanBase、Broker/MQTT 仍需验证。
- 同步领域投影与策略原事务绑定；异步通知网络 I/O 不持有业务 JDBC 事务。历史 policy_outbox 是原配置事件日志，不是新的通知确认权威。
- V9 交付域表 + V10 MySQL/H2 vendor 脚本；类型取自 SDK 自带 schema，自动 DDL 关闭。外置私钥启动校验、旧公钥保留、public-only VERIFY 与安全异常实现。
- HTTP 交付 RED：7 tests / 7 failures（路由 404），日志 `.local/task4-red.log`；实现后 102 tests 全通过，2026-10-09 05:12:44，日志 `.local/task4-initial.log`。
- 通知 RED：缺监听器导致发送等待超时；另一个测试误把容器生命周期调用当成业务发送，改为仅验证 send 未执行。日志 `.local/task4-messaging-red.log`。
- 审阅 RED：12 tests / 2 failures，公钥 SIGN 用途未规范为 VERIFY、STORED 被迟到拒绝覆盖；修复后 109 tests 全通过，日志 `.local/task4-messaging-green.log`。
- 非网络 JDBC 事务监听方案：109 tests / BUILD SUCCESS，2026-10-09 09:49:17，日志 `.local/task4-verify.log`。
- JMS 测试初次编译出现 jakarta.jms/java.lang 同名异常类歧义，显式限定后修复；113 tests / 0 failures / 0 errors / BUILD SUCCESS，2026-10-09 09:52:23，日志 `.local/task4-reviewed-verify.log`。
- 最终构建：2026-10-09 10:00:54，`mvn ... verify`，116 tests / 0 failures / 0 errors / 0 skipped / BUILD SUCCESS，日志 `.local/task4-final-verify.log`。包含拒绝状态过期不自动重试、引用 UUID 规范校验及签名文档应用引用一致性；可执行 JAR 已打包。
- Nimbus 与 opaque 身份路径为实际 SDK/数据库验证；Kafka 外部发送为测试替身，JMS 使用真实 JmsTemplate 与模拟 ConnectionFactory/Session/Producer。没有 Broker、MQTT、EMM、客户端缓存或真机成功证据。

## 产品与商业设计增强（2026-10-09）

- 新增[完整产品交付与商业运营模型](parental-control-product-operating-model.md)：全量工作包、状态机、审批/批量任务、页面信息、边缘场景、可售单元、权益合并、运营责任与发布门槛。
- 新增[数据库实施与认证规格](database-implementation-and-certification.md)：MySQL/OceanBase 决策、数据域、索引/事务、容量模型、真实 profile 认证、迁移回退与运维。
- 该次设计增强仅更新契约，未添加产品代码或执行新的后端测试；当时引用已完成的 Task 4 构建日志。其后审批代码与验证见下节，仍不代表完整功能或生产认证完成。
- 文档检查：65 个 docs 内本地 Markdown 文件链接，失效 0；新增规格无 TODO/TBD 占位。商店/数据库条件依据官方资料复核，未宣称获得准入或生产认证。

## Task 5：云端审批执行与证据

- Ruling：先完成 APP_LAUNCH/TIME_WINDOW 的云端访问窗口、期限和权限链；额度追加属于 Task 6 账本，签名例外/设备执行、SAF/END 继续保留 — 当前不存在合格执行适配器 — 不把管理员批准当作应用已解锁。
- 新增 approval 模块及 V11：申请、资源冷却槽、唯一决定、精确身份/基础/注册/主体绑定、时限与索引。公开 Fleet/Subject/Policy 边界复用现有 Spring Security、JDBC、MFA、幂等和审计。
- 创建仅 CHILD 本人范围；决定/撤销需当前成人权限与近期 MFA；强 ETag 和唯一决定序列化两位监护人的并发请求。儿童响应不包含审批人身份，理由不进入普通日志或审计。
- 通过策略新版本、成员撤权、主体归档与注册撤销的事务内事件持久失效旧例外；恢复成员不复活历史决定。请求者/设备主体变更在批准及读取时再次验证。
- Spring Scheduler 执行有界到期批次；详情/列表也持久校验失效、增加版本并写系统审计，避免动态状态复用旧强 ETag。后台清理不替代设备本地到期。
- 初始 RED：7 tests / 7 failures（路由缺失），日志 `.local/task5-approval-red.log`。首次实现剩 1 个错误为测试将毫秒写入 TIMESTAMP；修正夹具类型后 7 项通过，2026-10-09 10:39:47，日志 `.local/task5-approval-initial-green.log`。
- 生命周期 RED：11 tests / 2 failures（设备撤销不失效、动态过期复用版本）；修复后审批 11 项 + 模块边界 1 项通过，2026-10-09 10:45:49，日志 `.local/task5-approval-lifecycle-green.log`。
- 作业/撤权 RED：缺到期边界、正式成员撤权未立即持久失效；14 tests / 2 failures，日志 `.local/task5-approval-revocation-red.log`。修复后全量 130 tests / BUILD SUCCESS，2026-10-09 10:52:05，日志 `.local/task5-approval-verify.log`。
- 绑定审阅 RED：2 tests / 2 failures（设备改绑仍批准、请求者改主体仍有效），日志 `.local/task5-approval-binding-red.log`；修复了批准目标比较、当前注册/主体与请求人范围检查。
- 最终验证：2026-10-09 10:56:53，`mvn ... verify`，132 tests / 0 failures / 0 errors / 0 skipped / BUILD SUCCESS，日志 `.local/task5-approval-final-verify.log`，可执行 JAR 已重新打包。含 16 项审批旅程与既有 116 项回归。
- H2/MockMvc 为真实事务与 SQL 路径；JWT/设备是明确测试夹具，尚无真实 MySQL/OceanBase 并发/作业计划、IdP、例外签名/设备执行或恢复/退出证明。实际范围见[审批契约](access-request-contract.md)。

## Task 5：云端正常退出与清理任务执行及证据

- Ruling：先完成 BYOD 正常退出的具体后果预览、云端撤销与限时本代理清理链；正式 EMM 解除、整机擦除与原生执行仍保留 — 当前没有合格系统执行适配器 — 不将原密钥自报当作独立清理证明。
- 新增 lifecycle 模块和 V12；通过 FleetAdministration/RegistrationKeys/FleetPolicyAccess 公开边界复用 Fleet。Nimbus 签名/验签、Spring Security 独立认证链、JDBC 事务/锁、幂等与 Spring Scheduler 均用成熟组件。
- 普通凭证撤销后，原注册密钥仅访问 `/device-cleanup`，不能重新取得业务访问权。READ 可发现当前任务解决撤销后的引导问题；RECEIPT 必须绑定操作。短时证明可重用，不虚构一次性反重放。
- 预览绑定近期 MFA、当前成员、设备版本、原注册、确认人、后果哈希与期限。云端撤销、已有审批失效、签名命令、预览消费、幂等响应及审计同事务；缺签名配置或数据库持久失败不会部分撤销。
- 管理响应分 remoteAccess 与 localEvidence，CLEANUP_REPORTED 保持 DEVICE_REPORT_UNVERIFIED。取消不恢复凭证，不能召回离线缓存命令；取消/到期的新任务使用新 ID，旧任务不接受后续证明/回执。
- 初始 RED：4 tests / 4 failures（缺接口 404），日志 `.local/task5-cleanup-red.log`。首次实现 4 项通过，2026-10-09 11:15:11，日志 `.local/task5-cleanup-initial.log`。
- 边界/模块检查：13 tests / BUILD SUCCESS，2026-10-09 11:17:40，日志 `.local/task5-cleanup-edge.log`。含 12 项退出旅程及模块边界。
- 到期边界 RED：测试编译缺 CleanupMaintenance，日志 `.local/task5-cleanup-maintenance-red.log`。首次全量 147 tests / 1 failure 为全局 worker 被测试误按单租户计数；改为排空其他夹具、关闭测试自动 tick，仅验证显式维护调用。原子性与无签名配置 17 项通过，2026-10-09 11:23:03，日志 `.local/task5-cleanup-atomic-green.log`。
- 密钥兼容 RED：1 test / 1 failure（预览 201 而非 409），日志 `.local/task5-cleanup-key-red.log`；统一预览与清理认证的 SDK 公钥元数据检查，拒绝不允许 ES256/VERIFY 的历史注册密钥。
- 两次全量 150 tests 全通过但默认 JAR 重打包失败，日志 `.local/task5-cleanup-final-verify.log` / `.local/task5-cleanup-reviewed-verify.log`。Windows 现有 Java 进程占用默认产物；没有终止进程，将 Maven finalName 改为可配置并使用新的名称构建。
- 最终验证：2026-10-09 11:31:21，`mvn ... verify -Dbackend.artifact-name=manager-backend-cleanup-20261009-1130`，150 tests / 0 failures / 0 errors / 0 skipped / BUILD SUCCESS，日志 `.local/task5-cleanup-artifact-verify.log`。其中 17 项退出旅程、1 项无签名配置旅程与既有 132 项回归。
- 可执行产物：`backend/target/manager-backend-cleanup-20261009-1130.jar`，73,359,997 字节。默认路径的旧 JAR 不作为本轮打包证明；新产物没有部署到现有服务。
- 最终文档检查：82 个 docs 内本地 Markdown 文件链接，失效 0。JAR 内容包含 Boot Launcher、LifecycleController 和 V12 迁移。实际契约见[设备退出契约](device-deprovision-contract.md)。
- H2/MockMvc 与真实 Nimbus 覆盖云端事务、密钥/用途/任务、取消/期限、乱序回执、数据库故意失败的回滚及审批失效；没有真实 MySQL/OceanBase、原生清理/密钥删除、EMM/擦除、离线/重启或 UI 成功证据。

## Task 6：共享额度阶段记录（2026-10-09）

- 新增 quota 模块与 V13：整数秒日池、儿童固定 IANA 时区、TOTAL/APPLICATION 交集、共享预留、租约/分配、账本、持久事件日志；管理修改要求近期 MFA、强版本和稳定幂等键。
- Ruling：先交付明确日期的池，重复每日模板、时区安全变更与审批追加另行实现；代价是当前需逐日配置，不能宣称完整 QUO-01 完成。
- Ruling：生产 QuotaExecutionSupport 明确拒绝硬额度发放，直到真实设备计时/持久恢复/停止适配器认证；代价是当前只有可配置的账本与完整协议验证，不能实际限时停止应用。
- 实际 JDBC/MockMvc/Nimbus 覆盖并发总额、交集、幂等换体、累计序号、时间/单调计数、注册凭据、跨日补报、未知预留保留与事务故障回滚。执行认证接口单独替身，不把测试夹具称为真实设备证据。
- 初始路由 RED 后管理用例通过；结算时钟用例 RED 暴露服务端流逝时间约束缺失，修复后通过。真实 MySQL 初次 7 项通过，日志 `.local/quota-mysql-verify.log`。
- 独立审阅发现 2 项 Important：额度与访问窗口锁序反转；已有租约后新增应用池会漏计旧租约。修正测试代理夹具后，两项用例均真实失败（201 而非 409；死锁请求 500），日志 `.local/quota-review-red.log`。
- Final: fixed 两项 Important — 主体→设备→凭证域统一顺序并锁后复核绑定；同日应用已发租约时禁止新增应用池。相关 12 项 RED→GREEN，`.local/quota-review-green.log`；跨域用例实际执行 PolicyExceptionAccess 使用的公开主体/设备锁边界，并非完整审批 UI 联调。
- 真实 MySQL 8.4.11 独立临时库：9 项通过，含上述两项修复，2026-10-09 13:18:45，`.local/quota-mysql-reviewed.log`。全部 13 个迁移真实执行；临时账号和库已清理，未操作业务数据。
- 全量后端：169 tests、0 failures/errors/skipped，BUILD SUCCESS，2026-10-09 13:20:28，`.local/quota-final-verify.log`。包含并行部署工作新增的 3 项 JWKS 测试和本阶段 12 项额度用例。
- 2026-10-09 13:21：本机后端已用新 JAR 重启；MySQL 业务库 V12→V13 成功，8082 健康检查 UP。前端、Keycloak、MySQL 持续运行。
- 前端共享额度列表、详情、三类余额、调整和账本已接入。独立审阅的默认日期问题按实际影响提升为修复项：跨时区时会选择错误额度日。已抽取原逻辑并在 Chrome 复现洛杉矶日期 10-08 错为 10-09，使用浏览器标准 Intl 的 IANA 日期转换修复，后续检查见管理端记录。
- Final: fixed 默认日期跨时区错误 — Chrome 日期回归 RED→GREEN；Flutter 9 项、Chrome 1 项通过，静态分析无问题。正式 HTML/本地资源/无 PWA 构建通过，管理员实际登录、额度读取、MFA 拒绝提示、桌面与手机弹窗通过，无浏览器异常；不将密码会话拒绝当作敏感写入成功。
- 该轮结束时仍缺重复日计划、时区变更、策略基线/审批联动、事件消费者、客户端离线/重启/执行和保留治理；重复计划的后续交付见下一节，阶段契约见[共享额度契约](shared-quota-contract.md)。

## Task 6/7：重复额度计划（2026-10-09）

- 新增 V14 和计划/修订模型：儿童每种额度范围一个计划，七日规则、最多 60 个日期例外、今天/明天开始、修改/暂停/恢复次日生效、不可变历史和池来源版本。手工已有池优先，已用量与预留不会被计划编辑重置。
- 沿用 Spring JDBC/Flyway、java.time、Spring Scheduler 与 Flutter Material。后台索引批次逐计划短事务；设备新租约在同一事务先生成总/应用全部适用池；故障回滚、失败延后和停机不补历史预算。
- 计划表单读取儿童实际额度日历时区和服务端当地日期，支持工作日/周末填充、日期例外、即时分钟校验、次日生效说明、稳定幂等键及未知提交原样重试。列表、详情和版本历史覆盖成人与儿童/审计只读角色。
- 计划接口初始 RED 路由缺失；随后补充跨日、暂停恢复、手工池优先、六并发生成、DST 23/25 小时、设备即时生成交集与数据库故障回滚。日历接口 RED→GREEN 后专项 23 项通过，`.local/quota-plan-calendar-green.log`。
- 真实 MySQL 8.4.11 临时独立库执行 V1～V14：19 项通过（计划 9、并发 10），2026-10-09 13:52:03，`.local/quota-plan-mysql.log`。临时用户/数据库已清理；JWT/设备能力门槛仍是明确的测试夹具。
- 完整后端 179 tests / 0 failures / 0 errors / 0 skipped / BUILD SUCCESS，2026-10-09 13:56:05，`.local/quota-plan-final-verify.log`。已生成可执行 JAR，包含并行部署工作添加的 JWKS 验证。
- 本机业务库 V14 成功迁移，13:56:49 后端重新启动，8082 健康 UP。Chrome 真实管理员登录成功，认证方法仍为 pwd；没有配置或冒充用户验证器。
- Chrome 实际计划/日历读取、分钟上限、工作日填充、日期例外、提交正文、密码会话 401 认证提示均通过。浏览器发现并修复修正分钟数后旧提示残留、长表单错误提示位于可见区域之外：两项组件 RED→GREEN。最终 Flutter 14 项通过、analyze 无问题、HTML release 构建通过，手机滚动与固定操作栏截图检查完成，浏览器脚本异常 0。日志 `.local/quota-plan-ui-validation-red.log`、`.local/quota-plan-ui-scroll-red.log`、`.local/quota-plan-frontend-test.log`、`.local/quota-plan-analyze.log`、`.local/quota-plan-browser.log`。
- 独立审阅最初受默认工具初始化及输出截断阻塞，改为提权只读及分段读取后完成限定五个实现文件的审阅。确认 1 项 Important：本地日期加 24 小时在夏令时回退日仍为当天；1 项 Minor：同名计划无法识别儿童/应用。两项已修复：日期使用 UTC 日历字段构造，日期选择器上限同样按日历构造；列表/详情/编辑显示儿童及应用名称，读取名称失败保留精确目标 ID，工作空间切换重新载入目标名称。
- 夏令时浏览器夹具明确设定 America/New_York、日历日期 2026-11-01，修复前勾选明天仍显示 11-01，修复后为 11-02。日志 `.local/quota-plan-dst-red.log`、`.local/quota-plan-dst-green.log`。目标显示只读响应夹具验证列表、详情、编辑，名称来自实际范围内档案/应用；`.local/quota-plan-targets.log`。两类夹具都未写入业务数据，且不作为真实计划创建证据。
- 实际敏感创建/修改的成功提交仍需本人绑定验证器；服务端事务与权限通过自动化覆盖，不能替代真实 OTP 端到端证据。原生执行、时区迁移、审批/策略联动、事件交付和完整产品剩余范围继续保留。

## Task 5/7：审批签名文档与交付历史（2026-10-09）

- 新增 V15、AccessDeliveryService/Controller：设备独立凭据分页发现曾批准的申请、下载当前审批版本的 Nimbus ES256 文档，报告接收/保存/拒绝；管理端查询当前交付和分页历史。签名类型独立，绑定 tenant/request/version/subject/device/registration/baseVersion/application/rules，排除儿童理由与成人身份。
- 原批准起止时间不随下载、并发重试或断网延长；撤销/到期产生更高版本的 REMOVE_ACCESS_WINDOW。文档模式固定 CONFIGURE_ONLY、quotaEffect=UNCHANGED、执行状态 NOT_ENFORCED，不能用于实际解锁或加时。
- 主体→设备→凭证→审批→文档锁顺序；签名/文档/审计同事务。旧回执只保留历史，重复早期阶段不倒退当前状态；矛盾终态返回冲突。每轮设备同步需要从首页完整扫描，不能把 UUID 分页当增量游标。
- 初始 RED：4 项路由缺失失败，`.local/access-delivery-red.log`。边界专项 9 项通过，`.local/access-delivery-edge.log`：真实 opaque 凭据/Nimbus 验签、并发下载唯一文档、生命周期失效、跨设备拒绝、终态/原因冲突、旧回执隔离和审计失败整体回滚。
- 真实 MySQL 8.4.11 临时独立库执行 V1～V15，9 项专项通过，2026-10-09 14:31:59，`.local/access-delivery-mysql.log`。临时库/账户已清理。该结果不代表原生设备执行、OceanBase 或真实 OTP 敏感写入。
- 后端完整构建：188 tests / 0 failures / 0 errors / 0 skipped / BUILD SUCCESS，2026-10-09 14:34:17，`.local/access-delivery-final-verify.log`，包含模块边界检查。14:36:37 本机业务库 V15 迁移成功，新 JAR 已启动；3000 前端、8082 健康和 8081 身份发现均返回 200。
- Flutter 增加交付标签、批准截止、当前文档/回执和分页历史。15 项组件检查通过，`.local/access-delivery-frontend-test.log`。静态分析、HTML release 构建及最后 UI 操作记录见管理端交付记录。
- Chrome 管理员真实密码登录成功、真实审批列表读取 200；填充的桌面/手机详情和历史使用明确只读响应夹具，不写入业务数据。浏览器脚本异常 0。窄屏列表语义合并导致初次检查定位失败，修正定位后完成，不把脚本定位问题当作产品缺陷。
- 收尾发现关闭历史同时关闭申请详情，增加显式 closeOnSuccess 选项，让只读历史返回原详情；后续静态分析、构建与浏览器操作单独记录，不将此前 15 项组件结果作为这一变更的新增测试证据。
- V15 阶段 REJECTED 为同文档终态，同审批版本仍返回原文档。当时临时 BASELINE_MISSING/STORAGE_FAILED 的可恢复交付尝试尚未实现；后续 V16 进展见下一节。新增签发路由已使用统一 signer.requireConfigured，尚未新增独立缺配置旅程；既有公共签名配置检查不冒充该路由的专门证据。
- 独立客户端验签/持久水位/离线恢复、规则级执行、通知及额度追加继续保留。完整协议见[签名审批文档契约](access-window-delivery-contract.md)，不将此阶段标记为整个 Task 5 或完整产品已完成。

## Task 5/7：临时拒收恢复与交付诊断（2026-10-09）

- Ruling：授权文档保持不可变，恢复创建独立交付尝试 — 避免为了排除存储故障重新批准、改变原截止或生成另一份授权 — 客户端需记录并提交尝试编号。旧客户端省略编号时只归第 1 次，不会误确认后继。
- V16 保留原签名与时间，将已有文档/回执映射为第 1 次；新尝试表、回执表、当前指针与审计同事务。BASELINE_MISSING/STORAGE_FAILED 可重试，30 秒指数退避至 5 分钟、最多 10 次；剩余窗口不足或审批版本变化则拒绝旧批准重试。撤回文档在原截止之后仍可恢复交付。
- 新增诊断字段和尝试历史路由；管理端显示尝试次数、拒收原因、恢复状态和最早重试时间，可从文档历史进入逐次记录。设备凭据发起恢复，管理员界面不会通过用户 JWT 冒充设备确认或执行。
- RED：原接口缺失，14 项中 4 失败/1 错误，`.local/access-retry-red.log`；初次 H2 实现 14 项通过，`.local/access-retry-green.log`。追加剩余期限检查后审批交付专项为 15 项，另有 1 项精确 V15→V16 SQL 的非空旧数据迁移检查。
- 首次真实 MySQL 暴露并发错误：两项并发下载/重试出现 403，H2 未复现，`.local/access-retry-mysql-red.log`。原因是认证读取建立了旧快照，等待文档锁后关联尝试仍使用快照读取，看不到其他事务的新记录。锁后文档/尝试/回执改为当前读，并增加同阶段并发回执只记一次的检查。
- 修复后 MySQL 8.4.11：16 项 / 0 failures / 0 errors / BUILD SUCCESS，2026-10-09 15:00:14，`.local/access-retry-mysql.log`。一个独立临时库完整执行 V1～V16 并验证 15 项控制器/事务旅程，另一个临时库用最小父键运行原始 V15/V16 SQL，检查四种文档状态与五条旧回执保留；不把最小迁移夹具当作全业务存量库认证。两个临时库和用户均已清理。
- Flutter 17 项通过，analyze 无问题，HTML release 构建通过；日志 `.local/access-retry-frontend-test.log`、`.local/access-retry-analyze.log`、`.local/access-retry-build.log`。
- 后端最终 verify / 可执行打包成功，2026-10-09 15:02:42，`.local/access-retry-final-verify.log`：196 项发现，195 项通过，0 failures/errors，1 项跳过。跳过的是并行工作新增的 DeviceConfigurationHttpInteropTest，原因明确为未设置 device.dart.command；不将其计为本轮通过。审批恢复与迁移用例全部执行。
- 15:03:39 本机业务库 V15→V16 成功，后端 PID 139056 健康 UP。最初部署等待使用两秒 Invoke-WebRequest，等待脚本超时；现有 Java 进程实际已成功启动。直接 curl 与较长超时读取均为 200，因此没有重复重启，继续部署成功的前端产物；实际服务的 main.dart.js 与构建产物哈希一致。
- Chrome 管理员真实密码登录成功，真实审批读取 200。桌面 1440×1000、手机 390×844 的拒收原因、恢复状态、文档/尝试历史、滚动与逐级返回已检查，脚本异常 0，`.local/access-retry-browser.log`。填充数据为明确 GET-only 响应夹具，不写业务数据、不冒充真实设备交付或 OTP 敏感写入。SelectableText 的值不在普通 innerText 中，首次脚本等待值文本超时；改用实际字段标签定位后，人工检查截图中的字段值与布局。
- 这一步提供云端恢复接口与管理诊断；独立审批客户端的验签、恢复队列、自动同步、可信时间与原生执行仍待实现，不能称为真机自动恢复成功。

## Task 5/7：独立设备审批验签与恢复日志（2026-10-09）

- 新增独立 `packages/device_access`，复用 jose、Sembast、crypto、collection，与配置接收组件分离。外部可信公钥、完整 issuer/tenant/subject/device/registration、基础/应用/规则与固定期限均检查；始终 CONFIGURE_ONLY、UNCHANGED、NOT_ENFORCED。
- 事务同时保存原始 JWS、每申请最高审批版本、已观察时间与待发送终态回执；相同版本不能替换文档，后继不得改变原授权范围/期限。撤回水位重开保留，旧版本及更高 UPSERT 均不能复活已撤回申请；同次拒收不变成保存，新尝试只恢复交付。
- 失效与恢复：首次缺基础/过期可持久拒收；服务端已经 STORED 的本地后续失败只诊断，不产生矛盾 REJECTED。撤回可以在原截止之后、时钟回拨/不可用时保存；容量失败整体回滚并要求宿主停止使用相关缓存。待发送队列与 ACK 精确匹配文档/版本/尝试/阶段，旧 ACK 不清除新尝试。
- verifier RED 24 项失败后转为 24 项通过；journal RED 为 23 失败/1 通过，`.local/access-device-journal-red.log`，实现后与 verifier 共 48 项通过。首轮完整检查受到 C 盘临时空间耗尽影响；改用本项目 D 盘 TEMP/TMP 后继续，没有删除系统或其他任务数据。
- 新增 8 项跨平台检查，首次因同名 Sembast 内存数据库在 close 后仍保留数据导致 6 项夹具互相污染，`.local/access-device-portable-red-vm.log`、`.local/access-device-portable-red-chrome.log`。每项前清理专用内存库后，最终 VM 56 项全部通过，静态分析无问题；`.local/access-device-vm.log`、`.local/access-device-analyze.log`。包含实际文件库关闭/重开、六路并发重复、回执重放、容量回滚、损坏与当前公钥重新验证。
- 使用当前运行后端 JAR 的真实私有 Envelope/Document/Receipt 记录、Jackson 与 ConfigurationSigner.signAccessWindow 生成公开夹具，Dart 接收、缺基础恢复、原期限、撤回与 ACK 互操作通过；`.local/access-device-nimbus.log`。反射只用于测试构造记录，临时测试私钥在 finally 删除；不读取运行签名私钥，不把该结果当作真实 HTTP/MySQL/设备执行验收。
- 最终 15:33:52 VM 56 项通过；15:34:28 Chrome 的 24 项 verifier + 8 项内存事务检查全部通过，`.local/access-device-chrome.log`。Chrome 检查不冒充文件库或浏览器 IndexedDB 落盘证明，文件关闭/重开的证据来自 VM。静态分析无问题；互操作夹具目录仅保留公开 JSON，临时私钥已确认不存在。
- 收尾再次读取：3000 前端、8082 后端健康和 8081 身份发现均为 200，后端状态 UP。本阶段新增独立 Dart 包，无运行后端/前端替换；C 盘剩余空间显示 0.00 GB，验证进程继续使用 D 盘专用临时目录，该机器环境仍需释放系统盘空间。
- 这一阶段是可集成的配置接收基础。HTTP 自动同步、可信时间实现、安全存储、儿童宿主和原生规则执行仍待完成；完整产品目标保持进行中。

## Task 5/7：审批设备 HTTP 同步与真实后端联调（2026-10-09）

- 为 `device_access` 新增成熟 http 1.6/AbortableRequest、http_parser 和 retry 组件支持的 transport/synchronizer。HTTPS API 根、独立 opaque 凭据、逐请求凭据读取、拒绝重定向、响应大小/超时/取消、严格资源/版本/ACK 关联与安全错误已经实现。生产身份或密钥未参与检查。
- 有界完整扫描、每页续点/generation 比较交换与完成后回首页，避免旧申请的后续撤回被永久跳过。并发触发合并；提交文档事务后再发回执，成功 ACK 后才清队列。历史终态冲突及单条非法文档返回局部诊断并继续取后续撤回；身份错误终止。宿主必须停用诊断关联的缓存，身份失效时停用该注册全部缓存。
- 临时拒收在排除基础/存储问题、到达服务端等待时间、原期限仍有效及队列有空间后创建新尝试；每次重试或并发冲突后读取当前文档。REMOVE 在原期限之后也能恢复交付。POST 结果不明保留待确认工作，下一轮通过当前文档及幂等回执恢复；不改变原授权时限。
- 同步结果分别包含扫描是否还有页、剩余回执数、局部诊断、HTTP 状态/Retry-After/可重试/结果未知。初次积压字段检查复现返回 0 的遗漏，补齐后进入完整回归；`.local/access-http-result-red.log`。
- 初始 RED：传输 11 项失败/1 项通过，`.local/access-http-transport-red.log`；同步 13 项失败（未实现期间最后取消场景等待请求触发，按 30 秒测试上限超时），`.local/access-http-sync-red.log`。实现后专项通过；额外两个分页/数字边界在 `.local/access-http-page-red.log` 复现并修复。最终额外覆盖重试中撤回竞争、撤回截止后存储恢复、限次/窗口结束/永久拒收及调度提示。
- 最终 Dart VM **92 项全部通过**，analyze 无问题，`.local/access-http-vm.log`、`.local/access-http-analyze.log`。实际 Chrome **38 项全部通过**，`.local/access-http-chrome.log`；范围为验签、内存事务与分页/重试模型。网络与实际文件重开检查在 VM，浏览器 HTTP/CORS、IndexedDB 持久化和原生后台运行未由这些结果证明。
- Chrome 初次新增数字检查出现 1 项失败，`.local/access-http-chrome-number-red.log`：JavaScript 上整值 `2.0` 无法通过 Dart 运行时类型区分为非 int。按有界安全整数的数值契约，将可移植检查覆盖非整值 `2.5`、越界与错误后继；VM 单独保留严格 double 类型检查。没有声称 Web 保证 JSON 数字的词法表示。
- 新增 `DeviceAccessHttpInteropTest`：隔离 Spring 随机端口、真实设备 opaque 认证、实际 Nimbus 签名、H2 事务和六次独立 Dart 进程。通过两个真实业务批准验证缺基础拒收、等待后自动恢复、服务器已确认但本地未清队列的进程中断/重开、原期限、撤回、到期及最终凭据撤销 401。成人 JWT/MFA 声明、已激活设备、已发布基础匹配与可信时间是明确夹具，不冒充真实 OTP、新设备证明或原生执行。
- 后端审批旅程 + V15/V16 迁移 + Spring/Dart 联调专项 **17 项通过，0 skip**，2026-10-09 15:59:30，`.local/access-http-backend-regression.log`。随后显式组件启用条件下重跑最新 HTTP 联调 **1 项通过，0 skip**，16:04:18，`.local/access-http-spring-final.log`。这是隔离 H2 专项，不是本轮全后端构建或新增 MySQL 认证；此前 MySQL 证据仍按其原范围记录。
- 构建使用独立源码副本 `.local/access-http-backend-31f82c40855a4c24b57afe8d9a19f8e1`，没有占用共享 backend/target 或重启运行服务。该联调显式要求 `device.access.package` 和 `device.dart.command`；通用发布脚本尚未纳入此包的依赖准备/检查，发布门槛整合继续保留，跳过不能计为通过。
- 前端 3000 仍为 200，后端 8082 为 UP。本阶段完成可集成同步组件；儿童宿主、安全时间/存储、操作系统后台调度、原生执行及其界面仍需继续完成，整体目标没有完成。

## 待完成范围

- Task 1：独立设备组、归档恢复、通知、限流、幂等清理和保留治理；租户维护、所有者交接、成员角色/班级范围调整已接入管理端，教师申请及课堂工作流继续实施。
- Task 2：客户端接入、安全存储、硬件证明/密钥更换、正式 EMM 注册与 TV 验证、到期/保留作业、速率与真实数据库/消息验收。
- Task 3：策略继承/组织范围/例外、批量任务/默认模板、保留清理、经验证安装身份/权限元数据、全部模式的系统执行与客户端交互。
- Task 4：ENFORCE/正式 EMM/规则级回执/补偿/取消、客户端验证/离线/重启、密钥信任更新、真实 Broker/MQTT/ACL/凭证、退避/限批与持续故障治理。
- Task 5：正式模式的设备例外/撤销执行与规则级证据、审批儿童宿主/后台任务集成与真机恢复、双人审批/机构委派、客户端/通知、账户级速率/保留、紧急恢复、原生正常清理与密钥删除、正式 EMM 解除和整机擦除后果/证据；CONFIGURE_ONLY 文档、回执、云端恢复、独立验签/事务恢复及有界 HTTP 同步组件已完成当前阶段。
- Task 6～7：额度完整计划/策略/设备闭环、儿童客户端、全部敏感交互与设备端实际联调；Task 8～13：Android/TV、网站/机构集成、报告/删除、商业支付、智能辅助、部署与容量。
- 本机 MySQL、OIDC 密码登录和已有管理业务已有成功证据；真实 OTP 敏感写入、OceanBase、Broker、供应商、真机、支付沙箱、模型、HA/备份恢复与百万注册设备负载尚未执行。

外部资质、密钥和设备依赖在对应实施阶段处理。当前本机容器可用，仍可继续代码与契约工作，未判定总目标完成。

## Task 1/9：机构班级与教师只读范围（2026-10-09）

- V19 实现班级目录、版本化名册、双版本原子转班、归档及多班级教师授权。邀请与成员 classIds 最多 50 项，班级最多 500 个学生关联；严格租户/当前成员版本约束，重新加入不复活旧范围。
- 教师只读班级、未归档学生和设备/能力状态，不能修改档案/设备/策略或读取应用清单。范围查询复用 TenantAccess；内部设备工作流保持原权限入口，避免读状态间接扩大应用数据访问。
- 成员表单新增多班级选择、不可用范围提示和历史差异；班级页面完成名册、转班、归档、错误恢复。未知写入固定正文/键，版本冲突“关闭并刷新”，手机顶部留出完整工作空间切换位置。
- 先后 RED 暴露缺路由/classIds 和应用清单间接放行；修复后 66 项相关回归通过。真实 MySQL 两次受本机原生内存不足中断，降低 JVM 并发/内存后验证通过，不把环境退出计为通过。
- 最终独立 V1～V19 发布包：236 项全部通过，含三项真实 Spring/Dart HTTP 互通，2026-10-09 18:41:28，`.local/organization-release-verify.log`。真实 MySQL 38 项通过，18:42:51，`.local/organization-release-mysql.log`；临时库/用户已清理。
- 额外含并行 V20 的集成快照 243 项通过，但本阶段部署使用不含 V20 的独立包，避免混淆迁移发布边界。
- Flutter 31 项、静态分析、HTML release 构建通过。桌面 1440 和手机 390 浏览器夹具覆盖创建原样重试、取消返回、转班冲突刷新、多班级授权、改名、教师只读、归档，8 次写请求、0 页面异常；两轮视觉检查完成。
- V19 已于 18:43:40 应用到本机业务库；后端 PID 166584。运行 JAR 与验证产物哈希一致。前端 3000、后端健康 8082、身份服务 8081 最终均 200。管理员真实密码登录/班级读取成功，敏感创建被 MFA 门槛拒绝，未冒充真实 OTP 成功。
- 此阶段结束时，教师临时申请、课堂会话、独立设备组、逐学生名册历史及完整产品剩余阶段仍待实施；后续教师增量见下节。[当前合同与验证边界](organization-workflow-plan.md)。整体目标保持进行中。

### Task 5/9：教师有限申请增量（2026-10-09）

- 接入申请专用设备范围边界、当前策略可申请规则投影、教师创建/本人查询/取消，以及 OrganizationScopeChanged 同事务失效或撤回。既有设备/主体/策略管理权限没有加入教师。
- 儿童和教师查询均限定精确申请人，保护各自自由文本；已有班级多范围仍有覆盖时保留申请。创建/审批幂等重试返回当前状态，避免旧批准响应掩盖撤回。
- Flutter 接通申请表单、规则分页、1–60 分钟输入、20 条规则上限、未知提交冻结/同键重试、教师/儿童取消、管理员状态原因展示。
- 首次独立 V19 快照只完成编译打包和 19:10 运行更新；后续新增教师专项 11 项与表单 7 项回归。不能复用上一节只读阶段的测试数字认证这次扩展。
- 后续验证覆盖名册失权、申请人隔离、当前幂等响应、并发创建/撤权与跨教师锁顺序；真实 MySQL 49 项通过。修复 Spring MVC 查询校验误报 500、手机提交失败错误不可见两项实际问题，均有 RED→GREEN 证据。
- 独立管理端发布快照 38 项测试、静态分析及 HTML release 构建通过。默认并发测试曾耗尽本机内存，改为单任务并分开运行前后端；失败运行没有计作成功。最终完整验证、浏览器与运行包记录见 [机构工作流](organization-workflow-plan.md)。
- 最终 V1–V19 后端 247 项全部通过，含三项 Spring/Dart 联调；19:39:44 发布，Flyway 无新增迁移。桌面/手机隔离流程 5 次写请求通过，手机错误和刷新入口已人工检查。真实管理员密码登录、实际审批列表 200、非法/缺少参数 400、三项服务 200 均通过；真实 OTP 和系统执行未由这些证据证明。完整产品目标保持进行中。
