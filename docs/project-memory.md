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

管理台导航的名称、分组、搜索词和基本模块统一在 [console_modules.dart](../apps/guardian/lib/core/console_modules.dart)；受控列表的固定位置、视图枚举及参数识别统一在 [console_routes.dart](../apps/guardian/lib/core/console_routes.dart)，供 Entry→Shell→页面与登录精确回跳共用。[导航组件](../apps/guardian/lib/ui/console_navigation.dart)只负责呈现。目录不授予 API 权限，服务端与会话仍独立校验。

网站规则的 IDN/ASCII 规范化统一在后端 policy 的 [DomainNames](../backend/src/main/java/com/aimanager/policy/internal/DomainNames.java)，保存规则与草稿域名检查共用；客户端不另建 IDN 转换算法。检查绑定草稿版本，只解释精确命中及拒绝优先，无命中保持 `NO_MATCH`；不做 DNS、网站访问或设备执行。契约与简明界面见[应用/时间/策略](policy-application-schedule-contract.md)。

[EditDialog](../apps/guardian/lib/ui/design.dart) 默认保留服务器写入的未知结果保护。只有明确不写服务器的校验／本地草稿准备才可使用 `canCommit=false`，错误后允许修改输入；不能将已经发出的写入切换成只读模式来解除保护。域名规则编辑的只读规范化与最终保存草稿分开，见[编辑器](../apps/guardian/lib/pages/editors.dart)。

formDialog/EditDialog可按实例配置terminalConflictCodes（默认空），仅写入表单的指定409进入既有只读停止／草稿保留；入口及init各复制集合，didUpdate与原捕获setEquals，变化永久退役，普通409及本地准备保持原行为。通用关闭结果仍null；审批用独立ApiWriteDispatch决定退出后原详情单次核对，成功反馈另需非空表单结果＋已校验回执，避免raw移除后的晚toast。

formDialog 同样显式透传 canCommit（默认true），false不能配置原结果查询hook；仅用于不持久化远端状态的本地准备。额度计划的[日期编辑](../apps/guardian/lib/pages/quota_plan_editor.dart)使用该入口，直接编辑已有日期并精确保留分钟／余秒；0合法、总计不超过24小时。每周复制按源的当前精确秒数更新保留值，手动更改分钟才替换为整分钟。完整计划保存冻结外层与两个额度Map；未知、终态停止与关闭确认由父编辑器管理，不由日期窗口解除。关闭确认捕获每次独立标识，收起再打开也不复活旧确认回调。

[quota_plan_change.dart](../apps/guardian/lib/core/quota_plan_change.dart) 集中额度计划／日历解析、固定原正文与完整回执匹配，保留7天及全部日期整数秒，不接受日期归一化或浮点版本。QuotaPlanEditor 必需只读 onRecoverUnknown，未知后只查询，原保存回调不能触发查询或重放写入。[QuotaPlansPage](../apps/guardian/lib/pages/quota_plans_page.dart) 使用 UUID 与既有 creation-results/update-results 查询，更新保留原 If-Match，查询无写入幂等头；committed/current分开。详情、编辑、历史与API借用 ResourceActionLease，onCreateChanged/onOpenChanged 只返回列表核对信号，普通取消及只读不重读。

[quota_pool_change.dart](../apps/guardian/lib/core/quota_pool_change.dart) 集中每日池18字段、流水、日期、余额恒等式及原操作回执校验。分钟＋可选秒仅转为limitSeconds/deltaSeconds，不转发控件值；used/reserved与原调整回执保持。[QuotaPage](../apps/guardian/lib/pages/quota_page.dart) 借用列表租约查询原CREATE/ADJUST，区分committed/current；两个页签捕获同步推进的viewGeneration，旧结果／拒绝不影响新视图。后端QuotaPool显式JsonInclude.ALWAYS保障空关联字段完整，现有余额视图只接收已解析事实。

FieldSpec.validator 在原必填/数值规则后执行纯领域校验，文本、选项及时区字段共用此扩展。EditDialog/formDialog 可显式配置 onRecoverUnknown 与 recoverLabel，成对捕获首次提交及只读查询回调并冻结原值；恢复跳过当前控件校验/解析，408保持未知，查询404/401不解锁，模式切换则退役。不提供查询hook的表单仍使用原重试入口；不能把只读查询用于 canCommit=false 的本地准备流程。

应用登记规范化与严格回执匹配集中在 [application_registration.dart](../apps/guardian/lib/core/application_registration.dart)，复用既有 ApplicationClassificationIdentity 契约。包名保留大小写，摘要接受原始或冒号指纹后转小写排序，空项/重复/超限就地拒绝；application 使用UUID键及既有 creation-results 原结果查询，未知后不重放创建。返回仍为管理员声明，不据此宣称设备核验或执行，详见[应用契约](policy-application-schedule-contract.md)。

