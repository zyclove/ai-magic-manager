# Root单case launcher最终静态复核

**P2已关闭；固定资格范围内未发现其余静态阻断。所有case仍UNRUN，本报告不授权执行。**

新原件SHA `082b132e7f573ee792e99afb8a27ddd5df2dae47cb242c3a871c8d444170ccfc`；旧267原文在before-cleanup-fix文件中精确保留。静态机械对照仅有cleanupAttempted初始化、两次Kill前置标记、catch guard和receipt字段新增。

主路径第一次Kill前即设cleanupAttempted=true，所以Kill抛异常或首次WaitForExit(2000)返回false后，catch不再重新清理。异常路径若先进入清理也同样前置标记。因此两个文本wait分支互斥，每次运行**最多调用一次2秒应急等待**。这不保证Kill/WinAPI调用或OS整体暂停的实际耗时在2秒内。

同Process.Handle提前取得并保留，StartTime与终态后的ExitTime/exitCode在Dispose之前读取；未发现PID重开路径。Root Stopwatch早于Start，首次signaled立即取elapsed，strict小于原work+6；rootForced、failure、缺少或迟到signaled、非0 host均拒绝。Root强杀只作清理；如果没有实际终态，仍NotAccepted并等待外部post观察，不能宣称已释放窗口。

固定4case/f6/ArgumentList、前后6+6 pins及资源门槛保留。执行前仍须Root新鲜SDK0/unknown0、RAM与双盘均2GiB，门槛不降。真实句柄/ABI/nested/时限行为尚未验证。未运行脚本、解析器、WinAPI/进程API、SDK、测试或网络，也未修改任何原件。
