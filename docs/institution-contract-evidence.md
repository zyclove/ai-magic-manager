# 机构合同证据连接器（1.0.0 开发阶段）

## 目标与已实现边界

中国大陆机构合同优先。外部采购/签约系统须通过独立签发方给出短期有效的合同事实断言；平台只接受经过签名、签发方、受众、时效和字段校验的断言。已实现 `ContractEvidenceVerifier` 接口、基于 Spring Security/Nimbus 的 RS256 JWKS 验证器及默认关闭配置。没有配置合格的外部签发方时返回 `CONTRACT_PROVIDER_UNAVAILABLE`，不把截图、客户端回调或人工录入当作核验事实。

当前已接通合同提交、独立审批、机构管理员确认、不可变状态事件和内部权益账本写入。验签成功只允许进入待审状态，不自动开通权益或使目录报价可购买。已签名的撤销事实必须经过独立审批，审批后直接撤销对应来源权益。本地测试使用临时 RSA 密钥签名合成断言；该密钥不进入仓库、配置或业务数据库。

**发布状态：未开放真实机构签约。** 尚无合格合同签发方、合同主体映射与重查、法务/财务审批操作规程、支付/开票及对账系统。默认验签连接器关闭；启用前须完成下面的供应商与运营门槛。当前 API 为联调实现，不构成采购、付款、发票或交付能力。

## 签发方配置与责任

| 配置 | 要求 |
|---|---|
| `manager.contract.evidence-enabled` | 默认 `false`；未接入签发方时保持关闭 |
| `manager.contract.issuer` | 可信采购/签约服务的 HTTPS issuer，精确匹配断言 `iss` |
| `manager.contract.audience` | 专用受众标识，不能复用管理端用户令牌的 audience |
| `manager.contract.jwk-set-uri` | 签发方 HTTPS JWKS；只接受 RS256，凭 `kid` 选取公钥 |

部署环境变量依次为 `CONTRACT_EVIDENCE_ENABLED`、`CONTRACT_EVIDENCE_ISSUER`、`CONTRACT_EVIDENCE_AUDIENCE` 和 `CONTRACT_EVIDENCE_JWK_SET_URI`。默认配置全部为空或关闭，现有服务不会向任何签发方发起请求。

配置仅由部署管理员和密钥治理流程变更。启用时缺少 issuer、受众或 HTTPS JWKS 会导致应用启动失败。JWKS 公钥轮换由签发方公布及部署验收；私钥不得进入本系统。接入正式系统前需签发方提供认证环境、密钥轮换与吊销规则、合同签署事实的定义、可重查接口、对账与事故流程。配置签发方不等于已完成商业上架。

身份模板提供独立的 `contract:manage` 与 `contract:approve` scope，分别映射合同运营和独立审批角色；`/api/v1/me` 仅从经服务端验证的令牌权限返回 `canManageContracts`、`canApproveContracts`。合同提交与审批均要求近期 MFA，且提交人与审批人不能相同。机构接受者必须是当前租户 OWNER/ORG_ADMIN，完成近期 MFA，并与平台提交、审批人不同。

## 断言契约

断言为完整 JWS Compact Serialization，最多 16 KiB；签名算法固定 RS256，受保护头必须有非空 `kid`。每次业务提交应由签发方按需签发，`iat` 最多早于服务端时钟 10 分钟、最多超前 30 秒；`exp` 必须未到期且不晚于当前时间 10 分钟。所有时间以 Unix 毫秒表示，JWT 标准的 `iat`/`exp`/`nbf` 保持 Unix 秒语义。服务端也校验 `nbf`。

| 声明 | 语义与校验 |
|---|---|
| `iss`、`aud`、`jti` | 精确签发方、专用受众、规范小写 UUID 事件 ID |
| `tenant_id`、`offer_id`、`offer_revision` | 规范小写 UUID 租户/报价与正整数报价修订；提交、审批和接受时再次检查机构租户、当前报价状态及版本 |
| `contract_ref`、`source_revision` | 来源合同引用及单调正整数来源版本，供账本去重/续约/撤销 |
| `buyer_ref` | 签发系统中的采购主体引用；后续须与租户确认流程绑定 |
| `region`、`channel` | 首期仅 `CN`、`CONTRACT` |
| `capacity_kind`、`device_capacity`、`features` | 与既有商业账本枚举一致；基础名额至少 1、最大 100 万；功能不得重复或未知 |
| `active_from`、`expires_at`、`state` | 明确服务期、最长 3650 天，状态为 `ACTIVE` 或 `REVOKED`；撤销仍需独立核验与处理 |
| `executed_at` | 签发方确认双方签署完成的时间，不得晚于服务端当前时间 |
| `buyer_signature_ref`、`seller_signature_ref` | 两侧不同且非空的签署证据引用；验证器不下载或保存原始合同 |

