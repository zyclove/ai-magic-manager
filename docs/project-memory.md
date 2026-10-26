# 项目记忆

本页只保存稳定约定和导航，不替代规格、源码或验收记录。先读 [AGENTS.md](../AGENTS.md)，再按任务打开下列相关入口；无需每次通读全部文档。冲突时以用户最新指令和当前实现为依据，同步修正文档差异。

## 产品与领域边界

- 智能管家面向家庭和教育机构，管理成员、设备、应用、时间计划、策略、临时访问与额度；完整范围见[功能规格](parental-control-functional-spec.md)。
- 工作空间对应租户权限边界；服务端校验成员角色与操作范围，客户端显示状态不能代替授权。身份与设备接入分别见[后端接口](backend-api-status.md)、[设备接入契约](device-registration-contract.md)。
- 配置保存、设备接收、自报回执与系统实际执行是不同状态。能力以设备模式、适配器及实际验收为准，不能把 `CONFIGURED_NOT_ENFORCED` 或 `STORED` 展示为已执行。
- 规划、源码实现、构建产物、正在运行的服务和验证结果分别记录；新提交不会自动更新运行环境。

## 权威文档入口

| 任务 | 入口 |
| --- | --- |
| 规格与工程标准 | [SPEC](SPEC.md)、[领域模块设计](architecture/module-design.md) |
| 产品范围与流程 | [功能规格](parental-control-functional-spec.md)、[产品交付规格](parental-control-product-delivery-spec.md) |
| 架构与设备能力 | [平台设计蓝图](parental-control-platform-design.md) |
| 当前实施范围 | [实施计划](implementation-plan.md)、[实施记录](implementation-progress.md) |
| 首版版本与建库 | [1.0.0 初始化约定](version-1.0.0-initialization.md) |
| 实际 API 与交互契约 | [后端接口](backend-api-status.md)、[应用/时间/策略](policy-application-schedule-contract.md)、[审批](access-request-contract.md) |
| 部署与环境操作 | [简明入口](deployment-quickstart.md)、[完整手册](deployment-runbook.md)；执行前核对实际目标，不能沿用文档中的历史环境状态 |
| 其他专题 | [文档索引](README.md)，仅打开与本次变更有关的契约 |

## 源码导航与复用

| 范围 | 入口与约定 |
| --- | --- |
| 模块化后端 | [领域模块](../backend/src/main/java/com/aimanager/)、[构建配置](../backend/pom.xml)；沿既有领域边界组织逻辑 |
| Web 管理工作台 | [Guardian](../apps/guardian/README.md)：[入口](../apps/guardian/lib/main.dart)、[核心](../apps/guardian/lib/core/)、[页面](../apps/guardian/lib/pages/)、[共享界面](../apps/guardian/lib/ui/) |
| 监护人手机端 | [Parent](../apps/parent/README.md)，复用后端契约和现有共享模块 |
| 儿童设备端 | [Child](../apps/child/README.md)，区分观察授权、配置存储和系统执行能力 |
| 设备共享模块 | [身份](../packages/device_identity/README.md)、[策略](../packages/device_policy/README.md)、[访问](../packages/device_access/README.md)、[观察](../packages/device_observation/README.md)、[退出操作](../packages/device_operations/README.md)、[清理](../packages/device_cleanup/README.md) |
| 身份服务扩展 | [Keycloak 扩展](../identity-extensions/README.md)，外部身份能力按明确配置启用 |

优先复用现有领域服务、共享包和成熟框架。新增抽象应解决实际重复或明确边界，不为小改动另建一套模块、脚手架或技能。

[后端 Maven](../backend/pom.xml)可用 `-Dbackend.build.directory=<绝对目录>` 隔离产物，默认仍为 `backend/target`；优先用已有工具和缓存，不为改输出目录复制源码或清空旧 JAR。ArchUnit 默认排除依赖目录约定，[模块边界测试](../backend/src/test/java/com/aimanager/ModuleBoundariesTest.java)额外按真实测试 CodeSource 排除夹具并防止误排生产目录；修改验证目录不能靠忽略 `*Test` 名称或关闭边界规则解决。