策略编辑目录由 [PolicyRuleDirectories](../apps/guardian/lib/core/policy_rule_directories.dart) 按规则／已有引用读取；`null` 初始值表示未读，显式列表（含空）表示已读。缓存和进行中请求只属于捕获的作用域，失败可重试，失权清空并停止分页；界面刷新只重载本窗口用过的目录。不要恢复打开编辑器前的双目录门禁，或把目录失败当成空目录。

[policy_rule_duration.dart](../apps/guardian/lib/core/policy_rule_duration.dart) 只负责策略额度／提醒的分钟、秒与整数秒精确转换及可读摘要；界面复用 FieldSpec 范围校验并检查合计1～86400，不舍入或钳制。固定行为直接写入对应合法值；规则确认只加入／更新本地草稿，不把 `minutes` 发到规则协议，不改变最终保存和未知结果保护。

Flutter 回归优先稳定 Key／语义或类型谓词；`.icon` 按钮工厂可能返回子类，不能用精确运行类型查找代替。 `find.byTooltip` 命中提示包装器，读取按钮属性时须用类型和 tooltip 谓词定位实际按钮。涉及 [OwnedDialogRoute](../apps/guardian/lib/ui/owned_dialog_route.dart) 的旅程应等待路由完成及可观察加载状态；固定少量 pump 不代表异步完成，含进行中进度动画时也不能无限依赖 `pumpAndSettle`。用有界等待保留原业务断言，不靠改产品期限或放宽取证消除测试误报。MockClient响应、API原deadline清理和窗口动画可能跨越真实异步队列；先runAsync排空并等待可观察终态，不能用pumpAndSettle把假时钟推进到网络期限，或只等正文赋值就认定路由已完成。

Guardian浏览器旅程采用与[发布脚本](../scripts/build-deployment.ps1)一致的HTML渲染器，`flutter test --platform chrome --web-renderer html --no-pub`按受影响文件选择；命令见[Guardian说明](../apps/guardian/README.md)。不能把其他渲染器的启动失败或HTML通过当作CanvasKit验收，也不为本机测试改全局SDK或替换已有缓存。

Windows 私有进程验证的稳定工具源位于 [scripts/verification](../scripts/verification/README.md)。已证明的同 Job 成员保留只读句柄并持续核验创建身份，禁止在失败后按 PID 重开来补证；固定容量及原期限、分类器、终态标准保持。浏览器驱动须固定源码摘要，历史 NOT_ACCEPTED 不由新工具追认，清理缓存不能删除唯一工具源。

DialogAccessBinding 同时观察父路由 popped 与 completed；当前 Flutter 下 raw removeRoute 未必完成 popped，父路由完成仍须永久退役原权限并通知自有窗口。通知沿既有帧后机制发布，不能对独立覆盖窗口执行通用 pop。

管理台异步旅程可复用 [DeviceSubflowScope](../apps/guardian/lib/pages/device_subflow_scope.dart) 捕获账号、租户、角色和会话代际；名称虽源自设备流程，通知与工作台也采用此机制。旧响应与回调必须核对原捕获，不能仅比较当前租户/角色。普通网络失败可保留已读数据，服务端拒绝访问则隐藏私有摘要并作废捕获。

[SettingsPage](../apps/guardian/lib/pages/settings_page.dart) 独立持有展示期的原始会话 scope，所有账号/工作空间入口共用交互门禁和防重；路由 key 包含账号、工作空间、角色与代际。页面捕获立即退役，编辑器则独立持有 scope/lifetime 至 formDialog 完整结束后释放；帧后退役通知避免晚建表单监听已释放对象，旧结果不触发当前工作空间重载。创建与接受邀请仍调用原已有认证捕获流程，不绕过服务端授权。

[成员详情](../apps/guardian/lib/pages/members_page.dart)只以最新 access 读取决定角色、版本和获授编号；[member_access.dart](../apps/guardian/lib/core/member_access.dart)集中MemberAccessTarget／Snapshot，原行actor/cursor等待前捕获，六字段深冻结、kind/范围/safe-int校验；二次GET不倒退／同版漂移，PATCH匹配原正文全部范围与no-op原版／变更+1。actor保持OIDC原文，不要求UUID；档案班级不查活动状态，归档引用保持。页面只白名单补profile，不用任意Map覆盖访问事实；已观察到版本变化或最新角色不可编辑时核对列表，同版本只读不重读。[MemberClassScope](../apps/guardian/lib/ui/member_class_scope.dart)仅在有获授班级时异步读取名称，绑定原详情 API 和租约，不阻塞核心资料或决定授权。目录失败保留完整编号并就地重试 GET；编辑前复核留在原详情中，普通失败原地重试，成功才关闭详情并将该版本固定交给编辑器；[MemberAccessReview](../apps/guardian/lib/ui/member_access_review.dart)在原表单内比较initialMember与规范草稿，未知态优先pending，只展示角色／范围、班级增删及完整差异编号；名称仅取已有目录。摘要与保存共用draftBody的原白名单／排序／深冻结，未改保护及最终授权不由摘要决定。member_access.dart的memberAccessHistorySummary／memberAccessHistorySearchText只格式化已读历史，按精确集合显示班级增删与档案变化，缺失／异常范围标待核对；中文摘要和已知编号参与本地搜索，不读名称目录、不决定授权。原详情退役或被独立窗口覆盖不自动打开编辑器。成员邀请通过 onCreateChanged 返回需核对信号，普通取消保留列表，需核对时直接进入邀请记录，不先刷新退役的成员视图；筛选与操作同步防重并绑定原视图代次。成员与邀请通过 ResourcePage.onOpenChanged 返回需核对信号，PATCH/DELETE 发出前置位，不能只看表单非空结果；只读返回保留列表。危险确认复用 [confirmLeasedAction](../apps/guardian/lib/ui/leased_dialog.dart)，页面同步退役、帧后通知租约并释放通知器，避免导航重入。应用分类存于独立资源，应用身份详情返回不重读身份目录，保留原分页和搜索。

