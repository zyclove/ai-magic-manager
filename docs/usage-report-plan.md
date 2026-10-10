# 使用情况报表实施记录

承接已批准 implementation-plan Task 10、RPT-01 和现有观察数据合同。上一目标轮完成加密审计导出并部署 V22，属于实际进展。整个产品目标保持完整，报告聚合、导出、删除治理、支持诊断、商业化与智能辅助仍按原规格推进。

## 设计与裁定

- 首先实现可复用的使用聚合与授权读取边界，再接入管理端日/周、设备/儿童范围及后续班级/类别维度。不能把单设备数据源或内部算法通过测试称为完整 RPT-01 已完成。
- 复用 Spring JDBC/事务、Java Time、Jackson、Flutter Material 和现有设备/成员授权。reporting 只依赖 observation 的公共只读契约，不直接调用其内部服务或绕过授权查询载荷。
- 观察源按当前成员、设备注册周期、设备状态、使用观察授权和保留期读取；儿童只能读取自身，教师和审计员不因新报表获得家庭观察权限。跨租户或失权请求拒绝；关闭观察显示未授权，不能显示零使用。
- Ruling: Android UsageStats 是 OS_AGGREGATE、自报未验证，可能扩展查询边界、重复或重叠。采用最新序号优先的互不重叠区间作为聚合证据；同区间取最新值，其他相交区间不再累加，返回排除数。牺牲部分精度换取不重复计数，不将结果写入硬额度账本。
- 对每个已选应用区间 [a,b) 时长 t 与报告桶 W，令交集长度为 i，区间长度为 d。交集中可推导范围为 [max(0,t-(d-i)), min(t,i)]；无逐事件证据时不按比例分摊。
- 每应用每桶下界为不重叠证据下界之和；上界为各交集上界之和加未覆盖时段。完全没有证据时返回 UNKNOWN/null，不能把默认下界 0 当成零使用。每天范围独立计算，周范围直接计算，不机械累加日范围端点。多个应用/设备可并发，汇总不等同于人的唯一在线时长。
- 日期桶使用用户指定 IANA 时区，覆盖 DST 的 23/25 小时日、周一开始周；请求末端截断到生成时刻，不把未来时段算缺失。来源原时区保留。
- 设备摘要展示查询区间覆盖、最新观测/接收时间及保留边界。查询区间覆盖不证明持续监测或所有应用完整可见，界面必须明确。
- 同步报表输入与载荷有硬上限，超过上限明确要求缩小范围，不返回部分成功。后续大范围报表接入异步 ReportJob 与现有加密产物能力；不得据此宣称全校/长期容量已验证。
- 不扩展观察采集，不增加后台权限，不自动开启授权，不推断私人活动类别，不把未知用户归属认证为某个儿童。

## 实施步骤

1. 先定义输入/输出与纯聚合旅程，覆盖重复、相交、跨日、DST、时区、空证据与周范围。
2. 实现公共观察源的当前授权/注册/保留/大小边界与真实 HTTP 报表端点；覆盖撤权及跨租户/儿童范围。
3. 管理端查询、来源/覆盖/范围解释、趋势和明细、原筛选重试、工作空间变化丢弃，接入设备/儿童/班级选择与类别维度。
4. 独立阶段审阅，真实 MySQL、完整回归、浏览器和真实只读确认；完成完整可用阶段后再部署，不替换当前 V22 运行服务为半成品。

## 进度

