# 家庭与机构智能管家：产品、功能与技术设计蓝图

> 文档状态：设计基线（Draft 1.6）
> 更新日期：2026-10-09  
> 面向团队：产品、Flutter、Android、后端、SRE、安全、隐私与客户交付  
> 目标：统一产品能力定义、平台限制、架构边界、接口契约和分期验收标准

配套阅读：[功能规格与流程](parental-control-functional-spec.md)、[商业运营与交付规格](parental-control-commercial-spec.md)、[文档索引](README.md)。本文件负责平台总体决策，配套规格负责具体功能流程、异常状态、业务数据和验收项；实际能力必须以目标型号、管理模式和供应商验证结果为准。

实施细节见[产品实施与功能闭环](parental-control-product-delivery-spec.md)。进一步增强见[完整产品交付与商业运营模型](parental-control-product-operating-model.md)：全功能工作包、状态机、审批与批量故障收敛、跨端页面、共享监护/学校与家庭边界、套餐计量、渠道与服务运营。数据库默认仍采用 MySQL 8.4 LTS，OceanBase 的真实兼容与切换要求见[数据库实施与认证规格](database-implementation-and-certification.md)。

## 1. 产品定位与原则

### 1.1 产品定位

为家庭监护人与学校/机构提供儿童数字健康、安全访问和设备治理平台。家长或机构管理员集中配置规则，儿童/学生端查看规则和理由、查看使用情况并申请临时访问。首期聚焦 Android 手机/平板与 Android TV，后台同时支持家庭和机构租户。

控制链路分成三层：

1. **产品策略层**：管理员声明允许/限制什么、对谁生效、何时生效。
2. **平台适配层**：将策略映射到 Android Enterprise 管理 API、操作系统家长控制能力、网络过滤或应用内能力。
3. **执行与证据层**：设备本地执行可支持的策略，返回版本、结果、时间和失败原因；管理台区分“已创建、已下发、已接收、已应用”，不将下发误报成生效。

### 1.2 目标与非目标

**目标**

- 可解释、可审计地管理应用安装/启动、使用时长、时间段、系统权限、网站/网络和内容评级。
- 提供儿童可见的规则、阻止原因、健康提醒、例外申请和家长恢复通道。
- 支持家庭 BYOD、学校统一配发设备、电视设备不同等级的控制能力。
- 提供隔离的家庭/机构租户、用户/角色管理、设备注册、审计和可复用的策略服务。
- 支持多区域 SaaS 和客户私有化部署，并可水平扩展。

**非目标**

- 不绕过操作系统安全机制；不使用 Root、越狱、隐蔽录屏/摄像头、隐藏无障碍服务或未经授权的持久化方式。
- 不承诺普通消费设备上的第三方应用永远无法被强制停止、卸载、重置或通过系统/网络管理权限外的路径绕过。
- 不默认上传儿童屏幕、相机、麦克风或完整浏览内容；不建设隐蔽监视或儿童画像广告能力。
- Flutter 共用界面不代表不同系统可提供相同的系统管控能力。

### 1.3 质量原则

- 先展示能力和约束，再引导管理员授权。
- 每次拦截都能向孩子说明原因；每次执行失败都能向管理员说明设备、能力或网络原因。
- 本地继续执行最后一份有效策略；云服务故障既不能无故解除保护，也不能锁死紧急恢复路径。
- 权限最小化、按租户隔离、操作留痕、组件可替换；标准 API 和适配器优先。
- 不把 AI 置信度当作事实；自动识别只提示或触发低影响动作，重要结论需管理员确认。

## 2. 用户、角色与核心流程

### 2.1 角色权限矩阵

| 角色 | 范围 | 允许操作 | 禁止/限制 |
|---|---|---|---|
| 平台运营管理员 | 平台级 | 租户生命周期、系统参数、服务健康、受控支持流程 | 默认浏览儿童活动细节；无审计代客改策略 |
| 家庭所有者/监护人 | 一个或多个家庭 | 邀请监护人、绑定子女、注册设备、设策略、审批、看报告、撤销授权 | 访问其他家庭数据 |
| 监护人协作者 | 被授权家庭/成员/设备 | 在授权范围查看或改策略 | 扩大自身范围、移除所有者 |
| 机构管理员 | 所属机构 | 组织/班级/设备分组、批量注册、策略模板、报表、角色委派 | 访问其他租户 |
| 教师/设备操作员 | 指定班级/设备组 | 查看所需合规状态、发起有限临时访问请求、查看设备状态 | 修改组织安全底线、查看无关学生细节 |
| 儿童/学生 | 本人及本人设备 | 查看规则/用量/拦截原因、申请临时访问、求助 | 创建管理员、改策略、删审计或解除注册 |
| 审计员/隐私专员 | 授权审计范围 | 查看策略版本、授权和访问审计 | 变更运行策略 |

所有接口执行双重授权：用户在组织/家庭中的 RBAC 权限，以及目标资源属于该授权范围的 ABAC 检查。隐藏客户端按钮不能代替服务端校验。

### 2.2 核心流程

**家庭启用**：监护人创建家庭并完成强认证 → 邀请另一位监护人 → 创建儿童资料（只收集必要信息）→ 选择设备及管理模式 → 展示该模式可实现/不可实现的能力 → 扫码或系统授权绑定 → 选择年龄/场景模板 → 预览规则 → 确认下发 → 查看设备回执。

**机构启用**：创建机构与管理员 → 配置班级/设备组 → 验证 EMM 接入资格与配额 → 生成有期限的注册令牌/二维码 → 受管注册设备 → 绑定默认策略 → 验证策略回执 → 分批启用 → 通过合规仪表盘跟踪执行率。

**临时访问申请**：儿童点选受限应用/网站 → 看到阻止原因和下次开放时间 → 选择理由申请 → 监护人收到待审批 → 监护人重新认证 → 选择范围与有效期 → 设备收到限时例外 → 到期自动失效且留下审计。

**离线设备**：继续执行最后一份签名且有效的策略；显示最近同步时间。短期例外不得因离线延期；回网后幂等补交事件、获取新策略并返回执行状态。

## 3. 设备模式与能力边界

### 3.1 平台能力矩阵

| 平台/模式 | 应用控制 | 系统权限 | 时长/时段 | 网站/内容过滤 | 防卸载/强制退出 | 计划定位 |
|---|---|---|---|---|---|---|
| Android 家庭 BYOD、未受管 | 依赖系统授权、使用情况访问、受支持的本地过滤；能力按版本/厂商展示 | 只能使用系统公开且用户授权的控制能力，不保证可统一改任意应用权限 | 可采集部分用量并提醒；跨应用强制拦截可能有限且可绕过 | 受管浏览器、DNS 或明确告知的本地 VPN 覆盖部分流量 | 不承诺阻止系统设置中的强制停止、卸载、重置或安全模式绕过 | 家庭有限管理 |
| Android 受管全设备/专用设备 | 可通过受管策略管理支持的包、安装和锁定任务 | 通过系统管理策略控制兼容权限 | 本地执行时间策略 | 系统网络策略与受管应用组合 | Device Owner/锁定任务可增强，仍受 OS/OEM 能力约束 | 机构强管理 |
| Android 工作资料 | 策略主要应用于工作资料，不能视为管理个人空间 | 工作资料范围 | 工作资料范围 | 受管资料/浏览器范围 | 不宣传完整个人设备控制 | 有范围的 BYOD |
| Android TV/Google TV | 按系统、厂商、型号实测；不假设存在通用管理 SDK | 仅报告设备实际支持项 | 系统定时、启动器或受管应用因型号而异 | DNS/路由器/应用评级组合 | 只有实际支持 kiosk/受管模式时才承诺 | 认证型号清单 |
| iPhone/iPad（后续） | Family Controls 授权与系统应用 token | 仅公开框架允许项 | Device Activity | 系统/受管浏览器能力 | 系统家长授权机制提供平台级保障，与 Android DPC 不同 | 后续阶段 |
| Windows/macOS（后续） | 按系统版本、MDM/Assigned Access/家长控制评估 | 受管策略范围 | 平台机制 | 系统策略/受管浏览器/DNS | 仅承诺受支持版本的受管配置 | 独立验证 |

