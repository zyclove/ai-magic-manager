# 智能管家设计文档

更新日期：2026-10-09。设计文档构成实现契约，后端代码正在按[实施计划](implementation-plan.md)开发；验证与未完成范围见[实施记录](implementation-progress.md)。客户端、设备适配与部署验收尚未完成。

| 文档 | 用途 | 主要读者 |
|---|---|---|
| [平台设计蓝图](parental-control-platform-design.md) | 产品定位、设备能力、架构、技术与数据库决策、安全、容量、阶段门槛 | 全团队 |
| [功能规格与流程](parental-control-functional-spec.md) | 功能编号、正常/异常流程、跨设备额度、电视身份、接口数据、逐项验收 | 产品、客户端、后端、QA |
| [商业运营与交付规格](parental-control-commercial-spec.md) | 可售能力、权益、账单、交付、支持、成本、试点与上市门槛 | 产品、商务、交付、财务、SRE |
| [产品实施与功能闭环](parental-control-product-delivery-spec.md) | 全量功能对应、页面状态、实施/故障流程、数据库落地、渠道分权和交付门槛 | 产品、开发、QA、商务与交付 |
| [完整产品交付与商业运营模型](parental-control-product-operating-model.md) | 全功能工作包、状态机、审批/批量流程、跨端交互、边缘场景、售卖计量、成本及上线责任 | 产品、设计、研发、QA、商务、支持与 SRE |
| [数据库实施与认证规格](database-implementation-and-certification.md) | MySQL/OceanBase 决策、数据域、索引/事务、容量、真实数据库认证及迁移回退 | 后端、DBA、SRE、QA 与私有化交付 |
| [当前后端接口](backend-api-status.md) | 实际路由、认证、版本/幂等、配置及未完成项 | 开发与联调 |
| [设备接入契约](device-registration-contract.md) | 实际注册/恢复、独立凭证、两阶段轮换、能力与心跳 API | 后端、Flutter、Android 与 QA |
| [应用、时间与策略契约](policy-application-schedule-contract.md) | 应用身份/清单、日程/DST、草稿/模板、预览、配置版本、回滚及执行边界 | 产品、后端、Flutter、Android 与 QA |
| [签名配置与消息交付](configuration-delivery-contract.md) | 单设备 JWS、持久游标/回执、过期重发、通知登记/重试与验证边界 | 后端、Flutter、Android、QA 与 SRE |
| [临时访问申请与审批契约](access-request-contract.md) | 实际申请/决定/取消/撤销、窗口/到期、主体/设备/成员失效及执行边界 | 产品、后端、Flutter、Android 与 QA |
| [设备退出与清理契约](device-deprovision-contract.md) | 后果预览/确认、业务撤销、原密钥清理认证、签名命令/回执、取消/到期与验证边界 | 产品、后端、Flutter、Android、QA 与 SRE |
| [管理台交付记录](management-console-delivery.md) | 已接入的业务页面、身份联调、交互验证与剩余工作 | 产品、开发、QA 与交付 |
| [设备退出组件接入契约](device-operations-ui-contract.md) | 共享 Flutter 组件、宿主认证、恢复限制、浏览器证据与截图 | Flutter、后端、Android 与 QA |
| [设备签名配置接收契约](device-configuration-client-contract.md) | Dart JOSE、设备 HTTPS/opaque 认证、整页事务/续点、回执重放与真实 Spring/Dart 互操作证据 | Flutter、Android、后端与 QA |
| [设备身份客户端契约](device-identity-client-contract.md) | 原密钥认领/恢复、持久心跳、两阶段凭证轮换、认证暂停、secret-store 边界与真实联调 | Flutter、Android、后端与 QA |
| [2026-10-09 阶段交付](stage-delivery-2026-10-09.md) | 本阶段提交范围、重新验证、仓库配置边界及后续发布门槛 | 全团队 |
| [可复制部署手册](deployment-runbook.md) | 新环境初始化、独立构建、五服务 Compose、身份授权、TLS 与升级边界 | 开发、QA、交付与 SRE |

## 阅读顺序与变更规则

1. 先确认平台设计第 3 节的设备模式，再确认功能规格的能力前置条件。
2. 实施时选择一个阶段，以功能编号形成任务、API、界面和验收证据的对应关系。
3. 功能上架前核对商业规格：技术能力、套餐权益、管理员授权、运行状态必须同时满足。
4. 更新平台或供应商 SDK 时，同步更新能力矩阵、功能规格、兼容清单及售前说明。
5. 用产品实施规格的功能闭环表组织交付；实际接口与测试结果读取实施记录，不把规划接口当作现有服务。
6. 用完整产品运营模型安排功能工作包、页面状态、商业发布和支持责任；数据库部署先核对独立认证规格。

现有文档中的容量、SLO、售价模型和支持响应为规划参数，不是已测结果或已提供的商业承诺。分期不取消完整规划范围；未验证能力不得对外标记已支持。
