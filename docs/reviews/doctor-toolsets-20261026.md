# 按用途盘点部署工具：静态阶段

当前状态（2026-10-28）：前次真实组合路径回归失败保留；最新精确模式候选仅完成静态核对，复验在门槛前停止，不能视为已修复或部署验收通过。原转义候选已被真实回归否定，失败与待验证范围见文末。

日期：2026-10-26。基础提交：`465cf870a34fc330b06d11b9c2c2b9a6c11df6ef`。状态：源码与静态语法检查完成，参数和受控命令发现回归未运行；未推送或更新服务。

原 doctor 统一报告 Docker/Git/Java/Maven/Flutter 缺项，不能区分只运行已有环境与源码构建。本批增加 `doctor -Toolset Runtime`，只查询 Docker 命令；默认 Build 保留源码构建的五项查询。工具缺项仅限当前用途，不把源码工具缺失作为运行命令缺失。

Build 可复用 MavenCommand、FlutterCommand、DartCommand 覆盖项；文件路径沿用现有仓库基址，裸名称继续从 PATH 发现。Maven/Flutter/显式 Dart 允许应用和文件脚本类型，避免把合法脚本入口误报缺失；未显式指定 Dart 时不额外要求系统 PATH Dart。Runtime 显式传构建覆盖项会在发现前拒绝，其他动作也不能传 Toolset，不静默忽略参数。

结果补充 toolset 与每项实际查询命令，保留用途、missingTools 和命令可找到状态；没有 ready 标志。版本、SDK 内部、Compose 插件、守护进程、实际服务及平台兼容仍明确未验证。Plan 在命令发现前返回，诊断不读取环境配置或运行凭据，不连接服务或执行工具。

## 检查事实与最小接续

- PowerShell 入口、受控发现脚本文本及 Python 测试文件通过 AST 语法检查。首次抽取夹具时，命令输出按行收集后未拼回换行，造成静态解析输入错误；恢复换行后通过，未将该工具输入问题当作产品用例失败或通过。
- 独立静态审查未发现可证明问题；源码差异、空白及文档本地链接已核对。没有执行 doctor、测试、SDK 或资源采样。
- 新增 2 个待运行方法：Runtime 不查询源码命令、默认 Build 保留五项；自定义构建命令按最终路径及文件命令类型盘点。发现边界受控，真实裸工具入口由失败占位函数隔离，显式路径使用未创建的唯一测试路径；没有新建临时目录。已有计划及不适用参数矩阵同步增补。全部未运行。

恢复既有资源与空闲门槛后，执行上述两例及受影响的计划、非法参数、路径规范化用例即可；不为诊断检查启动 SDK、部署、网络或全量套件。真实工具发现、软件版本和实际环境验收仍按各自证据判断；其他阶段待运行项没有被追认为通过。入口与安装说明见[简明部署入口](../deployment-quickstart.md)。

本次源码摘要（静态候选定位，不代表运行通过）：

- `scripts/manager.ps1`：`dea47016ca93cdd5bd2ede34c7d80490f7ee1796fde85d9b92a63083db4a7c41`
- `scripts/tests/test_manager_entry.py`：`60df6fad3dab6f6d23de051fbef94f34181e64206658dc3019a042608d930832`


## 2026-10-28：字面工具发现

**本段为已被真实回归否定的历史静态候选，见下节。** 基线：`d7b64592122a203db3596f1c6c94bcfe592e1741`。诊断与构建中的5处动态命令查询，使用 PowerShell 原生 WildcardPattern 转义查找值；原参数、计划、显示及实际执行命令不变，Flutter 文件路径仍走既有 LiteralPath 分支。依据 [Get-Command 官方参数说明](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/get-command?view=powershell-7.5)，Name 接受通配模式，不能将模式匹配出的其他工具当作用户所配置工具。

受控发现夹具改为原生通配匹配语义，并新增1个聚合回归，覆盖带空格／方括号的配置路径、误匹配的裸名称、原值保留和缺项提示不回显私有配置。夹具仅证明受控发现契约，不替代真实 Get-Command 的文件、PATH、扩展名和平台行为。

- 两份 PowerShell 脚本通过 Parser.ParseFile 静态语法解析，Python 测试源码通过 ast.parse；没有执行部署入口或工具命令。
- 新聚合及受影响参数回归为 **NOT_RUN**。实际文件命令发现、构建、SDK及 Windows/Linux/macOS 部署验证为 **NOT_RUN**；需恢复验证窗口后确认，不能以受控夹具或解析通过推定完成。
- 未读取运行凭据、启动服务、采样资源、推送或更新部署；既有历史摘要及结果不追认为本轮通过。


## 真实文件回归与精确来源修订

基线：`d97e1087928a042251ee3295822ee9e764514088`。恢复原资源及空闲门槛后，在 PowerShell 7.6.5 实际执行两条定向检查：真实含方括号文件路径失败，受控通配模型通过（自然 exit1，1失败／1通过，源码无漂移，前后 SDK 为空）。这是真实发现失败，不能由原模型通过追认为成功。保留[r1原输出](../evidence/deployment-tool-discovery-20261028/r1-output.txt)和[r1回执](../evidence/deployment-tool-discovery-20261028/r1-result.json)。

