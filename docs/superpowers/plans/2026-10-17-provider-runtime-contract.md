# 短信与微信受控发布合同（2026-10-17）

本轮仅发布配置到关闭消费者入口的身份实例，并核对实际进程事实。发布确认不是短信、微信真机验收，也不开放销售。所有金额、账号、家庭及业务数据库保持原状。

## 管理端 API

前缀 `/api/v1/platform/identity-providers`。所有浏览器 API 要求近期平台 MFA、`Cache-Control: no-store`，拒绝未知字段。读取用 `identity-config:read`；PUBLISH 用独立 `identity-config:publish`；ROLLBACK 用独立 `identity-config:rollback`；主动核对用 `identity-config:test`。manage/test 不自动获得发布或回退权。

* `GET /release-status` → `{environmentId,runtimeRevision,observationReady,executorReady,activeOperation,confirmedOperation,rollbackTargets,runtimeStatus,salesAllowed:false}`。
* `POST /release-operations` → `{id,kind,versionId,preparationId,expectedRuntimeRevision,providerJarSha256,parentApkSha256}`，返回 `ReleaseOperationView`。
* `GET /release-operations/{id}` 返回原操作，不重放发布。
* `POST /release-operations/{id}/runtime-checks` → `{id}`，返回 `RuntimeCheckView`。
* `GET /runtime-checks/{id}` 返回原核对，不再次请求身份实例。
* `POST /release-operations/{id}/cancellations` → `{id,expectedRuntimeRevision}`，仅尚未领取的 WAITING_EXECUTOR 可取消，权限与原操作 kind 相同。
* `GET /cancellations/{id}` 返回取消对应的原操作，取消成功令运行 revision 加一，active 置空；丢包不能再发另一个取消。
* `GET /versions/{id}/release-preparations` 返回 `{items:[PreparationView]}`，仅本环境该版本 PREPARED 记录，按 created_at DESC、id DESC 最多 5 条；没有准备记录返回空数组，版本不存在返回 404。独立发布者通过 read 权限选择准备好的版本，无需写配置权限。

所有 ID 均为小写 UUID v4；版本与准备记录、环境、安装包和 provider JAR SHA256 冻结。配置 head 与运行 head 独立；运行 revision CAS 和单活动 fence 防并发覆盖。重复同 UUID 同参数返回原结果，参数或成人不一致返回冲突。

`ReleaseOperationView` 字段：`id,kind,versionId,preparationId,providerJarSha256,parentApkSha256,baseRuntimeRevision,state,reasonCode,createdAt,confirmedAt,canCheckRuntime,canCancel,runtimeStatus,salesAllowed:false`。

state：`WAITING_EXECUTOR | CLAIMED | EXECUTION_UNKNOWN | APPLIED_CLOSED | CANCELLED`。只有后端向全部固定身份实例发新鲜随机挑战、核对实际进程配置和 JAR 后，才能成为 APPLIED_CLOSED。CLAIMED / EXECUTION_UNKNOWN 不能取消或被新操作覆盖；丢失结果只能查询原 claim 和主动探测，不能自动重复重启。

`ReleaseTargetView`：`versionId,preparationId,providerJarSha256,parentApkSha256,confirmedAt`。回退仅选择服务器曾真实确认的历史目标，且与当前运行版本的 OTP HMAC 和微信 AppID 相同；不回退账号数据库或重置身份会话。

历史 operation/check 的 APPLIED_CLOSED 表示当次已确认结果。当前事实以 release-status.confirmedOperation 为最后确认版本；active 存在时顶层 runtimeStatus 和旧配置 DTO 均为 APPLY_REQUIRED，不把旧确认当成当前生效。

`RuntimeCheckView`：`id,operationId,versionId,state,reasonCode,createdAt,completedAt,instances,runtimeStatus,salesAllowed:false`；state 为 `CHECKING | CONFIRMED | UNAVAILABLE | MISMATCH`。

CHECKING 有 120 秒有限租期（大于 8 个实例各 5 秒及事务余量）。后端重启或写回失败后，GET 原检查在运行 head 锁内将过期原记录归为 UNAVAILABLE / RUNTIME_CHECK_INTERRUPTED 并审计，不重发挑战、不改执行 fence 或最后确认版本；迟到结果不能复活该记录。界面取得终态后解除原查询待办，允许成人显式发起新的检查 UUID。

`RuntimeInstanceView`：`instanceId,state,reasonCode,observedAt`；state 为 `CONFIRMED | UNAVAILABLE | MISMATCH`，不包含 URL、秘密、proof 或稳定秘密摘要。

旧 `/status` 及版本、验证、准备、验收 DTO 保持兼容；runtimeStatus 仅在目标版本与当前已确认版本相同时为 APPLIED_CLOSED，否则 APPLY_REQUIRED。12 项真实联调仍然 PENDING，salesAllowed 永远 false。

## 固定身份实例与随机证明

后端从私有 inventory 文件加载 `schemaVersion:1,environmentId,instances:[{instanceId,url,keyFile}]`，不接收浏览器 URL，1 至 8 个实例、ID 不重复；keyFile 为独立 32 字节 base64url 单行密钥，不能使用 OTP HMAC 或供应商密钥。HTTP 只允许固定内部身份主机或 loopback，其他主机要求 HTTPS；禁止重定向，正文和总耗时受限。