- 2026-10-10：当前部署 V22，前端 3000、后端 8082、身份服务 8081 均在线。并行工作为儿童端原生存储集成验收，不修改其文件或 Git 索引。
- 已按 brainstorming 的现有批准规格适配和 executing-plans 的逐步实施方式推进；无需重复申请已授权的产品实现或验证。
- 后端新增 UsageReportSource 公共边界、UsageReportReader、纯聚合和查询端点。H2/模块边界 19 项、真实隔离 MySQL 19 项通过；撤权需覆盖最终序列化预检的失败基线已观察到并修正。
- 使用观察服务仅将既有 current 方法调整为包可见供同模块读取。没有跨模块导入内部实现，没有新增数据库迁移。
- 管理端候选已接入 /reports、角色白名单、日期/时区/日周、设备选择、源覆盖与应用范围明细。前端专项由 11 增至 13 项，包括日历边界校验和失权关闭弹窗；两项新增均有实际 RED→GREEN 记录。前一次完整前端为 95 项，最新完整回归仍需更新。
- Ruling: 12ui 此前已明确拒绝地区访问，沿用已验证 Material 设计，不重试或绕过；前端时区换算使用本机已缓存 timezone 0.9.4，增加桶边界一致性校验，时区规则不一致时拒绝展示并留待库升级治理。
- 候选目录 .local/report-backend 与 .local/report-web；预览端口 3015，仅用于隔离浏览器夹具。3000/8082 仍为已部署导出版本，新增报表未部署、未生成提交冻结清单、未进行最终独立审阅。
- 后续仍按步骤 3–4 完成儿童/班级选择、类别数据来源、趋势/规则状态、真实接口联通、最终审阅与部署。不得将当前设备报表候选视作完整 RPT-01。
- 05:13:59 完整后端 319 项通过、零失败/错误/跳过（.local/usage-report-backend-full.log）；含已部署基线的 Spring/Dart 设备互操作，但尚无新增报表的跨语言真实 HTTP 联通旅程。
- 最新完整管理端 97 项通过（.local/usage-report-frontend-final.log），静态检查无问题；新增日历分桶与弹窗撤权修复已经纳入。源文件与候选校对 234 项一致、无排除（.local/runtime/report-source-hashes.json）。
- 本轮真实运行前端 3000、后端健康接口 8082、OIDC 元数据 8081 均返回 200；不将候选源码的测试结果误写为已部署服务的报表能力。
- 最新 HTML release 构建通过（.local/usage-report-build.log）。真实 Chrome 隔离接口夹具九类检查通过（.local/usage-report-browser-final.log）：桌面明细/无证据、设备选择取消、失败隐藏旧结果、原条件重试、手机无数据/未授权/有数据、儿童入口、教师拒绝。实际滚动后的手机与桌面截图已查看，保存在 .local/runtime/report-browser。图条旁明确显示“应用区间证据覆盖”，避免被误读为使用量。
- .local/usage-report-browser-preliminary.log 首次失败是测试定位器未包含下拉框组合可访问标签；按实际可访问标签修正并重新跑完整旅程。该失败未算成功，未通过修改产品文案迎合测试。
- 预览进程为本轮创建的 3015 / PID 49440，验收后关闭；运行前端 3000 / PID 39316、后端 8082 / PID 28856 保持不变。下一轮从步骤 3 的范围与维度扩展继续，最终一次独立审阅尚未执行，整体目标保持 active。

### 儿童／班级范围增量（2026-10-10）

- 上轮属于实际进展。本轮继续完整 RPT-01，新增 DEVICES/SUBJECT/CLASS 范围与 classVersion。公共 OrganizationRoster 由 tenant 模块实现，reporting 只使用公开接口；成员 → 班级 → 排序档案 → 排序设备，最终校对设备仍绑定原档案。无新增迁移。
- 班级只授予 OWNER/ORG_ADMIN 私有报表入口；儿童只能自身 SUBJECT 或设备。错误/过期/归档/移出名册拒绝，不把组织教师读取名册权限扩展为私有使用权限。
- Flutter 增加范围选择、当前名册解析、明确设备计数、超过 20 台需主动选择、范围版本响应校验。解析失败保持失败状态，不回落自由设备查询；原查询重试与工作空间隔离保持生效。
- 范围初始 4 个后端新测试实际失败后实现通过。真实 MySQL 增加旧快照与班级锁保持测试；移除名册 FOR UPDATE 的负控制稳定返回旧学生而失败。恢复源码后第一次仍失败，检查 javap 确认 Maven 因旧时间戳保留负控制字节码；触发重编译并核对字节码后 25 项通过。这个失败不是服务端锁语义失效，记录于 .local/usage-report-roster-snapshot-red.log 及 .local/usage-report-scope-mysql-final.log。
- 真实 Spring 随机回环 HTTP → 生产 Dart 客户端新增旅程：设备用量、儿童自身、班级版本、儿童班级拒绝和过期名册拒绝。缺少客户端旅程时先失败，完成后与 MySQL/聚合/模块合计 26 项通过、零跳过（.local/usage-report-scope-http-mysql.log）。使用虚拟身份解码器与隔离数据，不冒充真实 OTP 或原生采集。
- 前端专项 17 项通过（.local/usage-report-scope-client-final.log）。两项新增禁用按钮断言首次定位失败，按 Material 实际 ButtonStyleButton 基类修正；产品行为没有为通过定位器而改变。
- 05:36 源码与候选 238 项一致，无排除。旧阶段冻结清单未改；新增使用报表仍未部署，独立最终审阅待整个报表阶段完成。
- 已核验另一任务原始会话 2026-10-09T03:41:52.203Z 的真实 user 回复“允许协调，继续共同推进”，因此已获双方消息协调授权。向设备申请任务提供已验收 ApprovalService/AccessRequestChanged/NotificationService 冻结指纹；对方负责在其 Git 授权下提交此前 V21/V22 冻结阶段，再集成 V23 设备申请。此任务未操作共享索引；当前报表代码不混入旧冻结阶段。
- 05:47:20 完整后端 326 项通过，零失败／错误／跳过（.local/usage-report-scope-backend-full.log）。包含真实 Spring→生产 Dart 报表读取与拒绝路径；真实 MySQL 的 26 项证据记录在 .local/usage-report-scope-http-mysql.log。
- 浏览器班级范围初次停在 SelectableText 错误码定位，截图显示中文名册变化提示与错误码均正常。改为读取用户实际提示后，完整 11 类旅程通过；产品未为测试定位而改文案。随后补齐异常／重复设备在选择器前拒绝及不可变选项保护，新增用例先失败再通过，报表前端专项 18 项通过（.local/usage-report-target-validation-red.log、.local/usage-report-target-validation-green.log）。
- 下一阶段已核对现有 catalog 公共接口：应用身份只有管理员声明与签名摘要，没有类别来源；不得从包名或设备自由文本推测为“可信分类”。后续需单独实现有来源、授权和版本边界的分类维护，再接入报表。policy 当前公共读取接口仅支持指定发布详情，规则状态须通过公开诊断契约扩展，不能绕过模块边界读取内部表。
- 05:50 最终管理端 102 项通过，静态检查无问题，HTML release 构建成功；最终构建的 11 类浏览器旅程全部通过。记录为 .local/usage-report-scope-frontend-complete.log、.local/usage-report-scope-analyze-complete.log、.local/usage-report-scope-build-complete.log、.local/usage-report-scope-browser-complete.log。桌面班级与手机观测截图已检查。
- 当前源码与候选 238 项一致、无排除；前端构建与 3015 实际 HTTP 文件 SHA256 同为 8BD54AB02A469B83590A28EBC416BE09C85D10EBC3E9EBE5CA12347653AD717E，证据保存在 .local/runtime/report-candidate-evidence.json。校验归属后关闭本次预览 PID 60044；保留 3000／8082／8081 原运行服务。新增报表未部署，最终独立审阅尚待整个报表阶段完成。

