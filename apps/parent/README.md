# 监护人 Android 客户端

此 Flutter 应用是监护人/机构管理员的原生手机入口。已接入现有 Spring API：OIDC 登录与工作空间切换、儿童和设备概览、BYOD 设备配对、设备能力详情、正常退出管理、临时访问申请审批、儿童求助确认，以及商业权益只读查询。完整批量策略、合同审核与诊断仍在 Web 管理工作台。所有系统级设备执行能力以设备模式和实际回执为准。

## 配置与启动

使用同一可从 Android 设备访问的 HTTPS 域名部署 Keycloak 和 API；以下为示意地址，不是当前本地 Compose 的默认地址：

```powershell
flutter pub get
flutter run --dart-define=OIDC_ISSUER=https://id.example.cn/realms/ai-manager --dart-define=API_URL=https://api.example.cn/api/v1
```

`OIDC_ISSUER` 必须与 Keycloak Discovery 的 issuer 完全相同。`API_URL` 必须以 `/api/v1` 结尾。普通 Android 设备上的 `localhost` 指向手机自身；本应用拒绝 HTTP 配置，也不允许明文网络。试点需先部署可验证证书，并确保设备能访问上述两个地址。

Keycloak 新建或导入 `deploy/keycloak/realm-template.json` 中的 `ai-manager-parent` 公共客户端，启用 Authorization Code + S256 PKCE，精确注册 `com.aimanager.parent:/oauth2redirect`。已初始化的 Realm 不会因重新放置导入模板而自动更新；需由身份管理员按模板迁移客户端配置。这个移动客户端不授予平台目录/合同审批 scope。发布构建由交付流水线注入正式 Android 签名配置，不使用开发签名。

## 安全与交互边界

- 使用 `flutter_appauth` 的系统浏览器、OIDC Discovery 和 PKCE；密码不进入应用。刷新令牌存入 `flutter_secure_storage`，访问令牌仅在内存；Android 禁止自动备份。
- 访问审批先要求重新认证，服务端再次检查近期认证、MFA、成员角色、申请版本与时限。取消系统浏览器登录不会继续审批；网络结果不明时刷新原申请核对状态。
- 求助的“已看到”只表示成人已打开记录，不表示救援或问题解决。设备注册、商业权益、在线状态与系统策略执行分别展示，不混同为受保护证明。
- 设备注册凭据仅本次创建时可复制到剪贴板，应用不持久保存一次性令牌；只保留注册编号供中断后查询。复制后请只传给当前设备，完成后清空剪贴板。服务器创建结果不明时不要盲目重复创建，需先通过管理工作台核对。
- 本应用尚未完成真实 Android 设备、真实 IdP/MFA、TLS 证书和完整工作流的联合验收，不作为首发生产安装包。待完成页面与验收见 [手机端交付契约](../../docs/parent-android-delivery.md)。
