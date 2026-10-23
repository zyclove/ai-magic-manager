# 独立宿主监督候选：最小决策

状态：SOURCE ONLY / QUALIFICATION UNRUN / NO EXECUTION GRANT。既有r9、Main及其预算均不改。

## 目的和边界

修复现有controller同解释器两个Timer未能保障截止的问题。新宿主是独立的Python3.13进程，WinAPI通过现有ctypes.WinDLL调用；不新增依赖、Add-Type、SDK或全局环境。此候选仅有固定无SDK资格入口，不开放真实controller或任意命令入口。合格不等于硬实时保证，更不等于Guardian分析通过。

## 接口

`supervisor.py qualify <case-id> <exact-manifest-sha256>`。case只接受natural-zero、natural-nonzero、deadline、nested-owned-child。Python路径固定C:/Python313/python.exe，必须-I -B。fixture路径及参数在代码内固定，manifest不能引入任意argv。原180外层、174工作、165 worker、命令≤135、清理≤140、post25仅保留为后续接合合同，真实controller绑定需新精确pin、独审及Root新授权。

## 生命周期

1. 宿主最早记录ANCHOR，后续检查、创建、等待、清理、写盘全部扣同一QPC时间，不重置。资格使用更短固定work 4或8秒、清理6秒，绝不超过继承上限。
2. private、非继承、KILL_ON_JOB_CLOSE Job。CreateProcessW必须同时使用JOB_LIST属性、显式stdio句柄白名单和CREATE_SUSPENDED；先取同句柄creation FILETIME、检查IsProcessInJob与Job成员，再检查剩余时间，才Resume。失败关闭自有Job，不回退为事后按PID加入/查杀。
3. 控制循环只执行≤50ms原生WaitForSingleObject、QPC采样和Job查询，事件有界保存在内存。子stdout/stderr直接写独立文件，宿主循环不读取stdout、不写普通文件或fsync。
4. 首次signaled后立即采QPC，早于任何后续API/I/O；同一个保留句柄取GetExitCodeProcess、GetProcessTimes的creation/exit时间。后补等待不能替换首次采样。FILETIME是UTC域，QPC是单调域，不作未经校准换算。
5. 原根已终端而仍有成员、或工作截止到达，最多一次TerminateJobObject只针对自有Job。只在剩余6秒清理窗内有界等待，随后关Job作为内核兜底。任何强制动作都记录；没有及时终态就是拒绝，不能因Terminate调用成功升级。
6. 终态后才读取嵌套证明、重核源码/runtime pins并写observation。报告故意不称“最终通过”；输出尾部仍可能阻塞。Root须另外保留/观察宿主实际进程终端及退出时间，证明没有越过同一截止；仅凭写盘前elapsed/JSON内容不能验收。

## 固定资格合同

| case | 应观察 | 资格意义 |
| --- | --- | --- |
| natural-zero | 截止前自然0、Job0、无forced | 正常句柄/身份/退出采集 |
| natural-nonzero | 截止前自然7、Job0、无forced | 明确保留非0，不误报业务通过 |
| deadline | 超过4秒，自有Job终止124，清理截止前signaled/Job0 | 截止清理；这是预期负路径 |
| nested-owned-child | fixture在外Job内创建inner private Job+固定Python leaf；外Job曾观测total≥2；inner原子成员证明；8秒后外Job终止/Job0 | 显式资格化当前Windows的nested Job继承和自有子树清理 |

预期负路径成立可使该case宿主返回0，报告仍有forcedCleanup=true和原根124，绝不升级为真实分析成功。四case分别单次运行，已有case目录拒绝复用，不自动链式执行。

## 可证明范围

源码静态可核对固定路径、API签名、控制顺序、原始锚和拒绝谓词，不能证明当前系统支持JOB_LIST/nested Job、调用时延、ABI结构正确或资源清理实际完成。无任何资格已经运行。OS整体暂停或宿主本身失调度会延迟软件响应，恢复后用原截止拒绝；不能承诺物理实时终止。WinAPI自身若阻塞，源码也不凭空证明其必定及时返回。

这不是通用任务框架、SDK执行包或运行授权。已有r9失败原件封存，Main91cffee不动。
