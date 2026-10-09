# 签名配置、设备回执与消息通知契约

更新日期：2026-10-09。本文对应 delivery/signing/messaging 后端模块；配合[策略契约](policy-application-schedule-contract.md)、[设备接入契约](device-registration-contract.md)和[实施记录](implementation-progress.md)联调。

## 1. 交付范围

当前实现 `CONFIGURE_ONLY` 的设备级签名配置、HTTP 拉取、持久游标、回执、防重放和通知适配层。Flutter/Dart 的验签、事务保存及重开数据库恢复组件已交付，见[设备接收契约](device-configuration-client-contract.md)。`ENFORCE`、规则级系统执行、EMM、设备宿主/原生接入和真实 Broker/真机仍待完成。

配置版本的状态继续是 `CONFIGURED_NOT_ENFORCED`。READY/SERVED/DEVICE_REPORTED_RECEIVED/DEVICE_REPORTED_STORED 是交付过程中的状态，不表示系统权限、应用拦截、额度或内容过滤生效。接口不接受 APPLIED 回执，也不提升 Fleet 中的能力证据。

## 2. 签名与密钥

- 由 Nimbus JOSE/JCA 执行 ES256/P-256 签名，头部 typ=`aimanager-configuration+jws`，kid 为配置的密钥 ID。不实现自定义签名算法。
- `CONFIGURATION_SIGNING_KEY_FILE` 指向外置私有 EC JWK；未配置时不生成生产临时密钥，拉取/公钥接口返回 503 `SIGNING_KEY_NOT_CONFIGURED`。保存家长配置仍可正常完成。
- 私钥必须带合法 kid，曲线、算法、用途/操作及密钥对一致性在启动时校验。错误信息不附带会泄露 JWK 内容的解析异常。
- `CONFIGURATION_VERIFICATION_KEYS_FILE` 可提供旧公钥 JWKS，最多 32 个；拒绝私有验证环、曲线/算法不匹配或同 kid 不同密钥。当前公钥只标 VERIFY，绝不返回私有 d。
- 轮换通过外置密钥和实例升级进行，不改写既有签名。旧公钥需要覆盖离线配置的验证期；紧急撤销、设备信任根更新与区域轮换流程仍需实现/验证。
- 公钥拉取受独立设备凭证保护。生产必须使用可信 TLS；客户端还需绑定注册的服务端、预期 issuer、算法/typ/kid、公钥信任根及所有设备/版本字段。仅验证签名不足以接受配置。

## 3. 设备接口

均以 `/api/v1/device-api` 为前缀，使用 opaque `deviceBearer`，不接受家长 JWT。tenantId/deviceId/registrationId 来自当前凭证；每个事务重新核验 ACTIVE 生命周期和未撤销凭证。

| 方法与路径 | 请求 | 返回 |
|---|---|---|
| GET /signing-keys | 无 | 公共 JWKS |
| GET /configurations | after 默认 0；limit 默认 50，1～50 | items、nextAfter、hasMore、serverTime |
| POST /configuration-receipts | receiptId、deliveryId、cursor、envelopeHash、stage、reason? | 回执 ID、state、historical、evidenceStatus、receivedAt |

游标范围 0～2^53−1，超出设备当前高水位返回 400 `DELIVERY_CURSOR_AHEAD`。每个注册周期有自己的游标；游标没有授权能力。

拉取只返回该设备各策略流当前期望的配置，不返回其他设备、其他注册周期或管理员身份。每项含 id、cursor、compactJws、deliveryExpiresAt 和交付状态 state。nextAfter 是分页续点；客户端应在验证与本地事务保存后推进，不能先保存游标再保存配置。

签名载荷字段：

| 字段 | 含义 |
|---|---|
| schemaVersion | 当前为 1；未知必需模式应拒绝并保留既有有效配置 |
| issuer、purpose、mode | 注册绑定的签名方；CONFIGURATION；CONFIGURE_ONLY |
| action | UPSERT_CONFIGURATION / REMOVE_CONFIGURATION |
| tenantId、deviceId、registrationId | 精确绑定设备注册周期 |
| policyId、versionId、sourceSequence | 策略流、不可变来源版本、来源序列 |
| cursor、deliveryId | 期望状态更新游标及该次交付尝试 ID |
| issuedAt、deliveryExpiresAt | UTC epoch 毫秒；首次接收期限 |
| effectiveUntil | 当前为 null，表示配置不按交付 TTL 自动失效 |
| document | 单设备规则、应用、计划和恢复豁免；移除时为 null |

