# 设备连接检查队列：前后端静态阶段

日期：2026-10-26。基础提交：`0581894d8a000c1294a34557b128afa38dcd1670`。状态：源码与规格候选；依赖解析、Dart 格式化/分析、Maven、测试、构建及实际界面/API 验收均未运行，未推送或更新服务。

工作台已经指出需要检查连接的设备，但设备列表原先只能查看全部。本批补齐服务端 `connection=NEEDS_CHECK` 队列和两个受路由控制的筛选项，使优先任务直接进入对应设备，普通设备导航仍查看全部。

FleetReads 在现有租户/主体授权、ID 游标及 ORDER/LIMIT 前增加 ACTIVE 与缺失/严格过期心跳谓词，沿用概览的观察时限属性（缺省 180 秒，30～86400 秒），未新建配置、表或迁移。临界点不算过期；撤销及未确认注册不入队。Controller 仅接受缺省或精确 NEEDS_CHECK，显式空值和未知值返回 INVALID_CONNECTION_FILTER。返回 DTO、角色、分页上限与原游标规则不变。计数与列表不是冻结快照，心跳在读取之间更新时结果可以变化。

DevicesPage 复用 ResourcePage、原设备观察说明及 Material 分段按钮；筛选通过宿主更新 URL 后再读取，不在客户端筛选单页冒充全局结果。配对、设备详情和注册查询仍保留；注册查询现在共用表格 action 的防重、进度与错误边界，并保持不自动刷新设备列表。名称仅接收有效字符串，缺失回退完整编号，不回显任意对象。

固定路径从 OverviewAttention 经管理/只读宿主的原权限检查导航，Entry→Shell→ConsolePages→DevicesPage 传递筛选状态，页面 key 隔离筛选生命周期。登录回跳只额外放行精确 `/devices?connection=NEEDS_CHECK`；Session 保存路径和查询前先用既有白名单检查，未放行查询仍回退已知纯路径，不接受任意查询、片段或外部地址。没有改变认证、租户授权或 API 持久化防重复机制。

## 检查事实与最小接续

- 已独立静读路由/工作台/登录回跳接线，未发现可证明的阻塞；根会话核对 FleetReads SQL 与概览谓词、配置边界、设备复合主键、当前方法调用点及测试夹具。差异、新改源码空白与相关本地链接已核对，保留契约中既有 Markdown 换行；源码检查不计为运行通过。
- 新增 4 个待运行回归：2 个固定时钟 HTTP+SQL 用例覆盖心跳严格边界、状态排除、分页、租户及儿童/教师范围、坏参数；1 个 VM 用例聚合受控筛选/游标/只读/原行/操作锁和失权回调；1 个既有浏览器夹具用例验证管理工作台连接建议进入精确筛选 URL。已有回跳白名单及优先模型用例补充正反断言，不新增用例。全部未运行。
- 遵循用户静态完善安排，未启动 SDK、格式化器、分析、测试、构建、真实 API 或资源采样；2 GiB 门槛未降低。历史通过记录不覆盖本批源码，也没有将当前服务视为已更新。

窗口恢复后接续已有离线依赖解析，格式化/分析本批 14 个 Dart 文件；运行新增定向用例与受影响的已有设备入口、工作台优先/权限和登录回跳用例，再执行新后端 HTTP 队列测试。只在相关失败或集成风险需要时扩大，不重复无关后端或全仓库套件。权威 API 语义见[设备注册契约](../device-registration-contract.md)。

本次源码摘要（静态候选定位，不代表运行通过）：

- `apps/guardian/lib/core/api.dart`：`6c10dd0412d6b53dece1f134981cb3b8e31476ffd37a952da1f734180dddce87`
- `apps/guardian/lib/core/console_modules.dart`：`8dd2c761c9dda00b8fce0ac06b6edc8b08abf1201281bab0b1d740828896cf2d`
- `apps/guardian/lib/core/overview_attention.dart`：`e140d468e7e52a639e3d45dc428f2e9bff5699259a781c4c316d14af4d459e22`
- `apps/guardian/lib/core/session.dart`：`2482824d0a3266ec38fc89d9526f8002e401186c4054f052f6cc48f5dde88596`
- `apps/guardian/lib/main.dart`：`fbfd5a9c63fdab00d05787baedb91d2922d3c37a6c012af78fa64fc47125abaa`
- `apps/guardian/lib/pages/console_pages.dart`：`2d0dd38dfae4f1c108de3cb0d718acec047be0754c9116d9e720385ddbe41cc3`
- `apps/guardian/lib/pages/devices_page.dart`：`0001bad03a2755196d3b86619b071ba680024705f65a9404a9fc0f0ed48247a7`
- `apps/guardian/lib/pages/scoped_overview_page.dart`：`13c028369f5fa28687e9fa05facdf8bf20d8b40b288c74f7d92b478063448b56`
- `apps/guardian/lib/ui/shell.dart`：`773cc8a0293873937b68c0da2a1cb0b1e00c5e9e5280175c54dd7fd32b1f7b77`
- `apps/guardian/lib/ui/workbench_view.dart`：`7e20e47321a492f73d5ecf28bcb8722649bfd21380d4d84b9b56dc0f89cba23f`
- `apps/guardian/test/access_test.dart`：`adc416d1a816bf9f667c74ca263c18fc9084630a82fc96305d4e98958b521b16`
- `apps/guardian/test/dashboard_read_authority_test.dart`：`c0e9824445934958f6615c663f67a6fd835725e476310137e6eecba93c6edf3b`
- `apps/guardian/test/devices_page_test.dart`：`480ab44d3b61cd217a8c60b35ffeb849ffe5498d15eaed6db81f1912323bff9e`
- `apps/guardian/test/overview_attention_test.dart`：`9b743173d0460503cc33cb0d0460f392f46d14c280dc32a355b418d0753bc0f8`
- `backend/src/main/java/com/aimanager/fleet/internal/FleetController.java`：`a37e35a9120a332193bcf272321b06a0535e062c3aed8c3dd639230717b9cdae`
- `backend/src/main/java/com/aimanager/fleet/internal/FleetReads.java`：`03efc4ab40441c62f26e5f16249d42edd9b90d509e055dab62a634002bd70508`
- `backend/src/test/java/com/aimanager/FleetConnectionJourneyTest.java`：`efbf067c985a49bd093d0aa2fb987b3dd599a90823465553abd35b3a557270ea`
