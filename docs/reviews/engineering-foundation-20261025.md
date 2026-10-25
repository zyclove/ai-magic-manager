# 规格、模块目录与部署入口整理

日期：2026-10-25。本批改善工程入口和扩展方式，不代表全产品验收或运行环境更新。

## 改动

- [SPEC](../SPEC.md)统一规格入口及简洁交互、配置和执行状态语义；[模块标准](../architecture/module-design.md)约定领域所有权、公开契约、配置生命周期和适配器扩展。
- [项目记忆](../project-memory.md)集中稳定决定与源码导航；[AGENTS](../../AGENTS.md)补充按需选用技能及记忆维护规则，沿用最小必要验证。
- [模块目录](../../apps/guardian/lib/core/console_modules.dart)集中导航名称、分组、机构称呼、搜索词与精确内部返回路径。图标留在呈现层，用户/租户授权与后台功能准入保持独立。
- [部署入口](../deployment-quickstart.md)统一 doctor/init/build/init-ledger/start/status/verify，支持操作预览和 Windows/POSIX 启动器。复用现有脚本，不自动安装依赖、串联初始化或更新服务。
- README 将旧本机端口和验收结果明确标为历史记录，当前环境从选定部署元数据定位。

## 本批检查

| 检查 | 实际结果 |
| --- | --- |
| `python -I -B scripts/tests/test_manager_entry.py`，指定现有 PowerShell 7 | 5 项通过，11.828 秒；只执行新入口的计划和输入保护，不访问服务或运行 SDK |
| PowerShell 语法解析 | 通过 |
| 导航迁移静态比较 | 27 项名称/图标/搜索词、4 组显示顺序、2 个机构称呼和 28 条精确返回路径与原实现一致 |
| 本批文档及索引的本地链接 | 138 处存在，缺失 0 |

静态比较不能替代 Dart 编译或交互运行。Flutter 分析及现有 `console_navigation_test.dart`、`access_test.dart` 回归尚未运行；资源和错峰条件满足后仅验证这些受影响路径，失败再按原因扩展。

未执行 Linux/macOS 安装、真实初始化、构建、服务部署、后台全套或设备/供应商验证。现有运行服务保持原发布版本。本批目录是客户端元数据，不是已经完成的服务端动态功能开关系统。
