# Guardian独立宿主资格候选 r1

**SOURCE ONLY，4 case均UNRUN。没有执行授权，也没有真实controller入口。**

`supervisor.py`仅接受固定资格case和精确manifest SHA；`owned_job.py`提供原子暂停创建、private Job、保留句柄和退出时间采集；`fixtures.py`只运行本地自有Python固定行为；`qualification-cases.json`规定正/负预期。

设计和拒绝边界见design.md。当前静态准备不启动Python fixture、WinAPI、SDK、网络或编译，不修改Main、旧r9、审批和预算。

未来Root另行独审并授权后才可运行单个固定case；不能把下面接口说明视为授权：

`C:/Python313/python.exe -I -B -u <this-directory>/supervisor.py qualify <fixed-case> <exact-manifest-sha256>`

四个case：natural-zero、natural-nonzero、deadline、nested-owned-child。每个case对应单次新qualification-attempts子目录，拒绝复用。后两项期望强制清理；其case资格预期满足不是Guardian或真实controller通过。

宿主控制循环不做stdout/普通文件读写/fsync，退出观察后才写observation。Root须独立保留宿主进程句柄或同会话终态，结合其创建身份、实际退出时间和同QPC截止验收；写盘前结果不等于实际退出。OS暂停/调度或API阻塞不承诺硬实时，逾期必须拒绝。

runtime pins仅为现有Python exe/dll与ctypes相关文件，不宣称整个Python安装闭包已完全固定。没有下载或安装依赖。Manifest中的executionApproved=false表示此刻未授权；未来只能由Root用精确manifest摘要另行授权，不修改旧审批。
