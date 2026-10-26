# 班级名册返回、操作门禁与恢复

日期：2026-10-26。基础提交：`f85bfc97f62d973801c1d34e3de00388fdf34f9b`。状态：静态候选；SDK、格式化、分析、测试及真实身份/界面验收均 NOT_RUN，未推送或更新服务。

班级原改名/添加/学生详情/归档返回均重读，纯查看或取消会折叠名册分页与搜索；工具栏也缺独立操作锁。本批统一将表单/转班布尔值解释为 needsReview，而非成功。act 持有独立 acting/operation，先按原 capture 计算核对信号，再仅重读原班级一次；旧 ResourcePage 的 generation/id/filter 捕获即时失效，避免宿主重建前多读名册。移出/归档在实际发请求前置核对标记，详情捕获异常后关闭仍只GET，不重放写入；转班恢复信号不显示保存成功。只读和取消保留原数据，操作错误与班级读取错误分离。

ResourcePage 新增与 create 互斥的 onCreateChanged；false 保留原分页/搜索，true 只核对仍属于原范围的列表。原 void create 默认刷新路径保持，用于尚未提供明确结果的当前调用者，不另加状态框架。ClassesPage 创建与添加学生使用新入口；老师只读、班级状态、原请求键/If-Match和源/目标强版本继续由现有协议约束。操作锁不参与授权 current/capture，避免本次操作自我失效；旧工具栏/返回/筛选/分配教师入口复核原view，退役同步停止入口并帧后一次通知租约。移出确认使用已有只读 confirmLeasedAction，不扩展共享表单写入API。

ClassActionDialog 在回调前冻结原单字段正文，已有未知后普通认证/权限/4xx拒绝不解锁。412及既有结果过期/清除码停止旧请求重试，按实际错误保留只读草稿；classActionDraftText 在既有领域展示模块中保留原字段、已知名称/完整选项编号和其他字段，不读网络。未知关闭须原窗口二次确认，明确关闭不取消已提交操作，确认或终止返回 refresh:true。初始失权不新增监听，输入配置换绑退役；晚到和旧确认不能误关覆盖窗口。

## 检查事实与接续

- 根独立核对班级页面/短表单与2个浏览器旅程，目录/作用域捕获仍保留 selectedId+generation；独立静读共享创建信号和renderer接口。复核时修正一处测试夹具：失权需按真实宿主先重建，移除旧进行中动画，再等待晚到结果，避免把环境等待误作业务失败。限定差异、源码空白、本地文档链接及原换行已核对。
- 新增2条浏览器聚合源码，覆盖两页/搜索只读返回、取消改名无重读、重复打开单窗、原版本/key正常PATCH与一次班级/名册GET；页面key退役下独立覆盖通知保留、旧确认/工具栏无效、未知DELETE关闭后一次GET且不重发。HTTP/身份均为合成替身，不能代替真实后端/MFA验收。
- 复用原短表单基础字段校验，扩展原未知及冲突用例覆盖503→401→成功、原正文不可变、412/409过期键/410清除后保留草稿并阻止旧submit；新增1条未知关闭/撤回/旧确认/覆盖窗口用例。共享列表新增1条创建信号聚合，覆盖取消保留页、重复回调只执行一次、true单次GET及晚到失权不读；renderer新增1条纯展示用例。全部 NOT_RUN。
- 按用户安排未启动SDK、格式化、分析、测试、构建、真实API或资源采样；未降低2 GiB门槛，也未重复既有私有进程资格检查。静态核对不证明可编译、实际布局或全班级功能稳定；未修改后端、依赖、迁移或部署。

窗口恢复后接续已有离线依赖准备，格式化/分析本批8个Dart文件；先运行短表单、ResourcePage、草稿展示和新班级浏览器文件及既有受影响提交门禁，再检查真实创建/添加/转班双版本/归档、教师范围与窄屏。无新增问题不重复无关后端/全仓库测试，历史结果不覆盖本批。稳定规则见 [SPEC](../SPEC.md)、[机构工作流](../organization-workflow-plan.md)与[项目记忆](../project-memory.md)。

本次源码摘要（静态候选定位，不代表运行通过）：

- `apps/guardian/lib/pages/classes_page.dart`：`e80aafe11ea78e9633d46136121434acc049f3519f6d137f0848a2c81608de30`
- `apps/guardian/lib/ui/class_action_dialog.dart`：`8cd07988b56c3aac8dc70ebfb00f8796908909071a4ffa524e814da2b91dab0f`
- `apps/guardian/lib/ui/resource_page.dart`：`d5befd9e512dc70e5726764b9659d2575bf7af0d3d6be30470942a3ca0feb0e5`
- `apps/guardian/lib/ui/editor_draft_text.dart`：`2290045ac5c5f832726d6aed4d0ea2c2deda64366f428897ade41068ea544b11`
- `apps/guardian/test/classes_page_workflow_browser_test.dart`：`012cc1fb11651f867be63a9525d907a9f39d180687c6a39a4ecf7c549c9fda19`
- `apps/guardian/test/class_action_dialog_test.dart`：`a7c8b06ff154c9966136adc518079467d390bee236edfdba91a6ced5c60e5514`
- `apps/guardian/test/resource_page_resilience_test.dart`：`ce9fd2c2a9b5c075dd80acfdf24b7b8468235068dfe93016950b0b5e126b759d`
- `apps/guardian/test/editor_draft_text_test.dart`：`5772d166caae8b124cc7bd2153d1c79d4564682ea927f332ab4a2757ddb07691`
