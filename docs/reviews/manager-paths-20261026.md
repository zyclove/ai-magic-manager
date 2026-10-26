# 统一部署入口路径基准：静态阶段

日期：2026-10-26。基础提交：`6ebcb1b790905d1947b582d626a8bf6180f26a0a`。状态：源码与文档收尾，实际参数回归未运行；未推送或部署。

部署入口原先仅把部署目录固定在仓库基址；构建下级已经如此处理 SourceDirectory/MavenRepository，但显式身份目录与带目录的工具名称仍可能依赖调用者工作目录。例如从 scripts/tests 启动时，`.local/identity admin` 会与初始化记录的目录不一致；相对 SDK 路径也可能找不到或指向不同入口。

[manager.ps1](../../scripts/manager.ps1) 现在统一处理显式 SourceDirectory、MavenRepository、IdentityAdminDirectory、IdentityRuntimeDirectory，再处理带本系统目录分隔符或根路径的 MavenCommand/FlutterCommand/DartCommand。相对值按入口所在仓库解析，绝对值保留其含义；裸名称继续从 PATH 查找。部署目录仍限于原 `.local/` 边界，身份授权及文件核验仍在原下级动作中执行。这是路径字符串规范化，不读取配置、不检查存在性、不跟随链接或替代既有 Flutter SDK 链接解析。

预览与执行使用同一份最终参数，四类目录显示最终绝对路径。简明部署说明和项目记忆已同步，Windows/POSIX 包装器保持原样；不能据静态源码宣称 Linux/macOS 或真实安装验收完成。

检查事实：

- PowerShell AST 及 Python AST 语法检查通过；未执行管理入口、导入测试或调用 SDK。
- 独立静态审查未发现可证明的问题；差异、空白及相关文档本地链接已核对。
- 新增 1 项参数计划回归，包含两种工作目录下的 build/start 四组计划，覆盖带空格的路径；既有用例调整最终路径期望，并继续检查裸命令名称。这些测试均未运行，也没有新建环境、读取身份配置或更改服务。

恢复验证窗口后，仅运行新增路径用例，以及已有入口/裸命令、非法参数和预览不创建环境用例；不为本批启动 Java/Flutter、构建或全量套件。前端本地依赖解析及其他阶段的未运行项保持原状态。

本次源码摘要（静态候选定位，不代表实际命令通过）：

- `scripts/manager.ps1`：`6171aa98f13f6a5e1b12fc8ed1c17565dce860fe860c2a01ac4690a12f12fa2d`
- `scripts/tests/test_manager_entry.py`：`11aec6638186d5ed65d8874e0b658a200648a343ee7d256814530b5b1381d0dc`