成员列表／邀请列表的当前读取拒绝可锁存整页失权；单个access/history的403也隐藏已撤销或不存在目标，只退役该成员窗口并由原列表租约核对，不能直接推断所有成员失权。targetLost贯穿两层历史，scope同步门禁与帧后通知分开；scopedDetailsDialog/actionDetails可显式closeOnAccessLost，只结束所属OwnedDialogRoute，默认详情隐藏语义保持。成员三层窗口显式启用，非近期认证401／WORKSPACE_CHANGED可退役整页；普通读取错误、目录失败及写拒绝不扩大此边界。

[通用 API](../apps/guardian/lib/core/api.dart) 使用已锁定 `http 1.6.0` 的 Abortable 协议；[作用域包装层](../apps/guardian/lib/core/scoped_http_client.dart)必须透传中止信号，在实际发送/终结请求前同时检查原作用域和请求期限，借用的客户端不能被单次请求关闭。纯时限单元测试使用原生 `FakeAsync`；共享完成 Future 的取消续程可能在其区域外调度，正常重试须保留有界真实异步断言，参考[超时回归](../apps/guardian/test/api_deadline_test.dart)，不要用无限等待或删除完成断言掩盖问题。

ApiWriteDispatch／Api.trackingWrites 默认只保存带键写请求交给 HTTP 客户端的布尔事实；借用链保留父观察器、原作用域和共享待决写入，读取及无写键查询不标记。设备注册和设备管理仓储借用的专用观察器显式 includeUnkeyedWrites=true，覆盖其既有 Client-Request-Id 创建、确认／取消及云端撤销，不向请求补伪幂等键，不改变其他观察器或未知恢复语义。策略详情与其编辑、复制、回滚子流程共用同一观察器：原详情独立关闭后仍可返回列表核对信号，未派发或作用域失效不刷新；该信号不代表保存成功，也不替代原结果查询。

[有界 JSON 读取](../apps/guardian/lib/core/bounded_json.dart)同时覆盖身份刷新、发送和正文读取，保留调用方原始作用域／预览异常。已知拒绝状态下正文不完整，只保留 HTTP 失败而不给完整拒绝证据；不要把超时或中止当成操作未执行，或解除原请求的持久化防重复保护。

时间计划副本通过 [ScheduleCopy](../apps/guardian/lib/core/schedule_copy.dart) 隔离来源，保留原时区、空每周定义、跨午夜与全部日期例外；创建副本不替换策略引用。[ResourcePage](../apps/guardian/lib/ui/resource_page.dart) 的 `onOpenChanged` 只接收是否需要核对列表的信号：保存或明确关闭未知写入时重读，普通取消和只读返回不刷新；不能把子窗口正常返回或需重读推断成已保存。具体流程见[时间计划契约](policy-application-schedule-contract.md)。 停止旧提交后仍可只读核对已有策略；查询时清除临时错误不能解除原写入停止状态。原提交输入与停止原因分别保存，作用域失效一并清空；核对失败或不匹配不恢复旧 POST。

[schedule_creation.dart](../apps/guardian/lib/core/schedule_creation.dart) 复用 ScheduleCopy 完整解析并匹配原保存回执，固定对象键顺序后深比对、保留数组顺序，每层返回不可变值；不另造日程解析器。ScheduleEditor 首次使用UUID创建，未知后仅查询 schedules/creation-results/{key}/query，原正文与键不变且查询不传写入幂等头；404/近期认证不解锁，408视未知，坏回执不确认保存。安全验证不自动写入，仍需原scope与顶层窗口；停止/退出及ResourceActionLease沿既有保护。

[policy_draft_change.dart](../apps/guardian/lib/core/policy_draft_change.dart) 集中草稿／规则解析、CREATE/UPDATE 原正文与完整回执匹配；详情和编辑共用，不以当前 GET 内容推断原操作。PolicyEditor 捕获原草稿与 UUID，通过 policy-draft-changes 保存，未知后只查 policy-draft-operation-results/{key}/query，区分 committed/current；更新回执必须原 revision+1，当前后续修订只作提示。服务端 [PolicyDraftChangeService](../backend/src/main/java/com/aimanager/policy/internal/PolicyDraftChangeService.java) 仅编排既有 PolicyService 与原子幂等日志，不重复编译／授权／建库。当前内容核对不会解锁未知或停止状态，404／近期认证要求仍保留，408未知；失权隐藏、过期／清除终止沿原约定。