管理台导航的名称、分组、搜索词和已知路由统一在 [console_modules.dart](../apps/guardian/lib/core/console_modules.dart)；[导航组件](../apps/guardian/lib/ui/console_navigation.dart)只负责呈现。目录不授予 API 权限，服务端与会话仍独立校验。

网站规则的 IDN/ASCII 规范化统一在后端 policy 的 [DomainNames](../backend/src/main/java/com/aimanager/policy/internal/DomainNames.java)，保存规则与草稿域名检查共用；客户端不另建 IDN 转换算法。检查绑定草稿版本，只解释精确命中及拒绝优先，无命中保持 `NO_MATCH`；不做 DNS、网站访问或设备执行。契约与简明界面见[应用/时间/策略](policy-application-schedule-contract.md)。

[EditDialog](../apps/guardian/lib/ui/design.dart) 默认保留服务器写入的未知结果保护。只有明确不写服务器的校验／本地草稿准备才可使用 `canCommit=false`，错误后允许修改输入；不能将已经发出的写入切换成只读模式来解除保护。域名规则编辑的只读规范化与最终保存草稿分开，见[编辑器](../apps/guardian/lib/pages/editors.dart)。

策略编辑目录由 [PolicyRuleDirectories](../apps/guardian/lib/core/policy_rule_directories.dart) 按规则／已有引用读取；`null` 初始值表示未读，显式列表（含空）表示已读。缓存和进行中请求只属于捕获的作用域，失败可重试，失权清空并停止分页；界面刷新只重载本窗口用过的目录。不要恢复打开编辑器前的双目录门禁，或把目录失败当成空目录。

Flutter 回归优先稳定 Key／语义或类型谓词；`.icon` 按钮工厂可能返回子类，不能用精确运行类型查找代替。 `find.byTooltip` 命中提示包装器，读取按钮属性时须用类型和 tooltip 谓词定位实际按钮。涉及 [OwnedDialogRoute](../apps/guardian/lib/ui/owned_dialog_route.dart) 的旅程应等待路由完成及可观察加载状态；固定少量 pump 不代表异步完成，含进行中进度动画时也不能无限依赖 `pumpAndSettle`。用有界等待保留原业务断言，不靠改产品期限或放宽取证消除测试误报。

Windows 私有进程验证的稳定工具源位于 [scripts/verification](../scripts/verification/README.md)。已证明的同 Job 成员保留只读句柄并持续核验创建身份，禁止在失败后按 PID 重开来补证；固定容量及原期限、分类器、终态标准保持。浏览器驱动须固定源码摘要，历史 NOT_ACCEPTED 不由新工具追认，清理缓存不能删除唯一工具源。

管理台异步旅程可复用 [DeviceSubflowScope](../apps/guardian/lib/pages/device_subflow_scope.dart) 捕获账号、租户、角色和会话代际；名称虽源自设备流程，通知与工作台也采用此机制。旧响应与回调必须核对原捕获，不能仅比较当前租户/角色。普通网络失败可保留已读数据，服务端拒绝访问则隐藏私有摘要并作废捕获。

[通用 API](../apps/guardian/lib/core/api.dart) 使用已锁定 `http 1.6.0` 的 Abortable 协议；[作用域包装层](../apps/guardian/lib/core/scoped_http_client.dart)必须透传中止信号，在实际发送/终结请求前同时检查原作用域和请求期限，借用的客户端不能被单次请求关闭。纯时限单元测试使用原生 `FakeAsync`；共享完成 Future 的取消续程可能在其区域外调度，正常重试须保留有界真实异步断言，参考[超时回归](../apps/guardian/test/api_deadline_test.dart)，不要用无限等待或删除完成断言掩盖问题。

[有界 JSON 读取](../apps/guardian/lib/core/bounded_json.dart)同时覆盖身份刷新、发送和正文读取，保留调用方原始作用域／预览异常。已知拒绝状态下正文不完整，只保留 HTTP 失败而不给完整拒绝证据；不要把超时或中止当成操作未执行，或解除原请求的持久化防重复保护。

