# r9 外层180秒预算失效：静态独立诊断

结论：**截止执行失效已证实，具体阻塞根因未确定；本次 NOT_ACCEPTED，不构成分析通过。** 本报告没有调用 SDK、启动/控制进程、网络、编译或修改原件。

## 时间事实

| 记录 | 数值 | 能说明什么 |
| --- | --- | --- |
| controller result | 314.1163399 秒；UTC间隔314.082222秒 | 已超过180；采样发生在最终写盘、stdout及退出之前 |
| Root同会话58699、f8c394→720805 | 自然退出码1 | 控制器实际已终端；不证明worker自然退出 |
| Root QPC anchor→事后终端观察 | 423.2936237 秒 | 保守上界，含观察延迟；不是精确exit时刻 |
| 单次child.wait异常 | 0.1 秒 | 等待参数被剩余预算夹到最小值，不是整个314秒的原因说明 |
| 最终Job活跃数 | 0 | 最后采样已无该Job成员；不证明135/180秒内结束 |

## 源码可收窄的位置

controller:22/47 的硬/软 watchdog 都是同一 Python 解释器的 threading.Timer。硬分支预期 os._exit(124)，但本次执行到 finally 并返回1，无法再宣称它实际保障180秒上界。结果最终的超时检查仍正确拒绝，验收没有误报通过。

记录的 TimeoutExpired 最直接对应 controller:73 主路径 wait；:100 清理 wait 的异常被吞，不会写成原errorType。按未改写源码的正常控制流，说明 Assign已返回、:54截止检查通过，并走过:55握手和:56 stdout flush。只有:54检查时可知<174；未采样握手/print完成时刻，不能扩大成“握手在174前完成”。潜在时间损失仍涵盖print、poll、launch文件读取、Job query/terminate/wait和异常/finally收尾，不能锁定一项调用。

attempt精确只有 request.json、result.json、0字节worker-console.log。worker无 initial/preflight/launch/receipt/command log；因此启动、导入、输入读取及首次resources都缺少边界证据。不能凭空认定SDK已启动或SDK调用为0。worker的native helper在:391才导入，正常顺序先有:382 initial-gate、:384 preflight；没有正证据说明helper已运行，更不能将其当成本次外层卡顿的原因。

异常路径没有持久化 assigned、cleanup、expired、workerExitCode，也未记录每次Terminate返回值。软timer是否进入、进入时间和终止返回情况均未知。晚Job0及事后SDK0不能补齐这些事实。

## 不得写成根因的猜测

- Win32Job调用持有GIL：需具体pywin32实现或调用栈/线程证据，Python调用点本身证明不了。
- Python计时线程未获调度、进程或OS暂停：均有可能，但缺少timer进入记录、调度/电源事件；UTC与QPC大致一致不能排除这些情形。
- 内存/CPU压力：只有启动前约5.52GB和较晚08:57约1.19GB样本，没有故障区间连续证据。
- 最终fsync/stdout拖慢：可能影响真实退出尾部，但314采样在最终result写盘之前，因此“最终result fsync单独导致314”不成立。423与314差额也包含人工/工具观察延迟，不能全归I/O。

## 最小下一步设计（本轮未实现或运行）

1. 用独立宿主/监督进程，采用成熟的保留进程句柄与有界原生等待（或.NET Process.WaitForExit），配合现有私有Job控制确切子树。监督不共享可能卡顿的controller解释器，不靠广泛PID扫描，也不新增通用重试框架。
2. 保持原180外层、174软截止、165 worker与worker-relative命令≤135（清理≤140、后检25）预算。所有等待从同一原始anchor扣减，不能重新开始180。OS睡眠或系统整体调度暂停仍可能延迟软件观察，恢复后必须按逾期拒绝，不能宣称物理实时保证。
3. 先另行审查小型、无SDK的控件资格检查，确认保留句柄、Job归属和外部截止行为，再考虑昂贵SDK执行。本报告没有生成控件或执行资格检查。
4. 在创建/Assign/握手/print/Job查询与终止/wait/close/fsync前后写有界monotonic阶段记录；timer记录armed/entered/returned，异常路径也保留清理与退出状态。
5. 保留同一controller、worker及命令原生句柄；首次wait返回signaled立即记QPC、退出码、创建身份和强制终止尝试。signaled后用GetProcessTimes ExitTime采集该句柄对应的OS实际退出时间。FILETIME与QPC分开记录，不作未经校准的跨时钟换算。
6. 成功必须使用首次捕获的terminal观测严格早于finite deadline，并同时满足自然0、Job0及完整前后核验。后补wait、结果文件时间或Terminate成功不能补齐及时退出证明。首次观测依然有保守采样误差，不能等同精确内核退出事件。

完整证据pin和“已证实/控制流推断/未确定”分别见review.json。旧r9候选与attempt原件保持原状，不因静态诊断升级任何测试或分析结论。
