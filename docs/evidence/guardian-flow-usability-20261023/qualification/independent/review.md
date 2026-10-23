# 监督器 r3：四项实际资格证据独立回读

## 结论

未发现四项实际资格结果、原始观察、固定 post 和 Root 释放记录之间的矛盾。四项固定无 SDK 资格的实际结果符合本轮门槛；这不代表任何应用分析、编译、测试或界面验收通过，也不产生下一 SDK grant。

| 固定 case | 同句柄宿主首次终态 / 上限（秒） | fixture 退出 / 强制 | 最终 Job |
|---|---:|---:|---:|
| natural-zero | 0.2238287 / 14 | 0 / false | 0 |
| natural-nonzero | 0.1984433 / 14 | 7 / false | 0 |
| deadline | 4.0825113 / 10 | 124 / true | 0 |
| nested-owned-child | 8.0916503 / 14 | 124 / true | 0 |

四个宿主都自然 exit0；Root force、应急 cleanup 请求均 false，failure 均 null。其同对象 creation/exit Filetime 与 post、release 一致且顺序正确。内层 fixture 与宿主身份不同；观察 signaled/terminal 均 true，exit identity 与原 case 一致。Filetime 属 UTC 域，没有与 QPC 混算。

## 严格门槛与原件交叉核对

自然用例的首次完整 Job0 观察分别为 QPC 42622.4486263、42822.0459379，严格早于 min(work_end,firstSignaled+0.5) 的 42622.9379566、42822.5350671，亦早于各自原 8 秒 work 截止。post-accounting QPC 保持 firstSignaled <= firstComplete <= jobAccounting < cleanup 截止，无 force/termination/deadline。两个自然 case 首次 signaled 时 Job active1，自己的有界成员身份记录是 conhost.exe，约 10.7/10.9ms 后完整 Job0；这是本次样本，不能据此追认旧 r1 的未知原因。

deadline 与 nested 在原 4/8 秒 work 截止后执行自有 Job 终止，forcedCleanupRequested、terminationCallSucceeded、deadlineReached 均 true；真实 fixture exit124/Job0 在原 work+6 内观察完成。nested raw proof 的全部八字段和 JSON 标量类型与嵌入值一致：child77588、原 creation Filetime、atomicMembershipCheckedBeforeResume=true、suspendedActive/innerActive/innerTotal=1、childSignaled=false；外层最大 Job total4 后归零。仅支持本次固定 nested fixture 的环境资格，不声称任意 Job/ABI 组合已验证。

逐项重算四个 post 各 25 descriptors / 19 unique 固定输入和原始 evidence 的 size/SHA：全部匹配；raw 行数依次 4/4/4/6。固定 manifest f088c5b7、delivery4b1e5c39、launcher c1f8c0aa、post-r3 15694b2b 与先前独审原件一致。候选静态文档/manifest 的历史 UNRUN、sdkAllowed=false、realControllerEntryEnabled=false 原文保留，不回写为本次结果。

四个 post 的 reported/derived/status 一致、qualificationAccepted=true、failedChecks=[]；analysisAccepted、real controller、SDK 调用始终 false/0。没有再次执行固定 post 或其 acceptance/comparator/predicate，仅按 JSON 原始值和类型人工核证。

## 释放与范围

每个 release 引用的 post、完整进程清单 SHA 均匹配。冻结清单行数为 752/759/749/749，按固定命名范围只读统计均 SDK0/unknown0；已知宿主、fixture、记录成员及 nested leaf PID 均未再列出。Root release 的实际 launcher/post chunks 分别为 38b49e/940973、743f67/8253bc、e53fbb/957db9、caf7e4/0aaad1，均记录自然 exit0；无自有存活 SDK handle，nextSdkGrant=false。每次 preflight RAM 和 C/D 余量都高于原 2GiB 门槛；最后 release RAM4101890048B。

这是冻结文件证据审核，不是审阅者实时 OS/句柄观察；宿主真实句柄事实来自固定 launcher 及 Root 实际终态/释放记录。首次信号是保守采样，运行时 pin 仍为局部清单，不声称完整 runtime closure。

四项资格与应用验证分开。完整 181 个回归入口 scope 保留，critical80 只是子集，应用仍 UNRUN。新 SDK 方案必须另外绑定当前源和授权；本次不改原预算180/174/165/135/140/post25或8/4+6，不修改候选 sdkAllowed 标记。

审核只读取本地文本/JSON/hash及只读 Git，写自有报告/pin；未执行候选/helper/业务谓词、SDK/测试/AST/编译/formatter、WinAPI/进程查询或网络，未修改 Main、Git 或任何原件。