Android 锁定任务和设备级控制依赖受管模式；远程重启也要求设备所有者能力。[Android 锁定任务](https://developer.android.com/work/dpc/dedicated-devices/lock-task-mode)、[Android 设备控制](https://developer.android.com/work/dpc/device-management.html)

Android Management API 是机构受管设备的优先官方评估方案，但生产接入限于符合规则的商业 EMM 等提供方，且有准入和配额要求；满足条件时使用 Google 提供的 Android Device Policy，不默认自研 DPC。不符合准入时使用经过审查的 EMM 合作方接入，家庭 BYOD 不借用受限 EMM API。[API 概览](https://developers.google.com/android/management/introduction)、[使用规则](https://developers.google.com/android/management/permissible-usage)、[新 EMM 方案指南](https://developers.google.com/android/work/play/emm-api/register)

电视需按 Android TV/Google TV 版本、厂商和受管模式建立支持矩阵。设备不支持系统策略时，使用电视自带家长设置、受控启动器或网络过滤提供有限功能，并标记控制盲区。

### 3.2 统一能力状态

设备对每条策略返回明确状态，不得折叠为一个开关：

- **SUPPORTED_APPLIED**：系统支持且已应用。
- **SUPPORTED_PENDING**：支持但等联网、重启或管理员授权。
- **PARTIAL**：只覆盖部分应用、用户空间或流量。
- **UNSUPPORTED**：系统/设备不提供此能力。
- **NEEDS_ADMIN**：需要管理员完成授权或重新注册。
- **FAILED_RETRYABLE / FAILED_PERMANENT**：可重试/不可重试失败。
- **REVOKED / STALE**：授权已撤回/设备策略过旧。

每条规则都报告能力 ID、平台版本、厂商/型号、管理模式、策略版本、状态、最近生效时间、错误码和用户可理解说明。设备认证名单以真机验证结果为依据。

## 4. 功能需求与规则语义

### 4.1 功能模块

| 领域 | 能力 | 关键行为 |
|---|---|---|
| 身份/租户 | 账号、OIDC 登录、家庭/机构、邀请、组织 SSO | 多租户隔离；邀请可撤销/过期；高风险操作二次认证 |
| 角色权限 | 内置角色、自定义角色、资源范围、授权有效期 | 服务端授权；授权撤销和管理员交接可审计 |
| 设备注册 | 家庭绑定码、EMM 注册令牌、二维码、设备认领/撤销 | 单次、有期限、绑定目标的令牌；显示管理模式 |
| 应用目录 | 包名/商店标识、分类、年龄评级、风险标签 | 记录来源和更新时间；未知应用进入审核 |
| 应用控制 | 安装/启动/额度/时段/临时例外 | 发布前做能力校验、冲突检测和影响预览 |
| 权限管理 | 摄像头、麦克风、位置、联系人/文件等系统权限 | 只配置系统公开支持的管理项；显示控制边界 |
| 网站访问 | 白/黑名单、类别过滤、安全搜索、受管浏览器、DNS | 明确过滤范围，不解密 HTTPS |
| 使用健康 | 总用量、逐应用用量、连续时长、休息提醒、学习/睡眠计划 | 本地累计并补传；儿童可以查看自身数据 |
| 例外审批 | 临时访问申请、理由、批准/拒绝、有效期 | 精确限定目标/时长，不能改写基础策略 |
| 安全告警 | 未授权变更、管理授权变化、长时间离线、策略失败 | 风险、证据、可信度、建议动作分开展示 |
| 报告审计 | 使用趋势、策略执行率、设备合规、角色/策略操作日志 | 汇总优先、导出受控、保留期可配置 |
| 运维诊断 | 客户端版本、心跳、策略状态、组件状态、日志关联 ID | 诊断包剔除令牌、完整 URL、儿童敏感内容和媒体 |

### 4.2 核心领域模型

- **Tenant**：家庭或教育机构租户。
- **Household / Organization**：家庭/机构范围；机构下可含班级、年级和设备组。
- **Membership**：用户与家庭/机构关系、角色、范围、有效期和状态。
- **ManagedSubject**：儿童/学生档案及监护/所属关系，只保存功能所需资料。
- **Device**：平台、型号、版本、管理模式、绑定主体、能力集、Agent 版本、心跳和合规状态。
- **AppCatalogEntry**：稳定包标识、签名摘要、类别、评级、元数据来源。
- **PolicyTemplate**：年龄、学习/休息/周末或机构场景的可复用模板。
- **PolicySet / PolicyVersion**：不可变规则版本、目标范围、生效时间、创建者、审批者和签名摘要。
- **PolicyRule**：规则类型、目标、动作、条件、时间计划、例外和平台能力映射。
- **DeviceCommand / PolicyReceipt**：唯一 ID、版本、签名、过期时间、投递/执行状态和错误。
- **AccessRequest / TemporaryGrant**：申请者、资源、理由、批准者、起止时间、撤销状态。
- **UsageSummary / SafetyEvent / AuditEvent**：聚合使用、安全事件和管理操作。

规则类别包括 APP_LAUNCH、APP_INSTALL、APP_TIME_LIMIT、APP_SCHEDULE、RUNTIME_PERMISSION、DOMAIN_ACCESS、CONTENT_CATEGORY、DEVICE_RESTRICTION、BREAK_REMINDER。Android 应用标识至少使用包名和签名摘要，不能只用可变显示名称。

### 4.3 优先级、时间和模板

规则按以下步骤求值，不能将列表理解成“最后一项可覆盖所有前项”：

1. 先满足系统权限边界与不可取消的紧急访问/恢复保护。
2. 计算租户强制底线；被标记为 nonOverridable 的规则不能被下级管理员或临时例外放宽。
3. 在授权范围内合并家庭/机构基础规则、组、成员、设备规则；仅允许在上级明确授权的字段上覆盖。
4. 临时例外只替换 allowTemporaryOverride=true 且批准者具有放宽权限的指定规则，仍受步骤 1–2 约束。

同层冲突以拒绝优先；没有明确覆盖权时采用限制交集。家庭与学校是独立授权域，关联学生不自动合并租户权限或共享活动明细。学校设备的强制底线不能被家长放宽，学校也不能控制未授权的个人设备。例外只能放宽指定目标、规则和时间，不能使已卸载应用重新安装或自动授予敏感权限。能力不支持时显示 PARTIAL/UNSUPPORTED，不伪造成功。策略编辑采用草稿、差异预览、发布不可变版本和回滚版本。

日程保存 IANA 时区、工作日/节假日和 DST 规则。家庭默认家庭时区，机构默认机构时区；跨时区设备保持策略指定时区并报告变化。额度在同一开机周期内用单调时钟累计；重启后不能直接延用上次单调时间值，须恢复已提交计数、开机标识和服务端时间锚点。跨设备额度采用可验证的额度预留与结算，详见功能规格；设备无法可靠计时/执行时仅提供汇总和提醒。时钟偏移异常生成诊断事件。

预置模板：**低龄基础安全**（白名单、年龄评级、睡眠时段、审批例外）；**学习专注**（学习时段开放学习/紧急应用，娱乐在学习后按额度开放）；**均衡日常**（工作日/周末分开额度、休息提醒）；**机构设备**（受管应用清单、批量更新窗口、锁定任务和合规告警）。模板可复制调整，发布前仍进行设备能力校验。

## 5. 体验与信息架构

### 5.1 管理端导航

**家长端**：总览（今日状态、剩余时间、离线设备、待审批/风险）→ 孩子与设备（家庭成员、设备、能力等级、最近同步、有效策略）→ 规则（应用矩阵、日历、内容安全、权限清单）→ 动态与申请（用量、拦截、申请、风险）→ 家庭设置（监护人、角色、授权、注册、隐私、数据导出/删除）。

**机构端**：组织 → 班级/设备组 → 成员 → 设备 → 策略 → 合规/审计。批量操作先展示影响设备数量、支持率和无法执行的设备，再要求管理员确认。

### 5.2 交互要求

- 应用矩阵展示应用名/类别、开关/额度、时段、网络访问、敏感权限、平台支持和最近执行结果。
- 规则编辑分开展示“管理员设置”“平台可执行能力”“设备当前结果”；修改前预览影响对象并提示锁定风险。
- 儿童端给出友善、非羞辱性的阻止原因和下一次开放时间，并提供限时申请入口。
- 紧急恢复入口仅对认证管理员开放，支持撤销错误策略和提交诊断包，不提供隐藏口令后门。
- 电视端支持遥控器方向键、可见焦点、大字号、二维码/短码授权。
- 页面覆盖空、加载、离线、错误、无权限和不支持状态；不能仅靠颜色表达状态。
- Flutter 按触控、遥控器、键鼠输入自适应，平台能力由统一 capability view model 呈现，避免业务 UI 充斥平台分支。[Flutter 自适应设计](https://docs.flutter.dev/ui/adaptive-responsive)

## 6. 系统架构与组件选型

### 6.1 逻辑架构

~~~mermaid
flowchart LR
  subgraph Clients["管理与使用端"]
    Parent["Flutter 家长 App"]
    Admin["Flutter Web 管理台"]
    Child["Flutter 儿童端"]
  end

  subgraph Device["受管设备"]
    UI["Flutter 可视层"]
    Native["Kotlin 原生适配层"]
    OS["Android / Android TV 许可的本地接口"]
    DPC["供应商 DPC / Android Device Policy"]
  end

  subgraph Ingress["接入层"]
    WAF["WAF / API Gateway"]
    MQTT["MQTT Broker：Artemis"]
  end

  subgraph Backend["Spring Boot + Spring Modulith"]
    IAM["身份与租户"]
    Fleet["设备与能力"]
    Policy["策略/计划/审批"]
    Connector["平台连接器"]
    Audit["审计/报表"]
    Outbox["Outbox / 事件消费者"]
  end

  subgraph Infra["数据与遥测"]
    SQL["MySQL 8.4 LTS / OceanBase MySQL 模式"]
    Redis["Redis 缓存"]
    Kafka["Kafka 事件流"]
    OTel["OpenTelemetry Collector"]
  end

  Parent --> WAF
  Admin --> WAF
  Child --> WAF
  WAF --> IAM
  WAF --> Fleet
  WAF --> Policy
  WAF --> Audit
  Policy --> SQL
  Fleet --> SQL
  Outbox --> Kafka
  Policy --> Redis
  Connector <--> MQTT
  Connector --> EMM["服务端 EMM / 合资格 AMAPI"]
  EMM --> DPC
  DPC --> OS
  MQTT <--> Native
  UI --> Native
  Native --> OS
  Backend --> OTel
~~~

Flutter 管理 UI 不持有 EMM 密钥、设备私钥或服务凭据。Android 原生层只执行系统明确授权给本应用的操作。在 Android Device Policy 管理的模式中，系统策略由官方 DPC 执行，服务端连接器调用 EMM/AMAPI；伴随 Agent 的 MQTT 接收成功不能证明 DPC 策略生效。DPC 所有者权限不会自动转授给伴随 Agent，不能假设同时安装两个设备所有者。执行状态须分别核对供应商状态和可观测的本地结果。[AMAPI 策略字段](https://developers.google.com/android/management/reference/rest/v1/enterprises.policies)

### 6.2 后端模块边界

Spring Boot 模块化单体按以下领域包组织：

- **identity-access**：用户映射、租户成员、授权与认证事件。
- **tenant-household**：家庭/机构、监护关系、组织树和成员。
- **device-fleet**：注册、设备生命周期、能力清单、健康状态和撤销。
- **app-catalog**：应用标识、分类、评级、元数据来源和审核。
- **policy-management**：草稿/版本、冲突校验、计划、发布和回滚。
- **access-approval**：申请、审批、限时例外和到期撤销。
- **device-messaging**：设备身份、命令队列、幂等回执和重试。
- **platform-connectors**：Android EMM API/合作方及后续平台适配器。
- **usage-safety**：聚合用量、告警和内容过滤状态。
- **audit-reporting**：审计、报表、导出和保留策略。
- **tenant-operations**：租户配置、限流、功能开关和私有化诊断。

模块只能通过公开 application API 和领域事件交互，禁止直接访问其他模块私有数据库表。先使用 Spring Modulith 验证依赖和模块测试；仅在独立扩缩容、团队所有权或故障隔离有实测需要时再拆服务。[Spring Modulith](https://spring.io/projects/spring-modulith)、[Spring Modulith 事件机制](https://docs.spring.io/spring-modulith/reference/events.html)

### 6.3 基础组件基线

| 子系统 | 基线组件 | 约束 |
|---|---|---|
| Flutter 状态/路由 | flutter_bloc、go_router | 页面/业务/数据访问分层，平台能力由 adapter 封装 |
| API 与 DTO | Dio、OpenAPI Generator、json_serializable/freezed | 生成 DTO 与手写业务代码分离 |
| 本地数据 | Drift/SQLite、系统安全存储 | 只缓存必要策略/待补传事件；密钥进系统 Keystore |
| Android | Kotlin、Android Enterprise 官方 API/获准 EMM SDK、Android Device Policy、Pigeon | API 准入是机构强管控门槛，不默认自研 DPC |
| iOS 后续 | Swift FamilyControls、ManagedSettings、DeviceActivity | 申请 Family Controls entitlement，按授权范围实现 |
| 后端 | Java LTS、Spring Boot、Spring Modulith | 稳定版本基线；领域模块化单体 |
| 身份/鉴权 | Keycloak OIDC、Spring Security Resource Server | 用户 API 用 OAuth2；设备凭证与管理员 token 分离 |
| 事务数据 | MySQL 8.4 LTS + InnoDB（首期）；OceanBase MySQL 模式（满足条件后的部署选项） | 业务隔离在应用授权与租户字段；数据库账号/Schema/租户边界作为纵深防御 |
| 缓存/限流 | Redis | 不作为策略权威源；评估许可证和私有化支持 |
| 事件流 | Apache Kafka | 异步审计投递、遥测和报表，不作为最终策略状态 |
| 设备通道 | Apache ActiveMQ Artemis MQTT 3.1.1 | 验证移动网重连、ACL、持久消息、集群和容量 |
| 迁移/API 文档 | Flyway、springdoc-openapi | 数据变更可追踪，CI 生成接口文档 |
| 测试 | JUnit 5、Spring Modulith Test、Testcontainers、WireMock、Flutter test | 数据库/消息中间件集成与客户端逻辑验证 |
| 可观测性 | OpenTelemetry SDK/Collector + Prometheus/Grafana/Loki 或客户等价后端 | 不输出 token、原始媒体、完整 URL 查询和儿童敏感内容 |
| 容器交付 | OCI 镜像、Docker、Kubernetes、Helm | SaaS 和私有化共用镜像与部署模板 |

依赖固定为经过验证的稳定版本；季度复核维护状态、许可证、CVE、商业支持和替代路线。Android/Apple 平台 API 资格、entitlement 和 EMM 计划是外部关键依赖，必须有责任人和复核日期。

### 6.4 后端技术决策：Spring Boot 对比 Go

采用 **Java LTS + Spring Boot** 作为主后端。核心复杂度是租户、角色授权、审计、工作流、策略版本和多平台集成；Spring Security、事务、验证、数据访问、可观测性和企业连接器生态可降低交付与维护成本。使用 Spring Modulith 保持清晰领域边界。

Go 的并发模型和部署体积有优势，适合以后经负载验证的高连接边缘服务，但不是本项目首期全部业务后端的默认选择。设备长连接由专用 MQTT Broker 承担，不需要为连接数单独把核心领域服务改写成 Go。除非容量压测证明某个服务模块受 JVM 资源/延迟限制，否则不混用双语言。

Spring Cloud 不在首期强制引入；模块化单体先按分布式部署准备接口、事件、租户边界和状态外置。微服务化必须基于故障域或独立伸缩数据决定，届时使用 Spring Cloud 提供的配置、发现、网关和熔断能力。

### 6.5 组件许可证登记与替换边界

以下为技术选型阶段登记，不是已构建制品的完整 SBOM。实施时固定具体 tag/发行版与制品哈希，并复核传递依赖；项目首页的许可证不能代替实际交付包中的 LICENSE/NOTICE。

| 组件 | 官方许可来源 / 登记要求 | 交付影响与替换边界 |
|---|---|---|
| Spring Boot | [Apache-2.0](https://github.com/spring-projects/spring-boot/blob/main/LICENSE.txt) | 固定 Spring BOM；Security/Modulith 与所选 Boot 版本匹配，各依赖单独登记 |
| Keycloak | [Apache-2.0](https://github.com/keycloak/keycloak/blob/main/LICENSE.txt) | OIDC 为适配边界；插件、主题与数据库支持独立验证 |
| Flutter | [BSD 许可文本](https://github.com/flutter/flutter/blob/master/LICENSE) | Flutter/Dart 工具链锁定；pub 包、字体、图标、原生 SDK 各自登记 |
| Kafka / Artemis | [Kafka LICENSE](https://github.com/apache/kafka/blob/trunk/LICENSE)、[Artemis LICENSE](https://github.com/apache/artemis/blob/main/LICENSE) 的 Apache-2.0 | 客户端、插件和镜像也需清单；事件/命令通道由 adapter 隔离 |
| OpenTelemetry Java | [Apache-2.0](https://github.com/open-telemetry/opentelemetry-java/blob/main/LICENSE) | Collector 发行包与观测后端分别登记，不能以 OTel 许可覆盖 Grafana/Loki 等产品 |
| MySQL | [社区/商业交付规则](https://www.mysql.com/about/legal/licensing/oem/) | 社区 GPL 与商业许可按实际组合复核；服务端、Connector/J、容器再分发分别评估，不直接推定闭源打包无需处理 |
| OceanBase | [官方源码仓库](https://github.com/oceanbase/oceanbase)、[社区版本说明](https://www.oceanbase.com/docs/community-observer-cn-10000000000014828) | 不同发布资料可能涉及不同许可声明，以选定 tag/edition 为准；数据库、ODP、OCP、迁移/备份工具分别登记 |
| Redis | [官方版本许可矩阵](https://redis.io/legal/licenses/) | 7.2 及以前、7.4 与 8+ 许可不同；不能统一登记 BSD。托管服务和私有镜像交付分别确认所选许可/合同 |
| 缓存替代候选 Valkey | [BSD-3-Clause](https://github.com/valkey-io/valkey/blob/unstable/COPYING) | 若更适合采购/交付，可经命令、Lua、客户端、集群和故障回归后替换；不假设所有 Redis 扩展兼容 |
| EMM/OEM/支付/分类/模型 SDK | 供应商契约与实际 SDK/模型制品许可 | 分别登记调用资格、配额、数据处理、停服/替换方案；免费 SDK 不代表模型权重/分类数据可自由商用 |

ComponentRecord 至少记录 name、version、edition、来源、sha256、SPDX 许可标识或原文引用、传递依赖、使用方式、再分发方式、CVE/修复版本、维护期限、支持合同、责任人、复核日期和替代接口。CI 生成 CycloneDX/SPDX 清单、许可证 NOTICE 与漏洞报告；不为规避许可长期冻结在停止安全维护的旧版本。未确定版本的组件只列为设计候选，不冒充已完成兼容认证。

## 7. API、消息与数据契约

### 7.1 REST API 基线

统一前缀为 /api/v1；OpenAPI 3.1；JSON/UTF-8；时间字段采用 UTC 时间戳，计划额外携带 IANA 时区。分页使用游标；写操作接受幂等键；错误响应包含稳定 errorCode、字段错误、correlationId 和可本地化 messageKey。长任务返回 202 和 operationId。

| 资源 | 路由示例 | 说明 |
|---|---|---|
| 家庭/机构 | GET/POST /tenants，GET/PATCH /tenants/{id} | 创建/查看租户资料 |
| 成员/角色 | /tenants/{id}/members、/members/{id}/roles | 邀请、撤销、范围授权 |
| 儿童/学生 | /subjects、/subjects/{id}/guardians | 只保存必要资料 |
| 注册/退出 | POST /enrollments、GET /enrollments/{id}、POST /devices/{id}/deprovision、POST /devices/{id}/revoke | 短期注册、正常退出与紧急撤销分开 |
| 设备 | GET /devices、GET /devices/{id}、GET /devices/{id}/capabilities | 型号、能力、在线和同步状态 |
| 应用目录 | GET /apps、GET /devices/{id}/apps | 设备/平台允许时查询并记录来源 |
| 策略 | POST/GET /policies、POST /policies/{id}/validate、POST /policies/{id}/publish | 草稿、预览、发布不可变版本 |
| 例外申请 | POST /access-requests、POST /access-requests/{id}/decision | 限时批准/拒绝 |
| 命令/回执 | GET /commands/{id}、GET /devices/{id}/policy-status | 查询命令和设备执行状态 |
| 事件/报表 | GET /subjects/{id}/usage-summary、GET /safety-events、GET /audit-events | 范围鉴权、导出受控 |

服务端不能信任客户端传入的 tenantId、role 或设备所有权；必须从已验证 token 和数据库关系重新计算授权。高风险端点要求二次认证、限流和操作审计。

### 7.2 MQTT 消息基线

设备主题示例：v1/tenants/{tenantId}/devices/{deviceId}/commands、/receipts、/telemetry。Broker ACL 保证设备只能读取自身 commands、写入自身 receipts/telemetry；禁止通配订阅和跨租户主题访问。

TLS 下使用设备独立凭证，支持轮换和撤销。命令信封字段：messageId、tenantId、deviceId、commandType、policyVersion、issuedAt、expiresAt、idempotencyKey、schemaVersion、payload、signature。回执字段：messageId、commandId、deviceId、receivedAt、appliedAt、status、capabilityId、errorCode、retryable、agentVersion。

传输采用至少一次投递，设备端按幂等键执行；业务状态由回执收敛，不假设传输层 exactly-once。策略定期全量快照比对，用于修复丢失/过期增量。

### 7.3 Kafka 领域事件

事件字段包含 eventId、schemaVersion、tenantId、occurredAt、producer、correlationId、subject/device 引用及最小化 payload。首批事件：PolicyPublished、DeviceCommandIssued、PolicyReceiptRecorded、DeviceCapabilityChanged、AccessRequestCreated、TemporaryGrantExpired、SafetyEventRaised、MembershipRevoked。按租户范围分区并设置保留周期；敏感明细留在受控数据库。

## 8. 安全、隐私与智能识别治理

### 8.1 安全控制

- TLS 传输、静态加密、KMS/云密钥服务或客户自管密钥；Android Keystore/平台安全存储保护设备密钥。
- 管理员启用 MFA；策略放宽、角色变更、设备解绑、导出和删除需要重新认证并审计。
- 设备凭证可轮换/撤销；策略签名、防重放、版本和目标校验；设备使用最小权限。
- tenant context 贯穿 API、SQL、消息和日志；数据库隔离、服务端授权、负向自动化测试三层保护租户数据。
- SBOM、许可证/CVE 扫描、SAST、容器扫描、密钥扫描和构建制品签名纳入发布门禁。
- 审计日志采用独立写入权限及可选 WORM/追加式存储；审计读取本身也留痕。
- 错误日志不得包含 access token、原始视频、儿童聊天内容或与管控无关的位置轨迹。

### 8.2 AI/视觉能力

摄像头默认禁用。开启前说明识别对象、采集位置、保留方式、误判风险和关闭方法，儿童侧显示状态提示。仅允许有限安全辅助场景的本地识别；禁止身份、情绪、注意力、健康或能力推断。原始图像不离开设备、不落盘；设备不能本地处理则不提供此功能。

行为识别只使用平台许可且已告知的聚合指标，例如连续时长、深夜使用或异常访问尝试；不记录按键、私聊内容或无关位置。低置信结果只提示；高影响限制需管理员复核。模型来源/签名、版本、测试和回滚均可审计。

### 8.3 网络和内容过滤边界

- 优先受管浏览器策略；DNS 过滤可做域名级管控，通常无法读取 HTTPS 加密页面的路径或内容。
- 本地 VPN 必须明确展示网络路径和收集项，不抓取无关流量；不得承诺读到所有应用内媒体。
- 视频平台优先组合平台评级/家长设置、应用白名单、应用级时长限制；无法细分内容时明确提示只能限制整个 App。
- 电视无 Agent 时，路由器/DNS 只能覆盖已知域名和通过网关的流量，不能阻止蜂窝网络、VPN 或其他旁路。

### 8.4 数据类别与默认处理

| 类别 | 示例 | 默认处理 |
|---|---|---|
| 身份与授权 | 登录标识、角色、监护关系 | 只保存必要字段，支持撤销/删除流程 |
| 设备治理 | OS/型号、策略版本、执行结果、心跳 | 按服务目的保留，可配置期限 |
| 使用摘要 | 按应用/日聚合时长 | 聚合优先、短期保留、本人/监护人可查看 |
| 安全事件 | 策略失败、风险类别、异常离线 | 最小化保存，访问范围受限 |
| 原始视觉/音频 | 相机/麦克风 | 默认不采集、不上传、不保存 |
| 管理审计 | 登录、角色变更、策略发布、审批 | 单独授权，按地区设定保留期 |

保留期限、删除处理和未成年人法律依据需法务按目标市场复核；本设计不宣称自动满足所有地区法规。

## 9. 部署、容量和运维

### 9.1 SaaS 与私有化

**SaaS**：按主权/区域分开部署 API、数据库、MQTT、Kafka、缓存和密钥域；租户设 homeRegion。区域间只复制获准的最小化运营指标，不跨区复制儿童活动明细。

**私有化**：同一 OCI 镜像和 Helm Chart；客户提供 Kubernetes、经认证的 MySQL 8.4 LTS 或 OceanBase MySQL profile、对象存储、OIDC、邮件和所选消息服务。Keycloak 使用其官方支持的独立数据库，不因业务库采用 OceanBase 自动切换。交付安装、升级、回滚、备份恢复、离线镜像及许可证清单。air-gapped 部署须列出仍依赖公网的 EMM、商店、推送和分类服务；无替代通道时不得承诺同等设备能力。

Dev/Test/Staging/Prod 隔离；配置版本化，密钥放在 Vault/KMS/客户 Secret。数据库迁移遵循兼容扩展、数据迁移、验证、清理旧字段的分阶段方式。外部 EMM API 加配额监控、熔断、重试和人工降级。

### 9.2 容量和可靠性

- 容量基线为 **100 万注册设备**。峰值在线比例、遥测间隔、策略广播比例写成压测工作负载参数；注册数不能代替并发连接数。
- 心跳加入随机抖动；策略发布按组批处理并限速；全量快照与增量并用。
- MQTT 压测并发连接、消息率、QoS/持久订阅和重连风暴；Kafka 压测事件吞吐/保留；API 压测登录、筛选、批量操作和报表导出；MySQL/OceanBase 分别验证索引、分区、关联查询、故障切换及冷热归档。
- API 服务、事件消费者和报表任务水平扩缩；配置连接池、背压、退避+jitter、死信队列和受控重放。
- 本地策略不依赖云在线；恢复后比较版本并幂等对账。

### 9.3 初始 SLO（上线前以压测确认）

| 指标 | 初始目标 |
|---|---|
| 管理 API 月可用性 | 99.9%，不含计划维护和客户自有基础设施故障 |
| 在线设备策略回执 | 95% 在 60 秒内；99% 在 5 分钟内 |
| 本地拦截/提醒 | 使用本地有效策略时不依赖 API 往返 |
| 在线设备撤销收敛 | 5 分钟内；离线设备标示待处理风险 |
| 跨租户负向测试 | 零数据泄露 |
| 命令链路追踪 | 操作→投递→执行→回执具有 correlationId 和审计 |

这些是上线目标，不是既有性能承诺；压测报告必须声明硬件、连接数、设备/厂商分布和工作负载。

### 9.4 可观测性和运维

统一结构化日志 JSON、trace/span/correlation ID；OpenTelemetry 输出 traces/metrics/logs。关注 API p95/p99、认证失败、在线设备、MQTT 重连、策略回执延迟/失败原因、Kafka lag、数据库慢查询、证书到期和客户端崩溃/耗电。每类告警有等级、runbook 和责任人。客户端/策略 schema 支持兼容旧 Agent；灰度、停发、回滚、重放和恢复策略均可操作。诊断包需管理员显式提交，且默认脱敏。

## 10. 测试与验收

### 10.1 功能验收用例

1. 未认证无法访问管理 API；儿童创建/修改/发布策略被服务端拒绝并留审计。
2. 家庭 A 不能枚举、读取、改动家庭 B 的成员、设备、策略、事件或导出任务。
3. 受管 Android 策略返回设备实际执行结果；不兼容设备明确报告不支持。
4. BYOD 不支持的系统级能力显示 PARTIAL/UNSUPPORTED，不显示“已保护”。
5. 用量额度在重启、跨时区和 DST 切换后遵循策略时区；离线执行最后有效策略。
6. 临时访问由有效管理员批准，绑定目标和到期时间；离线不延长；重复审批幂等。
7. 重复、过期、乱序、签名错误或针对其他设备的命令不执行；坏策略不覆盖当前有效策略。
8. 撤销设备/用户凭证后服务端拒绝新操作；离线设备标示待处理并在联网后处理。
9. 撤回摄像头授权后识别停止；原始媒体不上云/不持久化；低置信度不直接产生高影响限制。
10. TV 遥控器可完成规则查看、允许应用选择、申请家长审批和恢复。
11. 导出、删除/撤回和备份恢复按租户/地区策略执行并有审计。
12. 策略发布到 Agent 回执可关联追踪，日志无 token/原始内容泄露。

### 10.2 自动化验证层级

- 单元：策略优先级、权限评估、日程边界、临时例外、能力映射、脱敏。
- 模块：Spring Modulith 边界、事件、事务和失败重试。
- 契约：OpenAPI、MQTT schema 和旧版 Agent 回执兼容。
- 集成：Testcontainers 验证 MySQL/Kafka/Artemis、outbox、幂等、死信、断线重连；OceanBase profile 使用目标版本的真实测试环境执行兼容回归。
- 安全：RBAC/ABAC 越权、租户隔离、重放、凭证撤销、注入、依赖和镜像扫描。
- 端到端：Android 家庭 BYOD、全受管、工作资料、TV 厂商矩阵；真机与模拟器结果分开。
- 性能/韧性：容量模型压测、Broker 节点故障、Kafka lag、数据库切换、区域隔离和恢复。

### 10.3 发布门槛

- Android Management API 商业资格、配额和用途获书面确认；否则机构受管模式采用签约 EMM 连接器。
- 每个支持设备模式经过真机验证；无支持的规则有明确 UI 状态。
- 隐私/安全审查、租户隔离、设备撤销、数据删除及“视觉媒体不上传”验收通过。
- 百万注册设备的工作负载模型、在线峰值假设、容量压测和恢复演练完成。
- 管理台区分已创建/下发/接收/应用/不支持/失败/离线。
- 私有化从空环境可安装、升级、回滚、备份和恢复。

## 11. 分期路线图

### 阶段 0：准入和技术验证

检查现有仓库、技术栈、授权与部署方式；实测 Android 手机/平板/TV 型号和系统版本；确认家庭 BYOD 真实权限；确认 Android Management API EMM 资格/配额和 EMM 替代方案；验证 MQTT Broker 移动网络重连、TLS/ACL、集群和许可证；输出能力矩阵、隐私评估、容量工作负载和不可承诺能力清单。

### 阶段 1：家庭 Android 版本

实现 Flutter 家长/儿童端、家庭成员/角色、设备绑定、应用/网站规则、时长/时段、临时申请与审批；BYOD 按平台实际支持能力实现并显示限制；实现 Spring Boot 模块化单体、身份、审计、基础可观测性和真机回归。

### 阶段 2：机构受管 Android

资质通过后接入 Android Management API 或签约 EMM SDK；实现组织/设备组、批量注册与策略、应用目录、合规状态和执行回执；建设 MQTT/Kafka 横向扩展和百万设备负载验证。

### 阶段 3：Android TV 与私有化

认证指定 TV 型号/系统版本；实现遥控器体验、应用级控制、受管启动或 DNS/路由组合能力；交付 Helm、客户 OIDC、配置覆盖、升级回滚和支持清单。

### 阶段 4：其他平台与智能辅助

接入 Apple Family Controls/Managed Settings/Device Activity 与 Windows/macOS 管理能力。视觉/行为辅助在隐私评估、授权、设备性能和误报流程通过后以功能开关推出。只有容量或团队边界数据证明有必要时才拆微服务。

## 12. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| Android Management API 资格/配额与产品模式不符 | 机构强管控无法按官方服务上线 | 阶段 0 设门槛；签约 EMM fallback；家庭模式不借用受限 API |
| Android 厂商/TV 系统碎片化 | 某些策略不生效 | 认证名单、能力探测、真机矩阵和分级支持标签 |
| BYOD 用户强制停止/撤销权限 | 个人设备保护中断 | 显示部分控制；监测授权/心跳变化；引导受管模式 |
| DNS/VPN 绕过或换网络 | 网站过滤失效 | 仅对受管设备承诺强网络策略；告警并展示过滤盲区 |
| 规则冲突导致误封 | 紧急访问受阻 | 冲突预览、紧急白名单、策略回滚、双重确认 |
| 离线/重连风暴 | 策略延迟或服务抖动 | 本地有效策略、随机退避、批次发布、背压和幂等 |
| 全球未成年人隐私法律差异 | 上线受阻/违规 | 区域发布门禁、数据驻留和删除配置、法务审查 |
| AI 误报/隐私疑虑 | 错误限制、信任受损 | 默认关闭、本地推理、低影响提示、高影响人工确认 |

## 13. 仓库落地说明

本文件是产品/架构设计基线，不代表客户端或后端代码已经实现。进入后续工程实现前，检查现有仓库、AGENTS.md、当前技术栈与 docs 规范；如已存在模块或服务，可调整目录建议，但必须保留平台能力边界、授权原则、接口兼容、隐私要求和验收门槛。


## 14. 工程契约补充：生命周期、版本与策略执行

本节补齐实现团队必须一致遵循的状态、并发、失败恢复及客户端能力契约。所有状态均由服务端作为审计真相源；设备可在离线期间暂存回执，联网后按事件 ID 幂等补传。

### 14.1 设备注册生命周期

设备生命周期状态：

| 状态 | 含义 | 可执行操作 |
|---|---|---|
| CREATED | 注册意图已创建 | 展示二维码/短码，不应用任何规则 |
| TOKEN_ISSUED | 一次性令牌已签发 | 等待设备认领；可撤销/过期 |
| CLAIMED | 令牌被设备认领 | 校验租户、设备证明和目标主体 |
| AUTHORIZING | 等待家长/机构管理员和 OS 授权 | 显示待授权项目，可取消 |
| PROVISIONING | OS/EMM 正在完成注册和初始策略 | 仅显示进度，不显示为已受管 |
| ACTIVE | 已完成强制授权且首个必需策略生效 | 接受策略更新和受管命令 |
| LIMITED | 绑定成功但只能执行部分能力 | 仅执行支持项并持续展示能力边界 |
| SUSPENDED | 管理员/风险控制临时暂停 | 设备连接可保留，策略变更需管理员恢复 |
| UNENROLL_PENDING | 已停止业务访问，等待管理解除与清理证据 | 仅保留限时、限用途的清理/确认通道；禁止新业务策略 |
| UNENROLLED | 设备已解除管理 | 不再收集新管理事件 |
| REVOKED | 凭证和令牌立即失效 | 拒绝设备 API/MQTT 访问 |
| FAILED | 注册失败且保留稳定错误码 | 可重试或重新签发令牌 |

连接状态（ONLINE、DEGRADED、OFFLINE）和合规状态（COMPLIANT、NON_COMPLIANT、UNKNOWN）是独立字段，不要把“离线”当成“已解绑”。正常解绑先验证管理员、停止新业务操作、投递限时清理/供应商解除管理操作，确认后撤销剩余设备凭证与 ACL；清理通道不允许读取活动数据或执行新策略，超时后撤销并记录“未确认本地清理”。账号/设备失陷则立即撤销访问，不声称撤销后还能经同一凭证送达清理命令；必要时通过独立 EMM 通道或现场恢复完成。

**数据后果按平台模式展示**：普通伴随 App 的移除仅清理本产品资料；工作资料解除可能删除工作资料；全受管设备解除可能要求恢复出厂。AMAPI 的 devices.delete 会尝试擦除设备，离线过久时不保证成功，因此不能将它直接映射成“无损解绑”。任何会触发擦除的路径都要求独立操作权限、重新认证、二次确认及数据后果说明；不支持保留数据时应明确提示或阻止该路径。供应商返回 404 也不能单独证明擦除/本地清理完成。[AMAPI 删除设备语义](https://developers.google.com/android/management/reference/rest/v1/enterprises.devices/delete)

Android 受管设备进入 ACTIVE 前必须完成所需系统授权、受管注册、必要策略应用和首次回执。家庭 BYOD 不满足强策略时进入 LIMITED，不能以受管强控名义激活。

### 14.2 策略发布状态机与并发

策略版本状态为 DRAFT → VALIDATING → READY / VALIDATION_FAILED → PUBLISHING → ACTIVE / ACTIVE_PARTIAL / PUBLISH_FAILED → SUPERSEDED / ROLLED_BACK。

- 发布创建不可变版本；修改内容会产生新版本，不能覆盖旧版本审计。
- 用 ETag/版本号做乐观并发控制；过期编辑器提交时返回 409 POLICY_VERSION_CONFLICT 和当前版本，不能静默覆盖他人修改。
- VALIDATING 按目标设备能力矩阵做影响预览，区分支持数、不支持数、授权待完成数、离线数和可能导致锁定的规则。
- PUBLISHING 产生目标设备快照和唯一命令；按设备组分批，速率可配置，暂停/继续/取消均记录操作者。
- ACTIVE 表示发布目标快照中所有目标设备的必需规则已有可验证生效证据；有离线/未知/部分失败目标则不能汇总为全部生效。发布任务另存终态与截止时间，超时结束不意味着设备生效。逐设备保存 desiredPolicyVersion、receivedPolicyVersion、effectivePolicyVersion 和规则级证据/时间；ACTIVE_PARTIAL 展示各状态数量、统计分母和未生效原因。
- 回滚是新版本引用先前配置并重新发布，不删除失败或已生效历史。

### 14.3 权限/功能评估结果结构

服务端预览和设备回执共用语义一致的结果对象：

~~~json
{
  "capabilityId": "android.app.launch_control",
  "evaluationPhase": "OBSERVED",
  "ruleId": "rule-app-youtube-study-hours",
  "requestedEffect": "DENY",
  "effectiveEffect": "DENY",
  "status": "SUPPORTED_APPLIED",
  "scope": "FULL_DEVICE",
  "sourcePolicyVersion": 42,
  "devicePolicyVersion": 42,
  "reasonCode": "SCHEDULE_ACTIVE",
  "userMessageKey": "restriction.study_schedule",
  "lastEvaluatedAt": "2026-10-08T02:30:00Z",
  "nextTransitionAt": "2026-10-08T09:00:00Z",
  "limitations": []
}
~~~

上例为实际执行后的 OBSERVED 结果。预览使用 evaluationPhase=PREVIEW、predictedEffect，effectiveEffect/devicePolicyVersion 为空，支持项 status=SUPPORTED_PENDING；不得把预测结果标成 SUPPORTED_APPLIED。拒绝访问的责任链解释目标应用/域名、命中规则、策略来源、当前日程、设备能力和下次状态变化。孩子端不返回管理员邮箱、内部组织名等非必要身份数据。

### 14.4 策略 JSON 契约示例

~~~json
{
  "schemaVersion": 1,
  "policyId": "pol_01J...",
  "policyStreamId": "stream_device_01J...",
  "policyVersion": 42,
  "tenantId": "ten_01J...",
  "deliveryAudience": {
    "deviceId": "dev_01J...",
    "registrationId": "reg_01J...",
    "targetSnapshotId": "snapshot_01J..."
  },
  "name": "学习专注",
  "timeZone": "Asia/Shanghai",
  "target": {
    "kind": "DEVICE_GROUP",
    "id": "grp_school_class_a"
  },
  "rules": [
    {
      "ruleId": "rule_app_001",
      "type": "APP_LAUNCH",
      "target": {
        "platform": "ANDROID",
        "packageName": "com.example.video",
        "signerSha256": "base64-or-hex-fingerprint"
      },
      "effect": "DENY",
      "schedule": {
        "daysOfWeek": ["MON", "TUE", "WED", "THU", "FRI"],
        "startLocalTime": "08:00",
        "endLocalTime": "17:00",
        "timeZone": "Asia/Shanghai"
      },
      "required": true,
      "reasonKey": "restriction.study_schedule"
    }
  ],
  "issuedAt": "2026-10-08T02:00:00Z",
  "deliveryExpiresAt": "2026-10-09T02:00:00Z",
  "effectiveFrom": "2026-10-08T02:00:00Z",
  "effectiveUntil": null,
  "offlineFallbackPolicyVersion": 41,
  "signingKeyId": "policy-key-2026-10"
}
~~~

契约要求：

- schemaVersion 用于选择明确支持的契约；policyVersion 在同一策略流中单调增加，重新注册用新的流标识。未知必需 schema/规则拒绝并报告兼容错误，未知可选字段可忽略。
- 组策略先解析发布目标快照，再生成绑定具体 deviceId/registrationId 的投递载荷；组 ID 仅表达配置来源，不能凭组名接受给另一设备或旧注册周期的策略。
- 上例是签名载荷，实际传输封装为标准 JWS，使用成熟 JOSE 库。protected header 校验 alg/kid，禁用不受信任算法；签名覆盖载荷字节、租户、目标、流标识、版本及时间。密钥轮换、离线信任窗口与紧急撤销单独定义，不自行拼接 JSON 字段实现签名协议。
- deliveryExpiresAt 只限制首次接收/命令投递；已验证的持久基础策略不会因投递窗口过期而解除。effectiveUntil=null 表示基础策略持续有效；限时策略和临时通行必须有明确到期与预先验证的离线回退。MQTT 命令 expiresAt、业务规则期限、凭证期限分别建模。
- required=true 且设备不支持时不得把新版本标为 ACTIVE；保留旧有效版本并报告发布失败/待人工处理。
- required=false 的可选规则可部分应用，但每项返回执行结果；UI 必须显示 ACTIVE_PARTIAL。
- 设备拒绝策略时保留上一份已验证基础配置，但系统 API 可能已经部分写入，不能宣称原子回滚。adapter 逐项记录实际状态、补偿结果与失败原因；恢复未确认时标记 DEGRADED/UNKNOWN，保留紧急路径并告警。

### 14.5 REST 读写语义

- 创建/变更策略使用 Idempotency-Key；相同租户、操作者、键和请求体返回相同资源结果。相同键但不同请求体返回 409。
- 条件更新使用 If-Match/ETag；资源不存在、版本冲突、授权不足和平台能力不支持分别使用不同稳定错误码。
- 用户移除先撤销身份会话/授权；设备正常退出以 POST /devices/{id}/deprovision 创建异步任务，紧急失陷以 POST /devices/{id}/revoke 立即撤销。DELETE /devices/{id} 只处理已退出设备的平台注册记录，不直接调用供应商擦除接口。法定数据删除另走可审计后台作业。
- 列表 API 必须进行租户范围约束后再分页，不能先全库分页再在客户端过滤。
- 批量策略操作返回 operationId 与逐设备状态；不以单个 HTTP 200 表示所有设备成功。
- 所有审核/策略发布接口记载操作者、重认证方式、请求 ID、前后版本哈希和结果。

## 15. Android 实施细节与设备行为

### 15.1 Android 能力分层

| 能力 | 普通家庭 App | 工作资料/受管资料 | 全受管/专用设备 |
|---|---|---|---|
| 自身应用的家长界面 | 支持 | 支持 | 支持 |
| 第三方应用使用摘要 | 用户授予使用情况访问后按系统可见范围获取 | 受管理资料范围；需核验数据接口 | 受管报告/许可的本地统计；不等于实时前台检测 |
| 列举全部安装应用 | 受 Android package visibility 和商店政策限制 | 资料范围 | EMM/设备管理 API 按许可获取 |
| 禁用任意第三方应用 | 不作为通用可靠承诺 | 资料内管理能力有限 | 由允许的设备管理 API 支持时可用 |
| 改写其他 App 的所有权限 | 不支持通用静默控制 | 仅公开的资料策略范围 | 由管理 API 和 Android 版本支持时可配置 |
| 跨 App 启动限制 | 仅在平台允许且可绕过条件下提示/限制 | 工作资料范围 | 受管策略、包暂停或锁定任务能力 |
| 阻止卸载/退出 | 不承诺 | 不承诺超出系统范围的控制 | 设备所有者/专用设备策略可增强，需按 OEM 验证 |
| 网站/域名过滤 | 明确用户授权的本地 VPN/DNS，存在旁路 | 受管浏览器/网络范围 | 网络策略、受管浏览器和 OEM 集成组合 |
| 重启后恢复 | 普通进程无法保证自动常驻 | 按系统资料策略 | 系统受管策略持久化；Agent 启动后对账 |
| 远程重启 | 不支持 | 通常不支持 | 仅在系统管理 API 明确支持时可用 |

个人设备不能依赖 AccessibilityService 模拟阻止其他应用作为主要控制机制；不能以隐藏通知或持续启动服务来伪造不可退出。运行时权限显示成“可建议、需用户确认”或“不支持”，只有系统受管 API 明确授权时才显示为管理员可执行。

### 15.2 Android Agent 模块

- **Provisioning Adapter**：受管 QR/令牌流程、使用模式识别、注册证明和权限状态。
- **Management Connector（服务端）**：封装 Android Management API/合作 EMM 的 REST 调用与事件通知；令牌只驻留服务端，不属于 Agent 模块。
- **Capability Probe**：检测系统版本、应用包、管理模式和 API 支持，不尝试规避限制。
- **Policy Compiler**：将平台无关规则编译成可执行策略并列出损失项。
- **Local Policy Store**：使用系统安全存储保存签名策略和最近有效版本；支持原子写入、回滚和 schema 迁移。
- **Policy Executor**：仅调用授予本应用的 Android 本地接口，记录逐规则结果。EMM 管理的系统策略交给供应商 DPC，读取供应商证据对账；禁止在无权限时假报成功。
- **Connection & Receipt Queue**：MQTT/HTTPS 断线缓存、退避、幂等回执和重连 jitter。
- **Health Monitor**：上报 App 版本、电量开销、同步、授权变化和最近错误；只上传必要诊断数据。
- **Child UX**：展示拦截理由、下次开放时间、申请入口和求助入口。

跨 Flutter/Kotlin 的方法通道优先使用 Pigeon 生成类型化接口；平台业务 API 在 Dart 侧只暴露能力接口（例如 CapabilityProvider/PolicyStatusRepository），不向 UI 泄漏 MethodChannel 字符串和厂商 SDK 对象。

### 15.3 重启、强制停止和恢复

- 强制停止/用户撤销授权后，服务端心跳超时只能标记 DEGRADED/UNKNOWN，并通知管理员；不能声称设备仍被强制保护。
- 受管专用设备依赖系统层设备策略/锁定任务保障主路径；启动 Agent 后读取当前系统策略并与服务端版本对账。
- 普通 BYOD 的 App 进程被系统结束或用户强制停止时，不保证后台自恢复；下一次打开应用时提示授权/同步状态变化。
- 重启后本地有效策略不得依赖先联网才能加载；系统受管模式按正式 API 执行持久限制。开机接收器只处理获准工作，不用于规避系统生命周期限制。
- 故障恢复需保留紧急拨号/管理员恢复路径；管理员错误策略支持回滚；修复操作本身记审计。
- 管理员解除设备管理应有清晰告知；不通过隐藏/禁用系统设置冒充不可移除保护。

## 16. 故障处理矩阵

| 故障 | 设备行为 | 服务端/管理端行为 | 恢复要求 |
|---|---|---|---|
| 管理 API 暂时不可用 | 本地执行有效策略；暂存回执 | API 显示服务故障，不创建假回执 | 指数退避+jitter；恢复后对账 |
| MQTT 中断 | 本地策略继续；回执入持久队列 | 命令保留到期时间，显示投递待处理 | 重连后只发送未过期命令 |
| Kafka 消费停滞 | 不影响设备本地执行 | 监控 lag，暂停非关键批任务 | 重放必须幂等并控制速率 |
| 数据库主库切换 | Agent 不依赖数据库往返 | API 短暂可读或返回可重试错误 | 故障转移和连接池恢复演练 |
| 策略签名/结构错误 | 拒绝新策略，保留旧策略 | 记录稳定错误码、设备版本和命令 ID | 修复服务端策略并生成新版本 |
| 必需能力不支持 | 不激活新必需策略 | 标示发布阻塞/不支持设备清单 | 管理员变更目标/策略或重注册 |
| 可选规则不支持 | 其余支持项执行 | 状态 ACTIVE_PARTIAL，逐规则列原因 | 管理员接受部分生效或调整策略 |
| 设备时钟漂移 | 使用单调计时和最后可信时间 | 上报告警；不提前延长限时授权 | 安全校时后重新评估并留审计 |
| 管理授权被撤回 | 停止声称受管；保留合规恢复 UI | 设备状态 DEGRADED，告知管理员 | 重新授权/注册或解除绑定 |
| 强制停止/卸载 | 不承诺后台自恢复 | 心跳超时并记录可能失联 | 管理端提示最后在线时间/保护风险 |
| 厂商策略 API 不一致 | 能力探测返回部分/失败 | 型号进入不支持/待认证队列 | 发布兼容性更新前做真机验证 |
| 注册令牌泄漏/过期 | 拒绝重复或已失效 token | 令牌立即撤销，审计来源 | 管理员重新生成短时单次令牌 |

## 17. 可观测性字段与审计事件

### 17.1 统一日志字段

所有服务端日志至少包含 timestamp、severity、serviceName、serviceVersion、environment、tenantId（必要时哈希/内部 ID）、actorType、correlationId、traceId、operation、resourceType、result、errorCode、latencyMs。日志不包含 token、密码、完整 URL 查询、原始媒体或私聊内容。

设备诊断事件至少包含 deviceId、agentVersion、platformVersion、managementMode、policyVersion、eventType、capabilityId、errorCode、occurredAt、queuedAt、receivedAt 和 correlationId。字段采集按用途白名单，防止平台 Agent 无意上传不相关个人信息。

### 17.2 必须产生审计的操作

用户登录/MFA 变化、邀请/加入/移除、角色和授权范围变化、设备注册/重注册/解绑、策略创建/预览/发布/回滚、访问申请批准/拒绝、数据导出/删除、管理员支持访问、密钥/证书轮换、配置/模型版本变化。

审计保存行为追加式，支持按租户/时间/操作者/设备/策略版本筛选；导出生成限时文件并记录下载人和时间。

## 18. 数据库与迁移约定

- 使用 MySQL 8.4 LTS + InnoDB 保存事务性租户、成员、设备、策略、审批和命令 outbox 状态；所有租户数据表 tenant_id 必填并按真实访问条件建立组合索引。OceanBase MySQL 模式不是只改 JDBC URL 的无条件替代品，必须通过单独的数据库 profile、兼容性回归和运维验收。
- 高频事件按时间范围分区或归档；核心策略/成员/设备不能仅存在缓存或 Kafka 中。
- Redis 只缓存可重建数据；缓存故障回源数据库并限流。策略签名后的设备快照保留在策略表或版本存储，不以缓存作为唯一副本。
- Flyway 迁移遵循 expand → backfill → verify → contract；发布前检查锁时长和回滚策略，避免大型表同步锁表。
- 所有时间字段区分 instant 与本地计划时间；数据库存 UTC instant 和 IANA timezone，禁止以服务器本地时区解释规则。
- 软删除适用于业务恢复期；法定删除通过可审计清理作业对数据库、事件副本、搜索索引、备份保留和对象存储制定明确处理规则。

## 19. 详细阶段出口标准

| 阶段 | 必需产物 | 通过条件 |
|---|---|---|
| 0 准入验证 | API 资格/EMM 合同结论、设备矩阵、威胁/隐私评估、容量工作负载 | 强管控执行路径和合规替代路径确定；关键型号功能有真机证据 |
| 1 家庭 Android | 家庭/成员/设备/策略 API，家长与儿童 Flutter 流程，审计和能力说明 | 核心家庭旅程可端到端完成；BYOD 限制在 UI 明示；权限越权为零 |
| 2 机构受管 Android | EMM connector、批量注册、设备组、执行回执、合规报表 | 受管策略真机执行通过；API 限流/配额和撤销流程验证 |
| 3 TV/私有化 | 支持型号名单、遥控器 UI、Helm、运维文档 | 目标 TV 型号逐项验收；私有环境可安装、升级和恢复 |
| 4 跨平台/AI | 平台 adapter、授权说明、AI 评估和回滚 | 各平台分别证明 API 权限；AI 隐私与误报门槛达标 |

所有阶段都需要产品负责人、平台工程负责人、安全/隐私负责人和运维负责人签收对应出口条件。


## 20. 数据库选型决策：MySQL 与 OceanBase

### 20.1 决策结论

将原 PostgreSQL 基线调整为 **MySQL 兼容 SQL 作为主线**，回应 MySQL/OceanBase 的部署选型需求；团队经验与真实查询负载仍需验证，不能仅凭数据库名称推定开发效率或关联查询性能。首期默认采用 **MySQL 8.4 LTS + InnoDB**，固定经过验证的维护版本。InnoDB 提供 ACID 事务、行级锁和崩溃恢复；具体 RPO/RTO 由部署拓扑、日志刷盘配置、存储和备份演练共同保证。[MySQL LTS 发布模型](https://dev.mysql.com/doc/refman/8.4/en/installing.html)、[InnoDB ACID 模型](https://dev.mysql.com/doc/refman/8.4/en/mysql-acid.html)、[InnoDB 事务模型](https://dev.mysql.com/doc/refman/8.4/en/innodb-transaction-model.html)

**OceanBase 作为 MySQL 模式的可选分布式部署目标，不与 MySQL 画等号。** 若明确需要数据库原生横向扩展、多租户资源隔离和跨节点/多 Zone 高可用，且已有 OceanBase 运维/DBA 能力，可通过容量 PoC 后将它作为特定区域或客户私有化部署的主数据库。MySQL 语法兼容降低迁移成本，但不能代替应用、SQL、DDL、备份恢复、监控和执行计划的兼容测试。OceanBase 的 MySQL 模式与原生 MySQL 在系统视图、功能、分区、优化器和存储引擎等方面有差异；需针对选定版本验证，不能只替换 JDBC URL。[OceanBase MySQL 兼容性](https://www.oceanbase.com/docs/common-oceanbase-database-cn-1000000005283144)、[OceanBase MySQL 模式兼容差异](https://en.oceanbase.com/docs/common-oceanbase-database-10000000000829643)

### 20.2 选择比较

| 维度 | MySQL 8.4 LTS + InnoDB | OceanBase MySQL 模式 | 本产品判断 |
|---|---|---|---|
| MySQL 语法/工具兼容 | 原生 MySQL 语法与生态 | 面向 MySQL 兼容，但仍有版本/功能差异 | 以 MySQL 方言开发；OceanBase 必须独立验证 |
| OLTP 事务 | 成熟 InnoDB ACID、行级锁，单集群事务边界清楚 | 分布式事务与多节点协调能力更强，资源与拓扑需专业治理 | 先保证家庭/设备/策略聚合事务短小；避免无必要跨租户事务 |
| 大表与关联查询 | 依靠索引、读副本、分区、归档；可通过专用分析流水线卸载重报表 | 可跨节点分布数据与查询，但数据分布/分区键不匹配会增加远程访问和协调成本 | 用真实租户/设备/日期分布做代表性 SQL PoC，不以空表或单表压测替代 |
| 横向扩展 | 通常通过读副本、分区和应用层分片；需要时另做迁移/分片工程 | Shared-nothing 分布式架构，节点、Zone、租户资源可分布管理 | 只有容量、HA 或客户隔离要求证明确有收益时启用 |
| 可用性/多区域 | 需明确选定云厂商托管服务或 MySQL HA 拓扑、复制语义和切换流程 | 原生支持多 Zone 等分布式部署选项，但拓扑与网络延迟设计更复杂 | 按数据驻留区域部署独立数据库域；不建跨洲同步写的单一全球事务库 |
| 运维与私有化 | 人才/工具面广，部署形态成熟，需自行选 HA、备份和升级方案 | 需熟悉 OB 集群、租户、资源池、Zone 和兼容视图；企业/社区部署能力需区分 | 私有化交付前必须提供版本矩阵、硬件 sizing、备份恢复和升级手册 |
| 许可证/商业支持 | MySQL 社区/商业发行版及托管服务条款需按交付方式核查 | 社区版、企业版和云服务功能/支持范围不同，逐项核验许可证 | 组件清单明确发行版、许可、支持承诺和可替代方案 |

OceanBase 官方资料描述其为 shared-nothing 分布式集群，并以 tenant/resource unit 提供资源隔离；这对大规模多租户集群有吸引力，但会引入数据库专门运维和 SQL 兼容验证工作。[OceanBase 系统架构](https://en.oceanbase.com/docs/common-oceanbase-database-10000000003450039)、[OceanBase 多租户与资源单元](https://en.oceanbase.com/docs/common-oceanbase-database-10000000001971107)

### 20.3 为什么 100 万注册设备不自动等于需要 OceanBase

注册设备数不等于同时连接数，更不等于数据库事务 QPS。高连接主要由 MQTT Broker 承担；高频状态和遥测先经过 Kafka/异步消费，数据库保存策略、设备、授权、命令状态和必要的聚合用量。不要让 Agent 每次心跳都同步更新多张核心表，也不要将高频原始遥测无限写入事务库。

首期用 MySQL 高可用主库承载核心 OLTP，加只读副本承载允许陈旧的报表读；事务读写场景维持主库一致性。热点租户、策略发布和批量设备更新经队列限速。压测指标显示主库写入、日志 I/O、复制延迟、连接数或恢复时间超过目标后，再评估 OceanBase 或按领域拆分数据服务。

OceanBase 优先适用条件：

- 单区域/私有化业务经压测证明，单主 MySQL + 读副本 + 归档仍达不到写吞吐、数据规模、故障恢复或维护窗口目标。
- 要求通过添加节点扩展写入/存储，且运维团队有 OceanBase SRE/DBA、监控、备份和升级能力。
- 多 Zone 容灾、SaaS 租户资源治理或客户私有化能力带来的收益大于分布式事务/查询和培训成本。
- 目标版本和 edition 对项目使用的 DDL、事务隔离、索引、JSON 函数、分区、驱动、备份恢复及 ORM 行为已通过兼容认证。
- 完成同负载下 MySQL/OceanBase 的容量、延迟、故障切换、恢复和成本对比；不能只使用厂商基准数字。

### 20.4 大表、分区和跨租户查询设计

- **先分类再存储**：核心 OLTP 表（租户、成员、设备、策略版本、审批、命令状态）使用 InnoDB；高频原始事件进入 Kafka/分析存储；数据库保留需要业务一致性的事件索引和日/周聚合。
- **按访问条件设计复合索引**：租户内常见访问先约束 tenant_id，然后使用 subject_id/device_id、状态、创建时间或策略版本；按 EXPLAIN 和生产 query digest 调整，不为所有列铺大量索引。
- **大表分区以时间/生命周期为导向**：仅对确认需要时间裁剪、分区归档的高流量表使用日期分区；所有查询需包含分区键并通过执行计划确认 pruning。分区方案必须与分片键、备份恢复和删除政策一起设计。
- **MySQL/InnoDB 分区约束**：MySQL 8.4 的 InnoDB 分区表与外键不兼容，因此核心实体表保留外键和事务边界；大流量分区事实表不设置数据库外键，通过应用层批量校验、租户约束和孤儿记录巡检保证关联完整性。[MySQL 分区与 InnoDB 限制](https://dev.mysql.com/doc/refman/8.4/en/partitioning-limitations-storage-engines.html)
- **大表 JOIN**：JOIN 必须按租户键和高选择性键连接，避免跨租户全表 JOIN；给计划列表、设备执行态、使用汇总分别设计查询模型。大型聚合/长时间范围报表走异步任务和分析存储，避免阻塞策略写事务。
- **OceanBase 数据放置**：按 tenant_id 或业务聚合键评估分区/副本放置，尽量让家庭/机构内事务与常用 JOIN 数据共置；只有分布/计划数据证明收益时才使用数据库特有 hint。对跨分区事务、跨 Zone 写延迟、大范围聚合和重新平衡做真负载测试。
- **冷热和删除**：按保留期限归档/删除旧遥测分区；核心审计数据按地区策略保存。分区 DROP/EXCHANGE 或 OceanBase 对应 DDL 操作应在 staging 评估锁影响、回滚和备份兼容。

### 20.5 事务边界和并发控制

- 事务围绕单一领域聚合边界：同一租户/设备/策略的必要变更在一个短事务内完成；禁止在事务中等待 MQTT、HTTP、Kafka 或 EMM API。
- 策略发布与消息投递使用 **Transactional Outbox**：在 MySQL 同一事务写策略版本和 outbox 记录，提交后异步发布；消费端幂等。避免数据库与 Kafka/MQTT 双写产生“状态已提交但设备命令丢失”。
- 额度、临时授权、设备命令状态用唯一约束、条件更新/版本列和幂等键防止重复；热点计数不以高争用单行作为无限 QPS 计数器。
- 默认采用清晰的事务隔离级别，不全局提高到最强隔离；依靠唯一键、版本检查和必要的行锁实现业务不变量，结合并发测试验证。
- 事务内不得调用外部推理或长查询；写请求限定批量大小、超时和重试类型。只对可安全幂等的死锁/瞬时错误做带退避的短重试。
- 用短事务更新 PolicyVersion 与 DeviceCommand/outbox；设备应用结果是异步状态，不把设备回执纳入数据库分布式事务。

### 20.6 MySQL 基线配置与 HA 验收

生产由托管 MySQL 或经过运维认证的 HA 部署提供数据库服务。应用不自行实现主从选举。至少定义：

- 事务持久性参数、binlog 与备份策略由 DBA 按 RPO/RTO 批准并在故障演练中验证；不以默认值推定没有数据丢失。
- 主库故障后连接重建、读写切换、重复提交和 outbox 重放均能恢复；事务客户端重试前必须确认是否幂等。
- 只读副本允许的延迟阈值和读一致性要求；策略发布/权限校验/设备最新状态不从可能滞后的副本读取。
- 在线逻辑备份/物理备份、binlog PITR、跨区域备份、定期恢复演练和备份加密；私有化客户需提供经验证的存储与恢复说明。
- DDL 在线变更使用 expand/backfill/verify/contract；大型表迁移先测复制延迟、锁时间、磁盘空间和回滚方式。
- 参数基线、连接池上限、慢查询门槛、死锁/锁等待告警、磁盘/日志增长、复制延迟和备份失败均有 runbook。

### 20.7 OceanBase 资格 PoC 清单

在选作首期或某区域默认数据库前，用真实结构和脱敏规模数据执行：

1. 验证 MySQL Connector/J、Spring 事务、Flyway、MyBatis/ORM、生成键、批量写和时间/JSON 映射。
2. 对所有 DDL、索引、唯一键、外键、分区语法、JSON 函数、锁语句和迁移脚本运行兼容测试。
3. 回放租户 dashboard、设备组策略批发、策略发布、设备状态 JOIN、使用摘要等最重的 10–20 条 SQL，记录计划、P95/P99、CPU/IO、跨节点请求和缓存命中。
4. 测试热点租户与跨分区事务、批量策略发布、实时写与报表混跑、租户资源限额。
5. 演练节点/Zone 故障、主副本切换、扩缩容/数据重平衡、升级、全量与增量备份及 PITR。
6. 验证监控视图、慢查询/执行计划、日志、SQL 诊断、备份校验和客户值班手册在目标 edition 可用。
7. 用同一硬件/云预算和 SLA 目标对比 MySQL 与 OceanBase 总成本、DBA 工作量、版本升级和故障恢复时间。
8. PoC 未通过任何必须功能/恢复项时，不把“语法兼容”当作上线豁免；修复 SQL/映射或维持 MySQL 基线。

## 21. 数据库兼容性与迁移策略

- 业务 SQL 以 MySQL 8.4 LTS 支持的公共子集为主；把数据库特有 SQL 收口到 adapter/repository 层，提供单测覆盖。
- 禁止依赖 MySQL/OceanBase 系统视图做业务功能；诊断模块使用可替换的 vendor adapter。
- Flyway 维护独立 profile：mysql、oceanbase-mysql；公共迁移尽量共用，差异脚本经过明确 review，禁止运行时自动猜方言。
- 每次依赖、驱动、数据库版本或 edition 升级，执行 DDL 套件、查询黄金集、事务并发、数据导入导出、备份恢复和回滚测试。
- 用脱敏的代表数据校验逻辑结果一致，特别检查 collation/大小写、NULL 排序、时间精度、JSON 值、唯一约束、自动生成 ID、分页和事务隔离差异。
- 若当前仓库已有 PostgreSQL 代码/数据，先单独做迁移评估与数据校验计划；本次选型文档变更不意味着可直接切换数据库或丢弃现有数据。

**第三方组件数据库单独认证**：Keycloak 官方支持列表包含 MySQL 8.4，不因 OceanBase 的 MySQL 模式兼容就推定 Keycloak 官方支持 OceanBase。业务库选 OceanBase 时，Keycloak 继续使用其受支持数据库和独立 schema/账号/迁移链；若客户要求统一到 OceanBase，必须取得供应商支持结论及单独升级恢复验收，未完成前不列为标准交付。[Keycloak 数据库支持矩阵](https://www.keycloak.org/server/db)

## 22. 数据库决策记录

**决定**：业务数据库方言采用 MySQL；首期默认 MySQL 8.4 LTS + InnoDB。  
**候选**：OceanBase MySQL 模式，在分布式扩展、HA/资源隔离收益通过 PoC 且团队具备支持能力后，作为某区域/私有化 profile。  
**不采用理由**：不因“百万注册设备”或“未来可能有大表”提前引入复杂分布式事务和兼容运维成本；也不把 OceanBase 宣称为与所有 MySQL 版本、SQL、DDL 和运维工具完全相同。  
**复核触发器**：MySQL 写入/存储/恢复目标连续压测不达标，或业务需数据库原生横向扩展、多 Zone SLA/租户资源隔离，或客户明确要求 OceanBase 且版本兼容通过。  
**复核责任人**：后端架构负责人 + DBA/SRE + 数据安全负责人 + 私有化交付负责人。

参考资料（官方）：

- [MySQL 8.4 LTS 安装与发行轨道](https://dev.mysql.com/doc/refman/8.4/en/installing.html)
- [MySQL InnoDB ACID 与事务模型](https://dev.mysql.com/doc/refman/8.4/en/mysql-acid.html)
- [MySQL InnoDB 分区限制](https://dev.mysql.com/doc/refman/8.4/en/partitioning-limitations-storage-engines.html)
- [OceanBase MySQL 兼容性文档](https://www.oceanbase.com/docs/common-oceanbase-database-cn-1000000005283144)
- [OceanBase 共享无架构说明](https://en.oceanbase.com/docs/common-oceanbase-database-10000000003450039)
- [OceanBase 多租户与资源单元](https://en.oceanbase.com/docs/common-oceanbase-database-10000000001971107)


## 23. 产品化能力地图与服务边界

### 23.1 可售产品线

围绕同一策略核心，形成三个明确产品包，避免把家庭、学校和设备管理平台混成一个未经区分的界面：

| 产品线 | 主要购买者 | 管理对象 | 主价值 | 控制前提 |
|---|---|---|---|---|
| Family 家庭版 | 家长/监护人 | 家庭、儿童、家庭设备 | 数字健康、家庭规则、安全提醒和访问申请 | 个人设备通常为有限控制；可选择受管设置 |
| Education 教育机构版 | 学校/学区/教育服务商 | 机构、班级、学生、配发设备 | 设备合规、学习专注、批量部署、班级和审计 | 机构购买和合法管理授权；强管理需合规 EMM |
| Managed Deployment 私有化版 | 大型学区、教育集团、政府/企业客户 | 客户独立部署的租户/集群 | 数据驻留、自主管理、组织集成、定制支持 | 客户负责基础设施、身份系统、备份与一线服务 |

共享的领域能力：身份/租户、成员与角色、策略服务、设备目录、审计、通知、Entitlement（产品权益）和连接器目录。各产品线通过租户类型、订阅权益和设备能力控制功能展示；禁止复制一套独立策略实现造成家庭版/机构版规则语义不一致。

### 23.2 全量功能服务目录

| 服务域 | 可视化产品能力 | 共享平台能力 | 最低验收 |
|---|---|---|---|
| 家庭与组织 | 家庭成员、班级/组、监护人/教师、邀请与交接 | Tenant、Membership、RBAC/ABAC、审计 | 不同租户/角色的数据访问负向测试通过 |
| 设备生命周期 | 注册、能力、在线、策略版本、授权健康、解除管理 | Enrollment、Device Registry、Connector | 每种模式状态可追踪，撤销凭证可验证 |
| 应用控制 | 白名单/黑名单、安装/启动、用量、时间计划 | Policy DSL、Policy Compiler、规则预览 | 单项规则报告实际平台执行状态 |
| 网站与内容 | 类别限制、安全搜索、浏览器策略、电视限制说明 | 分类服务、DNS/浏览器/VPN adapter | 实测覆盖范围和旁路提示可见 |
| 权限与隐私 | 敏感权限清单、授权状态、数据用途、撤回 | Capability Provider、Consent Registry | 授权撤回后采集/处理停止 |
| 数字健康 | 每日/连续使用、休息、睡眠/学习、目标与趋势 | Usage Aggregator、Schedule Engine | 本地离线累计、时区和 DST 用例通过 |
| 请求与审批 | 儿童请求、管理员审批、临时授权、到期撤销 | Workflow、Notification、Temporary Grant | 过期和重复请求幂等，管理员可追溯 |
| 安全与设备健康 | 异常、策略失败、离线、系统保护状态、求助 | Risk Rules、Alert Routing、Diagnostics | 风险有来源/可信度/建议，不把未知当安全 |
| 运营与审计 | 执行率、设备支持率、策略历史、数据导出 | Audit Log、Report API、Retention Job | 导出授权、脱敏、过期和审计测试通过 |
| 计费与权益 | 套餐、试用、升级/降级、订阅状态、发票 | Billing Adapter、Entitlement Service | 计费故障不静默取消已有安全策略 |
| 私有化交付 | 安装、授权文件、客户 IdP、升级和诊断 | Helm、License/Entitlement、Upgrade Path | 干净环境可安装、升级、回滚和恢复 |

任何功能在支持设备矩阵中都必须注明平台、OS 版本、设备模式、所需授权和验证日期。产品目录中不可展示对该设备不可能执行的控制项。

## 24. 端到端产品实施流程

### 24.1 生命周期阶段与责任交付

| 阶段 | 主责 | 关键工作 | 进入下一阶段的门槛 |
|---|---|---|---|
| 0. 用户与问题验证 | 产品/研究 | 家庭/学校访谈、现有工作流、儿童/监护人价值和滥用场景 | 明确用户、问题、付费者和被管理者分别是谁 |
| 1. 平台与政策可行性 | Android/平台、安全、商务 | EMM 准入/合同、系统 API、型号矩阵、数据权限、许可审查 | 核心卖点有合法、可支持的执行路径；不可行能力降级或移出承诺 |
| 2. 产品需求与流程 | 产品/设计 | 功能边界、状态模型、权限矩阵、异常路径、指标 | 需求可验收，有明确“不支持”表现和恢复路径 |
| 3. 架构与契约 | 架构/后端/平台 | Domain model、REST/OpenAPI、MQTT schema、租户和安全边界、ADR | 跨端契约与版本策略冻结；依赖组件许可证通过 |
| 4. UX 与原型验证 | 设计/客户端/研究 | 家长、儿童、机构、遥控器关键流程原型及可用性验证 | 管理员能看懂能力边界；孩子看懂阻止原因；错误策略可恢复 |
| 5. 平台基础与垂直切片 | 客户端/后端/SRE | OIDC 登录→家庭/组织→绑定一台设备→发布一条策略→返回执行回执 | 至少一条真实真机闭环，不允许只有静态 UI 或 mock API |
| 6. 核心功能扩展 | 各领域团队 | 规则、计划、临时申请、报告、审计和多设备批量操作 | 每个域达到 DoD；埋点、日志、回滚、文档同步完成 |
| 7. 设备/系统兼容验证 | 平台 QA | BYOD、全受管、资料、TV/OEM 机型、升级/重启/离线 | 支持矩阵有实测结果；失败模式可以识别和说明 |
| 8. 安全/隐私/商业审查 | 安全/隐私/商务/法务 | 威胁模型、数据流程、未成年人告知、订阅/退款/合同、许可证 | 发布审查清单无未接受的高风险项 |
| 9. 私测与客户试点 | 产品/支持/客户成功 | 家庭封闭测试、学校试点、迁移/培训、支持事件复盘 | 关键指标达标；高严重度缺陷关闭；客户接受能力边界 |
| 10. GA 与持续运营 | SRE/产品/支持 | 分批放量、服务状态、支持值班、版本维护和退役计划 | 监控/Runbook/升级/退款/安全响应均就绪 |

阶段不是瀑布式冻结：风险验证可并行，但外部 API 资质、系统控制能力、隐私数据路径是硬门槛，不能用功能开发进度替代。

### 24.2 每项功能的标准交付流程

1. 产品需求建立唯一 Feature ID，记录用户、问题、适用产品包、设备模式、能力依赖、非目标和成功指标。
2. 设计完成主流程、空/加载/离线/失败/部分支持/无权限状态，以及桌面、平板、手机和电视遥控交互。
3. 架构负责人评估领域边界、API/消息 schema、数据库迁移、隐私字段、外部依赖和回滚。
4. 先定义 API 契约与模拟端；客户端、后端和 Agent 并行实现。使用生成代码只生成 DTO/接口，不生成业务规则。
5. 按 vertical slice 联调：UI → API → 存储 → 命令通道 → 真机系统能力 → 回执 → 管理台状态。
6. 通过自动化测试、设备矩阵、权限/租户安全测试和故障演练；验收项逐条有证据。
7. 以 Feature Flag 灰度到内部设备、试点家庭/机构和小比例正式租户；支持暂停、回滚、补偿和数据修复。
8. 发布后观察错误率、执行率、客服问题和隐私指标；满足观察窗口后再推广。
9. 更新用户帮助、技术文档、组件清单、Runbook、兼容清单和版本变更说明。

### 24.3 Definition of Ready / Done

**Ready** 必须满足：用户和购买者明确；平台支持模式明确；主/异常/恢复流程完整；API 与数据需求列出；隐私、安全和合规影响评估完成；验收准则可验证；依赖和准入风险有 owner。

**Done** 必须满足：代码 review 完成；单测/模块/契约/集成/真机测试按风险完成；授权和多租户负向测试通过；日志、指标、告警和 correlationId 已接入；失败状态/回滚可用；API/用户文档/支持脚本更新；依赖许可证/SBOM 更新；产品和平台 owner 验收。

## 25. 产品体验、用户教育与管理责任

### 25.1 可解释规则生命周期

- 建规则时先选择场景/模板，再编辑应用、时间、网站和敏感权限；输入即显示规则适用对象和设备支持率。
- 发布前展示策略差异、影响孩子/设备数量、冲突、紧急访问白名单和无法执行的项目；需要管理员重新认证。
- 发布后展示每台设备 received/applied/partial/failed/offline 状态；提供规则原因和下次变化时间。
- 规则被拒绝时儿童能查看友善解释、查看下次可用时间或提交请求；不展示可帮助绕过控制的内部技术细节。
- 平台/系统更新导致能力变化时，通知管理员重新确认策略；不得静默收紧或放宽儿童访问范围。
- 管理员可设置共同监护人审批规则，例如新增管理员、放宽睡眠限制、删除受管设备需要两名监护人确认；该功能按家庭选择开启。

### 25.2 误用、争议和紧急流程

- 家长误配导致必要学习/医疗/联系应用被阻止时，提供管理员认证后的临时恢复和版本回滚。
- 学生/教师争议走访问请求和机构申诉流程；教师不能直接绕过全校安全底线。
- 设备丢失/账号失陷立即撤销访问并转入应急恢复；正常转校、转让、监护关系变化按验证关系、冻结变更、受限清理、确认退出、撤销剩余凭证的流程处理，不能共用会中断清理通道的顺序。员工离职先撤销人员会话与授权，不自动撤销仍在机构使用的设备凭证。
- 监护人账号失陷时，提供多因素恢复、其他监护人审批、会话撤销、设备凭证轮换和审计导出。
- 系统判定不确定时显示 UNKNOWN/NEEDS_REVIEW，不对儿童实施静默惩罚。

## 26. 商业化模式与套餐设计

### 26.1 商业模式建议

采用 B2C、B2B 和私有化三条收入路径，共用产品平台但采用不同合同、权益、服务级别和注册流程。不预设具体地区售价；价格通过成本模型、支付能力与试点验证后确定。

| 方案 | 建议计费单位 | 套餐包含 | 商业边界 |
|---|---|---|---|
| Family Free | 每家庭 | 基础规则、基础时间计划、单/少量儿童和设备、核心安全说明、基本访问请求 | 保留基本保护能力，不以付费为由撤销已生效限制 |
| Family Plus | 每家庭月/年订阅 | 多监护人、多设备、进阶网站/内容类别、跨设备报告、扩展历史、优先支持 | 可提供试用；取消订阅时显示权益变化和数据保留规则 |
| Education Standard | 每活跃受管设备/学年或学生席位 | 组织/班级、批量注册、策略模板、审计、合规仪表盘、基础支持 | 按活跃设备/席位而非遥测量收费；提供年度预算报价 |
| Education Enterprise | 按设备容量阶梯和服务等级 | SSO/高级角色、区域数据驻留、专属支持、集成和更高 SLA | 合同约定峰值容量、数据区域、SLA、支持时间和升级窗口 |
| Private Deployment | 年度软件许可 + 支持/维护 | 私有 Helm/镜像、客户 IdP、升级包、兼容性维护、运维培训 | 客户负责底层资源；订明可部署环境、许可离线校验和续费宽限期 |
| 可选服务 | 项目/设备/服务包报价 | 实施迁移、管理员培训、兼容性认证、集成、定制报表 | 定制功能必须回馈通用产品边界，避免永久分叉 |

**免费与付费原则：**

- 核心安全告知、设备能力披露、紧急求助和基本家庭规则不应被“付费墙”隐藏。
- 高成本服务（高级分析、延长历史、机构批量管理、私有部署、专属 SLA、额外集成）可作为付费权益。
- 取消付费不能让已发布安全策略突然失效；使用宽限期、显式降级预览和管理员确认完成状态迁移。
- 不出售儿童活动数据，不以广告、跨 App 追踪或数据经纪作为收入来源。
- 不以“检测到的风险”制造恐惧促销；营销表达不得承诺平台无法保证的绝对控制。

### 26.2 订阅、权益和支付系统

- 建立独立 Billing/Entitlement 域；支付渠道只更新订阅事实，产品服务根据当前权益做读授权。
- Billing 状态：TRIAL → ACTIVE → PAST_DUE/GRACE_PERIOD → CANCELED/EXPIRED/REFUNDED； webhook 必须签名验证、幂等、重放安全。
- Entitlement 以 capability key 表达，例如 multi_guardian、advanced_web_categories、longer_usage_history、bulk_device_management；服务端控制权限，不能只隐藏客户端入口。
- 订阅失效时不直接删除家庭、策略和审计；明确降级后的规则、设备、历史和导出期限，保护安全策略连续性。
- 支持地区化价格币种、税费、发票、退款/取消、促销码、学校采购订单和私有化合同；支付服务经适用商店/地区规则核验并隔离 provider adapter。
- 提供试用配额、续费提醒、账单/付款状态、取消、数据导出与支持入口；不在儿童端展示营销/升级购买提示。

### 26.3 成本与毛利模型

按产品线估算：设备注册/在线比例、MQTT 连接、策略命令、审计/使用数据保留、邮件/短信/推送、EMM API 配额/费用、存储/跨区域网络、支持工时、应用商店抽成/支付费用、试点交付和退款。套餐容量、保留期限及 API 调用预算由此确定。高成本指标达到阈值时应优化采样/聚合或调整套餐容量，不降低默认隐私保护。

## 27. 商业上市、渠道与客户成功

### 27.1 上市路径

- **家庭版**：从家长教育内容、家庭测试计划和设备兼容列表开始；先让用户自行验证授权和支持模式，再订阅升级。
- **学校/教育版**：先锁定学区/学校试点与配发设备范围，提供 IT 评估问卷、部署设计、管理员培训、家长告知模板、验收报告和学年续约计划。
- **私有化**：提供容量规划、硬件/集群前置条件、客户责任矩阵、安装验收、数据恢复演练和升级支持服务。
- **合作伙伴**：与合规 EMM、设备厂商、教育服务商/托管服务商建立连接器或联合交付；签约前确认 API 使用权、客户数据责任、支持边界、终止迁移和费用传递。
- **渠道内容**：明确适用年龄/地区/平台，展示能力矩阵、隐私说明、数据处理摘要、兼容设备、更新记录和服务状态页。

### 27.2 客户接入与客户成功

家庭自助路径：注册 → 监护人验证 → 添加家庭成员 → 设备能力检查 → 绑定 → 策略模板 → 预览发布 → 七日效果引导 → 续费/帮助。

机构上线路径：售前评估 → 数据处理与合同 → SSO/EMM 准入 → 设备盘点 → 试点分组 → 培训/家长告知 → 分批部署 → 合规报告 → 学期复盘 → 续约/扩容。

学校需提供实施向导、批量 CSV/目录同步、设备导入校验、班级映射和失败修复清单；每次批量变更提供预览/导出。客户成功团队通过采纳率、策略执行率、支持工单和管理员培训完成率发现使用障碍，不查看超出服务所需的儿童活动明细。

## 28. 客服、SLA 与产品运营

### 28.1 支持等级

| 严重级别 | 示例 | 建议响应目标 |
|---|---|---|
| SEV-1 | 大范围认证/API故障、跨租户数据风险、受管策略普遍错误锁定 | 24×7 值班；15 分钟确认接单并启动事件流程 |
| SEV-2 | 区域服务中断、主要设备模式策略停止执行、备份恢复风险 | 1 小时内开始处置（按合同服务时间） |
| SEV-3 | 单一租户/型号功能退化、有可用绕行方案 | 1 个工作日内响应 |
| SEV-4 | 使用咨询、优化请求、非阻塞问题 | 3 个工作日内响应 |

以上为预算与值班设计目标，完成支持人员、供应商责任及响应演练前不对外承诺。响应目标与修复目标分开写入 SLA；私有化客户的基础设施故障归属须明确。所有用户可查看服务状态；事故后提供影响范围、时间线、缓解措施、数据风险判断和后续动作。

### 28.2 运维产品能力

- 管理员控制台提供设备/策略/注册令牌/同步故障自助诊断，不要求用户先理解内部技术术语。
- 客服系统只通过授权的租户级 support grant 查看必要记录；临时提升权限要客户授权、限时、范围收窄并全量审计。
- 重大事故具备暂停策略广播、禁用有问题的平台能力、回滚服务版本、轮换设备证书、撤销 API 凭证和通知受影响租户的流程。
- 每次 OS 大版本/TV 固件更新前做预发布兼容验证；不再支持的设备提前通知并说明替代路径。
- 组织版本提供 API 变更窗口、客户端最低版本政策、弃用日程和迁移指导；不通过服务端静默升级破坏客户集成。

## 29. 产品指标与价值验证

### 29.1 北极星指标

建议北极星定义为：**在用户知情授权范围内，受支持设备上的家庭/学校规则持续、可验证地生效，同时不阻断紧急访问。** 不以“儿童屏幕时间越低越好”作为单一目标。

### 29.2 指标树

| 维度 | 指标 | 解释/防止的误读 |
|---|---|---|
| 激活 | 管理员完成验证到首台设备策略生效比例 | 仅绑定不算激活 |
| 可执行性 | 支持设备策略应用成功率、部分支持率、失败原因分布 | 分平台/管理模式报告，不混算 |
| 时效 | 在线策略变更确认 P50/P95/P99、离线补传时间 | 区分下发时间与实际应用时间 |
| 健康体验 | 儿童休息计划遵从率、例外申请成功/拒绝率、争议/误报率 | 不把限制总量当健康改善 |
| 使用价值 | 管理员每周有效规则、家庭/机构留存、设备合规变化 | 结合用户反馈看长期价值 |
| 安全 | 未授权访问拦截、账户接管、越权尝试、数据导出审计异常 | 事件按可信度和处置结果报告 |
| 运营 | 工单/千设备、首次解决率、设备兼容问题、MTTR | 按产品线及严重度分层 |
| 商业 | 免费转付费、家庭续费、机构席位扩展、毛利、获客成本回收期 | 分开家庭/机构/私有化核算 |
| 隐私护栏 | 数据最小化例外、授权撤回成功率、删除 SLA、媒体上传事件 | 原始媒体上传目标必须为零 |

所有分析指标聚合后再用于产品分析；不得为优化转化率采集儿童私聊/原始浏览内容。指标均有 owner、定义、来源、更新周期和数据保留策略。

## 30. 团队责任与治理

| 工作流 | 负责角色 | 最终批准角色 |
|---|---|---|
| 产品范围、套餐和路线图 | 产品负责人 | 产品总负责人/业务负责人 |
| Flutter UX、可访问性、多设备布局 | Flutter/UI 负责人 + 设计 | 产品设计负责人 |
| Android/TV 适配、设备支持矩阵 | Android 平台负责人 | 客户端架构负责人 |
| API、领域服务、数据库和消息 | 后端架构/领域负责人 | 技术负责人 |
| EMM/API 合作与平台准入 | 平台集成/商务 | 法务/业务负责人 |
| 多区域、私有化、容量与恢复 | SRE/交付架构师 | 运维负责人 |
| 身份、租户安全、威胁模型 | 安全负责人 | 安全负责人 |
| 未成年人、视觉识别、数据保留 | 隐私负责人/法务 | 隐私/法务负责人 |
| 兼容性、自动化和发布证据 | QA/设备测试 | 发布经理 |
| 试点、培训、售后与续约 | 客户成功/支持 | 商业运营负责人 |

关键外部集成（Android Management API、Apple entitlement、支付、推送、EMM vendor）必须明确商务 owner、技术 owner、合同/许可证复核、配额监控和迁移替代方案。

## 31. 产品与商业发布检查清单

正式 GA 前必须交付：

- 家庭、学校和私有化产品包的功能矩阵、价格模型和服务责任边界。
- 应用商店/网页/私有镜像的发布说明、隐私声明、数据处理条款、未成年人告知、监护人授权与撤回流程。
- Android、电视和各管理模式的公开兼容性清单、已知限制和授权步骤。
- 套餐权益/试用/续费/退款/取消/降级的端到端演练，确保订阅中断不突然解除保护。
- 支付/EMM/消息服务失败处理和配额熔断；外部服务终止时数据导出及客户迁移方案。
- 支持 SLA、状态页、客服脚本、管理员培训材料、私有化安装包和升级/回滚/恢复文档。
- 业务/技术 KPI 仪表盘、数据定义、隐私过滤校验和试点报告模板。
- 事故应急、账户接管、设备失联、误封、策略回滚、数据删除和跨区域故障演练记录。
- 组件 SBOM、开源许可证与商业服务合同清单、依赖升级周期和生命周期退役政策。
