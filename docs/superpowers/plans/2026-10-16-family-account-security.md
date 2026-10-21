# 家庭账号与安全开发增量

日期：2026-10-16。基于已批准的大陆家庭订阅计划，保留当前所有工作区改动，不变更已有本机数据库、身份域、销售开关或真实供应商配置。

## 本轮范围

1. 身份服务统一执行手机号换绑、已绑定微信恢复手机号、微信绑定与解绑，始终保留原 user ID，因此家庭、设备、订单与会员不迁移、不复制。
2. 家长端「我的 → 账号与安全」集中呈现脱敏手机号和微信状态；登录页提供「找回账号」。验证码在安全浏览器中处理，微信授权码只保留内存。
3. 操作开始前保存不含手机号、验证码、令牌的加密恢复记录。关闭浏览器、掉网或重启之后先核对原操作结果，不自动重复修改账号。
4. 换号及解绑等修改递增受保护的身份版本，撤销既有会话。业务 API 通过可信身份状态接口校验当前会话，避免旧 JWT 继续用于手机号邀请或敏感操作。

## 身份与安全契约

- `CHANGE_PHONE`：原手机号验证码 → 新手机号验证码 → 原账号原子换号。
- `RECOVER_PHONE`：已绑定微信服务端换取身份 → 新手机号验证码 → 原账号恢复。未知微信不得创建账号或按新手机号合并；没有原手机或已绑定微信时提供求助说明。
- `BIND_WECHAT`：当前手机号验证码 + 微信服务端身份验证；已被其他账号使用、已有不同微信均明确拒绝。
- `UNBIND_WECHAT`：当前手机号验证码；确认保留手机号登录与恢复路径。
- OIDC 参数：`family_account_action`、`family_account_operation`、`family_account_actor`、`family_account_revision`；微信授权码沿用 `family_wechat_code`。操作、actor、原手机号和版本固定到身份会话，后续表单不能替换。
- 共享的 realm/actor、realm/目标手机号、realm/AppID/openid 锁及最终版本检查覆盖注册与绑定路径；锁随身份事务完成释放。
- 当前可信访问令牌携带 `consumer_identity_revision`。刷新时核对当前用户属性，过时手机/版本不得继续出具可信声明。
- `GET {issuer}/consumer-account/status` 返回当前可信会话的脱敏状态与最近操作回执，禁止缓存；旧会话返回 401，配置不可用返回 503。
- 状态字段：`subject`、`phoneMasked`、`phoneVerified`、`wechatBound`、`identityRevision`、`sessionCurrent`、`accountSecurityAvailable`、`canChangePhone`、`canBindWechat`、`canUnbindWechat`、`canRecoverByWechat`、`lastOperationId`、`lastOperationAction`、`lastOperationAt`。
- 统一默认关闭的部署开关 `FAMILY_ACCOUNT_SECURITY_ENABLED` 同时控制身份修改与 API 当前会话校验。正式开启前必须在隔离环境验证完整闭环及升级兼容性。

## 实施分工及顺序

1. 冻结当前源码、HEAD 与未提交差异：`.local/family-p0-account-security-20261016/baseline*`，1774 个源文件。
2. 并行补齐 Keycloak 扩展及身份表单、家长端状态协调器及页面、业务端当前会话校验。
3. 接入 ParentSession OIDC 操作、我的与登录入口、默认关闭部署配置。
4. 审查冲突、重放、越权、取消、中断恢复、身份变化和未配置状态；覆盖窄屏与大字布局。
5. 运行隔离自动化验证与构建，保存可追溯证据及安装包；真实短信、微信和真机恢复仍作为发布验收，不以模拟测试替代。

## 验收重点

- 换号与微信恢复保留相同 subject；新手机号已有账号时拒绝，不静默合并。
- 绑定/解绑验证当前手机；微信 AppID 隔离；并发注册/绑定无重复身份。
- 验证码用途隔离、限流、次数上限和到期；修改中断与重复提交不会重复生效。
- 旧会话与旧手机号声明失效；身份状态接口失败时，已开启的业务校验不得降级放行。
- 操作结果只能由可信状态和匹配回执确认；取消浏览器不表示修改未发生。
- 页面无原始手机号、授权码或技术版本信息；加载、离线、不可用及恢复步骤可理解。
- 不修改机构 MFA、安全策略、现有数据库及本机部署；保留所有已有未提交工作。
