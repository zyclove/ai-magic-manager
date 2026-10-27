# 儿童档案归档查看与操作简化

日期：2026-10-27。基础提交：`9d2f7f65e2ef05b85238c0ba71520ed4c7a38330`。状态：静态候选，运行验收 NOT_RUN；未推送或更新服务。

## 变更

档案列表原来只读取活动档案，归档后无法在管理台核对。本批将列表编排提取到 SubjectsPage，复用 ResourcePage、既有主题与后端管理查询。成人管理员默认读取活动档案，可用一个“包含已归档”筛选查看归档状态；其他角色继续读取服务端授权的活动列表，不展示管理筛选或创建入口。未增加后端、依赖、轮询或数据迁移。

管理详情重新 GET 当前状态，仅 ACTIVE 可编辑或归档，ARCHIVED 及未知状态只读。归档确认补充昵称、完整档案编号、年龄段及影响；明确归档后可查看且不会自动解除设备管理。纯查看和取消保留原分页/搜索；原提交、版本与未知结果核对行为继续沿用，不将关闭解释为成功或自动重发。

筛选递增视图代次，往返相同值也不能复活旧行或工具栏事件。独立操作锁防重复入口，详情读取期间显示进度。每次操作持有独立 lifetime，页面离开或失权立即拒绝旧操作，帧后通知窗口，回调及路由完全结束才释放通知器；宿主 ConsolePages 元素被新模块复用时，旧详情响应不能在新模块打开弹窗。Dashboard 测试替身仅同步 subject 的命名参数签名。

## 核对事实与后续

- 静读 SubjectManagementController/Service：管理列表和详情限制成人管理角色，响应禁止缓存，列表支持 includeArchived，状态为 ACTIVE/ARCHIVED；普通档案读取只包含活动且受原范围授权。本批不修改这些后端契约。
- 核对生产接线、操作租约、筛选往返、未知状态及原 POST/PATCH 版本路径；限定差异、源码空白与新增本地文档链接已静态检查。静态检查不证明编译、可访问性或运行功能通过。
- 既有浏览器用例适配管理 GET 和 state，保留取消、分页/搜索、未知写入核对及不重放断言，增加归档确认身份断言。新增2条聚合源码：归档筛选/只读详情/旧回调失效/降为教师后的接口边界；同一宿主元素从档案切换应用后释放旧详情 GET，不弹旧窗口、不刷新应用或写入。HTTP 与身份均为合成替身。
- 本轮未运行 SDK、格式化、分析、测试、构建、真实 API、浏览器验收或资源采样，未降低既定资源门槛。4条浏览器用例及本批 Dart 改动均 NOT_RUN；历史通过不能覆盖本批。

窗口恢复后，沿现有离线准备格式化/分析本批4个 Dart 文件，优先运行 console_creation_review_browser_test.dart。Dashboard 文件仅签名适配，不因该适配重跑无关回归；若分析或相关用例发现边界问题再扩大。后端未变，不重复其全量验证。稳定约定见 [SPEC](../SPEC.md) 与 [项目记忆](../project-memory.md)。

源码摘要（仅定位静态候选）：

- `apps/guardian/lib/pages/console_pages.dart`：`ff50d4366876445dda1bf32572bc4c5ed89a339318ebeb0f557f3a6fdc448e38`
- `apps/guardian/lib/pages/subjects_page.dart`：`4a960f4d016a7d3aa487971ee737f123ecb100b9d5c8d9ff978fa53e96707f50`
- `apps/guardian/test/dashboard_read_authority_test.dart`：`b54cefa5908b6f62fbd1cef3c41f22110e60a322805a0c6d2b7e055dc10d55e8`
- `apps/guardian/test/console_creation_review_browser_test.dart`：`6d56b07bd68083e812f75a9342fc8ae4039315250358b4b85fdf668cf97270a0`