### 应用分类来源增量（2026-10-10）

- 上轮完成范围交互与完整回归，属于实际进展。本轮继续 RPT-01 类别维度。V23 由设备申请任务交付；已协调本阶段新增分类表使用 V24，不修改 V23、审批、通知或策略的分工文件。
- Ruling: 当前没有已配置且有资格使用的外部分类供应商，也没有可验证签名的观测证据。因此先实现工作空间可维护的分类来源，明确 `ADMIN_DECLARED`；未设置为 `NONE/UNCLASSIFIED`。管理员声明是可追溯配置，不称为客观可信分类、安全认证或应用真实身份认证。
- 分类键精确区分平台、资料和包名，同键不同签名的目录项共享分类，并在编辑界面说明；分类不修改不可变应用身份、访问策略或配额。SHA-256 键避免数据库不区分大小写的排序规则误合并包名。
- 更新要求当前 OWNER/GUARDIAN/ORG_ADMIN、强 If-Match 与原请求幂等重试；AUDITOR 只读，儿童/教师不能进入整个目录。报表只能在已有私有设备授权之后，通过 catalog 公共接口读取所选应用的分类，不能因此获得完整目录。当前分类用于历史时段时必须标明是当前配置，不冒充历史分类快照。
- 并发首次分类通过原子创建配置头后锁定版本，避免先读空行再插入的竞争；分类变更与审计/幂等响应同一事务。前端发生未知结果时冻结原请求，版本冲突要求重新加载，不静默覆盖其他管理员的更改。
- 分类接口最初 5 项旅程均因路由不存在失败；实现后 H2／模块 6 项及真实 MySQL 6 项通过。随后加入公共批量读取（502 个身份、分批、不可变、跨租户无命中）和非空 V23→V24 迁移用例。
- 报表分类联通先因 classification 字段缺失失败；前端分类响应和结果筛选也有实际失败到通过记录。分类响应额外字段替换必需空值字段曾被接受，新增失败断言后改为严格字段集合校验。日志为 .local/usage-report-classification-red.log、usage-report-category-link-red.log、usage-report-category-client-red.log、usage-report-category-filter-red.log、usage-report-category-schema-red.log。
- 应用目录接入分类编辑，报表显示来源／版本／更新时间及结果内类别筛选；空匹配与未授权、无数据、未分类分别展示。前端专项 26 项、完整管理端 110 项通过；最终静态检查无问题，HTML release 构建成功（.local/usage-report-category-frontend-final.log、usage-report-category-analyze-complete.log、usage-report-category-build-final.log）。
- 浏览器最终报表 12 类与分类维护 6 类旅程通过。新增筛选让手机页面变长，最初旧脚本在截图后未实际滚回查询按钮，语义节点点击被固定顶栏拦截；按真实滚动返回顶部后完整通过，未使用强制点击。分类手机截图等待重绘并按视口采集；桌面、手机、只读截图均已检查。日志为 .local/usage-report-category-browser-final.log、usage-report-classification-browser-final.log。
- 合并 c9f90cd/V23 后的后端候选完整 348 项通过，零失败／错误／跳过（06:17:11，.local/usage-report-category-backend-full.log）。随后增强真实 HTTP 旅程：Dart 读取未分类、更新为 EDUCATION，再由生产报表客户端读取新分类；真实 MySQL 报表／分类／聚合／模块共 33 项及独立非空 V23→V24 迁移 1 项通过，隔离数据库与用户已清理（06:18:36，.local/usage-report-category-mysql-final.log、usage-report-category-migration-mysql.log）。
- 本次完整回归使用独立后端源码快照；设备 SDK／儿童宿主来自执行时工作区，对方仍在另一个任务推进持久申请恢复。未把其进行中的新测试混入当前快照，也不把分类验证说成持久恢复新阶段验收。下一次完整基线回归须使用已提交设备 SDK／儿童端的固定快照，避免并行客户端改动影响可复现性。
- 最新主源码／管理端／HTTP 工具与候选 248 项一致、无排除。当前新增分类与报表仍未部署，整体 RPT-01 的趋势／规则状态、儿童原生入口、大范围异步报表及一次最终独立审阅仍未完成。
- 06:19:51 前端候选与 3015 实际 HTTP 产物 SHA256 均为 73924F8853668D5AA14899B9278BC21D79E8D16B511CFE22655ACB36A715EC77；证据已更新 .local/runtime/report-candidate-evidence.json。核对归属后关闭本次预览 PID 59488。运行前端 3000、后端健康 8082 和登录元数据 8081 均返回 200，未改运行版本或共享 Git 索引。