所有 HMAC-SHA256 canonical 字段按固定顺序编码：对每个字段写 UTF-8 字节长度（十进制）、冒号、UTF-8 字节。不加分隔空行。proof 为 32 字节 base64url 无 padding。nonce 随机 32 字节，issuedAt 使用 epoch 秒，时间窗口 30 秒。

`POST consumer-account/runtime-observation` 请求 JSON：`environmentId,operationId,nonce,issuedAt,proof`。

请求 canonical：`family-identity-runtime-request-v1, environmentId, operationId, nonce, issuedAt`。

响应 JSON：`environmentId,operationId,versionId,instanceId,bootId,startedAt,observedAt,providerJarSha256,phoneEnabled,wechatEnabled,accountSecurityEnabled,nonce,proof`。

响应 canonical：`family-identity-runtime-response-v1, environmentId, operationId, versionId, instanceId, bootId, startedAt, observedAt, providerJarSha256, phoneEnabled, wechatEnabled, accountSecurityEnabled, nonce, smsSignName, smsTemplateCode, wechatAppId, CONSUMER_OTP_HMAC_KEY, ALIYUN_SMS_ACCESS_KEY_ID, ALIYUN_SMS_ACCESS_KEY_SECRET, ALIYUN_SMS_SECURITY_TOKEN, WECHAT_NATIVE_APP_SECRET`。

响应末尾 8 个实际加载设置/秘密仅参与 HMAC，不能出现在响应中。身份实例使用进程启动时不可变配置快照和实际 codeSource JAR SHA；不能只签 version marker 或配置文件声明。三项消费者开关必须均 false。nonce、环境、实例、操作、版本、JAR、时间、启动和实际配置均由后端重新校验。

## 专用执行器协议

前缀 `/api/v1/platform/identity-provider-executor`。机器请求不使用成人 OAuth scope；每次必须有另一独立执行器密钥签名。机器密钥只能领取已批准操作，不能创建发布、回退、写配置或宣告生效。

POST `/claims` 对应 action CLAIM；POST `/claims/query` 对应 QUERY；POST `/claims/begin` 对应 BEGIN；POST `/claims/outcomes` 对应 REPORT。
POST `/claims/abandon` 对应 ABANDON_BEFORE_BEGIN，仅原 claim 且状态 CLAIMED、从未 BEGIN 时可终结为 CANCELLED 并清 fence；开始执行后永远拒绝。回包丢失仅 QUERY 原 claim，不能换 claim 重做。

请求：`environmentId,operationId,claimId,nonce,issuedAt,proof,outcome?`，仅 REPORT 可带 `outcome`，值为 `UNKNOWN | FAILED | FINISHED`。

canonical：`family-identity-executor-request-v1, action, environmentId, operationId, claimId, nonce, issuedAt, outcome-or-empty`。

响应：`operationId,claimId,state,executionAllowed,canFinalizeHostPointer,currentConfirmedOperationId,canClearPendingHostPointer,environmentId,versionId,preparationId,providerJarSha256,parentApkSha256,kind`，不含秘密和任意路径/命令。currentConfirmedOperationId 字段始终存在，可为 null。只有运行 head 当前 confirmed 为该操作且不存在 active fence，才在事务锁内给 canFinalizeHostPointer=true；历史 APPLIED_CLOSED 不授权重写主机 active pointer，防止旧请求未经新回退审批恢复旧版本。

canClearPendingHostPointer 仅在该操作 CANCELLED、从未 BEGIN、head 无 confirmed 且无 active 时为 true；主机还必须核对本地 PENDING 恰属该操作，才能只删除该指针。有旧指针时须 QUERY 旧 claim，只有 currentConfirmedOperationId 匹配、canFinalizeHostPointer=true、版本/JAR/本地签名仍正确才恢复。UNKNOWN 永不清理、恢复或重新执行。

CLAIM 仅 WAITING_EXECUTOR → CLAIMED，不执行；同 claim 恢复只返回事实。BEGIN 仅首次 CLAIMED → EXECUTION_UNKNOWN，并在该次成功响应返回 executionAllowed=true。重复 BEGIN/QUERY 永远 false；BEGIN 回包丢失不能再次执行。REPORT 只记录主机执行结果，不能确认为生效、不能清 fence。非活动或旧 claim 拒绝执行。

首次 REPORT FINISHED 会由后端自动进行一次真实随机核对，只有该证明通过才返回 APPLIED_CLOSED。QUERY 和重复 REPORT 不重复探测；未知结果通过管理端新核对 UUID 恢复。主动核对只允许 EXECUTION_UNKNOWN，WAITING/CLAIMED 尚未 BEGIN 时拒绝。

执行器在 BEGIN 前持有固定部署主机锁并持久化阶段日志。只运行预先配置的 Compose identity recreate，不给后端 Docker socket，不接受任意命令。整个版本目录绑定挂载；启动入口必须遵守已验证 active pointer，不能重启后回到旧秘密。

