# 项目记忆

本页只保存稳定约定和导航，不替代规格、源码或验收记录。先读 [AGENTS.md](../AGENTS.md)，再按任务打开下列相关入口；无需每次通读全部文档。冲突时以用户最新指令和当前实现为依据，同步修正文档差异。

## 产品与领域边界

- 智能管家面向家庭和教育机构，管理成员、设备、应用、时间计划、策略、临时访问与额度；完整范围见[功能规格](parental-control-functional-spec.md)。
- 工作空间对应租户权限边界；服务端校验成员角色与操作范围，客户端显示状态不能代替授权。身份与设备接入分别见[后端接口](backend-api-status.md)、[设备接入契约](device-registration-contract.md)。
- 配置保存、设备接收、自报回执与系统实际执行是不同状态。能力以设备模式、适配器及实际验收为准，不能把 `CONFIGURED_NOT_ENFORCED` 或 `STORED` 展示为已执行。
- 规划、源码实现、构建产物、正在运行的服务和验证结果分别记录；新提交不会自动更新运行环境。

## 权威文档入口

| 任务 | 入口 |
| --- | --- |
| 规格与工程标准 | [SPEC](SPEC.md)、[领域模块设计](architecture/module-design.md) |
| 产品范围与流程 | [功能规格](parental-control-functional-spec.md)、[产品交付规格](parental-control-product-delivery-spec.md) |
| 架构与设备能力 | [平台设计蓝图](parental-control-platform-design.md) |
| 当前实施范围 | [实施计划](implementation-plan.md)、[实施记录](implementation-progress.md) |
| 首版版本与建库 | [1.0.0 初始化约定](version-1.0.0-initialization.md) |
| 实际 API 与交互契约 | [后端接口](backend-api-status.md)、[应用/时间/策略](policy-application-schedule-contract.md)、[审批](access-request-contract.md) |
| 部署与环境操作 | [简明入口](deployment-quickstart.md)、[完整手册](deployment-runbook.md)；执行前核对实际目标，不能沿用文档中的历史环境状态 |
| 其他专题 | [文档索引](README.md)，仅打开与本次变更有关的契约 |

## 源码导航与复用

| 范围 | 入口与约定 |
| --- | --- |
| 模块化后端 | [领域模块](../backend/src/main/java/com/aimanager/)、[构建配置](../backend/pom.xml)；沿既有领域边界组织逻辑 |
| Web 管理工作台 | [Guardian](../apps/guardian/README.md)：[入口](../apps/guardian/lib/main.dart)、[核心](../apps/guardian/lib/core/)、[页面](../apps/guardian/lib/pages/)、[共享界面](../apps/guardian/lib/ui/) |
| 监护人手机端 | [Parent](../apps/parent/README.md)，复用后端契约和现有共享模块 |
| 儿童设备端 | [Child](../apps/child/README.md)，区分观察授权、配置存储和系统执行能力 |
| 设备共享模块 | [身份](../packages/device_identity/README.md)、[策略](../packages/device_policy/README.md)、[访问](../packages/device_access/README.md)、[观察](../packages/device_observation/README.md)、[退出操作](../packages/device_operations/README.md)、[清理](../packages/device_cleanup/README.md) |
| 身份服务扩展 | [Keycloak 扩展](../identity-extensions/README.md)，外部身份能力按明确配置启用 |

优先复用现有领域服务、共享包和成熟框架。新增抽象应解决实际重复或明确边界，不为小改动另建一套模块、脚手架或技能。

管理台导航的名称、分组、搜索词和已知路由统一在 [console_modules.dart](../apps/guardian/lib/core/console_modules.dart)；[导航组件](../apps/guardian/lib/ui/console_navigation.dart)只负责呈现。目录不授予 API 权限，服务端与会话仍独立校验。

管理台异步旅程可复用 [DeviceSubflowScope](../apps/guardian/lib/pages/device_subflow_scope.dart) 捕获账号、租户、角色和会话代际；名称虽源自设备流程，通知与工作台也采用此机制。旧响应与回调必须核对原捕获，不能仅比较当前租户/角色。普通网络失败可保留已读数据，服务端拒绝访问则隐藏私有摘要并作废捕获。

在仓库根目录可用 `pwsh -File scripts/manager.ps1 status -Active` 只读定位已选环境（2026-10-25 已实际执行）。前提是 PowerShell 7、可访问的 Docker 及完整的环境选择记录；显式目录查询使用 `status -Directory ...`。状态查询不自动恢复或发布服务，也不代替业务验收。[入口实现](../scripts/manager.ps1)会选取首个 Docker 可执行入口，避免 Windows 多个同名命令被拼成路径。

统一部署入口的初始化默认值由同一处解析，预览与执行共用：本机换端口只填 `-EdgePort`，指定公开 URL 时自动采用其端口；外部 TLS 代理保留独立内部端口。显式填写的 URL/端口仍交给初始化器校验，见[简明部署入口](deployment-quickstart.md)。

## 已确认的用户约定

- 按 **1.0.0 首版**设计与初始化，移除不必要的历史业务兼容和升级链；不因此删除现有数据，也不取消隐私删除、备份恢复、协议版本和并发控制。
- 界面优先简洁、易操作，减少步骤与重复输入；准确呈现待处理、未知、失败和完成状态，明确下一步动作。
- 按风险选择最小有效检查；文案和文档改动默认只审差异，行为改动验证受影响路径，关键权限/数据/契约变动检查相应集成边界。资源不足时说明未运行项，不重复无效尝试。
- 相关检查已足够时停止追加验证；复用范围内仍有效的结果，不把历史通过当作新行为通过。
- 阶段完成后本地提交相关改动，保留他人工作；提交不自动触发推送或部署。执行外部操作仍核对本次适用授权。
- 临时目录、构建并发、资源与维护边界统一遵循 [AGENTS.md](../AGENTS.md)，本页不复制门槛和环境快照。

## 维护与敏感信息

- 稳定的领域边界、公共契约、模块入口或用户长期约定变化时更新本页；普通实现进度与一次性故障写入对应任务记录即可。
- 优先修正原条目、合并重复并链接权威来源；移除失效入口，不累积会话历史、旧进程信息、资源采样或缓存证据清单。
- 不保存账号密码、令牌、私钥、会话标识、个人数据及环境文件内容；不把敏感配置或原始数据复制到记忆、技能、日志或提交中。
- 技能按当前任务选用现有最相关者；项目惯例保留在仓库文档中。确有重复且可泛化的工作流时，才单独评估创建项目技能。
