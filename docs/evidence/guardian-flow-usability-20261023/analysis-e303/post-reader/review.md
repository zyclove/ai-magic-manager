# r10 e303：独立纯文件结果回读器

入口仅为 `post.py <实际已批准 proposal SHA256>`，固定读取 r10-e303 的 proposal、inputs、Root grant/launcher/preflight/result、host request/result、worker receipt/launch/pre/post/gates/log/console。仅写本目录单次 `post.json`；不写 Main、共享候选目录、历史证据或资源归还文件。

本次只准备脚本文本，**未运行本回读器**，未执行 SDK、测试、AST、候选代码、进程或 WinAPI、网络操作；没有构造成功/失败数据来运行谓词。当前结果仍须实际运行后提供，不能用这份静态说明替代。

## 核对边界

- JSON 拒绝重复键和 NaN/Infinity；布尔值、整数、有限 QPC 浮点数分型，内嵌和独立记录用保留 JSON 类型的比较。文件路径固定、拒绝重解析链接，读取前后检查文件身份/大小/修改时间；单文件有界。
- 按实际 proposal SHA 重读 proposal、13528B 的固定 inputs、三个 controls 和 26 个 runtime 文件的大小/哈希。runtime union 必须精确等于输入列表；依赖元数据 descriptor 也重读。仅这些固定文件，不重新遍历或哈希 633MB 外部缓存内容。
- Root grant、实际 launcher 哈希和 Root 两份回执须同一 proposal/source；Root 记录的 retained host PID/正 FILETIME、自然 exit0、首次 signaled 原始180秒内、无强停/清理、pinsAfter 和事前资源门槛必须一致。Root preflight 的字段不能在 result 中悄悄改写。
- Host 原 QPC 的 +174/+180，worker 原 +165，SDK command 原 +135/+140 均按精确等式和观测顺序核对。只允许原 deadline 内自然0和 Job0；首次完整 Job0 还须严格早于 firstSignal+0.5。首次 signaled 和完整 accounting 时刻保持区别。
- 检查 worker receipt、host 内嵌副本、独立 preflight/postflight 文件、launch pid/creation/deadlines、资源 gate、日志 pin/文本、console 报告的相互一致性。完整 source410/package70/cache3536 摘要、sdkCalls1、无错误/无诊断和必要布尔保护均须满足。launch 仅允许固定命令/无 selector、local TEMP，以及 SDK 子环境记录的 REPO/SDK 两个固定 safe.directory。
- 独立 derive 后再比较 worker/host reported 状态，不单独信任任意一个 PASS 字符串。旧预输出 elapsed 仅作为预输出字段核对，**不当作真实 outer 退出时刻**。FILETIME 不与 QPC 数字互比。私有 Job 成员诊断不被推断成某类辅助进程原因。

## 输出语义

全部文件证据一致时仅输出 `DERIVED_ANALYSIS_CONSISTENT_PENDING_ROOT_RELEASE`，且 `analysisAccepted=false`。仍明确要求 Root 实际工具终态及 fresh 全进程资源归还；本脚本不查询进程、不代填工具 chunk、不生成 release。回读失败则输出 `NOT_ACCEPTED_FILE_READBACK` 并保留已读文件的指纹；单次输出不覆盖。

Root release helper 使用固定 `post.json` 和上述 pending 状态。回读器退出0只代表文件证据一致，不代表应用测试已通过、资源窗口已归还或完整产品可发布。

## 已读 schema 版本

已对照作者最终源码：host18928B/79b6e69e…46ca1，worker31761B/f7319e16…543c5，OwnedJob13322B/f8b44764…141b，以及 Root proposal6463B/6ad444f0…77ad9。最终运行时仍由传入实际 proposal SHA 及其 descriptor 重新绑定，当前不预填任何实际运行结果。
