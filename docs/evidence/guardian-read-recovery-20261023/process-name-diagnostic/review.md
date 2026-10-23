# 全量进程名称来源：只读诊断与最小接合建议

## 实际观察

只读初探工具 `fea89e / session80577 → d32523` 自然退出0，复现 psutil 的 PID172 name 为空，但 Get-Process 返回 `Secure System`。该初探的创建时间/HasExited属性没有提供完整可用身份，未拿它构造跨来源PID身份合并；原输出保留在工具记录，不回写旧 r10。

按 Root 后续确定的“完整 Get-Process 作为唯一名称权威”方案，运行本目录固定 `probe.ps1`：实际工具 `c540b8` 自然退出0，1.597秒；没有执行SDK、应用测试、资格case或候选业务函数。

- PowerShell7.6.5；完整 Get-Process/System.Diagnostics 库存两次各685行，逐行 `pid:int`、非空 `name:string`、`errors:[]`；无枚举错误、未知名称或重复PID，SDK名称/.test匹配均为0。
- 原始区间为2026-10-23T15:30:32.7917140Z至15:30:33.3599221Z。两份库存都包含 PID172 / `Secure System`；前后PID/名称集合恰好相同。这只是此样本，不是PID或名称豁免条件。
- psutil仅在单独的固定资源子助手里查询RAM/磁盘，子助手实际exit0，未强停：RAM3129892864B，C:4891373568B，D:24252682240B。其环境仅固定SystemRoot/WINDIR/PATH，`-I -B`；没有读取其他进程环境或命令行。
- `probe.json` 保存完整typed rows及provider/error边界。后续 `51fe10` 只读JSON/哈希自然0，核实两份685行的类型、唯一PID、0错误/unknown/SDK以及该实际Secure System行。该回读没有重新查询进程。

`probe.ps1` 若全量枚举、读名、类型或重复PID有任何问题，都保留错误/未知行并返回非0；不存在特殊PID或特殊普通名称白名单。资源助手超时分支只允许处理刚创建的精确自有Process对象，不按PID查找或控制无主进程；本次没有走该分支。全局名称读取不获取目标进程句柄、StartTime、模块、环境或命令行。

## 最小接合方案

1. 后续worker保留既有psutil RAM/磁盘采样；名称部分换成固定PS7、`-NoProfile -NonInteractive`、固定小脚本的**完整fresh库存**。调用程序、参数、脚本及进程级环境由后续Root独立审核并pin；不复用已消费r10。
2. 名称脚本只收集一次完整PID/ProcessName数组及明确错误。消费者严格验证JSON schema、行数、所有PID整数且唯一、所有名称非空字符串、错误列表为空；任何异常、部分输出、超时、未知行或SDK命中都拒绝。不是只给psutil某个PID补名，也不把name缺失转换为空数组。
3. 完整保留现有SDK范围：dart/dartaotruntime/flutter/flutter_tester/gen_snapshot/java/javaw/javac/mvn/gradle/go/gofmt/compile/link/vet/aapt2/asm/cgo/qemu-system-x86_64及`.test`，大小写不敏感，兼容provider可能带`.exe`。本诊断的SDK范围未缩小。
4. 每个门槛边界整份重新采样；不把上一份psutil或PS库存的PID解释为下一份的同一进程。若选择用双库存证明一次读取一致，差异应显式拒绝或重新取完整库存，不局部补行；单份库存只能证明该provider取样区间的名称观察，不能证明两次取样之间持续无进程。进程退出导致provider报错时不得悄悄丢行。
5. 全局名称观察只用于名称门槛，不控制他人进程。因此不需要为每个全局名称行强加自有Job的retained-handle控制身份条件；**自有host/worker/command的原retained handle、creation FILETIME、QPC期限和Job0约束完全保留**。

本次完成的是只读来源诊断，不是已封存/已独审的下一执行包。此目录的双采样及资源助手只是诊断结构，后续生产验证可提取更小的单次名称提供器，不能直接冒称所有后续集成都通过。`runtimeClosureComplete=false`：没有宣称完整PowerShell/Python/OS运行时闭包。

旧r10仍为SDKcalls0、NOT_ACCEPTED、应用分析UNRUN；本次不重跑或修写旧attempt，不创建SDKgrant、不改Main/Git、不安装依赖。RAM/SDK数只是当前诊断观察，下一真正验证仍需Root重新取得fresh窗口与授权。