修订采用单个共用工具发现模块：裸命令按原值使用执行器查询；显式文件先由 LiteralPath 确认，再从转义后的候选中只接收 Source 与原文件完整路径相同的命令元数据。仅调用执行器的 GetCommand 仍可能在显式路径上先匹配通配符，不能省略来源核对；实现边界见[官方 GetCommand 实现](https://github.com/PowerShell/PowerShell/blob/v7.6.5/src/System.Management.Automation/engine/MshCmdlet.cs#L280-L318)及[路径发现实现](https://github.com/PowerShell/PowerShell/blob/v7.6.5/src/System.Management.Automation/engine/CommandSearcher.cs#L412-L468)。

受控发现夹具改为隔离 PATH 中的真实探针文件，不再用 Get-Command 模型证明产品行为。真实文件旅程包含方括号目录与可通配匹配的普通目录并存、Source 必须对应原文件、只剩干扰项时报告缺失。所有探针只属于唯一任务目录，清理逐个已知文件与空目录，不递归删除，也不覆盖或删除未知文件。当前修订仍待定向复验；本记录的历史失败保持原结论。


r2 实际复验4个相关方法：3通过／1失败，自然 exit1，3份 PowerShell 源码解析通过，源码无漂移，前后 SDK 为空。真实文件、同名干扰、Source一致性及原文件移除后缺失已通过；失败为 PATH 内的 `configured-[stable]` 裸名称未识别。保留[r2原输出](../evidence/deployment-tool-discovery-20261028/r2-output.txt)及[r2回执](../evidence/deployment-tool-discovery-20261028/r2-result.json)，不将局部通过外推为完整通过。

后续修订保留框架正常查找；对带特殊字符的裸名称，仅从框架给出的 PATH 元数据候选中按原文件名及标准脚本／当前系统后缀规则选择，再核对完整 Source。构建执行绑定已核对的 Maven／Dart 来源，原参数与计划展示仍保留用户输入。该修订待同一相关范围实际复验，未执行构建、部署或 SDK 版本验收。


r3、r4 均为同4方法3通过／1失败，原始结果分别保留在 [r3](../evidence/deployment-tool-discovery-20261028/r3-result.json)、[r4](../evidence/deployment-tool-discovery-20261028/r4-result.json)，输出均同目录留存。随后只复验2条受影响回归：r5 裸特殊名称通过，但更严格的目录和叶名均含方括号、并含两层干扰项的真实文件场景仍失败（1通过／1失败，自然 exit1，源码无漂移，前后 SDK 为空）。保留[r5输出](../evidence/deployment-tool-discovery-20261028/r5-output.txt)与[r5回执](../evidence/deployment-tool-discovery-20261028/r5-result.json)。上述计数包含复跑，不相加，也不代表完整脚本套件通过。

[诊断2](../evidence/deployment-tool-discovery-20261028/trace2-result.json)证明裸候选已包含原文件，失败在其完整路径再次查询；[诊断3](../evidence/deployment-tool-discovery-20261028/trace3-result.json)证明组合路径的候选为空，而原值 API 可能返回干扰文件。这些仅是诊断数据，不是通过证明。曾有一次诊断把 PATH 列表当作单路径，修正诊断输入后重新取证，没有将该输入错误记作产品通过或失败。

没有采用物理文件描述对象或反射来代替框架准入：官方发现还包含[语言模式／WDAC信任过滤](https://github.com/PowerShell/PowerShell/blob/v7.6.5/src/System.Management.Automation/engine/CommandSearcher.cs#L773-L792)，不能为通过回归而绕过。公开 API 目前没有 literal 查找开关，剩余组合场景继续静态核对。下一条诊断在启动门槛即停止（可用内存1679634432字节，低于原2GiB），没有执行诊断主体或 SDK；不会降低门槛或重复轮询资源。


最新候选仅改变显式路径模式：按官方通配解析语法逐字符编码为**精确单匹配模式**，不附加宽泛后缀；普通路径不额外转义。GetNextFromPath 对完整路径多命中会拒绝该分支，不能用 -All 取消，故保留精确模式和最终 Source 等值。[多命中规则](https://github.com/PowerShell/PowerShell/blob/v7.6.5/src/System.Management.Automation/engine/CommandSearcher.cs#L450-L470)、[字面模式语法](https://github.com/PowerShell/PowerShell/blob/v7.6.5/src/System.Management.Automation/engine/regex.cs#L615-L683)。保留所有原断言及框架信任过滤，没有采用物理描述对象或反射。

r6 在原准入即 **NO_START**：内存1736978432字节低于2GiB，另有 go/platform.test 进程；未进入语法解析或两条目标回归，源码无漂移。保留[r6回执](../evidence/deployment-tool-discovery-20261028/r6-result.json)。最新 helper 摘要为 `bc03b9cac11960ea49655c566653687aca8bbbe1e24f56351efea9747acd3cf5`；这是待复验候选的绑定，不是通过证明。

后续静核发现固定发布 recipe 清单未包含新增 helper，已将 `scripts/tool-discovery.ps1` 纳入清单并同步两份既有夹具；原修改／删除拒绝回归增加该文件。此后没有运行回归，也没有更新已部署记录；新清单不追认历史发布。

随后仅执行静态检查：最新 helper 与来源清单脚本通过 PowerShell 语法解析，新增改动的 Python 夹具通过 AST 解析，三份 recipe 路径集合一致，源码与文档差异通过空白检查；原始输出包含测试工具产生的行末空格，按原字节保存，不做格式清理。没有执行 helper、入口或测试，不改变 r6 的 NO_START 结论。

本阶段保存本地检查点；真实构建、SDK、Linux/macOS、链接及整体部署验收仍未执行。资源或验证窗口发生实际变化后，先复验2条直接受影响的命令发现方法，以及既有来源回归的完整清单读取、recipe 修改／删除拒绝两例；除非出现新的失败或共享影响，不重跑未变套件。