[policy_draft_branch.dart](../apps/guardian/lib/core/policy_draft_branch.dart) 复用完整草稿／规则解析，匹配模板复制和历史回滚的原回执；[策略详情](../apps/guardian/lib/pages/policy_details_entry.dart) 共用一个名称表单与恢复流程。首次写入固定 UUID，未知后仅查询 copy-results 或 rollback-draft-results，保留原 If-Match／名称且不带写入幂等头。PolicyService 从原日志区分 committed/current，重新检查当前写权限，无新写入或查询 MFA；旧 creationResult 仍供其现有调用方使用。回滚默认当前名称，只产生草稿；完整核对来源规则与修订，不能用当前较新草稿代替原操作证明。

ResourcePage 可由纯 `searchText` 提供领域格式化后的本地检索文本，并用 `searchHint` 说明可查字段；未配置时沿用原字段和状态标签搜索。它只处理已接收记录，不改变分页、权限、操作租约或发起网络请求；展示投影变化不重读列表。

策略版本历史在原 OwnedDialogRoute 内复用 ResourcePage 分页与操作租约，先开窗再取首批，不用 api.all 预读全部；API及逐页校验谓词在本窗口保持稳定；搜索仅投影显示版本、格式化日期和完整编号，避免逐键遍历完整快照。每页通过完整版本解析再接收，发布时间同时验证整数毫秒及原生 DateTime 可表示范围，打开详情前冻结原快照；只读返回不重读，回滚变更沿原核对信号关闭旧详情。网络／坏页保留已读记录，原范围内明确失权则隐藏私有历史；不能把服务端403当作普通游标过期。

工作台的 [OverviewAttention](../apps/guardian/lib/core/overview_attention.dart) 只从既有授权摘要选择求助、申请、连接中的一个优先入口，角色文案不授予操作权；教师/儿童仅跟进本人申请，审计仅只读查看。管理与只读工作台复用 [WorkbenchTaskCard](../apps/guardian/lib/ui/workbench_task_card.dart)，宿主负责原范围复核及导航。刷新或错误时不展示下一步，旧摘要与读取时间仍可明确显示；不新增轮询、目录或计数请求。Dashboard与ScopedOverviewPage仅将非REAUTH_REQUIRED的真实401／403及工作空间失效归为读取失权；近期认证沿原错误／验证入口保留上次摘要和时间，验证回调不直接读取或重放写入，真实会话代际变化仍退役旧范围并按原生命周期重新读取。

[ResourcePage](../apps/guardian/lib/ui/resource_page.dart) 按自身有限布局约束选择760宽度断点，无界时才回退到视窗；搜索框用最大宽度约束随父容器收缩。尺寸变化只重排既有 State，不重读列表或重置搜索／游标；窄卡与表格共用明确的“查看详情”按钮和原操作门禁，卡片外层 InkWell 只保留指针快捷点击，不占键盘焦点或额外操作语义；具体静态候选及待验证范围见[布局记录](reviews/resource-page-layout-20261028.md)。宽屏表格保留主题最小行高，最大行高按内容增长；不修改全局表格主题。可用稳定的纯 `includeRow` 谓词接收已授权分页中的可展示行，保留原下一页游标；谓词改变按新的列表生命周期隔离，不能代替服务端筛选与授权。默认空态使用中性说明，有创建能力时由现有按钮提供入口；业务页面仍可明确覆盖领域空态文案。用户刷新、后页加载和失败重试遵循临时交互门禁，清搜索仅跟随该门禁；内部已确认操作的自动核对独立继续。刷新仍可替换在途后页，readDenied不阻止权限恢复后的新读取。既有读取拒绝分支会清除已读数据/搜索并推进读取与列表两种代次，作废旧事件和自动刷新；新操作须在完整新读取成功后恢复。恢复读取与安全验证仍可用，单次操作的 MFA 不据此撤销只读资料；通用操作错误使用结果待核对文案。

可读整秒时长集中在 [duration_labels.dart](../apps/guardian/lib/core/duration_labels.dart)，复用于额度、计划及策略摘要；0显示“0 秒”，较长时长拆成小时／分钟／秒，不舍入、换算正文或改变流水正负号。各领域继续独立校验输入边界，策略仍限定1～86400秒；显示工具不替代余额恒等式和原结果核对。

共用 [dateLabel](../apps/guardian/lib/core/labels.dart) 对数值先验证有限且为整毫秒，原生日期构造越界时显示“时间无效”；正常毫秒／ISO文本仍按本地分钟显示，null保持“—”，未解析文本保留原回退。显示失败不推断邀请过期或设备离线，也不替代策略版本等领域的严格准入；静态候选与待验证范围见[日期显示记录](reviews/shared-date-display-20261028.md)。

