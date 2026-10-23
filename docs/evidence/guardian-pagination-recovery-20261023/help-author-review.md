# 求助列表分页恢复候选 r1

**STATIC_CANDIDATE_UNRUN / NOT_APPLIED。仅一个生产文件；没有测试、渲染、解析、格式化或执行资格。**

本候选对应分页审计 P2-2，并按 Root 补充处理服务端已明确拒绝的 INVALID_CURSOR。Main raw 与 before.dart 完全相同；after.dart 是候选，不是已部署页面。完整差异在 help-requests-pagination.patch。

## 最小变化

1. 新增 pageError 专用于追加读取。more 开始只清 pageError，不清首页/确认操作的 error；普通分页失败写 pageError，保留 requests、cursor 和 uncertain。retryMore 在调用当下检查 current、!loading、!loadingMore、非空 cursor 与仍有 pageError，再以 more=true 重读原分页。列表底部显示分页 FailureView；该错误存在时隐藏重复“加载更多”，不再把普通追加重试交给全局首页刷新。
2. more 入口同样检查 current、!loading、!loadingMore、非空 cursor，拒绝加载中旧回调；成功追加不会清 uncertain，因为它没有重新读取已有记录。clear uncertain 仍仅保留在原 fresh 成功处，既有 fresh 语义未扩展为“所有未知确认竞态已解决”。
3. fresh load 继续允许初始化 loading=true 和显式刷新。它同步置 loadingMore=false、清两类读取展示错误、按既有语义清当前列表/cursor，并使用原 generation++ supersede 旧 append；旧 append 的返回/catch/finally 因 generation 不同不能回写或解锁新请求。
4. 仅当 append 收到 ApiFailure.code=INVALID_CURSOR 才清 cursor；保留现有 records 和 pageError。此已知分支用单 Notice 说明分页位置不可继续使用，并给出明确“刷新求助记录”按钮，不再叠加 FailureView 的重复警告/普通重试。没有称其“过期”。refreshAfterPageFailure 必须在调用当下仍 current、非 loading/loadingMore 且当前 pageError 仍为 INVALID_CURSOR，才执行原 fresh load；成功/刷新后旧按钮回调不再清新页。
5. 普通分页错误的 reauth 仍先检查 current。全局“刷新”和原 error 区域（首页/确认结果待核对）的入口及警告文字逐字保留。选择过滤器仍执行 fresh load。确认操作 acknowledge 方法、POST/version、发送/不确定集合逻辑、scope/current、init/dispose 与所有行展示文字逐字不变。

## 真实契约与边界

Api.page 以 cursor=null 表示首页、有 cursor 表示明确后续页，并在传输/响应前后核范围；本候选不改变 path、limit、current/scope 或 Api。HelpRequestService:98–132 会查询可访问 anchor，找不到时返回 INVALID_CURSOR，并注明另一个成人确认 anchor 本身不会使其失效；本候选未引入时间过期推断。设备确认仍是原 acknowledge 接口和 If-Match/version；没有改写写入流程、幂等约定或后端。

追加失败与确认不确定可以同时展示：重试分页不会抹掉确认 error，也不会把 uncertain 锁解除。fresh 成功仍照既有实现清 uncertain，本轮未重构 fresh 与确认的写后读并发、重复确认弹窗或其他业务竞态；不宣称这些已全部解决，也未顺手改变它们。

## 静态场景推导（全部 UNRUN）

- 初始 loading=true：fresh 入口正常执行，不被 more 专用 guard 拦住。
- 已加载多页 -> 普通 append 网络失败 -> retryMore：保留 rows/原 cursor、仅追加新页；未知确认 error/uncertain 保留。
- retryMore 同步进入 loadingMore 后重复点击：load/回调忙碌 guard 拒绝重复 GET；成功后 pageError=null，旧 retryMore 无操作。
- append 已知 INVALID_CURSOR：cursor=null、records 保留、只显示一条分页说明和明确刷新按钮；旧 retryMore/普通 more 回调因无 cursor 无操作。
- refreshAfterPageFailure：当前已知错误且非忙碌才 fresh；立即清 pageError 后，旧刷新回调无操作，避免清掉成功后的新页。
- fresh 刷新或切 filter supersede 旧 append：原 generation 守卫阻止迟到成功/错误/finally 覆写；fresh 失败仍保留原全局错误恢复语义。
- scope/current 失效：more、两种恢复方法和原请求/回写范围检查拒绝动作；本候选没有放宽 Session 或 actor 范围。
- append 成功不解除旧确认不确定锁；fresh 成功保持原清锁语义。此推导不是写后读全竞态证明。

本轮只写该新 cache 目录。没有改 Main、Git、旧审计或其他候选；没有调用 SDK、测试、formatter、代码解析器、候选、WinAPI/进程查询或网络。须独立审阅后由 Root 决定是否应用；后续行为验证另排资源窗口。
