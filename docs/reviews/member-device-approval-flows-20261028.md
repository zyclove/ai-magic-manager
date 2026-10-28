# 成员、设备与审批核心流程

实现范围：`4a8a069` 后的管理台流程改进，已提交阶段至 `da9213f`。本轮完善成员调整权限前的原地复核；各阶段验证分开记录，不继承历史通过。不推送、不部署，当前服务不自动使用这些提交。

## 已实现行为

| 范围 | 行为及权威合同 |
| --- | --- |
| 列表与邀请 | 普通查看、邀请取消及只读子流程保留分页和搜索；需核对邀请时直接进入邀请记录。成员、设备、审批以原 ResourceActionLease 返回单次核对信号，已尝试写入含未知结果仍需核对，信号不证明保存成功。筛选与操作同步防重并隔离旧视图。见[规格](../SPEC.md)。 |
| 成员 | access 的 Target／Snapshot 校验原 actor/cursor、六字段范围、精确版本与 PATCH 回执；班级名称按需读取，不阻塞核心资料。列表当前读取拒绝锁存整页，目标 access/history403仅退役该成员并核对原列表；三个自有详情／历史窗口贯通退役通知，保留独立覆盖通知。见[成员合同](../member-access-plan.md)。 |
| 设备 | 详情、注册及退出流程借用原父窗口和权限；专用派发观察器显式包含未带幂等键的既有写请求，默认观察器语义保持。仅纯 GET 诊断返回免重读，可能写入的执行记录保留核对；重复选择当前栏目不再 GET，明确刷新仍有效。控制器、窗口代次和路由隔离旧按钮，未知撤销只读核对，读取或失权仍可关闭，实际写入中保护关闭。见[设备合同](../device-registration-contract.md)。 |
| 申请与决定 | 分钟＋可选秒精确保留1～3600整数秒；未知正文及 ruleIds 冻结，后续拒绝不解锁，过期／冲突停止旧请求。创建窗口以原路由／代次阻止旧入口，读取拒绝清私有目录及可见草稿，写拒绝不推导读取失权。必传宿主 onComplete，组件不直接调用受保护 Route.didComplete。见[审批合同](../access-request-contract.md)。 |
| 审批历史与确认 | documents403退役当前申请及两层历史并核对原列表；attempts403也可能仅缺文档，只结束尝试窗口、核对文档列表，不能直接退役整页。真实401（非REAUTH_REQUIRED）／WORKSPACE_CHANGED退役申请。源列表范围与目标拒绝分开，保留单次核对信号。本人取消、撤销批准使用父路由租约确认，父详情退役时一并结束确认，旧按钮不写入；独立通知保留。 |
| 渐进交付摘要 | 核心详情先开，原授权历史／撤销不等待摘要；原窗口局部读取与重试。Summary只补交付事实，不覆盖原核心版本；新版、结果未知或读取中关闭需要核对原列表，已核验同版普通关闭不重读。新DTO及边界详见渐进交付摘要小节与审批合同。 |
| 共用窗口 | DialogAccessBinding同时观察父路由popped/completed，覆盖既有SDK raw removeRoute不完成popped的情况；同步停止旧入口、帧后发布退役。详情仅按显式closeOnAccessLost结束所属OwnedDialogRoute，其他默认隐藏语义保持，不关闭独立通知。 |

## 本轮成员权限复核

- 编辑前第二次access GET移到原“调整权限”动作：等待期间同步防重，普通失败保留同一详情及可再次点击的入口，避免返回列表后重复打开。成功才关闭详情，将已验证的最新快照固定交给原编辑器；不移除二次复核、原目标／版本校验或未知写入保护。
- 请求借用原详情API与可用期；旧详情raw移除后的晚成功／拒绝不打开编辑器、不退役新目标、不触发列表重读。独立覆盖窗口置顶或详情完成动画期间新窗口出现，都不自动将编辑器压到其上。已观察新版或目标角色不可编辑时仍需核对原列表。
- 相关2文件Dart分析通过；成员HTML浏览器11个唯一旅程通过。首轮handle48989自然exit1，10通过／1新增用例误等覆盖通知下的列表解锁；仅将等待改为原route.completed，通知关闭后才等待列表可操作，业务断言不变。修正文件分析及该1项复验在handle57620自然exit0，不重跑其余10项或未改设备／审批。日志保留在原忽略目录member-preparation-*，不纳入提交；资源原门槛均满足，窗口串行，未更新服务。

## 渐进交付摘要（da9213f）

