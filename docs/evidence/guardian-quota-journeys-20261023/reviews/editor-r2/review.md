# QuotaPlanEditor r2 独立静态审核

## 结论

固定 Editor r2 未发现静态阻断；可供 Root 与实际最终六文件接合审查。结论针对 after 28314B/15f1814e…24b6a。不是编译、渲染或行为通过，所有场景 UNRUN；无运行授权。

已完整人工读 r1 与最终 r2 源码、原完整补丁、r2 author review 和嵌入的全部 delta，并对完整补丁及 r1→r2 delta 做纯文本逐行位置/context/计数和逐字重建。没有执行候选或业务谓词。

## 原 owner、路由与异步完成

- 47–159 固定初始 widget owner 和原 ModalRoute。accepted 要求 mounted/active/notclosed/原 lifetime.active、自己 active/available 及 sticky access；current 另加 route.isCurrent。deactivate 同步使原 lifetime 永久失效，activate 不恢复它。旧 save/cancel/reauth、复制星期、选择/删除等入口先复查这些门槛，关闭先 markClosed 再 finish。
- 101–113 成功可 finish 原 OwnedDialogRoute<void>，不会依赖覆盖窗的 Navigator.pop。新用户 cancel 等仍要求当前 route；安全失权关闭只核原 route current/available，所以失权窗口仍可关闭。普通非 Owned fallback 在 covered 时只结束本地状态、不弹覆盖者；生产调用必须使用 Owned<void>。
- 127–146 先绑定 route/access 后再 postframe 初读日历。calendar 请求结果/错误同时核 accepted、原 subject 与 generation；关闭、失权、subject 改变均不能让旧读重新安装。滚动错误提示另核 current。
- save 385–435 与 r1 全部 1611B 逐字相同。新保存先 canAct，固定 operation/busy 后提交；合法已发送的保存成功只核 accepted+同 operation，允许 covered-success finish 自己；晚成功/错误/finally 在结束、失权或 dispose 后无动作。未知结果仍冻结原 pending body；重复重试不重新构造内容。
- 初始 Main→r2 的提交数据构造 731B、UTC civil effectiveDate getter 379B、七天映射均逐字保持。version/request key 仍由生产 Plans caller 固定；没有更换 endpoint/If-Match/幂等或时间/额度规则。

## override 与 r2 生命周期修正

293–306 在第一次 await 前同步设置完整 overrideOperation 锁，固定 calendar object、subject 和 generation；原 permitted 定义与最终 unlock 保持。save/cancel/编辑入口在此期间被既有 lock 拦住。

307–309 只创建一次局部 childAccess，覆盖整条 date→minute form 流程。它的 hasAccess 仅引用原 permitted，childPermitted 是原 permitted && childAccess.permitted，没有互相递归。323 日期 UI 与 361 formDialog 只听 childAccess.changes；378 的 dispose 位于两个被 await 的 owned route Future 之后，且早于原条件 unlock。它可在 Editor 自身销毁后继续发布原 owner 的失效，独立子窗重建不再直接重新 add Editor 已销毁的 lifetime/access merge。原 changes 只被该 binding 一次订阅；最后 removeListener 符合本机 Flutter 允许 disposed 后移除的契约。

r1 曾把 Editor 的 raw changes 暴露给独立子窗；本轮按 Root 要求修正该清理边界，没有把未经运行的任意外部 remove 场景称为已观测故障。生产 Page key 更换/独立 root dialog 存活的真实入口已文本核对；本结论不声称运行时所有重建顺序均已验证。

314–348 的成熟 DatePickerDialog 保留默认日历/输入模式、日期范围和帮助文字。局部 Navigator 的 Page 接收原 DatePickerDialog 最近 Navigator.pop；onPopPage 仅在 childPermitted+date route available/current 时完成该 dateOwned，返回 false 不弹局部页面或不相关覆盖者。实际 Flutter 3.22 的 DatePickerDialog、Navigator onPopPage/Route.navigator、PopScope.onPopInvoked 源码接口已按文本核对；未发现明显类型/参数冲突，不等于 Dart 编译证明。

日期返回后与表单返回后均复查 childPermitted/current，再安装例外；输入额度仍 0–1440 分钟、最多 60 个日期，取消不安装值。失权 date 只显示安全关闭，不能误关 cover。449 的说明把已发送操作引导回原工作空间核对结果，避免误查新工作空间。

## 交付与联合合同

最终 6 件成员精确，5 delivery 与 before/after/fullpatch/review/Main descriptors、6 个最终依赖 pin 匹配；历史 r1 的 5 delivery 原件及其 delivery pin 保留匹配，2 个 SDK 源文本 pin 匹配。完整 Main→r2 23-hunk patch 和 review 内 r1→r2 5-hunk delta 均重建同一 after 的每个字节。Main before 与 HEAD bb93c0b 的 raw Git blob f09858e86f7c2c74b50661aa3474f71b4ed60611 相同。

已核实际 Plans r2 9abbb08e 的 optional accessChanges/hasAccess、Owned<void> 以及不含 top gate 的 accepted 接口；ResourcePage 50ca974f 的 UI-only canInteract 与 helper c68c7457 接口分别已有独审。Root Page/host 的最终独立审阅和六文件应用由 Root 接合，不能把本报告当作其源码已编译或整个联合运行通过。

## 未运行边界

五个既有纯 Editor 测试源码保持，0 新测试；全部未运行。实际父页/Editor 销毁且子窗存活的重建、DatePicker 键盘/焦点/返回/布局、失权时已发送写的结果核对、权限 ABA、covered 成功和所有所列交互仍 UNRUN。没有宣称任意保留的 Flutter 私有 disposed 回调都安全。

仅文本/hash/JSON/只读 Git 与自有报告写入。未执行 SDK、测试、AST/解析器/formatter、候选/helper/predicate、WinAPI/进程/网络；Main、Git、测试、原候选和历史证据未改。