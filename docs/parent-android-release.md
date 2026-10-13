# 监护人 Android 安装包发布规程

适用范围：中国大陆机构合同试点的监护人手机 App。此规程只处理 **APK 的可追溯构建与签名**；设备受管能力、合同权益、真实身份联调和客户验收分别按其交付门槛核验。家庭 BYOD 和机构设备均不能因 App 已签名而被标为“不可绕过”。

## 发布输入与责任

| 输入 | 提供者 | 校验与保管 |
|---|---|---|
| 已提交的 `dev` 修订 | 研发/发布负责人 | 在隔离工作区构建；脚本拒绝未提交改动，并把完整 Git 修订号写入清单 |
| 正式 OIDC issuer、API 和管理台 HTTPS 地址 | 身份/后端运维 | 手机实机可访问，证书链可信；构建脚本拒绝非 HTTPS、URL 凭据、查询和片段 |
| Android 上传/发布密钥及别名 | 发布负责人/机构密钥管理员 | 保存在受限密钥库；流水线短时挂载绝对路径，不放入仓库、工单或聊天 |
| 版本名、递增版本号 | 产品/发布负责人 | `x.y.z` 版本名与正整数版本号；相同包名升级时版本号必须高于已分发版本 |
| SDK、Flutter 和 Android 构建环境 | CI 负责人 | 使用项目锁文件和统一工具链；保留 CI 记录、依赖清单及产物哈希 |

构建环境变量：`PARENT_ANDROID_KEYSTORE`（密钥库绝对路径）、`PARENT_ANDROID_STORE_PASSWORD`、`PARENT_ANDROID_KEY_ALIAS`、`PARENT_ANDROID_KEY_PASSWORD`。只通过 CI 的秘密存储注入。**不得**将密码作为脚本参数、`--dart-define`、Gradle 文件或日志内容传递。丢失或轮换密钥时，先核实机构分发渠道的升级签名规则；不要直接替换已有应用的签名。

## 构建与核验

在独立、干净且已提交的工作区中，由发布流水线提供上述环境变量，再执行：

```powershell
pwsh ./scripts/build-parent-android.ps1 `
  -Issuer 'https://id.example.cn/realms/ai-manager' `
  -ApiUrl 'https://api.example.cn/api/v1' `
  -ConsoleUrl 'https://console.example.cn/' `
  -BuildName '1.0.0' -BuildNumber 1
```

示例域名必须替换成客户可访问的正式地址。脚本完成 Flutter 依赖解析、release 构建、Android SDK `apksigner verify --verbose --print-certs` 与 SHA-256 计算；输出位于 `apps/parent/build/app/outputs/flutter-apk/app-release.apk` 和 `apps/parent/build/parent-release-manifest.json`。后者记录修订、版本、目标地址、APK 哈希和签名核验结果，不记录秘密。**签名检查通过只证明 APK 结构及签名有效，不证明其身份、API 或设备管控业务可用。**

Gradle 的 release 任务在缺少任何签名变量或密钥库文件时直接失败，防止意外产生未签名或开发签名的所谓正式包。调试构建仍可在不配置发布密钥时进行。发布流水线还应保存签名证书指纹、构建日志、依赖与漏洞审查结果，并将 APK 哈希交给机构接收方核对。签名密钥和密码不能随产物交付。

## 机构试点签收

1. 在目标 Android 手机安装**同一份已签名 APK**，核对包名、版本号、签名证书指纹和 SHA-256；验证旧版升级路径及回滚方案。Android 不接受低版本号直接覆盖安装，回滚应按机构批准的备份与重装流程处理。
2. 用真实 Keycloak 公共客户端完成系统浏览器登录与 `com.aimanager.parent:/oauth2redirect` 回跳；核对 PKCE、MFA、近期认证、令牌撤销与退出。管理台浏览器入口要再次独立鉴权。
3. 以成人、儿童、跨租户账号核对首页、申请审批、配对、正常退出和权益展示。审批重认证取消后不得写入，网络结果不明时应显示待核对状态。
4. 验证设备离线、重启、应用被系统终止后恢复、低网速与证书故障；按设备能力与策略回执判断实际执行，不能用“在线”或“已安装”替代。
5. 机构管理员签收服务地址、数据驻留、合同权益、应急恢复、客服与事件响应责任。无 EMM 合作方/Android Management API 准入时，不承诺系统级强管控。

首发分发渠道为机构合同约定的受控分发。公开商店上架、自动更新、MDM 推送、不同厂商 TV 安装和不同法域销售均需另立准入与验收记录。

## 当前状态

代码已提供 release 签名门槛和校验脚本。真实密钥、生产 HTTPS/IdP、Android 实机、机构验收材料尚未在本仓库提供；因此**当前没有可交付的正式签名 APK**。相关完整客户端状态见 [监护人端交付契约](parent-android-delivery.md)。
