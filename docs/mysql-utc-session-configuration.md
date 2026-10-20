# MySQL UTC 会话配置

## 当前状态

**SOURCE_CONFIGURATION_PENDING_RUNTIME_VERIFICATION**。本阶段补齐本地默认数据源、Compose 业务库/独立账本地址及 Kubernetes 示例的 JDBC 参数；尚未执行编译、测试、SQL、服务更新或部署。已提交的 90 天恢复逻辑仍须完成全端协议和真实数据库验证后才能上线。

## 为什么需要这项配置

`connectionTimeZone=UTC` 指定驱动的时间解释方式，本身不设置数据库会话时区；`forceConnectionTimeZoneToSession=true` 才要求驱动设置该会话。`preserveInstants=true` 用于保留时间点语义。[Connector/J 官方配置说明](https://dev.mysql.com/doc/connector-j/en/connector-j-connp-props-datetime-types-processing.html)

本项目统一使用驱动已有的三个属性，不增加 URL 重写器或时间换算实现。Spring Security 官方 MySQL 建表说明也给出同一属性组合；这只是配置依据，不代表本项目已通过运行验收。[Spring 官方示例](https://github.com/spring-projects/spring-security/blob/main/oauth2/oauth2-authorization-server/src/main/resources/org/springframework/security/oauth2/server/authorization/oauth2-authorization-schema.sql)

```text
preserveInstants=true&connectionTimeZone=UTC&forceConnectionTimeZoneToSession=true
```

数据库与驱动的时间解释不一致时，可信时间检查可能拒绝恢复或清理。不能通过扩大偏差容限、关闭校验或回退本机时间来处理会话配置问题。配置 UTC 也不能修复真实时钟漂移；主库及各节点仍需独立校时和监测。

## 部署时如何填写

| 使用方式 | 配置入口 | 行为 |
| --- | --- | --- |
| 本地默认 MySQL | `application.yml` 的数据源默认 URL | 已补齐三个属性 |
| Compose | 后端 `DATABASE_URL`、`ERASURE_LEDGER_URL` | 已补齐，保留原账本连接与读取超时 |
| 外部环境配置 | `DATABASE_URL`、`spring.datasource.url` | 完整覆盖业务连接地址，不继承默认 URL 的查询参数 |
| 独立账本环境配置 | `ERASURE_LEDGER_URL`、`manager.erasure-ledger.url` | 运行连接和显式初始化入口应使用一致的会话属性 |
| Helm | `database.jdbcUrl`、`erasureLedger.jdbcUrl` | 原样传入后端，部署方必须提供完整参数 |

外部业务库示例：

```text
jdbc:mysql://mysql.example.internal:3306/ai_manager?preserveInstants=true&connectionTimeZone=UTC&forceConnectionTimeZoneToSession=true
```

独立账本示例：

```text
jdbc:mysql://erasure.example.internal:3306/erasure_ledger?preserveInstants=true&connectionTimeZone=UTC&forceConnectionTimeZoneToSession=true&connectTimeout=5000&socketTimeout=10000
```

将属性合并到完整 URL 中，保留环境已有的 TLS、证书验证、超时、连接目标及认证参数。不要重复追加同名属性，也不要把密码写进 URL、values、提交记录或日志。示例不替代生产 TLS 配置；具体参数由部署环境提供。

本阶段只配置应用自有数据库连接的会话，不修改数据库全局时区、JVM 全局时区、机器环境变量、已有业务时间或用户展示时区。界面仍按家庭/机构的 IANA 时区展示与编辑日程；90 天保留期仍是固定时长，不按本地日历续期。

## 后续运行核对

以下是后续授权验证的检查项，本阶段没有执行这些操作：

1. 在独立环境分别配置 UTC 与非 UTC 主机/数据库默认时区，使用最终连接池和同一驱动连接确认会话 UTC、生成功能所需的正确时间点。不能用另开的管理员会话代替应用连接证据。
2. 对比应用节点时间、同事务主库时间及实际 UTC；分别检查成功写入、恢复查询和维护路径。固定时钟测试替身不证明驱动会话配置正确。
3. 连接池新建、连接回收、节点重启和数据库主库切换后重新核对。设置作用于新连接，修改模板不会重新配置已经打开的旧连接。
4. 保持偏差拒绝及持久观察时间约束，检查异常偏差/回拨拒绝、已过期不复活、失败事务回滚和不重复执行业务。
5. 分别核对 Compose、Helm 的 API/worker 与独立账本入口。保存脱敏后的有效参数、驱动/数据库版本、会话检查和业务断言结果；不能只凭模板文字宣布通过。
6. MySQL 与 OceanBase MySQL 模式分别认证。更换驱动、代理或兼容数据库时，重新确认这些驱动属性及时间语义，不能沿用 MySQL 的静态结论作为兼容证明。

## 发布与恢复

这是连接配置变更，不包含数据迁移、重置账本、重新生成密钥或自动修改现有私有环境。发布负责人应按既有发布流程验证镜像、最终参数和受支持客户端协议，再安排连接池或实例更新。

出现 `IDEMPOTENCY_CLOCK_UNTRUSTED` 时保留原操作标识和防重约束，核对会话参数、节点/数据库校时及主库连接目标。该错误不证明原业务未提交，不能自动换键重试。需要恢复部署时遵守既有恢复门槛，不能清空到期、擦除或最后可信观察标记。

相关文档：[后端实施说明](idempotency-result-retention-backend-implementation.md)、[Kubernetes 部署](kubernetes-deployment.md)、[部署与运维](deployment-runbook.md)。