访问审批的 [AccessRequestsPage](../apps/guardian/lib/pages/access_requests_page.dart) 接收宿主唯一持有的 pendingFilter 与筛选事件，编排待处理/全部视图及行摘要，不再另存本地筛选；复用 ResourcePage 的读取、分页及错误恢复；管理角色默认待处理，其他角色默认全部。消费实际返回的名称，不追加目录请求；审计视图只用核心编号。详情／创建通过租约返回布尔核对信号；普通关闭不重读，已派发写入含未知结果需核对。交付及尝试历史绑定原父窗口、会话与借用 API，只退役自有 OwnedDialogRoute；AccessRequestDialog 的完成回调由宿主接管，覆盖通知不能被成功回调误关。列表筛选后的空批次不等于后续页无待办，原详情与决定流程继续独立授权。[approval_decision](../apps/guardian/lib/core/approval_decision.dart) 集中七种状态、当前申请快照和精确秒数正文转换；registrationId按现行协议必传；verifyDecision核对原PENDING目标／注册／申请时长、规范正文和当前决定回执，含版本及固定时间窗。合法结果才由approvalDecisionFeedback提示当前事实，未知关闭仅核对无成功提示。grantedWindowSeconds键显式必传，未批准为null，批准／撤销必有合法时长，EXPIRED按是否曾批准保留，INVALIDATED仅未批准；版本须safe整数。审批详情主内容优先人可读事实，完整编号／包名／版本以原快照生成的只读ExpansionTile按需核对，不增GET；缺名仍完整编号回退，审计不增名称权限。详情比较申请与已核验批准时长，批准／拒绝确认保留原上下文并使用明确操作按钮；_tenantForm只为这两处传submit，其他默认保存。列表名称先脱离原行，再以完整引用匹配，不能覆盖最新核心事实。通用 FieldSpec 可选整数范围由既有表单就近校验，跨字段合计在提交前验证；继续使用原未知结果与幂等保护。

[ApprovalDeliverySummary](../apps/guardian/lib/ui/approval_delivery_summary.dart)把非PENDING交付摘要移出核心详情前置门禁；原窗口内一次GET，普通失败仅局部重试，历史／撤销仍按原核心授权可用。原Binding、API、request与generation固定，父popped/completed同步退役未核验读取并只记录review信号；关闭、重绑及旧按钮不复活。核心[ApprovalDeliverySnapshot](../apps/guardian/lib/core/approval_decision.dart)校验当前13字段、目标／精确版本／交付恢复组合与未执行证据；不复用设备签名文档。GET可能协调生命周期，新版／未知失败／读取中关闭均需关闭后核对原列表一次，同版成功不重读；不替换原request版本或解除未知写入保护。

审批本人取消／撤销批准复用confirmLeasedAction，绑定原详情父路由、changes/current，父popped/completed或权限退役会结束自有确认；确认后原current与版本检查保留，不能因有API门禁就留下失效确认。

审批详情与两层历史的读取拒绝按后端层级退役：documents403说明申请不可读，结束该申请旅程并核对原列表；attempts403也可能缺单个文档，只结束尝试窗口并核对文档列表。真实401（非REAUTH_REQUIRED）／WORKSPACE_CHANGED退役申请，普通网络、近期认证与写拒绝不扩大失权。原列表sourceCurrent与requestCurrent分开，目标退役后仍可返回一次核对信号；原scope／路由变化的晚拒绝忽略，不变更会话代际或整页审批权限。

[AccessRequestDialog](../apps/guardian/lib/ui/access_request_dialog.dart) 以分钟＋可选秒精确生成1～3600整数秒，秒空值按0，不发送控件分量；批准仍限制不超过原申请。创建Map和ruleIds列表冻结；未知重试跳过当前Form校验/解析，后续拒绝不清pending，408/非Api异常保留未知，isUnavailableOperationResult/412停止旧请求并只读保留。范围／配置失效时不借刷新目录解除未知锁。 复用DialogAccessBinding捕获原路由，didChangeDependencies中一次初载；新入口要求interactive，await续程只要求windowCurrent，覆盖不挡原完成。设备／应用／规则及加载／提交捕获原generation，loadOptions同步防重，应用切换推进代次；设备分页按返回时当前选择处理，不附加选择gen过滤。finish/deactivate永久退役；onComplete必需由创建方传所属OwnedDialogRoute.finish，组件不自行调用受保护Route.didComplete，测试与生产共用此契约。旧回调不能操作被覆盖、已关闭或卸载的窗口。目录GET当前范围明确401/403（非REAUTH_REQUIRED）或WORKSPACE_CHANGED时锁存readDenied，dataCurrent阻止成功／失败／finally晚回并清私有目录及可见草稿；窗口生命周期保留以允许关闭。规则拒绝先核原gen，设备分页不绑规则gen；POST catch与原pending/stopped独立，不从写拒绝推导读取失权。

