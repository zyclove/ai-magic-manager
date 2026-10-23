# 设备组批量选择器改进候选

状态：**仅静态候选，未编译、未运行、未验收。Main/Git/服务未改动。**

## 最小方案

使用现有 Flutter Material 控件，保持原页面 API 与路由接口：在批量选择器中搜索已加载名称/设备编号/注册编号，清除搜索后回到输入框，切换仅看已选、清空选择草稿，并显示已选/显示/已加载数量。

不增加远端搜索、自动分页或全量全选。“加载更多设备”从筛选列表中独立出来，搜索无匹配也不会失去继续浏览的入口。跨页选择继续保留，确认时再核对单次 50 台、当前已加载设备/注册组合与加入模式 ACTIVE 约束。

布局沿用项目内已有 `UsageReportDevicePicker` 的 `AlertDialog(scrollable:true)` 与有限高度 lazy `ListView`，避免在固定最大高度 Column 上继续堆叠搜索/筛选头部和 Expanded。控制器/焦点在 dispose 释放。矮屏、大字及键盘弹出表现仍须真实视觉运行验证。

## 文件

- `before/apps/guardian/lib/ui/device_group_batch_picker.dart`：所读 Main 原始字节。
- `after/apps/guardian/lib/ui/device_group_batch_picker.dart`：唯一产品代码候选。
- `candidate.patch`：该一文件精确差异。
- `application-manifest.json`：before/after 字节数与 SHA256，明确 UNRUN。
- `prepare.py`：只产生此目录 before/after/patch/manifest 的一次性静态准备脚本，不运行 SDK。
- `delivery-pins.json`：最终交付文件 pins。

## 保持的边界

- 原 `current`/单向失权/取消/covered-route `finish` 接口。
- 原 `load()`、cursor 和失败恢复语义；新筛选不修改远端或已加载数据。
- 原跨页选择 Map 与 50 台上限；没有因搜索或仅看已选清空选择。
- 宿主捕获的组版本、注册 ID、原子提交、同一幂等 key 与不确定结果重试不在本候选修改范围。
- 新动作在调用时再次检查 current；旧保留回调不凭按钮过去的 enabled 状态行事。

## 待验证

未运行 Dart format/analyze、Flutter 编译/测试或浏览器，也未修改或准备测试。最少应覆盖跨页选择与筛选清除、仅看已选取消、零匹配继续分页、50 台旧回调边界、注册/停用变化阻止确认、失权/路由覆盖/取消、控制器销毁，以及矮屏大字布局。源码审阅与文件哈希不等于这些项目通过。
