# 实施记录 — plan: docs/implementation-plan.md

## 当前状态

完整目标仍在实施。Task 1～4 基础后端与 Task 5 云端访问申请/审批、限期/失效、正常退出预览/确认及独立清理任务已有代码；各项扩展、系统执行、Task 5 紧急恢复/原生清理/受管解除与设备例外、Task 6～13 和正式环境验收保持待完成。没有把管理员批准、设备自报保存/清理或测试通过当作产品已完整交付。

## 环境证据与实施决定

- 2026-10-08：开始实施时仅有四份设计文档，无源代码或 Git。当前新增 Spring Boot 后端及实施文档。
- Java 17.0.14、Maven 3.9.7、Flutter 3.22.2/Dart 3.4.3 可用；Docker CLI 可用，daemon 未运行。
- Java 目标 17 LTS，使用 Boot 3.5.16 与 Modulith 1.4.0 兼容系列；springdoc 2.9.1 用于 OpenAPI 3.1。版本升级、安全扫描及部署 JVM 更新另需验收。
- 用户已授权完整实施，当前会话直接执行，不重复请求确认；不创建 Git、不提交、不部署到外部账户。
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
| 访问审批 | CHILD 范围申请、近期 MFA/版本/幂等决定、取消/撤销、冷却、限期作业、基础/主体/设备/成员失效；不签发设备许可或解锁 |
| 退出/清理任务 | BYOD 后果预览/确认、云端撤销与审批失效、原密钥限时认证、独立签名命令/公钥/回执、取消/新任务/到期；不伪装本地或系统执行 |
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

## 待完成范围

- Task 1：完整所有者交接、租户维护、成员/邀请查询和调整、机构班级/组范围、归档恢复、通知、限流、幂等清理和保留治理。
- Task 2：客户端接入、安全存储、硬件证明/密钥更换、正式 EMM 注册与 TV 验证、到期/保留作业、速率与真实数据库/消息验收。
- Task 3：策略继承/组织范围/例外、批量任务/默认模板、保留清理、经验证安装身份/权限元数据、全部模式的系统执行与客户端交互。
- Task 4：ENFORCE/正式 EMM/规则级回执/补偿/取消、客户端验证/离线/重启、密钥信任更新、真实 Broker/MQTT/ACL/凭证、退避/限批与持续故障治理。
- Task 5：设备例外/撤销交付与真实执行、双人审批/机构委派、客户端/通知、账户级速率/保留、紧急恢复、原生正常清理与密钥删除、正式 EMM 解除和整机擦除后果/证据。
- Task 6～13：额度、Flutter、Android/TV、网站/机构集成、报告/删除、商业支付、智能辅助、部署与容量。
- 真实 MySQL/OceanBase、OIDC/MFA、Broker、供应商、真机、支付沙箱、模型、HA/备份恢复与百万注册设备负载尚未执行。

Docker daemon 未运行限制了本机容器验证；外部资质、密钥和设备依赖在对应实施阶段处理。当前仍可继续代码与契约工作，未判定总目标完成。
