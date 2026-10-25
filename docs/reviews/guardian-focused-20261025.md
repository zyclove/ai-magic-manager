# 当前公共组件定点验证

日期：2026-10-25。验证基础为 `702ed57` 及本批 `Semantics` 两行兼容修正；未更新运行服务。

## 实际结果

| 文件/检查 | 结果 |
| --- | --- |
| `api_test.dart` | 29 项通过 |
| `access_test.dart` | 9 项通过 |
| `console_navigation_test.dart` | 6 项通过 |
| `dialog_submit_guard_test.dart` | 12 项通过 |
| `resource_page_resilience_test.dart` | 首轮编译失败；最小修正后单文件 31 项通过 |
| 相关 12 个源/测试文件严格分析 | `--fatal-infos --fatal-warnings`，无问题 |

五文件分别覆盖 **87 项通过，跳过 0**。首轮整体失败没有改写为成功：当前 Flutter 的 `Semantics` 构造不是 const，移除外层 const 并保留常量子树后，只复验失败文件，没有重复已通过的四个文件。首轮机器汇总的 1 个失败属于文件加载失败，不是已执行的业务断言。

执行前后已核对选定源码、测试和包配置；相对首轮只有上述 `resource_page.dart` 构造修正。使用现有缓存、单并发、D 盘进程临时目录，保留原 RAM/C/D 盘准入门槛与 135 秒命令期限。复用已验收的独立 Job；三次命令分别自然退出 1、0、0，均无强制终止、成员归零、后置 SDK/未知进程名计数为 0。

## 原始记录

- [首轮结果](../evidence/guardian-focused-20261025/tests-first-result.json)、[首轮日志](../evidence/guardian-focused-20261025/tests-first-output.jsonl)：约 16.0 秒，保留编译失败。
- [列表复验结果](../evidence/guardian-focused-20261025/tests-list-rerun-result.json)、[复验日志](../evidence/guardian-focused-20261025/tests-list-rerun-output.jsonl)：约 8.7 秒。
- [严格分析结果](../evidence/guardian-focused-20261025/strict-analysis-result.json)、[分析日志](../evidence/guardian-focused-20261025/strict-analysis-output.log)：约 7.9 秒，原生命令显示 `Analyzing 12 items` 与 `No issues found!`。

分析启动回显的 `files=5` 和结果里的 `tests` 是复用入口的测试列表元数据；实际分析范围以命令及原生日志中的 12 项为准。分析结果里的旧字段 `appTestsPassed` 只表示该分析退出验收，不计作额外测试。原件按原样保留。

本记录仅覆盖这五个 VM 测试文件及列出的静态分析范围。浏览器专属编辑器/详情回归、后端与真实数据库、登录后联合流程、设备/提供方、发布构建及多平台安装仍需对应验证，不能据此宣称全产品验收完成。