### 趋势与规则状态增量（2026-10-10）

- 上轮分类实现与真实读写、非空迁移均完成验收，属于实际进展。本轮继续趋势与规则状态，不缩小整体 RPT-01。
- Ruling: 使用量是区间证据，趋势差值采用 `[当前下界−上期上界, 当前上界−上期下界]`，范围覆盖零时不判断增减。只比较最后两个连续、完整、实际长度相同的日／周；当前未结束时段仍画出但不参与结论，夏令时导致 23／25 小时时段不和 24 小时日直接比较。缺失记录不能当零或跨过后与更早日期比较。
- 图表复用现有 Material 视觉与时间库，横条显示下界到上界，圆点表示汇总值；未知不画零值。每行提供完整日期和时长的无障碍语义。超过 7 个时段明确提示并可展开，不静默丢弃记录。汇总仍为未独立验证证据，图表不产生行为诊断或唯一在线时长。
- 规则状态取证发现 delivery 仅有 RECEIVED／STORED／REJECTED 自报回执，现有 ENFORCE 发布仍明确不可用。不能把接收／持久化回执写成规则实际生效；后续通过 delivery 公共只读边界展示当前配置与执行证据缺口，不将它冒充历史时段的执行状态。此公共边界与界面尚未实现。
- 并行任务已提交 efb20e224fa0d878ad7b6c7a6d2be36e21a7ae20 的持久申请基础。固定四个设备 SDK、儿童宿主和匹配的 DeviceAccessSubmissionJourneyTest 到 .local/report-clients-efb20e2，离线准备依赖，后续完整互操作从该快照运行，避免读取并行任务正在修改的客户端。
- 趋势新增纯算法 6 项和手机／无障碍组件 1 项。最初缺少实现文件的失败基线已记录；实现后发现混合时间单位格式会误省略下界单位，新增 `+1 秒 至 +1 分钟` 断言先失败再修复。组件初次失败仅为语义测试句柄在框架检查后才销毁，改为 try/finally 正确释放。静态检查另发现 3 处缺少花括号，修正后完整管理端 117 项、静态检查、HTML release 构建全部通过，日志为 .local/usage-report-trend-frontend-final.log、usage-report-trend-analyze-final.log、usage-report-trend-build-final.log。中间失败日志保留，不算通过。
- 最终浏览器报表 17 类通过，新增桌面／手机范围图、范围重叠仍不判定增减、最新完整桶缺证据不比较；分类维护 6 类在最新构建下再次通过。桌面与 390 像素手机的精确值／范围图截图已查看，范围与未知提示、文字换行正常。日志为 .local/usage-report-trend-browser-final.log、usage-report-trend-classification-browser.log。
- 下一步规则状态明确从 delivery 公共接口读取“当前配置与下发进度”，与所选历史使用时段分开标注检查时间。授权仍由报表的成员／名册／设备／观察事务建立；读取只使用所选设备当前 registrationId。按 registrationId 排序锁定已有 configuration_device_heads，再以当前锁定读取得 current streams 和载荷字节数，避免事务旧快照混入已替换配置；头不存在返回空列表，不创建配置。载荷／配置／规则数量需读前检查，超过容量返回明确失败，不部分截断。移除配置、等待签名、过期待拉取、接收／保存／拒绝分别展示，STORED 不证明系统执行或移除已生效。public source、后端与前端联通、撤权／注册周期／并发与容量用例均尚待实现。
- 06:44:25 使用固定 efb20e2 客户端及匹配持久申请旅程的完整后端 348 项通过，零失败／错误／跳过（.local/usage-report-trend-backend-full.log）。包含真实 Spring→Dart 分类读取／修改／报表读取与拒绝路径。当前候选主源码仍是 efb20e2 + 本阶段分类／报表，不混入其他任务进行中的恢复代码。
- 回归期间另一任务完成 793201d47970e0b6df4e4bf4f175bf4ef1ce0bad，专属验收见 docs/releases/stage-submission-recovery-verification.json。新的四个生产文件为 ApprovalService、DeviceAccessSubmissionController、DeviceAccessSubmissionService、IdempotencyService。主源码核对 250 项中这 4 项现在与当前候选不同，其余一致、无排除；另用 Git 对比证明候选四项全部精确匹配 efb20e2，记录 .local/runtime/report-fixed-baseline-differences.json。这是待集成版本差异，不写成所有最新源已通过本次测试。
- 下一轮固定快照已从 793201d 归档到 .local/report-clients-793201d：四个设备 SDK、儿童宿主、对应 4 个后端文件及 DeviceAccessSubmissionJourneyTest。尚未离线准备依赖，也未复制进入当前候选；下一轮先集成该快照并核对其变更，再完成规则状态。未操作共享索引、提交或推送。
- 06:45:24 真实隔离 MySQL 分类／报表／聚合／模块及 Spring→生产 Dart 读写 33 项通过，零失败／错误／跳过（.local/usage-report-trend-mysql-final.log），临时数据库与用户已清理。V23→V24 非空迁移本轮未改，沿用上一轮独立 1 项通过证据，未冒充本轮重新运行。
- 06:46:01 候选前端与实际 3015 HTTP 产物 SHA256 一致，均为 3695D497218811417DB46780B645B6AC28DC4E22F79496D59B5791706C27E93B。本轮临时预览 PID 51876 经归属核对后已关闭；现有前端 3000、后端健康 8082、登录元数据 8081 均返回 200。证据 .local/runtime/report-candidate-evidence.json。新增分类、报表与趋势仍未部署；未进行最后一次独立阶段审阅，整体目标继续 active。本轮已完成趋势与验证，属于实际进展，下一轮无需重复此实现。

