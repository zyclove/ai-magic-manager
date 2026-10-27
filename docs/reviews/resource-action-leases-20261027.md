# 列表操作生命周期统一

日期：2026-10-27。基础提交：`6c5892cc25f6d9866d1e08b810ff944f2a023b11`。状态：静态候选；SDK、格式化、分析、测试、构建与真实界面验收均 NOT_RUN，未推送或更新服务。

## 实现

列表原有晚结果门禁主要保护回调返回后的刷新，未统一通知等待中的表单和详情。本批新增 ResourceActionLease，由 ResourcePage 每次 action 创建并最终释放，布尔创建/打开回调显式接收租约。租约绑定原资源代际、API、路径和宿主权限捕获，离开/来源变化/拒绝读取/owner失效时同步退役，帧后单次通知；完整子流程与路由结束后才释放。忙碌或打开子弹窗不会使原操作失效。

交互代际覆盖页面离开和owner失效，防止同键重挂或原条件恢复后旧事件复活；活动租约身份与代际防止旧 finally 解锁新操作。正常重挂不为此增加列表读取。原 void 入口继续保留领域自己的授权与返回语义；设备登记查询仅同步公共 action 的回调参数。

应用登记/只读详情、时间计划创建/详情、策略创建/详情及预览接入租约交集，ConsolePages 捕获还检查当前宿主模块，避免元素复用后旧入口存活。策略预览的 parentAccess 同时继承外部有效期，包含最初日志读取与后续子窗口。应用身份详情返回 false 保留身份目录；分类仍是独立资源。

儿童档案页移除自建操作通知器，借用共享租约，父页面只退役、不释放。成员的详情/权限编辑/范围名称/历史及班级的学生编辑/转班/确认保持原领域scope与页面授权，并加入资源租约。班级仍先核对当前班级，再重建名册，原reviewBound在该读取之前捕获，避免重复列表读取。没有新增后端、依赖或数据结构。

## 核对事实与接续

- 静读资源代际、租约释放、旧finally与调用点；限定检索原布尔签名及 public action 调用，迁移相应源码/夹具。修正 ownerfalse→true 时旧事件仍可能复活的边界，推进交互代际。限定差异、空白及新文档链接已核对；不据此宣称可编译或运行通过。
- 新增2条资源聚合源码：退役即时性、单次帧后通知、未完成前仍可监听、晚true不刷新；同键重挂/权限条件恢复后旧事件拒绝、旧finally不解新锁且不额外GET。原资源用例仅迁移参数并保留原断言。
- 新增1条管理台浏览器旅程：应用503后同宿主切到档案，旧输入隐藏，捕获的旧保存/查询不再产生HTTP，当前目录不被刷新；既有晚档案GET与旧筛选回调继续覆盖。
- 新增1条策略预览旅程：账号、租户及父route保持有效，仅外部资源有效期退役，交付迟到日志读取也不能打开私有预览或产生HTTP/发布。以上均为合成替身，所有用例 NOT_RUN。

本轮没有运行 SDK、测试、构建、真实浏览器/API或资源采样。窗口恢复后沿既有离线准备格式化/分析本批10个Dart文件，先运行 resource_page_resilience_test.dart、console_creation_review_browser_test.dart、policy_details_scope_test.dart，再核对既有班级/成员工作流的取消、提交和核对边界；发现实际问题再扩大，不重复无关全仓构建。稳定契约见 [SPEC](../SPEC.md) 与 [项目记忆](../project-memory.md)。

源码摘要（仅定位静态候选）：

- `apps/guardian/lib/ui/resource_action_lease.dart`：`7e130f3a81cdfa1beb1c57cea8b5a8aaf92d36e2207b31bb2cf05b5fcaae6b21`
- `apps/guardian/lib/ui/resource_page.dart`：`c0396dc2e03ee726e1ede948124eff4c9adf527e7a4c3cbaa10825808821db57`
- `apps/guardian/lib/pages/console_pages.dart`：`8e7a0171e98e3e23b6ab3fc370c4bbaf3b92b3755a84311b2bca6f1be12b3c39`
- `apps/guardian/lib/pages/devices_page.dart`：`b460193cd41f8a730af2b1b69d525948858a6d7228b0b3dce442b163d1043950`
- `apps/guardian/lib/pages/subjects_page.dart`：`bd6447b289e9e34400bb208878a4f95ef78554d1ccd565b52c3fe96c81cf4639`
- `apps/guardian/lib/pages/classes_page.dart`：`4a051a188fc2c28a4b090caf7e0f463631c2ef6fd38ef11665bb3cc91d409a0d`
- `apps/guardian/lib/pages/members_page.dart`：`73f487dbddca784698ee10672bc0549971582f8d7878830ef42473f06ffce59c`
- `apps/guardian/test/resource_page_resilience_test.dart`：`f1fd2d5a6ffe44b8e7ed92a4133a9f4eee9b141d94140e57a67c059d0dc824b8`
- `apps/guardian/test/console_creation_review_browser_test.dart`：`499a01ac0d3711b1e38d13719d15e7516e6841446838791832f60af86817b53a`
- `apps/guardian/test/policy_details_scope_test.dart`：`1bb9abb534a8a62fbb78d998de0fdefd9bdd682a0a3b68a5781dac61b5bec590`
