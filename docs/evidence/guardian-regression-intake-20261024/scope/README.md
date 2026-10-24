# 完整181入口分批计划（静态、未运行）

| 范围 | VM建议 | 必须浏览器 | 外部HTTP夹具 |
|---|---:|---:|---:|
| Guardian142 | 103 | 39 | 0 |
| 全部package37 | 37 | 0 | 0 |
| 单列Spring工具2 | 0 | 0 | 2 |
| 合计181 | 140 | 39 | 2 |

`scope.json`逐根列路径/SHA/平台/模块/唯一批次；每根恰分配一次。80可见用例/7selector只是39个浏览器入口的一部分；editor_submit_guard明确@TestOn(browser)，且不在该7selector内。181是文件入口数，不是所有测试case总数。所有计划仍UNRUN，未创建运行器或执行授权。

## 首批：保守两份现有VM测试

在当前冻结的 `src/apps/guardian` 目录，建议新单次测试窗口使用：

```powershell
& 'D:\softwares\flutter\bin\flutter.bat' --no-version-check --suppress-analytics test --no-pub --concurrency=1 --reporter=json test/workbench_view_test.dart test/dialog_submit_guard_test.dart
```

保留135秒命令/180秒外层，不延长case超时。此处没有实测冷编译耗时，不能保证完成；若超时按失败处理，再以更小固定批次重绑，不能宣称通过。下一相关VM批为action_details_route_ownership、quota_plan_editor、audit_test、widget_test。editor_submit_guard单列Chrome批。

本机Flutter3.22命令源码确认默认VM后端叫tester，允许tester/chrome；不要传`--platform=vm`。浏览器现有入口沿用固定版本`--platform=chrome`（该选项已标deprecated），须绑定本地Chrome及独立任务profile。本计划不换框架。

## 直接相关入口与夹具

- workbench_view：本地OverviewSummary和回调计数；已有目标/权限/去重/忙态/时间/窄屏断言，但新“失败仍显示快捷操作”并无专门断言。
- dialog_submit_guard：Completer和本地MaterialApp，覆盖重复持有回调只发一次。Shared EditDialog新412分支没有专门现有case；widget_test覆盖旧未知结果/输入校验，不能冒称412已验。
- editor_submit_guard：浏览器Session子类、MockClient与本地diagnostic夹具，覆盖四编辑器重复提交；无需真实IdP/后端。
- action_details_route_ownership：本地routes/ValueNotifier/Completers，覆盖所属路由完成、cover保留与旧回调。
- quota_plan_editor：本地固定日历/回调，无HTTP；五个原声明覆盖目标、校验、payload和未知同body重试，不覆盖全部日期例外await路径。
- 审计实际入口是audit_test.dart（不存在audit_view_test.dart）；MockClient DTO覆盖游标重试/筛选/重新读详情/失权/手机布局，无需Spring。

## 全包范围与可执行输入前提

37包含device_access11、device_cleanup4、device_identity4、device_observation2、device_policy6、device_reports1、device_operations5及example1、usage_report_ui2、usage_reporting1。JSON按各自pubspec区分Flutter测试和纯Dart package:test；后者使用已声明package_config直接启动test/bin/test.dart，避免自动pub解析。11个项目（含Guardian和example）的现有pubspec/lock/config均已读取并核自身根。当前受限只读环境对PubCache test入口的一次stat拒绝，未升级权限或宣称runtime已可读，实际启动前须Root绑定可读runner。

28个额外package测试确在七root410冻结之外；不能拿Guardian快照冒充完整181执行包。即便在七root内的包测试，也没有独立冻结的模块package_config；需另绑/重定位各模块config与依赖，或固定当前commit的模块输入后运行Main模块。没有复制源码或改旧清单。文件数据库使用任务本地TEMP/TMP；若测试自建127.0.0.1临时HttpServer，是本地夹具，与下述预置Spring工具不同。普通回归不打开截图capture开关，不读取特定系统字体或写历史.local截图目录。

## 两个Spring工具必须单独预检

GUARDIAN_DEVICE_MANAGEMENT_HTTP_FIXTURE与GUARDIAN_ENROLLMENT_HTTP_FIXTURE均要求testOnly、显式loopback apiRoot、准备好的身份/业务记录。它们实际撤销设备或创建/取消/确认enrollment，dispose不回滚服务端；使用独占新fixture或明确外部重置，不能自动混入单元测试。JSON记录前置字段类别与副作用，不含凭据值。

这里只读当前181/80契约、源码与pubspec/config，继承已封静态平台分类，不等于编译兼容证明。未运行SDK/测试/AST/进程/网络，未写Main/Git/原契约，未新增测试、资格或执行框架。JSON后续分组只是初始命令集合，未保证每批实测耗时；所有实际批次须单独固定输入、原资源门槛与结果核证。