### 当前规则状态接入（2026-10-10，本增量已验证，未部署）

- 已合入 793201d 的四个已交付后端文件和对应 DeviceAccessSubmissionJourneyTest；四个设备 SDK／儿童宿主固定在 .local/report-clients-793201d 并完成离线依赖准备。未复制对方在途的儿童 UI 修改。07:04 源码与候选 254 项一致、无排除；当前完整回归使用此固定版本。
- 新增 delivery 公共 ReportConfigurationSource 及模块内 Reader，报表授权成功后在原事务内调用。按注册标识锁已有交付头，当前锁定读预检配置条数与 JSON 字节数，再读取当前 streams；最多 100 配置／设备、2 MiB 总来源、2000 规则／请求，超限拒绝，不截断。无记录不创建交付头，旧注册记录不复用。
- 新增规则状态与报表 JSON 字段均先观察到缺失实现的失败基线。测试首轮误重复注入事务字段，修正后缺失类型为唯一失败。真实 MySQL 注册周期夹具直接修改父键时违反既有外键，改为在隔离夹具中先移除旧授权、切换注册后建立新授权；没有修改产品外键或绕过约束。
- 配置来源／报表／聚合／模块真实 MySQL 34 项通过；负控制只移除当前 streams／载荷的 FOR UPDATE 后，旧快照稳定读到 Report reminder 而非 Current reminder，测试实际失败；恢复源码用新时间戳重编译后通过。日志 .local/usage-report-rules-current-read-negative.log、usage-report-rules-source-mysql-final.log。
- 报表 DeviceReport 新增 configurationState，标记 DELIVERY_ONLY_NOT_EXECUTION，并独立给出 checkedAt。包含当前发布序号、版本、交付阶段、设备回执时间与经缩减的规则描述；不输出 JWS、签名摘要、管理员身份或伪造 effectiveEffect。当前信息不冒充所选历史时段的执行记录。
- Flutter 新增严格不可变解析和 Material 展开区，区分待签发／待拉取／已提供／接收／保存／拒绝／过期及移除、空记录。拒绝未知执行声明、不一致回执时序、重复配置或缺失字段。设备报告已保存仍明确不证明系统执行；查看使用趋势也不证明配置造成了效果。
- 真实 Spring→生产 Dart 旅程新增非空规则状态读取；07:00:42 MySQL 报表／聚合／模块 35 项通过、零跳过（.local/usage-report-rules-wire-mysql.log），临时库和账号均清理。随后新增最终序列化期间交付头仍保持锁的用例，正在纳入全量回归。
- 客户端与界面新增 3 项，完整前端 120 项通过、静态检查无问题、HTML release 构建通过（.local/usage-report-rules-frontend-full.log、usage-report-rules-analyze.log、usage-report-rules-build.log）。最初自动修正指令使用了当前 Dart 不识别的 lint 名称，没有改源码；根据实际检查修正两处花括号后通过。浏览器初次定位把合并的标题／检查时间语义当成单独按钮或精确标题，正在按实际语义节点补齐验收。
- 07:11:13 固定 793201d + 分类／报表／规则状态完整后端 363 项通过，零失败／错误／跳过（.local/usage-report-rules-backend-full.log）。包含原操作过期恢复、非空规则真实 Spring→Dart 联通和最终序列化期间配置头保持锁的新增用例。
- 为改善可读性，规则时长改为整小时／分钟并保留非整分钟秒值；补充发布时能力状态和必需规则提示。新增界面断言先失败再修正通过（.local/usage-report-rules-readable-red.log、usage-report-rules-readable-green.log）。最终完整管理端 120 项通过，静态检查无问题，HTML release 构建通过（.local/usage-report-rules-frontend-final.log、usage-report-rules-analyze-final.log、usage-report-rules-build-final.log）。
- 07:13:51 最终真实 MySQL 报表／配置来源／分类／聚合／模块 42 项通过，零失败／错误／跳过，临时数据库和用户均清理（.local/usage-report-rules-mysql-final.log）。非空 V23→V24 迁移仍沿用此前 1 项独立通过证据，本轮没有新迁移。
- 最新发布构建浏览器报表 23 类和分类维护 6 类全部通过（.local/usage-report-rules-browser-final-complete.log、usage-report-rules-classification-browser-complete.log）。展开项的标题和检查时间实际合并为同一个可访问标签，按实际标签定位后通过，未改产品标签迎合脚本；最终手机与桌面截图已查看，时长、能力、限制及回执内容正常。
- 主源码／管理端／HTTP 工具与候选 254 项一致，无排除。前端构建与实际 3015 HTTP 文件 SHA256 均为 E2F22F87A1B72A9964FB6B7AEC78C2B27312DC0B1135E8035086AD7F28E8E16E。预览 PID 31416 已核对归属并关闭；现有 3000／8082／8081 均返回 200，未替换运行版本。最终证据 .local/runtime/report-candidate-evidence.json。
- 当前规则状态接入属于实际进展，不能称为全产品系统规则执行完成。整体 RPT-01 仍需儿童原生入口、大范围异步报表、最终一次独立审阅与部署。本轮未操作共享 Git 索引、提交或推送。已与儿童申请任务明确：其正在接入申请的 ChildSession/main/UI，不调用尚不存在的设备使用报表 API；下一阶段由本任务提供自设备报表 API 和公共 SDK 契约后再衔接。

