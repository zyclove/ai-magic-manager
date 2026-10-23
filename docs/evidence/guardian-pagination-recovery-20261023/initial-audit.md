# Guardian 分页恢复变体静态审计

基线只读 Git HEAD：`c4cd13fc880846b517ce18e5d73fd6d99ad6dbde`。已修的 device_groups_page 与 device_group_batch_picker 排除出发现范围；本轮只读其关键标记校准已知根因。结论为 **2 项 P2 / 3 个生产路径**，均为源码触发路径，**UNRUN / 未渲染**。

## P2-1：加载更多恢复成功后仍显示旧失败，陈旧“重试”会截断累计页

**位置：** `apps/guardian/lib/pages/commercial_catalog_page.dart:89`（启动状态）、`:109`（成功状态）、`:123`（失败赋值）、`:269`（错误重试）、`:298`（加载更多）；同形实例 `apps/guardian/lib/pages/contracts_page.dart:131`、`:150`、`:162`、`:395`、`:428`。

两处只有 `more=false` 分支设置 `listError = null`；`more=true` 开始及成功追加时均不清它。失败 catch 设置 listError，但“加载更多”不受该错误禁用，恢复网络后能按原 cursor 成功。

合理触发序列（未执行）：

1. 已加载第一页或多页，nextCursor 非空；点击“加载更多”，发生一次网络失败，listError 被设置。
2. 网络恢复后再次点击仍可用的“加载更多”，返回有效且不重复的一页，rows 成功追加、nextCursor 更新、loadingMore=false。
3. listError 仍指向旧失败，因此已成功页面继续展示 FailureView“重试”。用户若点击这个陈旧重试，回调是 `() => loadList()`，默认 more=false；成功后 `if (!more) offers.clear()` / `reviews.clear()`，累计浏览页退回首页。

影响是错误状态与成功数据矛盾，并诱使用户丢失已加载页的浏览上下文；不是服务端记录删除或越权。目录和合同 UI 都可直接走到该序列，无需构造失效 cursor、旧回调或更改权限。

契约核对：CommercialCatalogRepository.list:20–29 与 ContractsRepository.list:64–79 各自传原 cursor，使用 boundedJson；boundedJson 的 timeout/client exception 会转为 NETWORK_ERROR。后台 CommercialCatalogService:209–218、CommercialContractService:247–256/290–301 都按 UUID ID keyset 分页。这些契约不会自动清 UI listError，也没有游标 TTL。最小修正方向是独立保存读取失败阶段/游标，重试对应失败页，成功读取时清对应错误；保留明确“刷新”从首页重读的语义。此报告未实施修正。

## P2-2：求助列表的追加失败“重试”实际清空已加载列表并请求首页

**位置：** `apps/guardian/lib/pages/help_requests_page.dart:55`、`:59`、`:63`、`:82`、`:167`、`:188`。

普通 append 失败时，catch 只设置 error，保留 requests 和 cursor；但 FailureView 的 `retry: load` 不记录失败是否 append，也不携带原请求 cursor。默认 `more=false` 会在发请求前同步执行 `requests = const []`、`cursor = null`，因此通用“重试”与页面已有的明确“刷新”成为同一操作。

合理触发序列（未执行）：

1. 用户已展开 2 页或以上求助，当前 cursor 非空；点击“加载更多”时网络临时失败。
2. 页面保留已有求助，但错误区的按钮名为“重试”（真实 FailureView:191–195），不是“重新加载首页”。
3. 点击该重试，load 默认 more=false，立即丢弃已加载页并将读取变为 cursor=null；若这次请求也失败，之前可见的求助全部变为不可见，用户必须再次回到首页并逐页展开。

影响仅是已加载内容/浏览位置丢失，不声称求助业务记录丢失。另一个“加载更多”按钮仍可重试原 cursor，但不消除错误区主恢复入口执行了不同操作的问题。明确刷新可以重启列表；普通追加失败重试应恢复失败页，不能无提示采用刷新语义。注意该 error 同时承载 acknowledge 失败，后续修复应区分读取/操作错误，不把未知确认结果误当追加失败，也不改确认请求。

契约核对：Api.page:322–338 将 null cursor 与有 cursor 的 GET 明确区分（limit=50），Api.send:313–318 将临时传输故障转为 NETWORK_ERROR；HelpRequestController:28–36 将 cursor/state 原样交 service；HelpRequestService:98–132 按 created_at/id 排序查页，并在 cursor anchor 不可访问时明确 INVALID_CURSOR。它特别注明另一个成人确认该 anchor 不会单独使其失效。本发现只需普通网络故障，**没有把 INVALID_CURSOR 称为过期**，也没有假设被确认就必须回首页。

## 搜索范围、排除项与限制

先以已修 picker 的 INVALID_CURSOR/cursorInvalid 和 retry 入口校准，再用 rg 在 Guardian pages/ui 中展开 `INVALID_CURSOR|nextCursor|cursor:` 及 load-more/retry 绑定，得到 22 个候选源路径，见 summary 的 searchHitInventory。随后只对高相关读取/恢复入口深入追踪，未声称 22 个文件全部逐行审核或全仓无其他缺陷。

- ResourcePage 已将 INVALID_CURSOR 清 cursor/标记后给出明确“刷新列表后继续查看”，普通 append 错误保留已加载记录并同 cursor 重试，不作为本轮问题。
- AuditView / AuditExportsView 保存失败目标 cursor 的重试闭包，并有明确重置/刷新入口；本轮未发现上述错误状态残留形态。
- ManagedAndroidReviewPage 保存 failedPendingCursor/failedPendingMore，另有刷新待审核，不因名字相近报告为同缺陷。
- ManagedExecutionController 在 more 开始清 listError，INVALID_CURSOR 明确转首屏读取；不报告同形陈旧错误。
- PolicyTargetPicker 的设备分页只凭“不特判 INVALID_CURSOR”尚不足以证明合理服务端触发：共享 ItemPage.validate 验 UUID，不能从 ItemPage 推导时间过期。该线索未提升为已证 P2。报表任务的 cursor 查询也不能一概套用 INVALID_CURSOR；实际 ReportJobService 先查询 owned anchor，需按实际错误与已有上一页入口单独判断。

本轮仅文本读取、哈希、只读 Git HEAD 和新 cache 报告写入；无代码解析器、候选执行、SDK、测试、formatter、编译、WinAPI/进程查询、网络、Main 或 Git 写入。没有新增测试、规则或运行器。未来回归至少应覆盖：追加失败后同页重试成功清错误；重试不丢累计页；明确刷新仍重置；加载中/权限变更/旧回调不额外发读。所有这些均 UNRUN，静态路径不等于编译或行为通过。
