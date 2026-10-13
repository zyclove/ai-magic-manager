# 监护人手机端：观察授权与断网恢复

更新：2026-10-13。承接 [手机使用报告](parent-usage-report-delivery.md) 与 [观察后端契约](device-observation-contract.md)。本阶段补齐手机端应用清单、系统使用摘要的云端授权管理；逐应用权限观察仍是另一项独立授权。

## 产品流程

入口：设备列表 → 设备操作 → 观察授权；或使用报告右上角“管理观察授权”。支持 OWNER、GUARDIAN、ORG_ADMIN，设备须 ACTIVE；服务端成员、租户和设备范围是最终依据。

1. 读取加密待核对记录和当前设备注册，核对原设备、注册周期、儿童档案及平台。
2. 显示当前授权版本和两个独立开关。首次状态为关闭；不把未授权显示成已采集。
3. 修改范围、填写原因，阅读前后变化并确认采集和撤回影响。
4. 通过既有 AppAuth 再次安全验证。返回后重新核对设备注册和授权版本；变化时停止提交，要求刷新。
5. 在 Android 安全存储确认落盘原请求、版本及请求编号后，单次提交。服务端再次校验近期 MFA、当前权限、设备行锁、注册周期与授权版本。
6. 只读查询原操作结果及当前状态，两者分别展示。例如历史结果为允许、当前状态已撤回时，不显示为仍在允许。
7. 管理者明确核对后才能清除本机记录。清除不撤销云端授权，不重试原写入。

每次保存会清空当前应用清单，等待设备按新版本重报。关闭使用摘要会清理后端既有摘要和回执头。设备离线时只有下次连接核对后才能清理旧待发数据；界面不声称已远程即时擦除。云端授权不代替 Android 特殊访问许可，也不打开摄像头、读取 HTTPS 网页或证明系统限制执行。

## 接口契约

既有 `GET/PUT /api/v1/tenants/{tenantId}/devices/{deviceId}/observation-settings` 保持兼容。手机端使用新增注册绑定接口；这些管理响应增加 `Cache-Control: no-store` 和 `Vary: Authorization`。

### 注册绑定变更

`POST /api/v1/tenants/{tenantId}/devices/{deviceId}/observation-settings/changes`

头：管理员 Bearer 凭据、`Idempotency-Key: <UUID>`。正文：

```json
{
  "registrationId": "00000000-0000-4000-8000-000000000002",
  "version": 0,
  "inventoryEnabled": true,
  "usageEnabled": true,
  "reason": "监护人确认学习时间规划用途"
}
```

`version` 为已读取的原授权版本，范围 0～9007199254740990；原因必填且不超过 300 字符，手机拒绝控制字符。返回既有 ObservationSettings 六字段结构，版本必须恰好加一。注册检查和写入处于同一设备锁事务，注册不匹配返回 409 `REGISTRATION_CHANGED`；版本不匹配 412，近期认证缺失 401，权限不足 403。

继续复用 `observation.update` 的指纹（设备编号、原版本、原 Update 正文）、审计事件和幂等服务，不新增数据库表或另一套授权引擎。该追加接口不改变旧客户端的字段或调用签名。

### 只读恢复

`POST /api/v1/tenants/{tenantId}/devices/{deviceId}/observation-settings/operation-results/{requestId}/query`

正文为原 Change，返回 `{ "committed": <原提交授权>, "current": <当前授权> }`。POST 用于避免原因进入 URL 日志；接口不执行变更、不生成新请求、不延长保留期。

- 仅当前仍拥有成人写权限的原操作者能够读取；绑定原租户、设备、注册和指纹。
- 不要求再次 MFA；写权限不等于只凭旧响应获得新的授权。
- 404 `OBSERVATION_RESULT_UNAVAILABLE` 表示原结果不可得，不证明从未提交。
- 410 `IDEMPOTENCY_RESPONSE_ERASED`（底层删除流程返回时）表示历史结果已删除，手机保留记录供明确核对，不更换请求编号重建授权。
- 409 注册变化或设备停用不重放；401/403、服务不可用及不一致响应继续保留待核对记录。
- 回执版本、原开关或注册不匹配时整份回执拒绝展示，不能以部分字段确认成功。

## 客户端结构与成熟组件复用

| 层次 | 实现 |
| --- | --- |
| 展示 | ParentObservationPage，沿用手机端 Material 主题、SwitchListTile、Form、CheckboxListTile、滚动单列与语义提示 |
| 业务流程 | ParentObservationController，统一加载、预检、提交、查询、确认和生命周期状态 |
| 模型 | 已有 device_observation 的 ObservationAuthorization/ObservationScope 严格解析器 |
| 认证与传输 | 现有 flutter_appauth、ParentSession、ParentApi/http；令牌读取后再次核对作用域 |
| 持久化 | 现有 flutter_secure_storage + ParentDurableStorage 原生落盘确认，不新增明文文件 |
| 后端 | 既有 Spring MVC/Validation/事务、设备锁、RecentAuthentication、IdempotencyService、AuditService |

依赖锁新增工作区 `device_observation` 及其 `device_policy` 传递依赖（包括项目已有的加密/存储包），未升级原有依赖版本。此手机页面只调用模型解析，不启动设备侧采集代理。许可证和漏洞治理仍按仓库统一组件清单执行。

