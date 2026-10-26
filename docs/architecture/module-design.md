# 领域模块设计标准

更新：2026-10-26。沿用已有 Spring Boot / Spring Modulith 模块化单体与 Flutter 共享包；本轮统一增改标准，不进行无收益的全仓迁移或拆分微服务。

## 当前边界与所有权

| 模块/位置 | 所属职责与边界 |
| --- | --- |
| `backend/src/main/java/com/aimanager/tenant`、`identity`、`subject`、`fleet` | 工作空间授权、身份、受管主体与设备事实；调用者必须带上真实上下文 |
| 同级 `schedule`、`policy`、`approval`、`quota` | 时间规则、策略、申请决定与额度；各自维护业务约束和事务 |
| 同级 `delivery`、`managedandroid`、`messaging` | 签名配置交付、受管适配与通知传输；传输结果不替代设备执行事实 |
| 同级 `commerce`、`reporting`、`audit`、`lifecycle` | 商业权益、报表、审计及生命周期；不能直接修改其他域的内部表 |
| `apps/guardian/lib/core`、`pages`、`ui` | API/会话与领域呈现、页面编排、通用交互组件；浏览器存储与平台能力留在明确边界 |
| `apps/parent`、`apps/child` | 端侧宿主、导航、身份与平台适配；不复制服务端授权规则作为最终权限依据 |
| `packages/schedule_contracts` | 两端时间安排示例的纯响应解析与不可变值；宿主负责有界网络、授权、草稿、保存和发布 |
| `packages/device_identity`、`device_policy`、`device_access` 等 | 可复用协议、校验、持久化与同步；宿主注入凭据、安全存储、可信上下文和调度 |
| `deploy/compose`、`deploy/helm/ai-manager`、`scripts` | 部署拓扑、环境参数和受控操作；不承担业务规则和用户权限判定 |

以上是位置索引，具体公开类型以源码为准。后端主入口 [ManagerApplication.java](../../backend/src/main/java/com/aimanager/ManagerApplication.java) 使用直接子包划分领域；[ModuleBoundariesTest.java](../../backend/src/test/java/com/aimanager/ModuleBoundariesTest.java) 是已有边界检查入口。

## 新增或调整一个模块

保持最少必要层次，复用已有命名：

```text
com.aimanager.<domain>/
  <Domain>ReadAccess.java       # 跨域确有需要的查询/用例契约
  <BusinessFact>.java           # 不可变值或可信域事件
  internal/
    <Domain>Controller.java     # HTTP 输入、认证上下文、响应映射
    <Domain>Service.java        # 用例编排、授权复核、事务边界
    <Domain>Repository.java     # 必要时隔离存储访问
```

这是按需采用的模板，不要求每个域补齐所有文件。简单纯规则可直接使用已有值对象/引擎；不要为一处调用建立通用框架。

- 其他域只依赖公开根包契约，不导入 `internal`、直接访问其表或绕过其业务服务。`shared` 只接纳稳定技术原语，不成为跨域业务杂物箱。
- 控制器不承载领域状态机；服务不依赖 Flutter 页面或部署脚本。领域事件表达已发生的事实，不把外部 Broker 消息直接当作可信授权事实。
- 例：时间规则经 [ScheduleCatalog](../../backend/src/main/java/com/aimanager/schedule/ScheduleCatalog.java) 暴露；策略提交的 [PolicyConfigurationRecorded](../../backend/src/main/java/com/aimanager/policy/PolicyConfigurationRecorded.java) 明确为可信进程内事件。
- 数据变更在所属域短事务中完成；外部 HTTP/EMM 调用不持有业务锁。需要跨域恢复时使用既有持久作业、版本和幂等机制，不用无界轮询。
- 接口返回稳定领域错误码，界面翻译成对象、原因、下一步。分页、期限、时区、空值与并发版本在所属契约中明确。

## 配置与功能管理