引用仅允许有限长度的可打印标识，验签层返回原始 JWS 的 SHA-256 摘要。数据库仅保存业务必需的规范化字段、签署证据引用和摘要，不能保存原始令牌、合同全文、付款凭证或儿童活动。一次验签通过不意味着报价已批准、签约方身份已映射、机构管理员已接受或设备具备受管权限。

## 机构合同状态与执行流程

1. 合同来源按需签发断言，平台合同运营使用 `POST /api/v1/platform/contracts` 提交短期 JWS 和客户端生成的 UUID。服务端先鉴权及近期 MFA，再验签；在同一数据库事务中核对机构租户、当前已批准报价的版本及 `CN/CONTRACT/ORGANIZATION/QUOTE/CNY`、容量与功能，写入 `PENDING_REVIEW` 和 `SUBMITTED` 事件。仅同一提交人、同一证据摘要、同一 ID 的重试返回原记录；来源版本、事件 ID 和证据摘要均有唯一约束。
2. 独立审批人在 `POST /api/v1/platform/contracts/{id}/approve` 或 `/reject` 提交理由及强 `If-Match`。MFA、角色、提交人分离及报价状态再次检查通过后，普通 ACTIVE 合同进入 `AWAITING_CUSTOMER`，驳回进入 `REJECTED`；二者均不发权益。已签名的 REVOKED 事实还要核对已生效且较低版本的同来源记录，审批后在同一事务调用账本并进入 `APPLIED`。
3. 目标机构 OWNER/ORG_ADMIN 在 `POST /api/v1/tenants/{tenantId}/contracts/{id}/accept` 提交强 `If-Match`。服务端锁定当前成员授权与合同记录，复核来源有效期、报价和角色分离，再在同一事务调用 `CommercialLedger.apply`、更新 `APPLIED`、写入事件与审计。失败整体回滚；过期或被撤权的角色无法接受。机构 `GET` 列表/详情只显示合同业务事实，不返回平台运营人员身份；平台审核角色有自己的列表/详情。
4. 所有状态按版本单调递增，重复或陈旧 `If-Match` 返回 412；状态转换冲突返回 409。合同记录、事件、账本和审计均按租户关联。设备管控实际生效仍由设备能力与策略回执独立证明。

### API 摘要

| 方法与路径 | 权限与作用 |
|---|---|
| `POST /api/v1/platform/contracts` | `contract:manage` + 近期 MFA；`{id,evidence}`，其中 `evidence` 为完整 Compact JWS；201 创建、200 同提交者幂等重放；仅接受外部签名证据 |
| `GET /api/v1/platform/contracts/capabilities` | 平台合同角色查询签发方开关与审核/客户确认要求；默认 `submissionEnabled=false`，管理端据此禁用提交 |
| `GET /api/v1/platform/contracts[/{id}]` | `contract:manage` 或 `contract:approve`，分页列表/详情；列表 `limit` 1–100、UUID 游标 |
| `GET /api/v1/platform/contracts/{id}/history` | 平台合同角色读取按版本倒序的不可变事件；`limit` 1–100、`beforeVersion` 游标，包含操作人、原因与关联请求 ID |
| `GET /api/v1/platform/contracts/{id}/comparison` | 平台合同角色读取当前报价快照与签名合同事实的差异代码；只读预览，不代替审批时的锁定复核 |
| `POST /api/v1/platform/contracts/{id}/approve|reject` | `contract:approve` + 近期 MFA；`If-Match` 与 `{reason}`；不同于提交人 |
| `GET /api/v1/tenants/{tenantId}/contracts[/{id}]` | 当前 OWNER、ORG_ADMIN 或 AUDITOR；租户限定的分页列表/详情 |
| `GET /api/v1/tenants/{tenantId}/contracts/{id}/history` | 当前 OWNER、ORG_ADMIN 或 AUDITOR 读取租户限定事件时间线；仅提供动作、版本与时间，不暴露内部审批原因、操作人及请求标识 |
| `GET /api/v1/tenants/{tenantId}/contracts/{id}/comparison` | 当前 OWNER、ORG_ADMIN 或 AUDITOR 读取本机构合同的报价适用平台、设备模式、名额、功能、报价有效期及差异；不包含价格、内部审批人或原始证据 |
| `POST /api/v1/tenants/{tenantId}/contracts/{id}/accept` | 当前 OWNER 或 ORG_ADMIN + 近期 MFA + `If-Match`；只有 ACTIVE 且待客户确认的合同可接受 |