时间计划副本通过 [ScheduleCopy](../apps/guardian/lib/core/schedule_copy.dart) 隔离来源，保留原时区、空每周定义、跨午夜与全部日期例外；创建副本不替换策略引用。[ResourcePage](../apps/guardian/lib/ui/resource_page.dart) 的 `onOpenChanged` 只接收是否需要核对列表的信号：保存或明确关闭未知写入时重读，普通取消和只读返回不刷新；不能把子窗口正常返回或需重读推断成已保存。具体流程见[时间计划契约](policy-application-schedule-contract.md)。 停止旧提交后仍可只读核对已有策略；查询时清除临时错误不能解除原写入停止状态。原提交输入与停止原因分别保存，作用域失效一并清空；核对失败或不匹配不恢复旧 POST。

[ResourcePage](../apps/guardian/lib/ui/resource_page.dart) 的宽屏表格保留主题最小行高，最大行高按内容增长；不修改全局表格主题。可用稳定的纯 `includeRow` 谓词接收已授权分页中的可展示行，保留原下一页游标；谓词改变按新的列表生命周期隔离，不能代替服务端筛选与授权。默认空态使用中性说明，有创建能力时由现有按钮提供入口；业务页面仍可明确覆盖领域空态文案。 既有读取拒绝分支会清除已读数据/搜索并推进读取与列表两种代次，作废旧事件和自动刷新；新操作须在完整新读取成功后恢复。恢复读取与安全验证仍可用，单次操作的 MFA 不据此撤销只读资料；通用操作错误使用结果待核对文案。

访问审批的 [AccessRequestsPage](../apps/guardian/lib/pages/access_requests_page.dart) 编排待处理/全部筛选与行摘要，复用 ResourcePage 的读取、分页及错误恢复；管理角色默认待处理，其他角色默认全部。消费实际返回的名称，不追加目录请求；审计视图只用核心编号。列表筛选后的空批次不等于后续页无待办，原详情与决定流程继续独立授权。[approval_decision](../apps/guardian/lib/core/approval_decision.dart) 集中七种状态、当前申请快照和精确秒数正文转换；列表名称先脱离原行，再以完整引用匹配，不能覆盖最新核心事实。通用 FieldSpec 可选整数范围由既有表单就近校验，跨字段合计在提交前验证；继续使用原未知结果与幂等保护。

[HelpRequestsPage](../apps/guardian/lib/pages/help_requests_page.dart) 的服务端明确拒绝锁存为当前页面失权，清除私有列表并失效晚到读取；本地会话未变化也不能继续使用旧捕获。带目标信息的确认使用 [confirmLeasedAction](../apps/guardian/lib/ui/leased_dialog.dart)，沿用原路由与权限租约。未知确认的行内核对只发 GET，复用既有操作代次条件，不自动重发 POST。

恢复草稿的中文字段清单统一在[领域化展示模块](../apps/guardian/lib/ui/editor_draft_text.dart)，只读取已捕获的提交与现有目录。名称缺失保留完整对象编号，未知字段也保留；展示层不得读取网络、改写原提交或解除重试保护。

时间安排示例的不可变模型与严格响应校验统一在 [schedule_contracts](../packages/schedule_contracts/README.md)，Parent 保留轻量适配，Guardian 直接消费。目录仅按需读取，回填本地草稿、保留时区与日期例外，已有每周时段须确认替换；同包的 `weeklyWindowAdditions` 只计算独立新增项，两个宿主按实际新增数整体检查 56 条上限，不部分添加，不清除既有重复行。Guardian 的 [ScheduleWeekView](../apps/guardian/lib/ui/schedule_week_view.dart) 只做分组展示，删除仍由原编辑器的交互和权限门禁处理。宿主负责授权、有界读取和显式保存，不能将示例选择解释为已保存或已发布。交互契约及当前验证状态见[示例交付说明](schedule-preset-ux-delivery.md)。

