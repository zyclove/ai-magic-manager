# 智能管家设计文档

更新日期：2026-10-12。设计文档构成实现契约，代码正在按[实施计划](implementation-plan.md)开发；验证与未完成范围见[实施记录](implementation-progress.md)。管理端和部分设备客户端已进入联调，正式受管执行、真实签约和客户环境部署验收尚未完成。

| 文档 | 用途 | 主要读者 |
|---|---|---|
| [平台设计蓝图](parental-control-platform-design.md) | 产品定位、设备能力、架构、技术与数据库决策、安全、容量、阶段门槛 | 全团队 |
| [功能规格与流程](parental-control-functional-spec.md) | 功能编号、正常/异常流程、跨设备额度、电视身份、接口数据、逐项验收 | 产品、客户端、后端、QA |
| [商业运营与交付规格](parental-control-commercial-spec.md) | 可售能力、权益、账单、交付、支持、成本、试点与上市门槛 | 产品、商务、交付、财务、SRE |
| [中国大陆机构合同首发手册](institution-commercial-launch-runbook.md) | 合同优先的实际产品包、角色分工、签约/开通/交付/撤销步骤、异常处理与发布阻断项 | 商务、交付、财务、产品、安全与 SRE |
| [产品实施与功能闭环](parental-control-product-delivery-spec.md) | 全量功能对应、页面状态、实施/故障流程、数据库落地、渠道分权和交付门槛 | 产品、开发、QA、商务与交付 |
| [完整产品交付与商业运营模型](parental-control-product-operating-model.md) | 全功能工作包、状态机、审批/批量流程、跨端交互、边缘场景、售卖计量、成本及上线责任 | 产品、设计、研发、QA、商务、支持与 SRE |
| [数据库实施与认证规格](database-implementation-and-certification.md) | MySQL/OceanBase 决策、数据域、索引/事务、容量、真实数据库认证及迁移回退 | 后端、DBA、SRE、QA 与私有化交付 |
| [当前后端接口](backend-api-status.md) | 实际路由、认证、版本/幂等、配置及未完成项 | 开发与联调 |
| [监护人 Android 客户端交付契约](parent-android-delivery.md) | 原生 OIDC、今日概览、访问申请、求助、设备列表及生产准入 | 产品、Flutter、身份、安全与 QA |
| [所有者交接合同与实施](ownership-transfer-plan.md) | 双方确认、权限差异、成员版本、敏感待办失效与真实 MySQL 并发验证 | 产品、前后端与 QA |
| [成员资料与权限调整](member-access-plan.md) | 可识别身份、角色/档案范围、强版本撤销、变更历史与旧待办失效 | 产品、前后端与 QA |
| [机构班级与教师工作流](organization-workflow-plan.md) | 班级名册、原子转班、多班级教师范围及分阶段验证 | 产品、前后端与 QA |
| [设备接入契约](device-registration-contract.md) | 实际注册/恢复、独立凭证、两阶段轮换、能力与心跳 API | 后端、Flutter、Android 与 QA |
| [应用、时间与策略契约](policy-application-schedule-contract.md) | 应用身份/清单、日程/DST、草稿/模板、预览、配置版本、回滚及执行边界 | 产品、后端、Flutter、Android 与 QA |
| [签名配置与消息交付](configuration-delivery-contract.md) | 单设备 JWS、持久游标/回执、过期重发、通知登记/重试与验证边界 | 后端、Flutter、Android、QA 与 SRE |
| [临时访问申请与审批契约](access-request-contract.md) | 实际申请/决定/取消/撤销、窗口/到期、主体/设备/成员失效及执行边界 | 产品、后端、Flutter、Android 与 QA |
| [签名审批文档与回执](access-window-delivery-contract.md) | 设备文档、固定期限、撤回版本、接收/保存报告与管理诊断 | 后端、Flutter、Android 与 QA |
| [设备审批接收组件](../packages/device_access/README.md) | JOSE 验签、Sembast 事务、完整扫描/续点、HTTP 自动恢复、撤回与回执接入 | Flutter、Android、后端与 QA |
| [设备退出与清理契约](device-deprovision-contract.md) | 后果预览/确认、业务撤销、原密钥清理认证、签名命令/回执、取消/到期与验证边界 | 产品、后端、Flutter、Android、QA 与 SRE |
| [管理台交付记录](management-console-delivery.md) | 已接入的业务页面、身份联调、交互验证与剩余工作 | 产品、开发、QA 与交付 |
| [共享额度契约](shared-quota-contract.md) | 每日池、重复计划、事务账本、设备租约与执行边界 | 产品、后端、Flutter、Android 与 QA |
| [重复额度计划实施说明](quota-recurring-plan.md) | 星期/日期额度、生效规则、后台生成、来源版本与验收门槛 | 产品、后端、Flutter 与 QA |
| [设备退出组件接入契约](device-operations-ui-contract.md) | 共享 Flutter 组件、宿主认证、恢复限制、浏览器证据与截图 | Flutter、后端、Android 与 QA |
| [设备签名配置接收契约](device-configuration-client-contract.md) | Dart JOSE、设备 HTTPS/opaque 认证、整页事务/续点、回执重放与真实 Spring/Dart 互操作证据 | Flutter、Android、后端与 QA |
| [设备身份客户端契约](device-identity-client-contract.md) | 原密钥认领/恢复、持久心跳、两阶段凭证轮换、认证暂停、secret-store 边界与真实联调 | Flutter、Android、后端与 QA |
| [儿童端宿主契约](child-host-contract.md) | Flutter/Android 接入、加密存储、进程恢复与当前执行边界 | Flutter、Android、后端与 QA |
| [儿童求助记录契约](child-help-request-contract.md) | 设备端求助、云端幂等记录、成人收件与确认、离线恢复及非紧急服务边界 | 产品、Flutter、后端、QA 与交付 |
| [设备观察授权契约](device-observation-contract.md) | 应用清单/使用摘要的单独授权与报告边界；V20 代码交付状态以该文档为准 | 产品、前后端与 QA |
| [Android 应用权限观察与受管执行契约](runtime-permission-management-plan.md) | 单独授权、按需原生观察、设备模式差异及发布门槛；三端默认关闭，真实设备验收与受管执行待完成 | 产品、前后端、Android、安全与 QA |
| [网站与内容安全适配器准入](content-safety-adapter-gate.md) | 受管网络、BYOD VPN、受控浏览器的执行范围、隐私和验收门槛 | 产品、Android、后端、安全与交付 |
| [2026-10-09 阶段交付](stage-delivery-2026-10-09.md) | 本阶段提交范围、重新验证、仓库配置边界及后续发布门槛 | 全团队 |
| [可复制部署手册](deployment-runbook.md) | 1.0.0 全新初始化、独立构建、六服务 Compose、身份授权、TLS 与恢复边界 | 开发、QA、交付与 SRE |
| [Kubernetes 与 Helm 部署基线](kubernetes-deployment.md) | API/Web 多副本、独立作业、外部 MySQL/Keycloak/Secret、同源入口与验收门槛 | SRE、私有化交付与后端 |