同策略的新发布版本替代旧交付；对上一版本有、当前目标集合没有的注册周期生成签名 REMOVE_CONFIGURATION。它只撤销这一份展示配置，不撤销设备注册、不擦除数据，也不代表卸载或解除系统管理。

首次交付默认期限 86400 秒，可配置 60～86400。尚未接收的当前配置过期后，在设备拉取时生成新的 deliveryId/期限/签名；保留原 versionId、sourceSequence 和 cursor，避免跳过其他策略流。已缓存的有效配置不能因这个 TTL 自动放宽。显式拒绝的尝试不自动清除拒绝状态，需管理员重新发布；返回的旧拒绝项不能作为新有效配置应用。

服务端 firstServedAt 只说明准备了 HTTP 响应，不证明设备收到。HTTP 响应丢失可重复拉取同一持久签名。第一次尝试过期不会删除原历史，新尝试继续保留可关联证据。

## 4. 回执状态与错误

stage 只允许 RECEIVED/STORED/REJECTED；REJECTED 必须带 reason，其他阶段不带 reason。reason 为 UNSUPPORTED_SCHEMA/SIGNATURE_INVALID/IDENTITY_MISMATCH/UNSUPPORTED_RULES/STORAGE_FAILURE/EXPIRED/OLDER_VERSION。

envelopeHash 为 compactJws 字符串的 UTF-8 SHA-256 小写摘要。服务端核对当前设备注册周期、交付 ID、游标、已签名/已服务事实及摘要。未被服务、别的设备或摘要不匹配的回执拒绝。

- 同注册周期 receiptId 的相同请求返回原响应；异请求 409 `RECEIPT_ID_CONFLICT`。凭证撤销/轮换后仍先重新认证，不依靠历史缓存放行。
- STORED 可累积覆盖 RECEIVED；之后迟到的 RECEIVED 不使状态退回。已 STORED 后的矛盾拒绝返回 409 `RECEIPT_PHASE_CONFLICT`。
- 已拒绝的当前尝试不能转成成功，返回 `DELIVERY_REJECTED_REPUBLISH_REQUIRED`；相同拒绝回执重试仍可取原响应。
- 旧/过期尝试的回执可进入历史，historical=true；不会改变当前新版本或新尝试的状态。
- evidenceStatus 固定为 `DEVICE_REPORT_NOT_EXECUTION`。服务端收到迟到回执不证明客户端在首次交付期限内接受了配置；可信计时与设备验证器仍须独立验证。

管理者可查询 `GET /api/v1/tenants/{tenantId}/policy-publications/{publicationId}/deliveries`，使用用户 JWT、租户/操作授权，按 ID 游标分页。返回当前/历史标记、设备注册周期、交付阶段、回执时间与原因，不返回私钥、凭证或 compactJws。发布操作状态不因 STORED 改成 ACTIVE/APPLIED。

## 5. 事务与通知

配置版本保存后，Spring 同步领域事件在原事务内创建设备流、尝试和小型 ConfigurationChangedNotice。设备配置只由这条可信领域链和授权 API 建立，远程 Broker 消息不能写入策略或绕过权限。

