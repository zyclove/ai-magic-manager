# 时区搜索输入：静态阶段

日期：2026-10-26。基础提交：`0d311ea91ad1f23ff3e98a0251206270cdc2a469`。状态：源码与规格候选；离线依赖解析、Dart 格式化/分析、测试、构建及实际渲染验收未运行，未推送或更新服务。部署帮助已独立提交，本记录只覆盖时区输入。

工作空间创建/设置、每日额度与时间计划先前都要求手填时区编号。本批复用项目已锁定 timezone 0.9.4 与现有 Material RawAutocomplete，提供常见中文城市和 IANA 编号搜索。选择只写入编号，原输入不自动替换；目录外的手填值仍由原服务端校验，不把建议目录当成后端支持或设备执行证明。

TimeZoneField 借用宿主控制器、自有焦点和弹层滚动；目录按需加载且缓存公共标识，不为输入增加网络请求，不安装或升级依赖。已核对本地 package 源码：数据库是 final 单例，初始化 clear/add 同一对象；首次加载会重设 local，因此组件在原 local 可读取时保存并恢复，已有数据库不重载。建议最多 12 条；键盘高亮通过本弹层专用 ScrollPosition 滚入视野，不滚宿主页面或操作 Navigator。

FieldSpec.timeZone 显式选择该输入，原必填校验、最大长度与提交字段保持。通用表单和计划编辑器同时提供可视 enabled 与同步 canInteract，旧选项/键盘回调在 RawAutocomplete 改控制器之前核对；提交中、结果未知、失权、禁用、控制器替换或移除后的旧事件不能改原输入。原版本、请求键、未知结果冻结与精确重试规则不变。

## 检查事实与最小接续

- 已独立静读本地 Flutter/timezone API、字段实现与宿主接线，根会话核对新增键盘滚动、缓存和通用表单原提交保护；未发现可证明的阻塞。差异、新改源码空白与相关本地链接已核对。
- 新增恰好 3 个待运行 VM widget 回归：城市搜索只写编号/有界建议/靠后键盘高亮可见/保留目录外手填值；同步活门、禁用、重新启用和移除后的旧事件拒绝；真实通用表单在下一帧前冻结旧选项、503 后仍以 UTC 原值重试。全部未运行；既有时间计划和额度用例保留。
- 按用户安排没有启动 SDK、格式化器、分析、测试、构建、真实 API 或资源采样；2 GiB 门槛未降低。静态核对不证明可编译、实际建议位置、无障碍或业务验收通过，历史通过结果不覆盖本批源码。

窗口恢复后接续已有离线依赖解析，格式化/分析本批 7 个 Dart 文件，运行新增定向用例与受影响的既有计划编辑/草稿恢复、工作空间及额度表单用例；不重复无关后端或全仓库套件。稳定交互语义见[应用/时间/策略契约](../policy-application-schedule-contract.md)。

本次源码摘要（静态候选定位，不代表运行通过）：

- `apps/guardian/lib/ui/time_zone_field.dart`：`a83fa920b8d8ae5c9a02092bbc53dea66dafee0bccdb08f5dd1beba417b31fbd`
- `apps/guardian/lib/ui/design.dart`：`e4744cf4c4d94d611381a3a240269dfec483dd6d9253ca7b24ffa7683d85a098`
- `apps/guardian/lib/pages/console_pages.dart`：`233d8af90e48c94dd0436ad8f5b7df068b0f4a679c81204a3e44c0593f851e3f`
- `apps/guardian/lib/pages/quota_page.dart`：`5a28a69cbccf238ef3e531f3a70bd3063f86549b242b60876ab5eeab6548504e`
- `apps/guardian/lib/pages/editors.dart`：`0d1bffeb4dcf81322027c2b8988d4b26bf26368548b2390ca55ec967cadac389`
- `apps/guardian/test/time_zone_field_test.dart`：`d0d387688469f0b169c4781d7b675c7fcf4bc099f39bf63af83585be878eeb0d`
- `apps/guardian/test/dialog_submit_guard_test.dart`：`2f43f3ca5beecd104df24049252f51dee8cbf28535d7a0e64b56d117d85de241`