时间计划的[日期例外编辑器](../apps/guardian/lib/pages/schedule_exception_editor.dart)只返回独立本地草稿；取消不写回，保存整个计划才提交。管理台的日期例外、每周时间、关闭日期与示例弹窗共用 [leasedDialog](../apps/guardian/lib/ui/leased_dialog.dart) 绑定原父路由及权限租约；每周与例外时间共用 [pickLeasedTime](../apps/guardian/lib/ui/leased_time_picker.dart) 的 24 小时输入。系统选择器的返回限制在局部 Navigator，不能关闭独立覆盖通知；具体交互见[时间计划契约](policy-application-schedule-contract.md)。

在仓库根目录可用 `pwsh -File scripts/manager.ps1 status -Active` 只读定位已选环境（2026-10-25 已实际执行）。前提是 PowerShell 7、可访问的 Docker 及完整的环境选择记录；显式目录查询使用 `status -Directory ...`。状态查询不自动恢复或发布服务，也不代替业务验收。[入口实现](../scripts/manager.ps1)会选取首个 Docker 可执行入口，避免 Windows 多个同名命令被拼成路径。

已有发布的无构建恢复入口为 `manager.ps1 resume`，复用原启动的配置、来源和账本校验，先确认目标持久容器齐全，再只启动原容器；恢复前后严格绑定原应用容器集合和原运行记录摘要，不通过重写记录接受变化。该能力仍以[部署手册](deployment-runbook.md)的当前验证状态为准，不能把源码接线当作真实恢复验收。

部署诊断 `doctor -Toolset Runtime` 只盘点运行命令，默认 `Build` 盘点源码构建命令；自定义构建工具使用已有命令参数和同一套路径基址。命令发现不能作为 SDK、Compose 插件、守护进程、服务或平台已验证的证据；保持不执行工具、不连接服务的检查边界。

统一部署入口的显式目录及带目录分隔符的工具路径统一按该仓库根目录解析；裸工具名称保留 PATH 查找，预览与执行共用最终参数，不为预览读取身份配置或启动工具。参数契约见[简明部署入口](deployment-quickstart.md)。

统一部署入口的初始化默认值由同一处解析，预览与执行共用：本机换端口只填 `-EdgePort`，指定公开 URL 时自动采用其端口；外部 TLS 代理保留独立内部端口。显式填写的 URL/端口仍交给初始化器校验，见[简明部署入口](deployment-quickstart.md)。

## 已确认的用户约定

- 按 **1.0.0 首版**设计与初始化，移除不必要的历史业务兼容和升级链；不因此删除现有数据，也不取消隐私删除、备份恢复、协议版本和并发控制。
- 界面优先简洁、易操作，减少步骤与重复输入；准确呈现待处理、未知、失败和完成状态，明确下一步动作。
- 按风险选择最小有效检查；文案和文档改动默认只审差异，行为改动验证受影响路径，关键权限/数据/契约变动检查相应集成边界。资源不足时说明未运行项，不重复无效尝试。
- 相关检查已足够时停止追加验证；复用范围内仍有效的结果，不把历史通过当作新行为通过。
- 阶段完成后本地提交相关改动，保留他人工作；提交不自动触发推送或部署。执行外部操作仍核对本次适用授权。
- 临时目录、构建并发、资源与维护边界统一遵循 [AGENTS.md](../AGENTS.md)，本页不复制门槛和环境快照。

## 维护与敏感信息

- 稳定的领域边界、公共契约、模块入口或用户长期约定变化时更新本页；普通实现进度与一次性故障写入对应任务记录即可。
- 优先修正原条目、合并重复并链接权威来源；移除失效入口，不累积会话历史、旧进程信息、资源采样或缓存证据清单。
- 不保存账号密码、令牌、私钥、会话标识、个人数据及环境文件内容；不把敏感配置或原始数据复制到记忆、技能、日志或提交中。
- 技能按当前任务选用现有最相关者；项目惯例保留在仓库文档中。确有重复且可泛化的工作流时，才单独评估创建项目技能。