## 主机绑定与启动入口

主机管理员先以 `initialize_identity_provider_runtime.ps1` 新建独立机器密钥和固定 inventory，以 `initialize_identity_provider_admin.ps1` 准备独立加密目录。两个目录必须使用同一环境别名。

`initialize_identity_provider_target.ps1` 仅绑定已存在的 ConsumerIdentity 部署，参数为 `DeploymentDirectory,AdminDirectory,RuntimeDirectory,BackendUrl,IdentityImageId,ProviderJarSha256`。它核对受限权限、祖先链接、单实例 inventory、固定环境片段以及 Compose project 归属；只有确认镜像的真实 ID，且从一个从未启动的独立检查容器取出的实际 provider JAR 与指定 SHA256 相同、包含运行证明实现后，才新建 `identity-release-target.json`。目标配置不可覆盖。检查容器带独立标签，清理前再次核对；新建检查容器不等于部署或启动身份服务。

如果同一 Compose project 已存在 identity 容器，必须只有一个，并且 `com.docker.compose.project`、`com.docker.compose.service` 和 `com.docker.compose.project.working_dir` 均绑定所选部署。复制目录而复用其他部署的 project 会在领取操作前拒绝。新空部署则要求已核对的 ConsumerIdentity release manifest 与实际本地 JAR。

`run_family_identity_release.ps1 -TargetFile <固定目标> -OperationId <已批准操作>` 只领取服务端批准的操作。先检查原开关均为 false、固定镜像和项目归属，再领取；准备只解密服务器固定 `<preparationId>.json` 文件到新的 `identity-provider-releases/<operationId>`，不覆盖原 `.env` 或 `secrets`。

收到版本后准备失败且从未 BEGIN 时，执行器调用 `ABANDON_BEFORE_BEGIN`；服务端原 claim 校验通过才取消该操作并允许后续重新审批。未知 BEGIN、重建或回报结果均不自动重复执行。机器响应无论是否带 Content-Length 均限制 32 KiB，头与正文共享 15 秒期限；Docker 子进程有独立上限。

BEGIN 发出前即保存受认证的 `EXECUTION_UNKNOWN` 指针，普通启动暂时停止。即使 BEGIN 回包丢失，也不会在普通重启中静默选择旧版本。实际操作只对预先绑定项目执行 `identity` 的 `--no-deps --no-build --pull never --force-recreate`，不执行任意命令，不操作数据库或身份域。后端实际随机核对通过后才保存 `APPLIED_CLOSED` 指针；执行器再次运行只查询原操作，核对文件未变后可补齐确认指针，不重复重建。

指针绑定环境、操作、版本、claim、非秘密 overlay SHA256，以及仅在私有主机文件保存的版本内容 HMAC。普通启动会重新核对固定五项秘密文件，发现文件变化则拒绝启动，不能只依靠版本标签。秘密或秘密摘要不进入管理端响应、普通审计或公共验证证据。

`start-deployment.ps1` 新增可选 `IdentityAdminDirectory` 与 `IdentityRuntimeDirectory`。有 active pointer 时必须使用目标中绑定的同一目录；两个固定环境片段和 backend overlay 会保留，身份镜像 overlay 使用 `!reset` 只移除 identity 的 build，backend/edge 仍沿用已有构建流程。无 active pointer 的普通部署保持原身份构建方式。

本轮主机执行器只支持一个身份实例，遇多实例会在网络领取或重建前拒绝；服务端核对协议仍支持固定多实例 inventory。消费者入口、账号安全入口及销售保持关闭。实际配置加载确认与短信送达、正式签名安卓微信、账号恢复、付费验收分别记录，不能互相代替。

主机启动入口与执行器在读取 active pointer 前取得同一个 `identity-release-host.lock`，持有至配置核对和 `up` 完成；竞争有界失败，不能继续使用已经过期的启动参数。恢复历史操作只能查询，只有服务端 `canFinalizeHostPointer=true` 且本机 pending/current pointer 仍属于原操作时，才允许补齐确认。

机器响应追加 `canFinalizeHostPointer,currentConfirmedOperationId,canClearPendingHostPointer` 三个当前资格字段，nullable confirmed ID 必须保留 JSON 属性。不能因操作历史为 APPLIED_CLOSED 就覆盖较新的 pointer。取消 pending 后，恢复保存的旧 pointer 必须再次 QUERY 该旧 operation/claim，其 ID 与 currentConfirmedOperationId 相同、可 finalize，且旧签名、版本文件 HMAC 和 overlay 均通过；首次解除 pending 只能在服务端确认无当前版本与活动操作、canClearPendingHostPointer=true 时进行。

ABANDON_REQUESTED 恢复查询若仍为明确 CLAIMED，可安全重发同 claim 的 ABANDON_BEFORE_BEGIN；这是从未开始操作的取消，不是重复重建。EXECUTION_UNKNOWN 永远不能通过取消解除。可继续执行的 CLAIMED 恢复，在消耗 BEGIN 前重新核对固定镜像和 Compose 归属。合法但与固定主机不符的 JAR SHA 会在记录 claim 后安全取消，不留下永久 fence。