| 层次 | 所有者 | 应用规则 |
| --- | --- | --- |
| 环境/基础设施 | 部署维护者 | 现有 `application.yml`、Compose/Helm 参数；秘密独立注入；必要时重启 |
| 业务规则 | 获授权租户管理员 | 领域 API 校验租户、对象、版本和有效期；按领域发布机制应用 |
| 商业权益 | 商业领域 | 从可信合同/权益事实计算；不能当作技术能力或用户授权 |
| 设备/供应商能力 | 对应适配器与证据所有者 | 核对设备模式、范围、版本与时效；未知或未配置时保持明确不可用 |
| 个人展示偏好 | 当前用户/客户端 | 仅影响布局、过滤、显示；不授予后台能力 |

新增配置依次明确：归属和用途 → 类型/范围/安全默认值 → 服务端校验 → 持久化或部署注入 → 应用时机 → 状态反馈与审计 → 撤销/失效。不能用一个万能布尔值替代整个生命周期。

有效操作须同时满足适用配置、权益（如需要）、当前授权、实际能力及运行条件；具体判断顺序和错误信息由用例决定。前端可据此简化操作入口，服务端仍在实际读写时复核。

管理台的 `apps/guardian/lib/core/console_modules.dart` 集中维护客户端模块 ID、名称、机构称呼、分组、搜索词和已知路由。导航消费该不可变目录，权限仍由 `Session` 与服务端独立核对；目录不构成服务端功能开关或全站功能管理系统。调整元数据应保留既有入口与排序，不放宽登录返回路径的本地路由限制。

## 扩展适配器与跨端复用

1. 在所属域定义最小端口与领域结果，供应商 SDK、HTTP、OS 调用放在适配器内部。新增提供方不要求上层页面识别其 SDK 类型。
2. 每个适配器声明支持范围、配置、超时、重试条件及不可用原因；默认关闭尚未具备准入或真实验证的执行能力。
3. Dart 共享包接受宿主提供的依赖；端侧密钥、安全存储和调度不能由通用组件偷偷创建。可参考 [device_policy 的宿主契约](../../packages/device_policy/README.md)。
4. 共享组件统一 loading/empty/error/unknown 与防重复提交，保留查询、焦点和输入；页面负责本任务的少量编排，不复制网络恢复状态机。
   [ResourcePage](../../apps/guardian/lib/ui/resource_page.dart) 对可能修改数据的详情提供 `onOpenChanged`，以明确的处理结果决定是否重读；普通取消和只读返回不等同于修改。明确关闭结果不明的写入也须重读核对，但不能据此报告保存成功。原 `onOpen` 与该结果回调互斥，避免同一行启动两条详情流程。临时 `canInteract` 门禁只限制新事件，不丢弃已经确认保存后的读取；刷新仍核对原 owner、资源和权限。时间计划复制使用此边界。
5. 只有出现真实第二个使用方或明确变化点时再提取通用抽象；保留成熟框架惯例，避免万能实体、万能配置表和动态脚本规则引擎。

## 变更与验证

用一份领域契约记录范围、状态、错误和边界；重要且难逆转的取舍才新增简短决策记录。文档和配置不重复生成源码副本或证据清单。

后端 Maven 支持 `-Dbackend.build.directory=<绝对目录>`，默认仍为 `backend/target`；定向验证可将输出放在项目忽略的 `.cache` 中，无需清空旧产物或复制源码。`test` 阶段不打包服务 JAR。[模块门禁](../../backend/src/test/java/com/aimanager/ModuleBoundariesTest.java)按本次测试类 CodeSource 精确排除测试输出，先核对生产目录不会被排除，再保留完整 `verify()`；不依赖 `target/test-classes` 等固定目录名，也不按类名或包名整体忽略违规。

只运行与本批变化有关的检查：纯文档看差异；领域行为选受影响测试；跨域依赖调整运行已有模块边界检查；接口、权限或数据一致性变动再扩展到对应集成。部署模板可用不代表真实集群、设备或提供方已经验收。
