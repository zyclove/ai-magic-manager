# 儿童临时访问：可信上下文与加密存储契约

本阶段交付临时访问宿主所需的可信绑定、私有数据库入口和损坏保护。实际进度见 [实施记录](access-child-host-plan.md)；临时窗口接收、儿童界面、设备申请和系统执行仍需后续接入验收。

## 1. 设备上下文

`GET /api/v1/device-api/access-context` 使用独立设备不透明凭证，要求 `device:operate`。成人 OIDC 管理权限不能代替设备凭证，待激活轮换凭证也没有操作权限。

响应仅含以下字段，均为非空 ID；无档案昵称、成人资料、密钥、签发者配置或执行状态：

```json
{
  "tenantId": "credential-bound-tenant",
  "subjectId": "device-bound-subject",
  "deviceId": "credential-bound-device",
  "registrationId": "credential-bound-registration"
}
```

- 服务端不接受选择目标的请求体/路径参数；附加查询参数不能切换目标。成功响应 `Cache-Control: no-store`、`Vary: Authorization`。
- 按已有访问下发的顺序观察设备 → 锁档案生命周期 → 锁设备生命周期 → 重查绑定 → 锁凭证范围并重查凭证。事务超时 10 秒。档案归档、设备非 ACTIVE、范围撤销或凭证失效不能取得有效上下文。
- 401 表示凭证不可用；403 表示操作范围/生命周期不允许；并发绑定改变返回 409 `ACCESS_TARGET_CHANGED`。同现有错误契约带请求关联标识，不包含 SQL 或凭证。
- Dart 客户端固定调用该路由，每次重新读取凭证；严格要求恰好四个字段。调用者必须以 `requireIdentity` 比较已恢复身份的租户/设备/注册，随后使用服务端 subjectId 建立 `DeviceAccessScope`。JWS 内容和界面输入不提供可信档案来源。
- 该上下文仅描述响应时刻的绑定。宿主遇到 401/403、身份改变、解除管理时必须隐藏全部旧访问状态；不能因已有上下文继续展示旧授权。已归档后不依赖新上下文接收 REMOVE，宿主直接停用本地访问状态。

## 2. 私有数据库

`openAccessDatabase(scope.storageKey)` 是独立入口；默认密钥保护仅允许 Android。其他平台明确失败，不能退回明文或内存库。文件位于应用支持目录，名为 `access-v1-<64位小写十六进制范围摘要>.db`；范围参数校验在任何路径或密钥访问之前执行。

| 层 | 已采用实现 | 失败行为 |
| --- | --- | --- |
| 事务与文件格式 | 锁定依赖 Sembast 3.7.2 | 显式 `DatabaseMode.create`；损坏或解密失败抛错，保留原文件 |
| 记录加密 | PointyCastle 4.0.0 AES-256-GCM，经 `SembastCodec` 适配 | 随机 96 位 nonce、128 位 tag；范围摘要参与 AAD；认证失败仅返回固定错误 |
| 密钥保护 | 已有 FlutterSecureStorage 10.0.0 Android 配置 | `resetOnError=false`；复用原生 `flushIdentity` 持久化屏障 |
| 密钥生成 | 平台安全随机源生成 32 字节 | 无现有库时才可创建；先写入、持久化、回读并再次持久化校验 |
| 并发 | 同一应用 isolate 中的串行密钥获取 | 不支持多 isolate/多进程同时写库，宿主必须保持一个生命周期拥有者 |

密钥独立固定键为 `access_key_v1_<scope摘要>`；不提供 readAll、delete、reset、导出或儿童重置入口。已有库但密钥缺失、编码异常、读写失败或持久屏障失败均抛 `ACCESS_KEY_UNAVAILABLE`，不能重新生成。写屏障失败后保留原记录；后续通过回读校验恢复，仍使用同一密钥。

记录 JSON 编码后上限 1 MiB；解码前限制密文字符串长度，认证 tag 校验后才解析 JSON。数据库打开失败统一 `ACCESS_STORAGE_FAILED`；编解码错误统一 `ACCESS_DATABASE_INVALID`，不暴露密钥、原文或加密底层异常。

成熟库提供加密原语和事务，项目仅实现范围绑定、密钥生命周期和 Codec 适配。官方说明 Sembast 接受外部 Codec，默认 `neverFails` 可删除损坏数据库，因此授权相关库必须显式选择创建模式并验证损坏行为。[Sembast Codec](https://pub.dev/documentation/sembast/latest/sembast/SembastCodec-class.html)、[打开模式](https://pub.dev/documentation/sembast/latest/sembast/DatabaseMode-class.html)、[PointyCastle](https://pub.dev/packages/pointycastle)

## 3. 已有基础配置库修复

基础配置的 `configuration-v1.db` 同样改为显式 `DatabaseMode.create`，可新建和正常重开；损坏时不清空重建。新增可注入目录用于真实文件回归，正式宿主仍使用应用支持目录。本阶段未改变其文件格式、未添加密钥迁移，也不声明基础配置库已被新增访问 Codec 加密。

## 4. 交付边界与后续流程

本地加密不替代签名验证、基础版本/应用/规则匹配、撤回墓碑和原期限检查；不提供硬件防回滚、root 防护、强制停止防护或已执行系统策略证明。Android SDK 的 MethodChannel 用例验证调用次序与错误保护，实际文件用例验证加密和数据保留；二者不等同于新密钥路径的原生跨进程认证。

后续宿主须先恢复有效设备身份，读取并匹配上下文，再打开范围库；基础配置重新验签后才允许 `AccessWindowJournal` 接收临时文档。后台/回前台/到期刷新保持原截止时间；失败停止旧状态展示。儿童申请入口需设备申请专用授权或真实儿童 OIDC，不能用设备凭证冒充成人/儿童成员。界面必须区分已保存配置与系统实际管控。