### 本设备报表及共享类型 SDK（2026-10-10，候选未部署）

- 新增设备不透明凭据认证的 GET /api/v1/device-api/usage-report，仅接受唯一的 from/to/timeZone/period。自设备范围来自认证上下文，拒绝设备/租户/档案覆盖参数。读取在事务内重新核对档案、设备、注册周期、凭据和观察授权，最终序列化前保留锁；复用既有聚合和当前配置来源。
- 新增 6 项设备接口用例，先观察到缺失路由的失败，再完成实现。覆盖本设备范围、参数覆盖、关闭授权、档案归档、设备撤销、过期凭据、认证后撤权和最终序列化期间凭据锁保持。专项 6 项及模块边界通过，日志 .local/usage-report-device-api-red.log、usage-report-device-api-green.log。
- 设备 transport 新增固定只读路由，复用 HTTPS、凭据获取、超时、中止和禁止重定向。三项新用例先因缺少方法失败，后完整 63 项通过；另补充宿主较大容量设置不得放宽报表 8 MiB 上限，负例确实接受过量 JSON 而失败，修复后完整 64 项和静态检查通过（.local/usage-report-device-cap-red.log、usage-report-device-transport-final.log、usage-report-device-transport-analyze-final.log）。负例模拟载荷产生较大输出，确认失败记录后停止本轮输出进程 PID 60400，未停止运行服务。
- Ruling: 抽取纯 Dart packages/usage_reporting 作为唯一模型与趋势实现，新增 packages/device_reports 作为类型化自设备客户端，而非在设备端复制管理端解析。复用 intl/timezone，保持模型不可变、来源/绑定/日历严格校验；代价是管理端模型异常类型改为 UsageReportFailure，适配器和通用错误组件统一转为原有 ApiFailure 中文提示。不能把管理端全部 API 错误和网络依赖移动进共享模型。
- 管理端已迁移至共享包，设备类型客户端接收宿主当前绑定与 current 回调；会话变化、dispose 或绑定不一致时拒绝结果，不持久化、不自动重试。共享模型 2 项、类型 SDK 5 项通过，二者静态检查无问题；首次缺少实现的失败基线与最终日志分别保存为 .local/usage-report-shared-red.log、usage-report-device-sdk-red.log、usage-report-usage_reporting-final.log、usage-report-device_reports-final.log。
- 首次模型抽取指令使用了错误的相对工作目录，仅导致脚本未运行；改用绝对路径完成。管理端完整 120 项通过，静态检查首次发现 4 处冗余导入，收窄公开导出后无问题，HTML release 构建成功（.local/usage-report-shared-guardian-tests.log、usage-report-shared-guardian-analyze-final.log、usage-report-shared-guardian-build.log）。
- 07:41:22 真实隔离 MySQL 报表/分类/聚合/模块共 48 项通过、零失败/错误/跳过。真实 Spring→生产 Dart 旅程先验证管理端，再用类型化设备 SDK 读取自身非空用量/配置，撤销真实设备凭据后返回终止性 401。日志 .local/usage-report-typed-device-http-mysql.log；测试数据库和用户已清理。
- 发布构建的浏览器报表 23 类及分类维护 6 类通过，桌面和 390 像素手机当前配置截图已检查（.local/usage-report-shared-browser-final.log、usage-report-shared-classification-browser-final.log）。浏览器仍使用隔离接口夹具，未冒充真实设备或身份认证。
- 后端与四个已有 SDK/儿童宿主保持固定 793201d 基线；本轮专属修改及两个新包复制到 .local/report-native-clients，管理端候选明确覆盖到该固定共享模型目录。对方 c085377 的儿童申请 UI 和新的跨进程验收未混入此候选。正在进行完整后端回归；未修改共享索引、提交或部署。
- 已通知儿童申请任务 API/SDK 契约和已验证范围，由本任务下一步提供可复用原生报表页面，再协调 ChildSession/main 入口，避免并发修改宿主。儿童原生 UI、大范围异步报表和最后一次阶段独立审阅仍待完成，整体目标保持 active。
- 07:51:09 固定 793201d + 分类/报表/共享 SDK 的完整后端 369 项通过，零失败/错误/跳过（.local/usage-report-device-backend-full.log）。包含最终类型 SDK 的真实 HTTP 读取及撤权拒绝。对方正在推进的儿童会话刷新修复和跨进程 UI 旅程未纳入此固定候选，后续需按交付提交另行集成。
- 当前源码核对扩展为 277 个文件，覆盖新共享包、设备 transport、报表 HTTP 测试与管理端依赖定义，无差异/排除。最终发布构建与 3015 实际 HTTP 文件 SHA256 同为 1B37E248A3384127E57650ACF9C5448B1348298E6FB1B22021F7FD843A58BA86；预览 PID 60540 已核对归属并关闭。3000/8082/8081 均返回 200，未替换当前 V22 运行服务。
- 收窄公共导出后的最终管理端完整 120 项再次通过（.local/usage-report-shared-guardian-tests-final.log）。最终候选证据已更新 .local/runtime/report-candidate-evidence.json；旧 V13/V21/V22 冻结提交清单未改。本轮接口/共享 SDK 属于实际进展，下一轮从原生报表页面接入继续，不重复实现本轮工作。