## 生命周期、交互和恢复边界

- 用户、角色、租户改变时隐藏内容并移除对应页面；进入后台隐藏表单与当前回执，丢弃迟到响应。回到前台由用户重新读取或查询。
- 系统身份验证返回后允许按原确认范围继续，但仍需要原注册和原版本预检。取消身份验证不提交。
- 身份过期时提供“重新安全验证并核对”；成功后只重新读取当前状态或查询原结果，不自动重放授权变更。
- 进入观察设置时销毁报告界面的旧结果；返回报告时重新建立视图并重新读取，不保留撤回前的用量快照。
- 网络失败、进程中断、落盘结果不确定时，重新进入使用同一记录只读查询。没有自动重试、定时写入或“读取结果”触发授权的路径。
- 本机记录按租户、成人、设备隔离；每台设备同一成人一次仅保留一项待核对变更。当前恢复入口在原设备页面，设备不再可见时需通过管理台/支持流程核对审计；尚未交付独立的跨设备待核对中心。
- 页面不承诺瞬时感知其他管理员的远程撤回；显示的是此次服务器核对的当前事实。原生后台网络读的取消仍沿用 ParentApi 超时与页面代次失效，非底层立即断开保证。

## 本阶段验证

| 检查 | 结果与证据范围 |
| --- | --- |
| 手机完整回归 | 95 项通过，其中新增观察授权 14 项；MFA 取消、身份过期后只读恢复、作用域/注册/版本变化、落盘失败、回执丢失、后台迟到结果、404/410、伪造成功、大字交互和撤权关闭 |
| 手机静态分析 | 无问题；新增 HTTP 验证工具也单独分析通过 |
| Android debug APK | 构建成功；配置为示例 HTTPS 域名，仅证明编译，不代表真实身份服务连接 |
| 后端定向回归 | 基线 `9c85594` 加本次两个生产文件与独立恢复测试，隔离 H2 验证 10 项通过（恢复 3、既有观察旅程 7），0 跳过 |
| 手机生产控制器 → Spring 实际 HTTP | 同一隔离基线新增 opt-in ParentObservationHttpInteropTest，1 项通过、0 跳过；子进程 Flutter 工具 1 项通过 |
| 可视化 | 390×844、1.5 倍字体下完整表单/提交/确认流程通过，截图人工检查无横向溢出；[授权页](design/parent-observation/portrait.png)、[结果页](design/parent-observation/result.png) |

首次后端测试夹具试图直接改动外键引用的注册号，被数据库约束拒绝；已修正为向实际设备发送不匹配的原注册号，重新运行 10 项全部通过，没有禁用约束。隔离快照不包含另一任务未提交的主体删除/幂等归属改造。

最终补齐变更接口的必需 UUID 幂等编号校验后，上述三个后端测试类一起重跑：11 项通过、0 跳过，75 秒退出成功；两个生产文件和两个测试文件均与实际工作区 SHA-256 一致。

协作阶段提交 `e1e39d9` 后，再从该提交完整导出后端，加入本阶段两个生产文件与两个测试文件，重新执行同样 11 项检查（包括手机生产控制器实际 HTTP），全部通过、0 跳过，55.954 秒退出成功。该联合结果覆盖新增幂等归属结构与观察接口共存；协作阶段自身的完整回归仍属于其原有证据范围。本阶段未部署到正在运行的服务。

真实 HTTP 工具使用生产 ParentApi、ParentObservationController、严格模型和实际 Spring 安全链/事务/数据库。通过临时回环端口授权，消费成功响应后主动丢失回执，重建控制器并保留同一原请求编号，再由既有 PUT 撤回，核对历史允许与当前关闭。最终数据库授权版本为 2，幂等记录为 2；重复查询未产生额外写入。测试只接受 `127.0.0.1` 夹具地址，临时凭据仅通过子进程环境传递，不写到命令行或磁盘文件。

成人 JWT decoder、近期 MFA 声明、活动设备、认证回调及手机内存存储是显式夹具。控制器重建不代表 Android 进程杀死后加密恢复；本次没有设备侧采集，也未调用真实 IdP。上述结果不称为真实 Android → IdP → 后端完整联调，不视作 MySQL/OceanBase 发布认证。

复现：在冻结后端目录用 Maven 执行 `-Dtest=ObservationRecoveryTest,DeviceObservationJourneyTest test`。真实 HTTP opt-in 另执行 `-Dtest=ParentObservationHttpInteropTest`，并设置 `parent.dart.command` 为本机 Dart 可执行文件绝对路径、`parent.flutter.tool` 为匹配 SDK 的 `flutter_tools.snapshot` 绝对路径、`parent.package` 为本仓库 `apps/parent` 绝对路径。它使用固定独立 H2 内存库；默认未提供 opt-in 时跳过，跳过不代表通过。

UI 沿用已审核的现有组件。此前 12ui 外部生成受运行及自动审批限制，本阶段未重试上传仓库内容。手机大字截图使用本地公开夹具，不能代替实体设备、屏幕阅读器和真实登录验收。

仍需完成独立权限观察手机入口、多设备/班级报告与导出、跨设备待核对中心、真实身份服务和 Android 生命周期联调。EMM 实施、实体 TV 兼容、全球发布和完整容量门槛仍在总项目范围内。