- 核心申请先显示，非PENDING的delivery独立渐进读取；原授权历史／撤销不等摘要。普通失败局部GET重试，PENDING仍零请求。
- 新Summary DTO按后端13字段核对目标、safe版本、交付／恢复及固定未执行证据；真实空文档正常处理。测试夹具同步改用现行UPSERT/REMOVE动作、SIGNED/NOT_FETCHED等真实状态。
- 原窗口／API／请求／代次固定，旧重试、认证、晚成功或拒绝不影响新窗口；真实401/403（非REAUTH）仍退役当前申请、保留独立通知。新版只提示并记录核对，不覆盖原状态、版本或未知正文。
- 静态复核补齐GET生命周期结果未知：服务器可能已推进版本但响应丢失，或用户在读取中关闭；失败与父popped/completed都保守记录原review信号，来源有效时仅核对一次。已核验同版普通只读不重读。
- 验证完成：相关5个Dart文件分析无问题；approval_decision纯测试5项通过；approval_help_flow的HTML browser30项通过，原handle19861自然终态exit0。未重复未改成员／设备及原7文件。首轮分析两处多余非空断言已修正；随后浏览器编译对nullable字段回调不接受分析器的字段提升，改为捕获局部回调后仅重分析该组件并重跑browser，未重复领域测试。失败及复验输出均保留在同一忽略目录的progressive-*日志中。

## 此前阶段验证（截至522890f）

| 检查 | 结果与范围 |
| --- | --- |
| Dart分析 | 本阶段22文件首轮7处info，补显式mounted及测试花括号后同范围exit0、No issues found。`3cef0af`的最新3文件分析通过；本轮两份测试等待修正后再分析这两文件，无问题。 |
| 普通测试 | 7文件共106项通过。首轮103通过／3失败，定点改为等待真实HTTP与路由完成；两文件复验15通过／1条迟到HTTP遗留Timer，补齐原deadline清理等待后成员单文件15项通过。合并未变化的通过范围，不把重复执行计为新增测试。 |
| HTML浏览器 | 3文件共43项通过：成员9、审批与求助28、设备入口6。首轮37通过／6失败；本轮只复跑6个失败旅程，原handle38903自然终态exit0、6项全部通过。其余37项源码及断言未变化，不重复执行。 |
| 改动边界 | 本轮只调整测试等待，保留原有界期限与全部业务断言。历史拒绝先等三窗口退役及新列表落地，写拒绝／新版读取后等列表恢复可操作；未知DELETE先等真实SERVICE_UNAVAILABLE。既定产品会自动关闭失权详情，去掉测试中过时的手动关闭步骤并明确断言窗口已消失。审批历史关闭后等原route.completed及父按钮解锁，再继续实际确认／取消。 |
| 交付状态 | 未改依赖或SDK，未运行未改组件的全量构建，未更新服务。以上不证明真实账号MFA、完整后端联调、所有平台安装或整个产品已经验收；广义产品目标仍有效。 |

普通文件：access_requests_page_test、devices_page_test、api_deadline_test、device_management_test、device_management_dialog_test、access_request_dialog_test、member_editor_test。浏览器文件：members_page_workflow_browser_test、approval_help_flow_browser_test、device_management_entry_test（均为.dart）。

## 保留的失败与运行边界

- 默认CanvasKit启动曾失败：本地/canvaskit/chromium/canvaskit.js及/canvaskit/canvaskit.js均404，bootstrap Promise拒绝，测试正文未开始。通过原session1700正常中断并核对本轮创建身份，无残留进程；没有因观测超时重启或按PID结束共享进程。
- 静态定位为Flutter3.22.2在Windows将URI转为反斜杠路径后仍检查POSIX前缀；SDK四份CanvasKit资产实际齐全。未下载、改SDK或建立联接。Guardian [README](../../apps/guardian/README.md)与[发布脚本](../../scripts/build-deployment.ps1)均固定HTML，本次浏览器检查采用同一--web-renderer=html目标，不把HTML通过当CanvasKit通过。Web测试SDK本身固定jobs=1。
- 保持RAM、C盘、D盘均至少2GiB的原门槛，并串行使用共享窗口。本轮摘要验证启动时RAM4,168,744,960、C盘10,646,888,448、D盘5,402,828,800字节均达标；17:16可用内存1,027,842,048字节时未启动SDK；本次HTML窗口准入为RAM4,200,194,048、C盘10,847,821,824、D盘6,004,944,896字节。语言服务或Gradle daemon不因名称被误判为正在验证。
- 原始失败及复验输出保留在被忽略的 `.cache/guardian-flow-validation-20261028/`，包括analyze、affected-tests、browser-html-tests及browser-failed-cases-retry等日志。所有运行均观察原工具句柄至终态；资源／排期仅在有意义变化后复查，不降低门槛或停止共享服务。
- 本阶段仅提交必要源码、现有回归和权威文档。临时文件、缓存、源码副本及历史大取证文件不在提交范围，没有清理SDK缓存或唯一交付证据。
