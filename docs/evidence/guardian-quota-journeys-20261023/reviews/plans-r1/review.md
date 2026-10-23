# QuotaPlansPage r1 独立静态审阅

## 结论与接合条件

该固定单文件未发现静态阻断；结论以明确的兄弟接口共同交付为条件，不能单独应用或声称可编译。before/after、完整 3-hunk 补丁和共享实际依赖已读回。所有场景 UNRUN，未渲染，未编译。

尚待最终核对：

1. Root 的 QuotaPage 必须给唯一生产调用传原 parentCurrent/accessChanges，并保持原 owner 不可复活；parentChanges 对原 owner 稳定，不以单纯替换 parentCurrent 回调把旧 State 交给新父 owner。
2. ViewLifetime helper c68c7457…9815 须应用到 ../ui/view_lifetime.dart；本轮核的是实际 1068B helper 原件，不假设 Main 已存在。
3. ResourcePage 可选 canInteract 须按 UI-only 合同交付；仅核 Root 当前草稿 18737B/50ca974f…f0360 的接口形状，未预填最终 metadata/完整独审通过。
4. QuotaPlanEditor 须新增 optional hasAccess/accessChanges、原 owner/own-route 交互检查及 covered 成功 finish 自己的 Owned<void> route；本轮尚无最终 Editor 字节，不能预填通过或推断其完整行为。

## 完整源码审核要点

- 29–77 固定原 Session/root/parentCurrent/parentChanges，DeviceSubflowScope 捕 actor/tenant/role/generation。current 同时要求 mounted、原 lifetime.active、scope.current；新 Session 或 parent changes 对象替换会 invalidate。deactivate 同步失效且没有激活旧 lifetime 的分支；dispose 先安排 lifetime 失效通知，再释放 scope。即使 scope.dispose 不通知，稳定 changes 合并仍带原 lifetime.changes，使独立 root dialog 可观察页面结束。
- 80–99 使用 scope.api 读可选标签；原 owner 失效后不安装迟到标签。标签不可用仍走旧空映射回退，不误当新增授权。112–157 失效后隐藏原列表；key 包含固定 Session/actor/tenant/role/generation，read owner 和 top-route 交互通过 isCurrent/canInteract 分离。
- edit:160–182 在异步预检前建立原 parent 的 DialogAccessBinding，固定 api/defaultZone/request key/version/path。每次 children/apps await 后再核原 binding 和 parent current，避免晚预检在覆盖窗上另开 editor。
- 183–215 的 accepted 只核 canWrite、原 access、自己 route.available/isActive，不要求 isCurrent；编辑日历与提交的 Api 也绑定 accepted。合法发送后被 cover 不会仅因覆盖而丢失完成资格；新的用户保存由待交付 Editor 的 current-route 门槛负责。reauth 已要求 route current。
- Api.scoped 实际实现只创建闭包，不在构造时执行 predicate，因此编辑/history 中在 route 赋值前建立 scoped Api 不会自行求值未初始化的 late route。route 在 present/build 之前已赋值。以上仅人工数据流检查。
- key、version、path 固定在同一 edit flow，原 POST/PUT endpoint、calendar 编码及 body 原样转发，未生成重试新 key/新 version。原 pending exact-body 保留依赖 Editor 合同；不声称本文件已独立证明 Editor 行为。
- details:221–295 在 GET 前捕原 parent binding，读回再核 current/top。共享 scopedDetailsDialog 保留成熟 owned 路由与失效隐藏；原 saved version/effective date、target、timezone、状态说明、七天额度与排序 dateOverrides 均仍显示。
- 两个 DetailAction 在实际执行前核原 access 和其真实 Owned<void> route.available/current。history 使用实际 detail context 建子 flow，保留原详情作祖先。modify 仅 finish 该详情并置 requestedEdit；等原 Future/transition 完成后，只有原 page 仍 current/writable 且 binding 未失效才打开 editor，仍用原 plan/version。
- history:298–363 的 DialogAccessBinding 捕 actual detail parent，能检查祖先 Owned.available；cover 不误撤权，祖先 finish→dispose 期间仍可同步拒绝旧访问。自己 accepted 包括原 owner/binding/route.available/isActive，API 和 ResourcePage.isCurrent 允许 covered 在途读取；canInteract 另核自己 route.current。
- history 失权替换为隐藏视图，关闭只在自己 available/current 时 finish 自己，没有权限要求，因此撤权窗口可安全关闭但不会弹覆盖者。presentOwnedDialog 和 finally 保证原 route 完成后释放其 access 监听。全文件不再使用任意 Navigator.pop/raw showDialog。

## 人工类型与保留范围

新增 parentCurrent 为 bool Function()、accessChanges 为 Listenable，与稳定 merge 和共享 DialogAccessBinding 的接口一致。OwnedDialogRoute<void> 与 shared detail route、Editor void Future 对齐；API version 固定为 int?，body 继续 Json；既有 JSON 数据正常类型及列布局未发现明显不匹配。不是 Dart 类型检查结果。

原 JSON/version/时区/配额/限制规则、HTTP/If-Match/幂等协议、公共 API 后端和测试源码未改。历史改为详情的 owned child、详情使用共享组件是明确 UI 调整；不声称所有布局或路由并发已验证。原 parentCurrent 必须是不可复活 owner 门槛，不要求它在 child cover 时为 false；否则将自行撤销合法流程。

## 字节证据与限制

6 文件成员精确；全部 5 delivery、4 metadata 文件、8 baseline dependency、实际 helper 指纹匹配。Main before 与 Git bb93c0b 的 blob 52557a0205392eec97cc4d1e9f104abc9dd735a4 相同。完整补丁重建 after 的每个字节：16238B SHA256 621d3f71141ef30904fa70334f4f2f221debd9cff960798ee49e0eedba193fdd。

仅文本/hash/JSON/只读 Git 与自有报告写入；未执行候选、业务谓词、SDK/测试/AST/解析器/formatter、进程检查/WinAPI/网络。Main/Git、测试、候选和旧证据未改。四个兄弟接口的最终联合复核仍待交付，本报告不授运行资格。