持久异步通知使用 [Spring Modulith 事件登记/重试](https://docs.spring.io/spring-modulith/reference/1.4/events.html)与 JDBC。Kafka 用 Spring Kafka；Artemis 用 [Spring JMS](https://docs.spring.io/spring-boot/3.5/reference/messaging/jms.html)。源事务回滚时不发送通知；失败保留未完成记录，成功按 DELETE 模式清理。网络发送不包在业务 JDBC 事务内。

通知仅有 eventId、tenantId、deviceId、registrationId、policyId、cursor、createdAt、correlationId。它是拉取提示，不包含完整文档，也不证明执行结果。

| 通道 | 默认 | 路由与行为 |
|---|---|---|
| Kafka | KAFKA_NOTIFICATIONS_ENABLED=false | topic 默认 manager.configuration-changes.v1；键为 tenantId:registrationId；acks=all、producer idempotence；等待 ACK 最多 5 秒 |
| Artemis JMS | ARTEMIS_NOTIFICATIONS_ENABLED=false | Topic 为 manager/tenants/{tenantId}/registrations/{registrationId}/configuration；持久文本通知、TTL 60 秒 |
| HTTP | 无 Broker 依赖 | 有有效设备凭证和配置签名密钥时可拉取；通知丢失不改变服务器期望状态 |

Kafka/JMS 异步通知可能重复或乱序；跨实例重试不保证一次且仅一次。设备收到通知后拉取权威当前状态，用游标/策略来源版本防回退。Kafka 内部消息键也不代替设备范围校验。

Artemis Topic 与 MQTT 的映射、通配分隔符、TLS、每设备 ACL/凭证与重连仍须按 [Artemis MQTT 文档](https://artemis.apache.org/components/artemis/documentation/latest/mqtt.html)配置并实测，不能把 JMS 单元测试当作 MQTT 已打通。当前没有设备 MQTT 凭证发行，也不能把 HTTP opaque 凭证直接当 Broker 密码；不得使用跨设备共享密码。

## 6. 配置与运维

| 配置 | 当前默认 / 作用 |
|---|---|
| CONFIGURATION_ISSUER | ai-manager；客户端需绑定一致 |
| CONFIGURATION_SIGNING_KEY_FILE / CONFIGURATION_VERIFICATION_KEYS_FILE | 空；外置私钥/验证公钥，不提交文件 |
| CONFIGURATION_DELIVERY_TTL_SECONDS | 86400，范围 60～86400 |
| KAFKA_BOOTSTRAP_SERVERS / KAFKA_CONFIGURATION_TOPIC | localhost:9092 / manager.configuration-changes.v1；开发默认 |
| ARTEMIS_BROKER_URL | 开发原生端口 61616，durable send ACK 和 callTimeout=5000 |
| ARTEMIS_USERNAME / ARTEMIS_PASSWORD | 空；由密钥配置提供 |
| NOTIFICATION_RETRY_SECONDS | 30，范围 5～3600；重新投递未完成通知 |
| EVENT_CORE_THREADS / EVENT_MAX_THREADS / EVENT_QUEUE_CAPACITY | 4 / 8 / 1000；有界工作队列，可按测量配置 |

生产连接必须配置 Broker TLS/SASL/mTLS 等实际认证参数及发送确认超时；替换 ARTEMIS_BROKER_URL 时不可意外失去 ACK/超时设置。依赖解析版本为 Spring Kafka 3.3.16、Artemis Jakarta client 2.40.0、Modulith 1.4.0；完整许可证/SBOM/漏洞验证仍属于发布门槛。

低基数指标 manager.notification.published 与 manager.notification.failures 按 channel 标签统计；日志记录 eventId/correlationId，不附 SDK 可能含敏感配置的异常原因。长期失败的持久记录需监控；限批/退避/区域故障及容量门槛仍待验证，不宣称百万设备通知容量达标。

V9 建立交付域表。V10 按 MySQL/H2 vendor 使用 SDK 原始事件登记类型，Flyway locations 为 db/migration 与 db/vendor/{vendor}；SDK 自动 DDL 关闭。MySQL/OceanBase 上的 UUID/时间、并发/备份/迁移仍需实测。历史 policy_outbox 保留为原配置事件日志；通知登记与重试的权威是 EVENT_PUBLICATION，旧 delivered_at 不能作为 Broker 或设备确认。

## 7. 验证与待完成

已有证据包含真实 HTTP、数据库事务、Nimbus 签名/验证、设备凭证、目标变更、序列/分页、过期重发、回执顺序/重放及撤销。消息登记测试使用真实 Modulith/JDBC，Kafka 发送采用明确测试替身；JMS 测试调用真实 JmsTemplate，但 ConnectionFactory/Session/Producer 是替身。

真实 Kafka ACK/集群、Artemis/MQTT/ACL、MySQL/OceanBase、正式 EMM、设备 JWS 验证/离线/重启、信任根轮换和高并发没有成功证据。ENFORCE、规则级系统回执、执行补偿/取消、供应商擦除后果确认及全客户端交互继续实施。