### 儿童端报表页面与宿主接入（2026-10-10，候选未部署）

- 上轮 API／SDK 交付属于实际进展。本轮基于对方已交付 `e72f556d4e00dd6b4d8665306bf0bb72fc010b77`，将 ChildSession 原子身份刷新与七阶段申请 HTTP 旅程纳入固定候选 `.local/report-child-ui`。对方后续正在推进的申请离线修复／原生持久化验收未混入本候选；共享 Git 索引未操作。
- Ruling: 使用 Flutter Material 与已存在的公共模型，新建 `usage_report_ui` 共享页面、趋势和配置组件。管理端原组件改为公共导出；儿童宿主新增“使用”导航与专属 loader。沿用此前 12ui 地区拒绝的已记录决定，不重试或绕过外部服务。
- 页面提供近 7／14／30 天、自选日期、日／周、IANA 时区、应用搜索／资料选择、类别筛选、趋势、来源与当前配置。刷新失败清除旧结果，按原条件重试；无数据、未授权、无明细、类别无匹配和连接失效分别展示。退出、后台、身份或授权变化时取消请求、丢弃迟到响应并关闭私有弹窗，不保存报表。
- `DeviceChildReports` 每次读取真实 access-context 并核对宿主绑定，再用当前凭据调用类型 SDK；检查原生解锁状态和实际 Android／TV 平台。普通 Web 入口不创建设备读取器。没有新增成人凭据依赖，没有把报表阅读当作系统规则执行。
- 共享页面首次红灯包括测试样例语法问题；修正样例后再次确认缺少实现的失败，再完成实现。宿主导航测试暴露浏览器模式仍构造 receiver，修复为仅 nativeAvailable 时创建。共享界面最终 8 项通过、静态检查无问题；儿童完整 97 项通过，静态检查修正工具文件两处花括号后无问题。日志 `.local/usage-report-shared-ui-final.log`、`usage-report-shared-ui-analyze-final.log`、`usage-report-child-full.log`、`usage-report-child-analyze-complete.log`。
- 正常儿童主入口 Web release 和 Android debug APK 均构建成功。独立浏览器夹具另用 `REPORT_PREVIEW_FIXTURE=true` 构建，隔离在 3016；不作为生产儿童 Web 或原生系统采集证明。主入口 Web 保存在候选 `build/main-web`，APK 位于 `build/app/outputs/flutter-apk/app-debug.apk`。
- 扩展已有真实 HTTP 旅程，使用实际 Spring → ChildSession → ChildApp → DeviceChildReports → 类型 SDK 展示非空用量／规则，实际撤销设备凭据后 access-context 返回 401 且不再读取报表。原生平台事实和宿主初始化使用受控替身，不冒充 Android 真机验收。
- 08:29:27 完整后端 371 项通过，零失败／错误／跳过（`.local/usage-report-native-ui-backend-full.log`）。08:31:12 隔离 MySQL 报表／聚合／分类／模块共 48 项通过，包含上述真实儿童页面 HTTP 旅程，测试数据库和用户已清理（`.local/usage-report-native-ui-mysql-final.log`）。本轮无新迁移，V23→V24 迁移沿用此前独立证据。
- 管理端完整 120 项、静态检查和 HTML release 构建通过；发布构建浏览器报表 23 类、分类维护 6 类通过。儿童端浏览器 11 类通过，涵盖桌面／手机、搜索选择、日周、时区校验、无记录／未授权、刷新失败、键盘重试与退出。浏览器使用隔离接口夹具，真实数据库 HTTP 联通由上条独立证明。
- 浏览器脚本首次失败来自 Material 单选项的合并 aria-label、Flutter 输入框未完成焦点切换和错误假设的 Tab 起点。根据真实可访问树／截图修正定位，实际点击并等待焦点后输入，真实 Tab 走到重试按钮再回车；未修改产品逻辑迎合定位器。前次失败日志保留，最终完整日志为 `.local/usage-report-child-browser-final.log`，管理端为 `usage-report-native-guardian-browser-final.log` 与 `usage-report-native-classification-browser-final.log`。
- 儿童页面及宿主接入已完成本轮候选验证。RPT-01 仍需大范围异步报表、完整阶段最后一次独立审阅与部署；Android／TV 真机报表操作和真实系统执行仍需另外验收，整体产品目标保持 active。
- 最终源码／候选校对 299 个文件一致、无差异；固定 e72f556 的 170 个非本轮修改文件与归档一致，另外明确列出本轮儿童宿主覆盖文件。两组检查分别记录在 `.local/runtime/report-source-hashes.json` 与 `report-child-fixed-baseline.json`，不将并行任务正在修改的工作区整体冒充为已验收候选。
- 管理端发布构建与 3015 实际文件 SHA256 同为 `B6C414B2B1420E7643857763F51E81DC0341698EF3107107A0480113A8D182AE`；儿童主入口 Web、正常 APK 和独立预览各自记录指纹，不互相替代。最终手机规则明细及桌面趋势截图已查看，结果保存在 `.local/runtime/child-report-browser`；全部证据更新 `.local/runtime/report-candidate-evidence.json`。
- 核对进程归属后关闭本轮隔离预览 3015／PID 68692、3016／PID 58620；前端 3000、后端健康接口 8082、身份元数据 8081 再次均为 200。原运行版本未替换，旧阶段提交冻结清单未改。下一轮继续大范围异步报表，最后一次阶段独立审阅尚未进行。

