# 家庭身份供应商配置发布准备

平台管理员保存和加密导出的配置版本，需要经过部署侧准备与受控发布才能被身份服务使用。本文件中的准备工具只准备可审查的文件，状态始终是 `APPLY_REQUIRED`，不会把“保存成功”或“格式通过”显示为“已经生效”。新增执行器、实例确认和回退见 [受控发布说明](family-identity-controlled-release.md)。真实短信、微信与收费开放仍依照[联调验收要求](family-identity-provider-acceptance.md)。

## 初始化管理员受限存储

首次使用可运行 [`scripts/initialize_identity_provider_admin.ps1`](../scripts/initialize_identity_provider_admin.ps1)，选择仓库忽略范围内的全新目录：

```powershell
./scripts/initialize_identity_provider_admin.ps1 `
  -Directory .local/family-identity-admin `
  -EnvironmentId family-cn-isolated
```

它生成独立 `provider-keyring.json`、`release-preparations/` 与非秘密 `identity-admin.env` 片段；不会改已有目录、账号、身份域或启动服务。部署管理员应将片段与 [`deploy/compose/compose.identity-admin.yaml`](../deploy/compose/compose.identity-admin.yaml) 一起审查；overlay 只给后端只读密钥挂载和可写的加密准备区，不改变消费者或销售开关，也不能直接更新 Keycloak。

Linux 主机须按目标部署的 `APP_UID` / `APP_GID` 配置所有权，确认后端进程能够读取 `0600` 密钥、访问受限配置根并写入准备区；不能通过放宽成全局可读来解决权限问题。Windows 使用当前执行者、SYSTEM 和 Administrators 的受限 ACL，并核对容器运行身份及挂载后的实际读写权限。初始化成功不替代容器内验收。

密钥环应通过受限秘密管理流程独立备份，不能仅依赖业务数据库备份。密钥轮换时保留仍被历史加密版本引用的旧 `kid`；未确认所有需要保留的配置和回退资料可解密前，不得删除旧密钥。密钥环最多八项，不能使用新的空密钥环替换旧环来“修复”解密失败。主密钥与已有供应商秘密均不回传浏览器。

## 准备一个新版本

使用 [`scripts/prepare_family_identity_release.ps1`](../scripts/prepare_family_identity_release.ps1)。需要 PowerShell 7 与支持 AES-GCM 的 .NET，不需要安装额外加密依赖。输入为管理端导出的加密 release bundle，以及由部署管理员管理的独立 JWK 密钥环文件。密钥不通过聊天、命令参数或管理界面回读；命令参数只有文件位置和非秘密版本信息。

```powershell
# 只创建仓库忽略目录内的准备区，不能使用盘根临时目录。
New-Item -ItemType Directory -Path .cache/family-provider-admin-20261017/prepared -Force

./scripts/prepare_family_identity_release.ps1 `
  -BundleFile .local/family-identity-admin/release-preparations/00000000-0000-4000-8000-000000000002.json `
  -KeyFile .local/family-identity-admin/provider-keyring.json `
  -EnvironmentId family-cn-isolated `
  -VersionId 00000000-0000-4000-8000-000000000001 `
  -OutputDirectory .cache/family-provider-admin-20261017/prepared/00000000-0000-4000-8000-000000000001
