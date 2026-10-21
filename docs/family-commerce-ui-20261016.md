# 家庭订阅订单、售后与日账单界面

日期：2026-10-16（中国上海时区）。本记录只描述软件实现与本地验证，不代表真实支付、退款到账或正式收费验收已经完成。

## 家长端

- 家庭会员继续保留一个套餐的月／年选择、手动续费和订单目录。共同监护人查看会员与订单，付款、领取试用和退款申请由家庭所有者处理。
- 订单详情使用一个付款状态主卡和一个退款进度卡。默认刷新只读取原订单与原退款记录，不向支付渠道发起新交易或退款。
- 本地发现支付时间已到时，显示“付款结果待核实”，暂停新的支付调起。只有服务端最终事实才能显示“订单已关闭”。服务端确认从未预约过支付的草稿到期时，显示“订单已过期”，并解除本地原付款恢复引用。
- 家长只能申请原路全额退款、查看人工审核与渠道处理进度。审核通过后由服务自动提交，页面不再要求家长点击供应商退款提交按钮。
- 申请前说明退款金额、仅撤对应订单来源、其他续费单独核算及设备恢复通道保留。审核说明使用独立 `reviewNote` 字段，不把家长原申请原因当作拒绝原因。
- 退款申请按家庭、成人和原订单隔离写入加密持久记录，再发送原幂等请求。断网、杀进程、身份过期、安全验证和请求处理中均保留原记录，重新打开后明确确认再继续；不会自动另建申请。
- 同进程多页串行访问同一退款日志。落盘结果未知时停止发送，金额、订单、原因或状态回执不符时保留原请求。切换身份使旧页面失效；离开前台关闭未提交确认框。

代码入口：

- `apps/parent/lib/ui/family_membership.dart`
- `apps/parent/lib/ui/family_order_page.dart`
- `apps/parent/lib/core/family_after_sales.dart`
- `apps/parent/lib/core/family_payment.dart`

## 管理台

`FamilyFinancePage` 为独立的平台权限页面，不依赖当前家庭／机构工作空间。上层平台导航与会话集成由 `ConsolePages` 负责。

界面只有“退款售后”和“日账单”两类入口；按退款审核与财务权限分别加载。采用现有 `consoleTheme`、`Panel` 和统一按钮样式。

- 退款列表支持状态、原订单编号、分页及刷新。本人申请与不可审核记录不显示审批按钮。
- 审批前读取最新退款及权益预览，展示金额、当前申请、保留续费和退款影响；通过／不通过均要求说明并明确确认。
- 审核结果只显示已记录；退款到账仍以服务端渠道核验为准。需要原单核对时仅排队查原单，不创建新退款。
- 日账单支持上海日期、原任务重试、分页和差异详情。部分核对、渠道不可用、失败及达到重试上限的人工处理状态均单独显示。
- 人工跟进只写说明并保留差异性质，不将账单当作已对平。可安排已匹配的原订单／退款单查询；未匹配原单的渠道记录交人工核对。
- 所有写入先保存同标签页原请求；保存内容仅含账号哈希、操作路径、编号、预览哈希、日期与短说明，不保存家长申请原因、支付凭据或登录令牌。未知结果及近期 MFA 保留原请求，返回后需要再次确认。
- 账号、权限或前后台改变时立即隐藏旧资料、关闭确认框，并丢弃迟到页面结果。已明确拒绝的旧预览释放后必须重新预览；审核决定、订单／退款编号和账单日期的回执与原请求绑定。

代码入口：

- `apps/guardian/lib/ui/family_finance_page.dart`
- `apps/guardian/lib/core/family_finance.dart`
- `apps/guardian/lib/core/finance_storage_port.dart`
- `apps/guardian/lib/core/family_finance_storage_web.dart`

## 本地验证

- 家长端订单／退款恢复／付款安全／会员权限及既有首发回归定向测试：33 项通过，静态分析通过。旧首发测试补齐退款日志存储替身及真实合同字段，保留未知退款读取时禁止重复申请的断言；订单可只读展示，未核对成功的退款进度隐藏。
- 管理台退款／账单／持久恢复／权限及前后台保护定向测试：30 项通过，静态分析通过。包含真实控制台外层滚动宿主、拒绝审核提示、账单日期明确拒绝后的恢复和 `INVALID_BILL` 状态。达到 50 次或人工处理状态不再展示重试；仅相应操作已明确被拒时释放日志，人工跟进竞争不覆盖已有说明，认证及未知结果继续保留原日志。
- 两端均包含 320 px 宽度、两倍字体场景。测试使用虚构订单和 MockClient，不访问微信商户接口。
- 管理台 ATTENTION、预览改变、说明长度、审核决定与账单日期回执绑定已先观察失败，再通过对应修复。
- 运行中系统盘临时目录容量不足造成一次测试编译失败；最终管理台定向已改用工作区 D 盘 TEMP/TMP 并完成，编译环境失败不记作功能验收通过。

证据在 `.local/family-p0-commerce-20261016/`：

- `parent-regression-final.log`、`parent-analyze.log`
- `finance-final-green.log`、`guardian-analyze.log`
- `finance-definite-conflict-red.log`
- `parent-regression-storage-diagnosis.log`、`parent-launch-contract-red.log`、`finance-integration-red.log`
- `ui-page-red.log`、`refund-amount-red.log`
- `finance-attention-red.log`、`finance-contract-red.log`、`finance-receipt-red.log`
- `after-sales-fictional.png`
- `operator-refund-fictional.png`、`operator-bill-fictional.png`

真实商户支付、退款到账、正式签名、真实账户近期验证与国内网络仍需发布验收。全量回归与安装包构建以本轮主交付记录的最终结果为准。
