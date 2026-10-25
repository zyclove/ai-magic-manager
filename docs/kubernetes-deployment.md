# Kubernetes 与 Helm 部署基线

## 范围与先决条件

`deploy/helm/ai-manager` 部署 Flutter Web 静态界面、Spring API 双副本和一个后台作业副本。MySQL、Keycloak、入口控制器、TLS、备份、外部消息服务由现有平台提供。Chart 不创建业务用户、数据库、密钥、身份服务或受管 Android 策略；当前也没有在真实 Kubernetes 集群完成容量、故障切换和恢复验收。

在同一命名空间准备：

1. Keycloak Service，HTTP 端口必须提供 `/identity` 相对路径；公开的 `https://域名/identity/realms/ai-manager` 必须是令牌 issuer。Keycloak 自己的数据库与运行配置按官方方式管理。
2. MySQL 8.4 LTS 业务库、专用账号和经过演练的备份。OceanBase MySQL 模式仅在单独 SQL/迁移/故障切换认证后选用。
3. 已存在的 Kubernetes Secret：业务库密码键 `spring.datasource.password`；签名密钥键 `signing.jwk` 和 `verification.jwks`。Chart 仅引用 Secret 名称，不把密钥写入 values 或镜像。签名私钥仅供获授权的 Pod 读取；轮换时保留仍有效文档对应的验签公钥。
4. 与公开域名匹配的 TLS Secret、入口控制器及可信代理配置。仅对外开放 HTTPS，浏览器回调必须在 Keycloak 客户端允许列表中；Guardian Web 产物用同一公开 origin 的 `API_URL`/`OIDC_ISSUER` 构建。部署镜像应使用经过验证的不可变 digest。
5. 独立 MySQL 删除账本、固定小写 UUID、独立运行账号及 Secret。先按 `erasure-ledger-plan.md` 显式初始化空账本，运行账号只授予账本头 SELECT/UPDATE、条目 SELECT/INSERT。账本身份、凭据、备份与恢复权限不得随业务库一起回退。
6. 当前按未上线的 1.0.0 基线从空业务库执行 V1/V2 初始化，不提供历史开发库升级路径。需要更换开发数据结构时使用新库，保留既有数据由部署方明确处理。

## 安装配置

将下列**非秘密**配置放入环境专用文件（示例名称 `manager-values.yaml`，不要提交真实环境配置）：

```yaml
publicOrigin: https://manager.example.com
images:
  backend: registry.example.com/ai-manager/backend@sha256:0000000000000000000000000000000000000000000000000000000000000000 # replace with verified digest
  edge: registry.example.com/ai-manager/edge@sha256:0000000000000000000000000000000000000000000000000000000000000000 # replace with verified digest
database:
  jdbcUrl: "jdbc:mysql://mysql.example.internal:3306/ai_manager?preserveInstants=true&connectionTimeZone=UTC&forceConnectionTimeZoneToSession=true"
  username: ai_manager
  existingSecret: manager-db-password
erasureLedger:
  jdbcUrl: "jdbc:mysql://erasure.example.internal:3306/erasure_ledger?preserveInstants=true&connectionTimeZone=UTC&forceConnectionTimeZoneToSession=true"
  username: erasure_runtime
  id: 11111111-2222-4333-8444-555555555555 # replace with the provisioned fixed identity
  existingSecret: manager-erasure-password
  passwordKey: password
identity:
  serviceName: manager-keycloak
  servicePort: 8080
signing:
  existingSecret: manager-signing-keys
contract:
  evidenceEnabled: false
  activeSubmissionsEnabled: false
  issuer: ""
  audience: ""
  jwkSetUri: ""
ingress:
  host: manager.example.com
  tlsSecretName: manager-tls
  className: nginx
```

外部 `DATABASE_URL`、`ERASURE_LEDGER_URL`、`spring.datasource.url` 或 `manager.erasure-ledger.url` 会替换相应地址；Helm 的 `database.jdbcUrl` 与 `erasureLedger.jdbcUrl` 按提供值原样传入。覆盖时同样显式保留 `preserveInstants=true`、`connectionTimeZone=UTC` 与 `forceConnectionTimeZoneToSession=true`，并保留该环境已有 TLS、超时和认证参数；不要仅设置 JVM 时区或数据库默认时区。此变更只配置应用自有连接的会话，不执行数据迁移。配置含义及待运行的核对流程见 [MySQL UTC 会话说明](mysql-utc-session-configuration.md)。

使用已固定版本的 Helm 在独立环境执行 `helm lint deploy/helm/ai-manager -f manager-values.yaml` 和 `helm template manager deploy/helm/ai-manager -f manager-values.yaml`；检查渲染结果没有私钥或密码，且所有容器镜像 digest 与发布清单一致。经变更审批后才执行 `helm upgrade --install manager deploy/helm/ai-manager -n <namespace> -f manager-values.yaml --atomic --wait`。仓库没有附带可直接部署的真实凭据或镜像地址。