## 阅读顺序与变更规则

1. 先确认平台设计第 3 节的设备模式，再确认功能规格的能力前置条件。
2. 实施时选择一个阶段，以功能编号形成任务、API、界面和验收证据的对应关系。
3. 功能上架前核对商业规格：技术能力、套餐权益、管理员授权、运行状态必须同时满足。
4. 更新平台或供应商 SDK 时，同步更新能力矩阵、功能规格、兼容清单及售前说明。
5. 用产品实施规格的功能闭环表组织交付；实际接口与测试结果读取实施记录，不把规划接口当作现有服务。
6. 用完整产品运营模型安排功能工作包、页面状态、商业发布和支持责任；数据库部署先核对独立认证规格。

现有文档中的容量、SLO、售价模型和支持响应为规划参数，不是已测结果或已提供的商业承诺。分期不取消完整规划范围；未验证能力不得对外标记已支持。

- [站内审批通知契约](inapp-notifications-contract.md)：当前权限收件箱、个人已读、分页与状态语义。
- [站内审批通知实施与验收](inapp-notifications-plan.md)：V21、并发/迁移/浏览器验证、备份及运行指纹。
- [审计查询工作台](audit-explorer-contract.md)：时间倒序、条件查询、详情权限、错误恢复和当前功能边界。
- [审计异步导出](audit-export-contract.md)：后台任务、加密文件、取消/下载、权限重验与有效期；[实施及验收记录](audit-export-plan.md)。