[DevicesPage](../apps/guardian/lib/pages/devices_page.dart) 只编排受路由控制的全部/连接检查筛选，继续复用 ResourcePage 的分页和操作边界。`connection=NEEDS_CHECK` 由 FleetReads 在授权 SQL 内筛选 ACTIVE 与缺失/过期心跳，使用现有观察时限配置；客户端不按单页计算全局队列。工作台任务保留目标 section 的权限检查，再导航固定筛选位置；登录只允许明确列入目录的精确筛选回跳地址。详情、添加和注册查询使用 ResourceActionLease 与布尔核对回调，纯查看／取消保留分页和搜索；查询后真实确认／取消仍核对一次。筛选代次仅隔离页面事件与操作，实际列表读取仍由 ResourcePage 的 api/path 代次管理，宿主未接受筛选不能使原读取悬挂。注册详情衔接等待自有窗口和子详情结束后再释放原作用域。DeviceManagementController.runAction 默认保留返回重读；仅纯只读诊断按钮显式 refreshAfter=false，保留当前栏目、快照和读取时间。执行记录可包含管理员复核写入，不能一律视为只读。同一栏目重复选择不发GET、不推进读取时间；刷新／核对结果仍明确读取。应用清单以inventory.observationStatus解释空原因与旧报告，勿借心跳或页面读取时间推断报告新鲜；空时不显示搜索。应用栏目的原隐私／诊断／执行记录入口前置到条目之前，复用commonActions和既有runAction语义，无重复副本。设备说明／应用／操作统一在有界CustomScrollView，SliverList按profile/packageName稳定键懒构建；matchingApplications每次build仅筛选一次，同结果用于行、计数及无障碍总数，不恢复嵌套shrinkWrap列表或全量卡片Column。DeviceManagementDialog 所有用户控件捕获原控制器、单调 interactionEpoch 与所属路由；controller/accessChanges 换绑、deactivate、close同步推进代次，ABA不复活旧事件。普通入口核对hasAccess/!busy，搜索保留读中本地过滤，close允许失权／读取中关闭且仍限制writeBusy；未知结果GET与MFA入口保持。内部确认／子流程不套入口busy/current-route门禁，finally仅按原epoch与独立lifetime/token清理自己的展示标识。

[HelpRequestsPage](../apps/guardian/lib/pages/help_requests_page.dart) 的服务端明确拒绝锁存为当前页面失权，清除私有列表并失效晚到读取；本地会话未变化也不能继续使用旧捕获。带目标信息的确认使用 [confirmLeasedAction](../apps/guardian/lib/ui/leased_dialog.dart)，沿用原路由与权限租约。未知确认的行内核对只发 GET，复用既有操作代次条件，不自动重发 POST。

时区输入统一使用 [TimeZoneField](../apps/guardian/lib/ui/time_zone_field.dart)，通用表单通过 `FieldSpec.timeZone` 显式选择。复用已锁定 timezone 数据，按需加载并缓存公共目录；只建议、不替服务端决定有效时区或执行时区换算，手填保持可用。宿主必须同时传可视禁用状态与同步 `canInteract`，在重建前阻止旧选项改变控制器；目录初载保留可读取的原本地时区，字段不拥有调用方控制器。

[MemberEditor](../apps/guardian/lib/ui/member_editor.dart) 在回调前冻结原 Map 与班级 List；已有未知提交后，认证/权限等普通拒绝不清 pending。412 与通用不可恢复结果停止旧请求重试，保留原草稿；未知关闭先就地确认，再返回 refresh/reviewInvitations 核对信号。输入与目录来源绑定当前窗口，换绑或失权不能复活旧窗口。

成员教师范围用原Material纵向单选直接切换，两种模式保留本地选择；重复选中当前项不读取目录，旧回调仍受角色／锁定／原窗口门禁。设备管理读取的REAUTH_REQUIRED表示近期安全验证要求，不等于真实401／403失权：保留已有事实及验证入口；撤销结果核对中的验证也不重放写入。

[DeviceGroupsPage](../apps/guardian/lib/pages/device_groups_page.dart) 以一个加入入口复用 [DeviceGroupBatchPicker](../apps/guardian/lib/ui/device_group_batch_picker.dart)，1～50台均走既有原子 batches；确认保留完整设备／注册编号。详情操作锁在首个等待前建立并保持至子路由完成，返回、筛选及操作捕获原视图代次。选择器明确读取拒绝时锁存失权并清空私有数据，普通网络／近期认证保留选择，满50台有就近提示。五类修改共用 EditDialog 的固定UUID／原值查询钩子，单台移出也走 removals；新建借用 ResourceActionLease 并返回布尔核对信号，普通取消不重读，不再维护设备组专用确认状态机。[device_group_change.dart](../apps/guardian/lib/core/device_group_change.dart) 校验7字段、原回执／当前事实及合法无变化结果，未知后仅用既有 operation-results 查询，不重放写入，不改变目录性质或设备执行能力。

设备组页面在原有效读取／操作范围内收到明确拒绝时锁存失权，借既有 accessChanged 清空私有状态、推进视图代次并关闭自有窗口；旧范围晚到拒绝不影响当前视图。近期认证／网络失败保持原恢复语义，不能用刷新或本地旧Session让失权页面复活。

