# 设备观察管理端集成记录

## 交付范围（2026-10-09）

设备详情新增“使用情况与隐私”，所有者、监护人、机构管理员可以进入。成人页面读取权限与既有设备管理读取范围一致；教师、审计员和儿童没有此成人入口。打开前后核对工作空间，页面随工作空间或角色变化隐藏旧数据；关闭后返回原设备详情。

应用清单和系统使用摘要分别授权，默认均关闭。修改需要原因、明确确认采集范围和撤回影响、当前资源版本、幂等键和服务端近期 MFA。结果未知时锁定原开关、原因、版本与请求键，支持原样重试；版本冲突要求关闭并刷新。手机提交失败自动滚动到错误和恢复操作，避免只看到禁用按钮。

无障碍收尾中，实际 Chrome 复查发现 Flutter 3.22.2 的禁用字段仅增加 `readOnly` 仍保留可编辑的语义 textarea。锁定时改为静态语义值并排除内部字段语义，同时保留表单状态与原内容重试。该浏览器失败记录为外部 QA 目录的 `observation-console-readonly-red.log`；不能仅凭组件属性断言就声称 HTML 语义已正确。

报告每页最多五批，保留前后翻页。每批明确系统实际聚合区间、设备自报未验证状态、应用前台时长和资料范围；不将重叠区间累加成日总量，不表示完整安装清单、精确计费或实际系统控制。应用行增加完整的无障碍语义说明。

V20 将观察授权绑定当前设备注册。授权变化清空当前应用清单，关闭使用摘要清理服务器批次及回执头；设备下一次核对授权后处理本地旧队列。不能把服务器清理当作离线设备已经擦除。旧应用清单上报现在必须携带 `authorizationVersion`，设备端需使用相容的观察协议；旧客户端不会获得默认授权。

## 验证证据

| 范围 | 实际结果 | 记录 |
|---|---|---|
| 完整后端 V1–V20 独立快照 | 255 项通过，0 失败、0 错误、0 跳过；verify 与可执行打包成功，20:28:31 | `.local/observation-console-backend-verify.log` |
| 真实 MySQL 8.4.11 | 64 项通过，0 失败、0 错误、0 跳过，20:32:52；V1–V20 完整迁移 | `.local/observation-console-mysql.log` |
| 前端独立快照 | 57 项通过，analyze 无问题，HTML release 构建成功 | `.local/observation-console-frontend-tests-final.log`、`.local/observation-console-analyze-final.log`、`.local/observation-console-build-final.log` |
| 手机错误可见性 | 412、503、401 三项先失败，修复后编辑器全部 7 项通过 | `.local/observation-mobile-error-red.log`、`.local/observation-mobile-error-green.log` |
| 权限一致性 | 教师、审计员旧读取判断复现错误，修正为成人设备管理三角色 | `.local/observation-entry-role-red.log`、`.local/observation-entry-green.log` |
| Chrome 完整管理端 | 1440×1000、390×844；4 次隔离夹具写入；默认关闭、独立开关、静态锁定语义、原样重试、分页、逐级返回、角色入口、手机冲突及撤回均通过；页面异常 0 | 外部 QA 目录中的 `observation-console-browser-final.log`、`observation-console-browser-deployed.log` |

MySQL 专项覆盖 DeviceObservationJourney、InventoryJourney、DeviceObservationHttpInterop、TeacherAccessJourney、OrganizationJourney、MemberAccessJourney、OwnershipTransferJourney。真实 Spring/Dart HTTP、观察 SDK 与管理端解析器使用显式包路径启用。使用随机专用库和专用账户，验证后均清理；没有写入本机业务库。

只读独立代码审阅未发现具体 P0–P2 问题。该审阅不替代数据库、浏览器或真实设备验收。完整后端快照的生产源码与当时工作目录逐文件哈希相同；前端后续纳入移动错误提示和应用行无障碍改进后重新跑完整测试、分析和构建。

QA 目录为 `C:/Users/Administrator/.codex/visualizations/2026/10/09/01a11ea6-cc46-7563-baf7-82638043ee15`。截图包含默认关闭、桌面重试、展开报告、手机页面、手机版本冲突和撤回状态。首次浏览器脚本有 Flutter 输入和语义定位问题，已改用真实键盘输入及当前语义；截图发现的移动错误隐藏问题有独立 RED→GREEN 证据。

## 本机部署与真实登录

- 升级前核对业务库 V1–V19 连续成功，并生成 77,234 字节 mysqldump 备份、完成标记和 SHA-256；备份和凭据只在忽略目录。保留旧后端 JAR 与前端构建。
- 20:37:02 业务库 V19→V20 成功，随后再次通过 JDBC 核对 V1–V20 连续成功。后端 PID 180100，前端 3000、后端健康 8082、身份发现 8081 均 200。
- 候选 JAR、常规启动用的 backend/target JAR、运行 JAR 哈希一致：`F115A4472DCEE89DFA3D198A20E49FADC712D271E984C80AA345CF562B474B4C`。
- 20:46:54 最终无障碍修复部署后，候选 main.dart.js、服务目录和实际 HTTP 下载哈希一致：`A25B1E14EEC7FA565D5D02EC49906AC525C1FCD9BCB1E7B7EDC017DC9EF5361D`。
- 指定管理员真实 Keycloak 密码登录通过，角色 OWNER、身份与工作空间接口 200。检查三个可见工作空间，当前设备数为零，因此未声称在业务库中读取到真实设备的观察数据。不存在设备按既有范围隐藏语义返回 403；首轮脚本错误预期 404，检查 FleetReads 后修正，未修改生产授权行为。
- 最终构建在 3000 部署后重新真实登录，并重跑整套桌面/手机隔离浏览器交互，全部通过。锁定原因的 editable textbox 数量为零，静态值可读；重试体、版本和键与原提交相同。日志为 `observation-live-admin.log` 和 `observation-console-browser-deployed.log`。
- 真实敏感授权成功写入仍需管理员本人绑定验证器。浏览器夹具及测试 JWT/MFA 均不代替这一验收；没有创建虚假业务设备或伪造真实设备报告。

## 后续范围

本阶段完成观察管理入口、协议集成与本机服务更新。Android/TV 真机、系统特殊权限、原生执行、硬额度与正式受管能力，以及完整产品其他剩余阶段继续按实施计划推进；当前报告不能证明这些能力已经可用。全产品目标保持进行中。