```

示例文件名和版本号需替换为本次管理端实际导出的记录。准备任务 ID 与配置版本 ID 是两个不同标识，`VersionId` 应使用配置版本 ID，不能把加密文件名当作该版本号。输入、密钥及输出默认只能位于当前仓库 `.cache/` 或既有 `.local/` 内；父目录必须存在，输出目录必须全新。部署管理员也可显式传 `-DeploymentDirectory`，选择已经存在、权限受限且 `deployment.json` 声明为消费者部署的独立目录；此时该目录也是允许的范围。工具拒绝盘根目标、归一化越界、相似前缀、任一父路径或输入中的链接、现有输出目录和过大的文件。它不覆盖既有 `.env`、秘密、部署、数据库、身份域或历史版本。

密钥文件必须只允许当前执行者、Windows SYSTEM 和 Administrators 读取；Unix 不得向 group/other 授权。工具先认证并验证整个 bundle，再创建受限输出目录；Windows 取消继承并限定为上述主体，Unix 目录为 `0700`、文件为 `0600`。权限设置或复核失败即停止，不能降级成开放权限。部署主机应由受信管理员独占准备区与父目录，避免其他进程同时改动目录或文件。

成功退出码为 `0`，仅表示离线文件准备成功；失败退出码为 `1`，错误不回显输入、密钥、供应商响应或秘密路径。写入过程中失败时保留本次新建的受限目录供审查，不递归删除指定目录；没有完整的 `prepared-release.json` 就不是已准备版本。清理前须确认准确任务边界、保存唯一资料与脱敏清单，先解除目录链接并保留审计记录。

新版本目录包含：

| 文件 | 内容 |
| --- | --- |
| `family-identity.env` | 短信签名、模板、微信 AppID 的固定非秘密配置片段；消费者手机号、微信、账号安全及销售开关全部为 `false` |
| `secrets/consumer_otp_hmac_key` | 由服务端生成或沿用的验证码 HMAC 密钥 |
| `secrets/consumer_sms_access_key_id` | 短信 AccessKey ID，仍作为秘密处理 |
| `secrets/consumer_sms_access_key_secret` | 短信 AccessKey Secret |
| `secrets/consumer_sms_security_token` | 可选 STS token，未使用时为空文件 |
| `secrets/consumer_wechat_app_secret` | 微信移动应用 AppSecret |
| `prepared-release.json` | 环境、配置版本、非秘密设置、凭据是否存在、非秘密配置摘要及明确的待发布状态；没有任何秘密原文、秘密摘要或掩码 |
| `NEXT_STEPS.md` | 必须完成的受控部署、实例回执、真实联调与回退说明 |

整个目录必须保留受限权限，不能上传 Git、发到聊天、存入普通日志或截图。没有生成完整部署 `.env` 或 `deployment.json`；供应商配置片段不包含完整部署上下文，不能直接替换现有部署环境文件。

## 认证和格式契约

外层 JSON 仅允许 `schemaVersion=1`、`environmentId`、规范小写 UUID `versionId` 与 `protectedPayload`。目标环境与版本必须同时匹配命令参数、JWE 保护头和解密后的 payload，禁止把另一环境或另一版本的加密包用于当前发布。

JWE 使用 `alg=dir`、`enc=A256GCM`，保护头固定 `typ=family-identity-provider-release+jwe`、`cty=application/json`、`purpose=family-identity-provider-release-v1`，携带 `kid`、`environmentId` 与 `versionId`。`kid` 必须匹配独立 JWK ring 中唯一的 256 位 `oct` / `enc` / `dir` 密钥；最多八个密钥。不接受压缩、critical 扩展、远程密钥引用、未知或重复 JSON 字段、非规范 base64url、错误认证标签或长度异常。输入不会触发网络访问。

payload 只包含 `schemaVersion`、`versionId`、五项固定公开 `settings` 和五项固定 `credentials`。签名与模板必须能够安全写入固定 `.env` 片段；AppID、包名和证书登记按当前安卓家长端契约验证。凭据需单行 UTF-8、无 BOM/换行/NUL、每项最多 8192 字节，仅未使用的 STS 允许为空；明确的占位凭据被拒绝。格式检查不证明凭据有效、短信审核或微信应用审核已完成。

## 审查后受控部署

`ConsumerAuthenticatorFactory` 与 `ConsumerAccountResourceFactory` 共享进程启动时加载的固定配置；业务数据库中保存版本不会更新该快照，单独覆盖文件也不能完成发布。本轮不提供热更新或立即启用：受控执行器按批准操作整体挂载新版本并重建指定身份服务，随后由后端核对实际加载结果。

由授权部署管理员先核对环境、版本、正式 APK/JAR 和目标部署，在独立消费者验收环境将已审查的固定配置及秘密一致合并到受控部署，再按部署流程重新创建 `identity`。将来开放账号安全能力时，`FAMILY_ACCOUNT_SECURITY_ENABLED` 同时影响身份服务和后端当前会话门禁，需要协调后端配置与重新创建。原始账号、家庭、设备、会员、订单及数据库不得被清空或恢复到旧状态；不要靠重新导入身份域应用供应商配置。

准备工具不会执行上述操作，也不会调用完整部署启动脚本或获得 Docker socket。新增执行器的权限、绑定目标、原操作恢复及启动指针另行核对；缺执行器或实际实例证明时保持待确认。正式启用还需要真实联调通过；健康页、保存记录或脚本退出码不能代替实际配置证明。

短信试发送必须限制在已授权接收人和预算内，未知结果不自动重发。真实收码、微信原生 SDK 授权、账号换绑/恢复/绑定/解绑和旧会话拒绝应在正常 OIDC/PKCE 流中验收；管理员工具不提供微信 code 粘贴入口。采购与销售保持独立门禁。

回退是指向历史受限版本的另一个受控部署计划：先确认历史凭据仍有效、AppID 绑定范围与当前身份版本兼容，再重新创建并采集全部实例回执。HMAC 轮换会影响未完成的验证码，STS 有有效期，AppID 变化不是普通 AppSecret 轮换。回退配置不能恢复已经撤销的登录会话或解绑身份。

离线测试在 [`scripts/tests/test_prepare_family_identity_release.py`](../scripts/tests/test_prepare_family_identity_release.py)，使用 .NET AES-GCM 实际生成的格式 fixture；不调用短信、微信、数据库或已有部署。测试准备区在仓库 `.cache/family-provider-admin-20261017/deploy/`，TEMP/TMP 只在测试进程覆盖。