设备组同源详情刷新只保留原已读事实并标示“上次读取”；loading／失败期间旧资料只读，写入与翻页同步门禁，成功完整替换后恢复。切换分组／成员筛选不带入旧数据，沿原generation退役旧响应；原操作回执和当前记录刷新仍分开，不由缓存确认保存。

成员范围的 [MemberScopeDirectories](../apps/guardian/lib/core/member_scope_directories.dart) 按窗口捕获缓存/并发读取，null 未读与不可变空 Map 区分。MemberEditor 按角色和范围加载所需一类目录，现有引用始终保留完整编号占位；目录对象内部补名称不等于换绑，重载不改提交或版本。每窗独立实例在退役时 revoke，阻止晚到页继续读取；直接注入已读 Map 的组件路径仍使用原快照，不能与异步目录形成双重数据来源。

教师班级选择使用 [MemberClassPicker](../apps/guardian/lib/ui/member_class_picker.dart)，只管理本地查找/仅看已选与有界懒列表；唯一选择集合、Form校验和实时权限/写锁仍由MemberEditor持有。options与已选编号取并集，缺项也保留并允许移除；过滤不裁剪范围，不触发请求。目录已读只表示选项可校验，必填和无效引用继续由表单就近提示。

[ClassesPage](../apps/guardian/lib/pages/classes_page.dart) 将表单/转班返回值统一解释为需核对，由独立acting/operation锁编排一次当前班级与名册读取；view捕获generation/id/筛选，不能在宿主重建前由旧ResourcePage再读。取消保留列表，操作错误与读取错误分开。创建可使用 [ResourcePage](../apps/guardian/lib/ui/resource_page.dart) 的 onCreateChanged（与create互斥），false不重读，true只核对当前列表，不代表创建成功。[ClassActionDialog](../apps/guardian/lib/ui/class_action_dialog.dart) 保留不可变原提交/停止草稿与未知关闭确认。

[ConsolePages](../apps/guardian/lib/pages/console_pages.dart) 的资源适配器及档案页将儿童/应用/时间/策略创建的布尔核对结果传给 onCreateChanged，档案详情传给 onOpenChanged。私有表单仍返回Json回执，档案另以发送前回调记录尝试，未知关闭返回null也不能漏核对；布尔结果不作成功提示。概览操作只在需核对或曾中断读取/无摘要时补读，普通取消恢复原错误并保留数据/时间，不能因关闭窗口将旧失败抹掉。

[SubjectsPage](../apps/guardian/lib/pages/subjects_page.dart) 独立编排档案筛选与操作锁，复用 ResourcePage；成人管理员读取 subjects/management 并可包含归档，其余角色沿用获授权的活动列表。管理详情重新读取当前 state，只有 ACTIVE 提供变更入口，ARCHIVED 和未知状态只读；归档确认包含完整档案身份与影响。筛选使用递增视图代次，不能因往返相同值复活旧回调，也不把操作锁混入读取权限捕获。操作借用 ResourcePage 提供的统一租约，父页面仅退役、不释放，不给窗口传入已释放的父 scope；ConsolePages 元素被其他模块复用也不能让旧详情晚到弹出。

[ResourceActionLease](../apps/guardian/lib/ui/resource_action_lease.dart) 由 [ResourcePage](../apps/guardian/lib/ui/resource_page.dart) 每次 action 创建并最终释放；onCreateChanged(lease)、onOpenChanged(row, lease) 返回需核对信号。租约绑定原资源代际、API、路径与宿主捕获，独立于 busy/canInteract/子窗口置顶；退役同步拒绝旧操作、帧后单次通知，完整回调结束才 dispose。页面离开、资源变化、拒绝读取及 owner 失效推进相应有效期/交互代际，旧 finally 不能解新锁；同键重挂不因此新增普通列表读取。领域授权仍独立保留，成员/班级历史与编辑、应用登记/详情、时间计划和策略预览须取租约交集。既有 void 入口保持自身返回与授权语义，需要子流程有效期时使用布尔租约入口。

ResourcePage.onReadDenied 可通知领域父范围：只在原有效读取代次真正清除拒绝数据后调用原捕获回调，置于setState外；旧资源晚到失败不通知新owner。额度计划据此退役其页面／租约并隐藏旧内容；近期认证要求由领域保留，不把普通网络或写入MFA错误当作该读取通知。

[SubjectChangeDraft](../apps/guardian/lib/core/subject_change.dart) 统一 CREATE/UPDATE/ARCHIVE 的固定正文、档案快照与回执校验，分开 committed/current；待变更必须活动且版本可递增，同版本内容不得变化，较新编辑/归档作为当前事实核对。创建/编辑复用 EditDialog 查询钩子，使用一次UUID及既有 subjects/changes、operation-results/{key}/query，未知后不重放，后续事实只在原窗口/权限仍有效时提示并核对列表。管理详情读取也绑定原编号，昵称按服务端UTF-16长度就近校验。

