# AI Manager 智能管家

面向家庭和教育机构的跨设备访问管理平台。完整功能正在按[实施计划](docs/implementation-plan.md)推进；当前状态和验证记录见[实施记录](docs/implementation-progress.md)。

当前统一按 **1.0.0 首版**初始化和开发，不承担历史开发版本的兼容与数据升级迁移。全新安装、版本与数据库基线见 [1.0.0 初始化约定](docs/version-1.0.0-initialization.md)。

## 工程结构

- `backend/`：Spring Boot 模块化后端、全新数据库初始化和行为测试。
- `docs/`：产品、功能、架构、商业与实施契约。
- `apps/guardian/`：Flutter Web 中文管理工作台，连接真实 OIDC 与业务 API。
- `packages/device_operations/`：可复用设备退出操作组件。
- `deploy/keycloak/themes/ai-manager/`：身份服务登录主题。
- Android/TV 原生代理和系统执行适配仍按计划推进。

## 本机启动与管理端

从干净克隆部署新环境，使用 `scripts/initialize-deployment.ps1`、`scripts/build-deployment.ps1`、`scripts/start-deployment.ps1`；流程与身份初始化见[可复制部署手册](docs/deployment-runbook.md)。该流程使用独立 Compose 项目和文件凭据。

本机已配置的服务：管理端 `http://localhost:3000`、后端 `http://localhost:8082`、身份服务 `http://localhost:8081`。本地 MySQL 使用 3308 端口。运行 `./scripts/start-local.ps1` 可恢复本机服务；此入口使用忽略目录 `.local/runtime/` 中已配置的本机凭据，不会创建默认密码。

管理员使用已单独配置的账号登录。首次执行设备注册、成员邀请或策略发布前，在“设置 → 账户与验证器”绑定自己的验证器，再执行“重新安全验证”。前端使用授权码 + PKCE，令牌仅保存在当前标签页会话中。

前端开发要求 Flutter 3.22.2 / Dart 3.4.3 或经验证的兼容版本：

```powershell
cd apps/guardian
flutter pub get
flutter run -d chrome --web-port 3000
# 生成静态部署产物
flutter build web --release --web-renderer html --pwa-strategy=none
```

其他环境通过 `--dart-define=API_URL=...`、`--dart-define=OIDC_ISSUER=...` 配置服务；同步设置身份客户端 `ai-manager-guardian` 的回调地址 `/auth/callback`、Web Origin 和后端 `CORS_ALLOWED_ORIGINS`。生产使用 HTTPS 并设置 `--dart-define=ALLOW_LOCAL_HTTP=false`，静态服务器需将前端路由回退至 `index.html`。

功能范围和验收记录见[管理端交付记录](docs/management-console-delivery.md)。

## 产品与商业设计

完整设计从[文档索引](docs/README.md)开始。最新补充的[产品交付与商业运营模型](docs/parental-control-product-operating-model.md)覆盖全功能工作包、状态机、页面、异常、套餐计量和上市流程；[数据库实施与认证规格](docs/database-implementation-and-certification.md)细化 MySQL 默认方案与 OceanBase 可选方案的事务、容量、认证、迁移和恢复。

## 后端开发

要求 Java 17+、Maven 3.9+，生产默认 MySQL 8.4。运行前提供：

```powershell
$env:DATABASE_URL = 'jdbc:mysql://localhost:3306/ai_manager?connectionTimeZone=UTC'
$env:DATABASE_USERNAME = 'ai_manager'
$env:DATABASE_PASSWORD = '<由本地密钥配置提供>'
$env:OIDC_ISSUER_URI = 'https://你的身份服务/realms/ai-manager'
$env:OIDC_AUDIENCE = 'ai-manager-api'
mvn -f backend/pom.xml spring-boot:run
```

不要把密码/私钥提交到仓库。用户 API 使用标准 Bearer JWT；`tenant:create` scope 只能发给可信成人/机构管理员，儿童账户不能自行设置。租户角色在数据库中校验，不以客户端传入角色授权。

```powershell
mvn -f backend/pom.xml test
```

测试数据库使用 H2 MySQL 模式，不能代替真实 MySQL、OIDC、Broker、EMM 和真机验收。当前没有可验证的供应商/设备执行能力，不提供“全部已受保护”的承诺。

Windows 上正在运行的 JAR 可能阻止 Maven 重打包重命名。需要保留当前进程时，使用新产物名称执行 `mvn -f backend/pom.xml verify -Dbackend.artifact-name=manager-backend-review`；产物位于 `backend/target/manager-backend-review.jar`。每次运行中的产物使用独立名称，构建不代表部署已更新。

当前管理接口与配置见[后端接口状态](docs/backend-api-status.md)。设置 `API_DOCS_ENABLED=true` 后可在 `/v3/api-docs` 获取实现路由的 OpenAPI 3.1，需要有效 Bearer 认证；生产默认关闭。

设备注册/恢复、独立凭证、心跳与能力接口见[设备接入契约](docs/device-registration-contract.md)。当前支持 BYOD 云端绑定与有限观察；受管系统执行仍待正式 EMM/原生适配，不把注册或心跳成功作为管控已生效。

应用目录/设备清单、时间计划、策略草稿/模板、预览、配置版本及回滚见[应用、时间与策略契约](docs/policy-application-schedule-contract.md)。当前配置保存结果为 `CONFIGURED_NOT_ENFORCED`，没有系统执行适配器；`ENFORCE` 返回明确不支持/未配置原因。

设备签名配置拉取/回执与 Kafka/Artemis 通知适配层见[配置交付契约](docs/configuration-delivery-contract.md)。签名密钥必须外置，Broker 通知默认关闭；回执只表示设备自报接收/保存，不表示系统执行。真实 Broker、MQTT、EMM 和客户端联调仍待验证。

临时访问申请/决定/撤销、到期与生命周期失效见[审批契约](docs/access-request-contract.md)。当前管理员批准保存有界窗口，executionState 为 NOT_ENFORCED；没有设备解锁、例外许可签发或额度追加。

设备退出后果预览/确认、云端撤销和独立清理任务见[退出管理契约](docs/device-deprovision-contract.md)。原注册密钥只能访问限时清理命名空间；本地结果保持设备自报未验证。客户端清理执行、受管解除和整机擦除仍待实现。
