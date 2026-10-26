# 成员范围按需目录

日期：2026-10-26。基础提交：`30b402faeafc034052dc9b8c3a4bc55f6dd6f391`。状态：静态候选；SDK、格式化、分析、测试、实际账号/页面验收均 NOT_RUN，未推送或更新服务。

邀请原来打开前依次读所有档案及机构班级；权限编辑也强制等待两类目录，默认审计员等无范围角色因此承担无关等待和失败。本批两处入口均改为每个窗口独立 MemberScopeDirectories；编辑仍先重读最新 access，固定原版本/请求键，邀请立即开表单。无范围角色不读目录，儿童/教师单档案只读 subjects，教师班级只读 classes。

目录模块复用现有 scoped API/all 分页，区分 null 未读、失败与成功空 Map；同目录并发去重、缓存只留活动编号和名称，普通失败可重试，刷新只影响当前目录。字段长度对应当前后端 nickname 60、class.name 100；坏类型/重复/超长资料明确报本地 INVALID_MEMBER_SCOPE_OPTIONS，不伪装空目录。通用 API 仅增加这一中文消息，传输/写入逻辑与基础提交字节相同。

表单按当前角色/模式确保所需目录，加载不锁角色切换；错误在选项旁恢复。原 subject/classIds 始终保留，未读、失败与成功缺失分别给完整编号占位，不清空或默认换第一项。占位档案不可选，新提交仍须有效活动范围；目录内部补名称不等于换绑，旧选项/重试/验证回调必须通过原窗口和写入锁门禁。REAUTH_REQUIRED 保留窗口，可就近验证并显式重试；原scope拒绝或目录永久退役则隐藏内容。未知写入重试继续原正文，不依赖重读选项，也不会被读取错误解除保护。

同一目录实例仅属于本次编辑器，deactivate/dispose/包装层退出均 revoke；晚到响应不得回填、复活或继续分页。直接注入已读Map的组件路径仅在无目录对象时使用，保留已有组件测试与离线资料注入的明确来源。没有新依赖、轮询、后端路由或协议变更。

## 检查事实与接续

- 根核对两处入口、表单/目录接口、原版本和幂等边界；独立静读确认原引用占位需求及当前接线/用例。根最终复核并修正可恢复401与核心目录策略一致、失效占位不可选。差异、本批源码空白和本地文档链接已核对。
- 新增2条纯目录聚合用例，覆盖零预读、分页/并发/缓存/活动投影/不可变、单目录刷新、普通及坏资料失败重试、认证/权限失效、晚到停止续页；既有成员编辑测试内新增2条组件旅程，覆盖默认零读、范围加载中切回无范围角色可提交、退出阻晚到续页，以及原档案占位、REAUTH→显式GET恢复、缓存补齐不撤窗和未知写入后旧目录重试无效。全部 NOT_RUN，HTTP/身份为替身，不证明真实交互或后端授权通过。
- 未启动 SDK、格式化、分析、测试、构建、真实 API 或资源采样；未降低2 GiB门槛。没有重复执行既有私有进程/API资格检查，静态检查不证明可编译或全部成员功能稳定。

窗口恢复后接续已有离线依赖准备，格式化/分析本批7个Dart文件，先运行目录和MemberEditor文件，再按受影响边界核对成员浏览器旅程及真实邀请入口的零无关查询、当前版本保存与权限失效；必要时扩大，避免无关全仓库重复。稳定约定见 [SPEC](../SPEC.md)、[成员合同](../member-access-plan.md)与[项目记忆](../project-memory.md)。

本次源码摘要（静态候选定位，不代表运行通过）：

- `apps/guardian/lib/core/api.dart`：`b99f7e9ef9f74cf69fb40573d414b82114f76989ab865bf51d5d1bd501d83a24`
- `apps/guardian/lib/core/member_scope_directories.dart`：`dc28a34894ec8fbfb76eef1a8be221012ff1bf2995e518a69e65d8e08b705894`
- `apps/guardian/lib/ui/member_editor.dart`：`17f47bb2db9196996e6430bbb96a00e0bc2c531c507957b9e15639ca1b2bfa15`
- `apps/guardian/lib/pages/console_pages.dart`：`2d73d156d9fc238d5b7427c105a05ff8f23d409d01dbe90c747e6978d5ce9ebb`
- `apps/guardian/lib/pages/members_page.dart`：`7974b3c4e05a02e65bb9ba97425d704569ba82df954bc821496b10f323fadf84`
- `apps/guardian/test/member_scope_directories_test.dart`：`2230b281ac326aa64cd89c5b95e61f4d4d414166de012b73a7375bbb12c4d895`
- `apps/guardian/test/member_editor_test.dart`：`54bff9b1c0e40cdeacf5628d7a3264ae065865c721454c0b3c0ad6c8354ead92`