[SubjectArchiveOperation](../apps/guardian/lib/core/subject_archive.dart) 仅持有归档状态/请求键与异步生命周期，正文和回执委托共同草稿；[归档窗口](../apps/guardian/lib/ui/subject_archive_dialog.dart) 复用 leasedDialog。查询不传写入幂等头，404/认证拒绝不解锁原 POST，412/结果不可恢复停止；完整窗口结束才释放操作对象，尝试后关闭返回核对信号并退出旧详情，普通取消不刷新。初次明确拒绝的人工重试沿用原键与正文，不另造协议或跨窗口持久化副本。

恢复草稿的中文字段清单统一在[领域化展示模块](../apps/guardian/lib/ui/editor_draft_text.dart)，计划、策略与成员的展示只读取已捕获提交与原目录。名称缺失保留完整对象编号，未知字段也保留；展示层不得读取网络、改写原提交或解除重试保护。

时间安排示例的不可变模型与严格响应校验统一在 [schedule_contracts](../packages/schedule_contracts/README.md)，Parent 保留轻量适配，Guardian 直接消费。目录仅按需读取，回填本地草稿、保留时区与日期例外，已有每周时段须确认替换；同包的 `weeklyWindowAdditions` 只计算独立新增项，两个宿主按实际新增数整体检查 56 条上限，不部分添加，不清除既有重复行。Guardian 的 [ScheduleWeekView](../apps/guardian/lib/ui/schedule_week_view.dart) 只做分组展示，删除仍由原编辑器的交互和权限门禁处理。宿主负责授权、有界读取和显式保存，不能将示例选择解释为已保存或已发布。交互契约及当前验证状态见[示例交付说明](schedule-preset-ux-delivery.md)。

时间计划的[日期例外编辑器](../apps/guardian/lib/pages/schedule_exception_editor.dart)只返回独立本地草稿；取消不写回，保存整个计划才提交。管理台的日期例外、每周时间、关闭日期与示例弹窗共用 [leasedDialog](../apps/guardian/lib/ui/leased_dialog.dart) 绑定原父路由及权限租约；每周与例外时间共用 [pickLeasedTime](../apps/guardian/lib/ui/leased_time_picker.dart) 的 24 小时输入。系统选择器的返回限制在局部 Navigator，不能关闭独立覆盖通知；具体交互见[时间计划契约](policy-application-schedule-contract.md)。

在仓库根目录可用 `pwsh -File scripts/manager.ps1 status -Active` 只读定位已选环境（2026-10-25 已实际执行）。前提是 PowerShell 7、可访问的 Docker 及完整的环境选择记录；显式目录查询使用 `status -Directory ...`。状态查询不自动恢复或发布服务，也不代替业务验收。[入口实现](../scripts/manager.ps1)会选取首个 Docker 可执行入口，避免 Windows 多个同名命令被拼成路径。

已有发布的无构建恢复入口为 `manager.ps1 resume`，复用原启动的配置、来源和账本校验，先确认目标持久容器齐全，再只启动原容器；恢复前后严格绑定原应用容器集合和原运行记录摘要，不通过重写记录接受变化。该能力仍以[部署手册](deployment-runbook.md)的当前验证状态为准，不能把源码接线当作真实恢复验收。

部署诊断 `doctor -Toolset Runtime` 只盘点运行命令，默认 `Build` 盘点源码构建命令；自定义构建工具使用已有命令参数和同一套路径基址。 诊断与构建复用[工具发现](../scripts/tool-discovery.ps1)，裸命令保留精确查询，显式文件以 LiteralPath 和命令 Source 完整路径核对；不能直接把通配候选或转义后未找到当作字面发现证明。计划与显示保留原命令值，构建实际调用绑定已核对的 Maven／Dart 完整来源，Flutter沿用原安装解析及来源绑定。构建脚本的新增直接依赖须纳入[固定 recipe 清单](../scripts/deployment-provenance.ps1)，避免发布来源遗漏执行逻辑。命令发现回归使用隔离 PATH 和真实任务探针，不能用自造通配模型证明框架行为；保留框架的语言模式／信任过滤，不以物理文件存在替代命令准入。命令发现不能作为 SDK、Compose 插件、守护进程、服务或平台已验证的证据；保持不执行工具、不连接服务的检查边界。

统一部署入口的显式目录及带目录分隔符的工具路径统一按该仓库根目录解析；裸工具名称保留 PATH 查找，预览与执行共用最终参数，不为预览读取身份配置或启动工具。参数契约见[简明部署入口](deployment-quickstart.md)。

统一部署入口的初始化默认值由同一处解析，预览与执行共用：本机换端口只填 `-EdgePort`，指定公开 URL 时自动采用其端口；外部 TLS 代理保留独立内部端口。[Get-DeploymentOrigin](../scripts/deployment-common.ps1) 是初始化器和预览共用的纯地址/端口/TLS校验，冲突在预览即拒绝；端口推导使用 TryCreate，不能让格式转换异常回显含私密内容的 URL。doctor 缺项时先给补齐逻辑命令和对应覆盖参数的建议，不直接引导初始化；仍只盘点、不执行工具或证明部署可用，见[简明部署入口](deployment-quickstart.md)。

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