所有响应禁止共享缓存，单项带强 ETag。正式接入需考虑由合同来源按需重新签发短期断言；浏览器不得长期保存 JWS。合同主数据的删除/保留与财务、争议流程须另定策略，当前只在留存目录中分类为租户级 `SHARED_ACCOUNT`。

### 管理端交互

Flutter 管理台新增“平台机构合同”和“机构合同”两个入口。平台人员看到当前已加载记录的状态统计、合同列表与详情；合同运营仅在签发方开关已启用时可粘贴短期 JWS 提交，独立审批人可批准或驳回并填写原因。机构 OWNER/ORG_ADMIN 在自己的机构空间核对采购方引用、报价版本、签约确认时间、设备名额、功能、期限及签名断言摘要后确认；AUDITOR 只读。双方均可分页查看不可变事件时间线和当前报价对照。对照加载失败或发现差异时，页面暂停批准/确认，但仍允许驳回；服务器在写入时重新加锁核验。机构视图不接收平台操作人或关联请求标识。页面会在工作空间/账号变更时清空旧数据，处理加载、空态、错误、版本冲突和近期 MFA 重新验证提示；撤销完成明确显示“撤销已执行”，说明对应来源权益停止。敏感操作触发 OIDC 重新认证时，同一浏览器标签仅短期保存合同 ID 与拟执行动作，并绑定原操作人、机构和角色；返回后重新读取最新记录并要求人工再次提交，不保存原因或自动重放写入。短期 JWS 不跨重定向保存，运营员需从签发方重新索取。

界面沿用现有控制台组件与配色，尚未在浏览器完成真实账号和视觉回归。曾按项目 UI 技能要求调用 12ui 生成候选，服务返回 `unsupported_country_region_territory`（HTTP 403），因此没有获得设计图或完成像素级对照；保留了现有设计体系和响应式列表/详情布局。

### 仍需完成的产品化能力

- 浏览器真实操作员验收、真实身份服务的重新认证回跳验收尚未交付；现有报价对照是当前快照，不是独立核验签约主体和价格的凭证；现有 SHA-256 是签名断言摘要，不是合同文件摘要。不可把模型、接口和组件静态检查等同于真实运营可用。
- 外部合同提供方、买方引用与租户法定主体的独立映射、证据可重查/吊销、到期及更高版本续约的自动同步、财务对账与开票未接入。
- 真实 MySQL 并发审批、签发方 JWKS 轮换、可用性和运营恢复演练尚需专门验收。撤销发生时，保留基础安全策略，付费权益按账本规则失效。

合同运营数据涉及采购主体，应与儿童活动分权；只有必要的租户级映射进入商业业务库。正式地区法务、税票、数据驻留与售后责任由发布流程逐项签收，本连接器不作合规结论。

## 验证

`ContractEvidenceVerifierTest` 用真实 RSA 签名与 Spring/Nimbus 解码检查正确断言、篡改、错误签发方/受众、过期/过旧/未来时间、地区/渠道/容量/功能矛盾和默认关闭行为。`CommercialContractJourneyTest` 通过 Spring HTTP、真实数据库事务与可替换的已核验证据接口，覆盖角色、MFA、同人审批禁止、机构确认前无权益、跨租户阻断、幂等重试、强版本、拒绝、入账、撤销、默认未启用签发方的能力响应、事件分页、机构时间线脱敏、当前报价对照、报价版本漂移时预览提示与写入拒绝。隔离源码 H2 验收中，合同流程 5 项通过；此前同一隔离副本还通过验签 4 项、产品目录 5 项、新库初始化 1 项和删除准备/留存分类 12 项，但这些其他模块未随本轮报价对照重跑。Flutter 本轮全部 253 项测试通过，包括重新认证指针的身份、机构、角色和超时限制；静态分析无错误或警告，既有文件保留信息级提示；Flutter Web Release 构建成功。外部真实签发方、MySQL 并发、浏览器操作与生产交付不在这组测试结论内。