## 受管 Android：实现导航与交付边界

本节核对日期：2026-10-16；已提交代码基线 `3d7aac9`。这里的“内部实现”表示服务或连接器代码已经存在，不等于用户可以下发系统策略，也不等于运行环境已部署该版本。部署结果另以发布记录为准。

| 工作环节 | 实现与证据入口 | 当前边界 |
| --- | --- | --- |
| 受管注册与管理员操作 | [受管注册体验](managed-enrollment-experience.md) | 需要提供方接入、有效机构权益及管理员授权；普通设备绑定不能代替受管注册 |
| 管理代理绑定 | [绑定流程](managed-agent-binding-workflow.md)、[绑定体验](managed-agent-binding-experience.md)、[保留与删除](managed-agent-binding-retention.md) | 核验当前注册密钥与受信代理身份，不自动授予系统执行能力 |
| 目标应用事实 | [报告契约](managed-application-report-contract.md)、[身份核验](managed-application-identity-verification.md)、[证据刷新](managed-application-evidence-workflow.md) | 安装签名证据与应用用户空间证明分开；不能将清单声明当作系统控制证明 |
| 策略预览 | [预览证据](managed-policy-preview-evidence.md) | 展示当前证据及未核验原因；预览成功不是执行回执 |
| 发布与文档编译 | [冻结发布输入](managed-publication-input.md)、[完整策略文档](managed-complete-policy-document.md) | 从服务端发布快照生成完整文档；不接受儿童端声明的执行权限 |
| 提供方文档读写 | [完整策略传输](managed-complete-policy-transport.md)、[提供方回执](managed-policy-receipt-contract.md) | 官方 SDK 与本地 HTTP 验证；写入响应不能代替设备应用回执，资源独占仍需证明 |
| 当前设备资料 | [设备资料与时效](managed-device-execution-profile.md) | 核对精确设备、管理模式、API、状态与时效；不是厂商兼容认证 |
| 已发布策略准备 | [准备链路](managed-policy-preparation.md)、[阶段证据](evidence/managed-policy-preparation-20261016.json) | 两次短事务复核当前上下文；内部准备成功不开放入账、写入或分配权限 |
| 执行持久化 | [执行账本](managed-policy-execution-journal.md)、[完整策略异常恢复](managed-complete-policy-recovery-plan.md) | 内部状态机、领取与完整观察回执转换已存在；公开执行入口、发送器和人工复核界面尚未接通 |

### 联调时如何判断完成

1. 先确认当前服务版本和实际设备模式，再检查对应接口、用户权限和提供方配置。
2. 将配置保存、设备接收、提供方写入、策略分配和设备应用分别记录；任何前一步成功都不能替代后一步证据。
3. 当前准备阶段的 521 项是冻结后端的定向回归，包含前面阶段的重叠用例，不能与各历史阶段数量相加作为独立覆盖总数。
   完整策略恢复阶段为 543 项定向回归，新增 22 项；其 [阶段证据](evidence/managed-complete-policy-recovery-20261016.json) 保留了首轮失败和修正后的编译、测试结果。它同样不是全产品、真实提供方或真机验收。
4. 本地 HTTP、H2 和模拟授权边界分别说明其验证范围；真实 MySQL/OceanBase、正式 EMM、Android/TV 真机和容量验证须查看各自证据。
5. 中国大陆机构合同首发仍需可用合作方接入；Google 连接器的本地验证不改变中国大陆禁用和正式准入条件。没有合作方时保持明确不可用状态。

应用用户空间证明、设备兼容认证、远端资源独占、执行入账及每次写前的完整授权、后台执行编排和真实设备验收仍未完成。上述文档用于复用已交付组件和定位剩余工作，不能作为“所有 APP 已能强制管控”的售前承诺。
