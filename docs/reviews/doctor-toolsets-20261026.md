# 按用途盘点部署工具：静态阶段

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

基线：`d7b64592122a203db3596f1c6c94bcfe592e1741`。诊断与构建中的5处动态命令查询，使用 PowerShell 原生 WildcardPattern 转义查找值；原参数、计划、显示及实际执行命令不变，Flutter 文件路径仍走既有 LiteralPath 分支。依据 [Get-Command 官方参数说明](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/get-command?view=powershell-7.5)，Name 接受通配模式，不能将模式匹配出的其他工具当作用户所配置工具。

受控发现夹具改为原生通配匹配语义，并新增1个聚合回归，覆盖带空格／方括号的配置路径、误匹配的裸名称、原值保留和缺项提示不回显私有配置。夹具仅证明受控发现契约，不替代真实 Get-Command 的文件、PATH、扩展名和平台行为。

- 两份 PowerShell 脚本通过 Parser.ParseFile 静态语法解析，Python 测试源码通过 ast.parse；没有执行部署入口或工具命令。
- 新聚合及受影响参数回归为 **NOT_RUN**。实际文件命令发现、构建、SDK及 Windows/Linux/macOS 部署验证为 **NOT_RUN**；需恢复验证窗口后确认，不能以受控夹具或解析通过推定完成。
- 未读取运行凭据、启动服务、采样资源、推送或更新部署；既有历史摘要及结果不追认为本轮通过。