Chart 在缺少 HTTPS origin、镜像、业务或账本数据库地址/账号、固定账本 ID、Secret、身份 Service 或 TLS 域名时拒绝渲染。`publicOrigin` 必须严格等于 `https://ingress.host`。Ingress 将 `/api` 交给 API Service、`/identity` 交给现有 Keycloak Service，其余路径交给 Flutter Web。Web 容器对误入的 `/api`、`/identity` 返回 404，不把这些路径回退成前端页面。入口控制器须保留路径，不做剥前缀重写。`ingress.enabled=false` 时，部署方必须自己提供语义相同的 HTTPS 路由。

`contract` 的双开关默认关闭，API 和 worker 使用相同配置。取得合格合同签发方、完成商业审核与签名验证后，才填写 HTTPS `issuer` / `jwkSetUri` 及专用 `audience` 并开启 `evidenceEnabled`；新 ACTIVE 合同另需开启 `activeSubmissionsEnabled`。Chart 在开启证据开关但缺少签发方字段时拒绝渲染，Spring 启动时再次校验 HTTPS。只关闭 ACTIVE 开关仍可处理可信撤销；关闭证据开关也会停止待审合同的批准和待机构确认合同的入账。多副本暂停销售时须先排空旧配置 Pod，再宣布暂停生效。当前没有正式签发方，生产配置应维持关闭；具体流程见[机构合同首发手册](institution-commercial-launch-runbook.md)。

镜像必须使用完整的 SHA-256 digest；示例中的全零值仅用于说明字段形状，不能部署。入口控制器还须强制 HTTP 跳转 HTTPS；配置 Ingress TLS Secret 本身不能证明跳转已生效，应在部署前后分别验证。

## 多副本与安全边界

- API 和 Web 默认各两个副本、滚动更新时 `maxUnavailable=0`、各自 PDB `minAvailable=1`。可在具备 Metrics Server 的集群中启用 API CPU HPA（默认关闭，范围与目标值可配置）；它不能代替设备并发、数据库连接和队列容量压测。这些设置只约束副本数量与自愿驱逐；真实高可用仍取决于多节点调度、存储、入口、MySQL 和 Keycloak。给不同节点设置反亲和与拓扑分散的生产参数要基于部署环境和负载测试确定。
- HPA 关闭时使用 `api.replicas`，最低为 2；启用后 API Deployment 不再设置固定副本，由 `minReplicas` / `maxReplicas` 管理，二者均至少为 2 且最小值不得超过最大值。启用 HPA 时无需同步调整未使用的固定值，但其类型仍须为非负整数；Web 固定副本要求不变。
- 独立 worker 运行报表、导出、通知保留、额度物化、清理和审批到期作业；API 副本关闭这些作业。worker 保持单副本，升级时短时重叠仍需依赖业务事务幂等。使用摘要的旧批次清理目前在每个 Spring 实例上独立定时执行，采用有界、可重复删除；此项未作为全局唯一作业承诺。
- Pod 使用固定非 root UID、只读根文件系统、禁用权限提升、丢弃 Linux capability、RuntimeDefault seccomp、禁用 ServiceAccount Token 自动挂载，并给 `/tmp` 等写入点加有界临时卷。不同环境仍需实施 NetworkPolicy、数据库/TLS 出站策略、Secret 加密与 RBAC；Chart 本身不宣称完成这些集群级措施。
- Spring 用 Kubernetes Secret 作为 `configtree:` 数据库密码及只读签名文件；健康探针分 startup、liveness、readiness。工作 Pod 不对外路由。当前 Kafka/Artemis 通知传输默认关闭，启用前须补齐真实 Broker 的认证、TLS、ACL 和故障演练。

API 与 worker 都强制在启动完成前检查独立账本。当前仅允许已验证空账本进入就绪；缺失、损坏、不可访问或非空时启动失败。尚未实现的域处理器与已应用水位不能通过人工把读取游标置为完成来替代；启动保护也不等于运行期跨节点隔离已经完成。

## 发布检查与恢复

部署前检查 1.0.0 初始化基线、独立账本初始化与权限、Keycloak issuer/JWKS、浏览器回调、证书、镜像摘要、Secret 键、数据库容量与备份恢复记录。部署后检查 `/actuator/health/readiness`、Web `/healthz`、公开 `/identity`、真实 PKCE 登录、普通 API 读取、近期 MFA 敏感写入、设备凭证调用和一次受控的签名配置回执；没有这些证据不能宣称集群生产可用。

首版初始化失败时先停止流量，检查初始化结果并保留现场；不要自动清空库或把 `helm rollback` 当作数据库恢复。恢复业务备份时保留独立账本的最新状态，并重新执行启动保护；完整恢复再删除演练仍待域处理器实现后验收。定期演练 MySQL 和 Keycloak 的备份、恢复、跨节点切换、密钥轮换、长连接/Broker 恢复与断网重连风暴。百万注册设备只作为压测基线，在线比例和心跳频率必须用实际试点数据确定。

本 Chart 只完成可配置部署模板。Android 受管执行、电视适配、OceanBase 认证、真实多区域部署与高并发验收仍需独立实现及证据。

## 参考资料

- [Helm 模板与校验](https://helm.sh/docs/chart_template_guide/debugging/)
- [Kubernetes 启动、存活与就绪探针](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-probes/)
- [Kubernetes Ingress 路径与 TLS](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Spring Boot Kubernetes 健康探针](https://docs.spring.io/spring-boot/reference/features/spring-application.html)
