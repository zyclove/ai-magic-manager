# 产品目录 / 合同分页恢复候选：独立静态审阅

**结论：本两文件候选未发现静态阻断。全部场景 UNRUN / 未渲染；无 Dart 编译、行为验证或执行授权。**

已先 rg 实际库存，再读取完整 6002 字节补丁、作者说明、pins、两份 after 的列表/恢复/详情/写后刷新关键上下文，以及实际两个 repository。对完整 before/after 做原始文本比较，确认详情/写入等未改区间逐字相同。原问题审计由本审阅者完成；本候选实现由另一作者完成。

## 修复及边界证据

- 两页均新增显式 listPageFailed。每个当前失败按真实入参 more 保存模式；开始与成功都清 listError/模式，不从 rows.isEmpty、已有 selection 或 nextCursor 是否为空猜测失败是首页还是追加。累积页存在时一次 fresh 失败，重试仍是 fresh；append 失败则保持原 cursor 与累计 rows。
- 新 retryList 调用当下核 mounted/current、当前 listError 非空、!loadingList/!loadingMore；据当下失败模式调用 loadList。第一次重试同步清错误并置相应 loading 后，重复旧回调即拒绝；成功或明确刷新已清错误后，旧 retry 同样不发读。成功追加不再保留原 P2 的陈旧 FailureView。
- more=true 的入口新增 loadingList guard，UI load-more 也同时禁用 loadingList/loadingMore，因此 fresh 进行中不能以旧 cursor 发 append。fresh 入口没有全局 loadingMore 禁止；仍会 listGeneration++、同步 loadingMore=false，允许显式刷新与既有写后读取替代旧 append。
- 原 generation/listGeneration/current/mounted 响应及 catch 守卫保留：先发 append，再发 fresh，旧 append 持有旧 listTicket，其成功/失败不能回写 fresh 结果或 loading 状态。并发 fresh 仍以原 listGeneration 规则决定最新请求，本补丁未改变这些既有语义。
- current 谓词全文与 before 字节相同；scope-denied 只新增清 listPageFailed，不放宽 actor、tenant、role 或权限。select/history/comparison/edit/action 等方法区间全文相同；从 _detail 开始的详情与 dialog 尾部全部相同。选中项、历史、版本、原写入参数与 key/未知重试语义没有被列表修复改写。
- 目录 edit/action 和合同 submitEvidence/act 的 await loadList() 写后刷新调用全文保留；fresh 仍能 supersede append，因此没有以“防并发”名义吞掉写后刷新。实际 CommercialCatalogRepository/ContractsRepository list 仍明确传 cursor，保留 boundedJson 的 current 与响应校验；写入接口和 Api 版本/标识构造未改。本补丁没有宣称给 UUID cursor 增加时间过期策略。

## 固定原件与差异

实际 candidate 精确 8 文件（7 delivery 项加 delivery 自身），七项摘要/大小均匹配，before 两文件与当前 Main raw 逐字相同。对 before/after 全文重建统一 diff，与交付 patch 原始字节相同，无隐含额外生产变更。

- catalog after：22761 B / `6e948a6881e68838eaf838917259a663849fb66107a3037ca093c89444e45819`。
- contracts after：35518 B / `4737b6672e373e0e08d90ff00373725b14faaac8f8529964bfe48546e1ca258c`。
- patch：6002 B / `ce3754c3436786b62b45c280afbe082d675801cf9c93bab99ed036971b45b278`。
- delivery：1898 B / `f0b02969529d849349d87907ab90570d05f5b872d5200218e3fdcb56b7434b93`。

## 审阅限制

静态源路径包括：append失败→同cursor重试→成功清错；fresh失败且保留旧行→仍按fresh重试；旧retry成功后/刷新中无动作；旧append被fresh替代；scope改变与迟到响应。全部未执行，未渲染，不将逻辑阅读称为通过测试或编译。

本轮仅文本读取、字节/hash比较和新 cache 报告写入；无 AST/代码解析器、候选导入、SDK、编译、formatter、测试、WinAPI/进程查询或网络，没有修改 Main、Git、候选或旧证据。此结论只评估该最小分页补丁，不为既有页面所有路由/并发/权限流程提供运行证明。