### 大范围异步报表后端（2026-10-10，候选未部署）

- 继续完整 RPT-01，新增 V25 持久任务与按设备加密分片，支持最多 200 台显式选择、当前范围冻结与重新鉴权、原键重试、取消／撤权／到期清理、租约恢复及有界后台生成。复用现有 Spring JDBC、事务、调度、幂等和 JWE 密钥环，独立加密 purpose 保持原审计导出兼容。
- 新增任务 20 项通过，包括 200 台无观测记录设备完整生成；班级归档清理和每片重复全量授权读取均有独立 RED→GREEN 证据。后者优化为每片检查自身、最后一片发布前和下载时复核全部范围；未完成任务不能读取中间密文。
- 详细设计、容量、接口和本轮失败／修复记录见 [异步报表计划](usage-report-jobs-plan.md) 与 [接口契约](usage-report-jobs-contract.md)。管理端任务页面、真实客户端联通及完整阶段最后一次独立审阅／部署继续推进。本轮未把后台接口完成称为异步报表全流程交付。

### 管理端任务与真实客户端增量（2026-10-10）

- 管理端后台报表流程已接入：最多 200 台设备的明确选择、提交确认、原请求重试、安全验证回跳草稿、任务进度／分页／取消、按当前设备名称搜索结果与逐片读取。已保存结果标注生成时配置，后台、失权和到期清除私有内容。最终完整管理端 147 项、共享界面 8 项、静态检查和 release 构建通过，浏览器 14 类隔离交互通过。
- 10:00:21 最终隔离 MySQL 任务 21 项通过，含真实 Spring → 生产 Dart 客户端的创建／重试／状态／分片／MFA 拒绝／成员隔离／取消；测试身份解码不作为真实 OIDC 或 OTP 证明。346 项来源与固定候选一致，管理端构建与预览实际文件 SHA256 为 `4846DC2150F2DCB5462DECC240C69EEEDFDB53AE5386F863C047B6FFB3F08330`。证据 `.local/runtime/report-jobs-ui-evidence.json` 与单独源码指纹已保存，3015 隔离预览已关闭。
- 儿童固定依赖仍为 e72f556 加本报表阶段覆盖，未混入 a194aa1 和另一任务在途 Android HTTP 阶段。下一步集成已交付儿童修复、进行新组合完整后端／儿童回归，完成整个报表阶段最后一次独立审阅与部署。当前 3000／8082／8081 均为 HTTP 200，运行版本仍是 V22；整体目标继续进行。
