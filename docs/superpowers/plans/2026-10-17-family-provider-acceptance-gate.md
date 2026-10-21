# 家庭账号真实验收入口与收费门禁

本轮继续既有家庭订阅首发计划。用户确认供应商与正式真机尚未准备，先完善管理端验收入口和收费门禁。保留已有改动、已有部署和数据，不发送短信、调用微信、安装 App 或开放购买。

## 可观察交付

- 管理端按“准备环境 → 手机完成 → 核对结果”展示当前缺口、十二项真实待办和最近验收记录。刷新从服务端读取事实，断网后不使用旧状态执行操作。
- 建立本次验收时自动使用服务端已确认的配置、发布操作及产物摘要；记录冻结发布操作、运行修订和二十四小时有效期。目标变化、活动发布或过期后，旧记录不能继续代表当前版本。
- 验收页面不收集手机号、验证码、微信 code 或 token，不提供手工通过或开售按钮。关闭消费者入口的配置仍须由部署管理员另行准备受限成人试点，不能假定可以直接在真机登录。
- 收费开关仅表达开售意图。生产微信支付适配器在展示可购买和发起新付款时均检查服务端门禁；缺少真实证据时关闭。查单、通知验签、关单、退款和日对账继续工作。
- 新增只读安卓准备预检：实际检查 APK 包名、签名、调试属性、预期证书和本地设备准备状态。调试包、无设备或仅声明 AppID 均不能计入真实验收通过。

## 接口合同

`GET /api/v1/platform/identity-providers/acceptance-status` 返回：

`environmentId, versionId, confirmedOperationId, runtimeRevision, status, nextAction, passedCount, requiredCount, latestRun, readinessChecks, checks, salesGate`。

- `versionId`、`confirmedOperationId`、`latestRun` 允许为空。
- `status` 为 `BLOCKED / PENDING / STALE`。本轮 `passedCount=0`、`requiredCount=12`。
- `nextAction` 为 `CONFIGURE / CHECK_CONFIGURATION / PUBLISH_CONFIGURATION / CHECK_RUNTIME / REGISTER_RUN / PREPARE_PILOT`。
- 两类检查沿用现有 `Check` 类型；配置准备可以 `READY`，十二项真实检查保持 `PENDING`。
- `salesGate` 为 `{allowed:false,status:"CLOSED",checks:[...]}`。本轮没有可信的真实通过采集和显式启售机制，不把实现门禁说成已可收费。

`GET /acceptance-runs` 返回 `{items:[...]}`，同环境最多最近五条，按创建时间及 ID 倒序。

既有 `POST /acceptance-runs` 增加成对可选的 `releaseOperationId` 和 `expectedRuntimeRevision`。新页面发送这两项；服务端在运行版本头锁内核对当前确认操作、无活动操作、环境、配置与 JAR/APK，再冻结绑定和有效期。旧五字段请求保留为未绑定清单，不自动升级为当前验收。原 ID 重试恢复原记录，不重新绑定目标。

既有返回增加可空 `releaseOperationId/runtimeRevision/expiresAt`；原清单的 `status=BLOCKED` 语义保留，由聚合状态解释绑定、过期和下一步。所有读写继续使用独立平台权限、服务端近期 MFA、`no-store` 和原有幂等保护。

## 数据和验证

继续未发布 1.0.0 初始化基线，只给验收记录新增三项可空绑定列，并同步保留目录的精确列分类。不得修改已有运行库、清库或修复迁移校验值。

先验证越权、旧版本、重复提交、过期、活动发布、假通过、失败刷新及单开关付款绕过，再验证正常登记与读取。正式供应商、安卓真机、真实 MySQL、普通单元测试和模拟 HTTP 各自记账，不互相替代。最终冻结源码后执行对应回归、分析、构建与文件摘要核对，记录所有条件跳过。

临时目录使用 `.cache/family-provider-acceptance-20261017-r3/`，交付目录使用 `.local/family-provider-acceptance-20261017-r3/artifacts/`。临时环境覆盖仅作用于进程；清理先盘点、校验边界和文件摘要，保留源码、独有证据及历史失败记录。
