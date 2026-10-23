# 儿童档案详情取消与原窗口归属：静态候选 r1

状态：作者候选，待独立审阅；全部场景 UNRUN，未渲染。基线 e303580030192497a63492d1147156e465082706。本目录只含两个生产文件的 before/after、完整可读 diff 与审阅指纹。Main/Git、r10 任何文件、SDK/共享缓存、原测试均未修改。未新增测试、依赖或框架，未执行候选/函数/谓词/AST/formatter/SDK/测试/进程查询/网络。

## 原调用点和根因

原 ConsoleActions.subject([Json? existing]) 返回 Future<void>，丢弃 _tenantForm 的 Json? 结果。列表添加入口 console_pages.dart:304 和首页 perform 入口原 :2074 使用它；原详情 :666 是第三处编辑调用。详情的编辑与归档 DetailAction 均采用默认 closeOnSuccess=true，_ActionDetails.perform 在 action Future 正常返回后就结束详情。因此取消编辑或取消归档确认，也会被当作正常完成而关闭原详情。原详情 GET/归档写还直接使用 s.api，没有固定本条详情的工作空间/角色/代次与路由归属。

## 最小候选

- public subject([Json?]) 的 Future<void> 签名完整保留，两个既有外部生产调用不改；转交私有 Future<Json?> _subjectForm。私有表单延用同一成熟 formDialog、原昵称/年龄段字段、初始值和 POST/PATCH 路径/body。requestId 仍只在每次表单流程创建一次，原 version/path 在首 await 前固定，未改变 payload 或重试 key 的所有权。没有改通用 _tenantForm 或它的其他消费者。
- _subjectForm 先检查原 context/parent.mounted，再查询原 ModalRoute；新交互需原路由 active/current/owned.available。随后 DeviceSubflowScope 固定 actor/tenant/role/generation、root、canWrite 与 subjects 权限，并保留原 parent 可用性和传入的原详情 hasAccess。新 DialogAccessBinding 观察这些原来源，API 同时受 scope 和 binding 约束。合法子窗覆盖不会导致持久 hasAccess 失效；新操作需要 current，已经合法发出的提交完成可按原归属结束。
- subjectDetails GET 改为本次详情的固定 scope/API 与 binding。GET 后再次检查原页面 current 与许可，拒绝迟到详情覆盖其他窗口。详情 UI 只监听本流程 binding.changes；原工作空间/角色/代次变化隐藏原字段，保留既有安全关闭与重新验证。
- 两个详情 action 均 closeOnSuccess:false。开始前检查实际 owner.mounted、原权限、真实 Owned<void>.available/current，再捕获 captureDialogCompletion。编辑把实际详情 context 和原 hooks 传给私有表单，只有 Json? 非空且原详情仍 accepted 才 finish；取消、返回、失败或失权都不自动关闭详情。
- 私有 _archiveSubject 使用已有 OwnedDialogRoute<bool>/AlertDialog 保留原确认标题、正文、取消与确认归档按钮。局部 DialogAccessBinding 覆盖完整“确认→POST” Future，而非确认结束即释放。取消/返回/遮罩关闭得到非 true，不发送归档；确认后再次核原详情 current/available/原权限，才用原 scope/API 发送原 POST/archive 和原 version（原来没有 request key，此处也未新增）。成功后只 finish 捕获的原详情，即使另有合法 cover，也不 pop 该 cover。失败留原详情由既有 FailureView 展示。
- ui/design.dart 仅把 actionDetails 的“已隐藏原申请内容”改为“已隐藏原窗口内容”，没有其他共享行为变更。

## 原详情结束与通知寿命

编辑 UI 只接收 _subjectForm 自己持有至 form Future 完成的 access.changes；归档 UI 只接收 _archiveSubject 自己持有至确认及 POST 完成的 access.changes。父详情的原 binding/scope 即使先被释放，存活子窗不直接向它们的 raw notifier 新增/重加 UI 监听。局部 binding 一次性观察原来源和 parent.popped；原 Owned 详情一旦 finish，available 同步 false，所有后续确认/提交/reauth/merge 入口通过原 binding/route 拒绝，失效提示随后使用仍存活的局部 notifier 更新。

失效子窗的关闭不需要旧业务权限，只要求其自身 owned route available/current，因而可安全退出而不 pop cover。局部 binding 的 finally 在完整 awaited route/请求流程后释放。scope/hasAccess 不引用自己的 binding，避免回调环。原详情关闭后不会重新捕获新工作空间来补写。失权前已经送达服务器的请求不能由前端回滚；候选只拒绝后续旧归属操作、迟到 UI/完成及错误的窗口关闭，不伪称撤销服务端提交。

## 已核对与待运行边界

静态确认完整 ConsoleActions 修改范围仅原 subject/subjectDetails 区域及两个私有辅助；区域前后所有源码、通用 _tenantForm、其他详情/工作台/配额等字节不变。design 只有上述一处文案替换；完整两文件 diff 可由 before/after 重建。现有测试文本检索未找到儿童详情取消编辑/归档及上述 route-lifetime 组合的直接断言；api_test.dart 有通用 subject PATCH 行为，不代表此新 UI 流程通过。

待未来授权窗口运行：取消编辑/取消归档均留原详情且没有写请求；正常保存/归档只关闭原详情并触发原列表刷新；重复点击、提交失败、未知结果同 body/key 重试；确认前/提交前换租户或角色与 away-back；父详情在 child 存活/被覆盖时关闭，child 立即拒绝旧操作并仍可安全关闭；合法已发送保存完成时有 cover；重新认证与窄屏/大字/键盘返回。全部尚未运行，不以静态合理性代替真实通过。
