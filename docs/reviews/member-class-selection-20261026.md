# 成员班级选择与必填提示

日期：2026-10-26。基础提交：`ea2e2331d666e33d91b6e35108ff9775f2d91857`。状态：静态候选；SDK、格式化、分析、测试和实际界面验收均 NOT_RUN，未推送或更新服务。

前一阶段 directoryReady 同时判断目录已读与选择有效，使教师邀请尚未选择档案时按钮被提前禁用，原有必填提示用例无法触发保存校验。这是源码与现有用例的静态推导，没有执行失败证据。本批 optionsReady 仅管目录读取/加载状态，首次提交仍由原 Form validator 校验必填、上限与不可用引用；未知正文重试继续原保护，不受新选项验证影响。

班级多选从原全量Column提取 MemberClassPicker，使用现有Material TextField/FilterChip/CheckboxListTile；仅管理本地名称/完整编号搜索与“仅看已选”，不读网络、不另存选择。候选始终是 options.keys 与父 selectedIds 的并集，目录缺项保留完整编号并可取消。选择仍由父Set、field.didChange和原校验管理；父每次重检当前角色/范围模式、scope、写锁、最新目录与50上限，旧档案模式回调也不能改写其他模式。

行放入自有ScrollController、primary:false、最大240高的ListView.builder，避免一次构建全目录；小列表可自然收缩，行无固定itemExtent，名称和完整编号分行。搜索/筛选不裁剪选择、不全选或清空范围；满50时阻止新增且保留取消。输入owner与展示view分别推进，允许同帧连续文本事件，已改变筛选/目录/选择或禁用/卸载的旧回调仍受限；只重置自身列表位置，不操纵父滚动。

## 检查事实与接续

- 根核对原必填旅程、父表单提取与新组件；独立静读核对接口、受控Set、Form回填、模式门禁、连续输入与fixture一致，未发现明确静态阻塞。源码空白、限定差异、本地文档链接已核对，原MemberEditor唯一CRLF保留。没有修改目录/权限/版本/幂等/网络实现。
- 未新建重复的必填用例，接续原 member_editor_test.dart 的 teacher invitation 场景。新增恰好2条组件聚合用例：500项有界懒建、名称/编号查找、跨筛选选择与缺项移除；同帧连续输入、同步冻结、旧view/换目录/启停/卸载回调与50上限。全部 NOT_RUN；测试拟检查构建数量与控件交互，不代表真实性能或可访问性验收。
- 按用户安排未启动SDK、格式化、分析、测试、构建、API或资源采样；未降低2 GiB门槛。静态核对不证明可编译、窄屏/大字号体验或全部成员功能通过。

窗口恢复后接续已有离线依赖准备，格式化/分析本批3个Dart文件；运行新picker文件和原MemberEditor受影响旅程，再检查窄屏/大字号与真实目录中的搜索、失效编号、权限和未知提交锁。无新问题不扩大至无关后端或全仓库套件。稳定规则见 [SPEC](../SPEC.md)、[成员合同](../member-access-plan.md)与[项目记忆](../project-memory.md)。

本次源码摘要（静态候选定位，不代表运行通过）：

- `apps/guardian/lib/ui/member_editor.dart`：`a8fe6aabb7eeac94d657d881bf4b3920c15a4fca5c592dd0b54f8211fb024025`
- `apps/guardian/lib/ui/member_class_picker.dart`：`6b9c2e82f8d648ed631eba0bcdb23cbfe7970d0dfad012571048a223faa33526`
- `apps/guardian/test/member_class_picker_test.dart`：`6969a941e33384391bf045666120b7bcc2f9b852b373b3a2e79cb5e05eeaf44a`
