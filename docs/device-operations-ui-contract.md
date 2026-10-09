# 设备退出组件与管理台接入契约

更新：2026-10-09。独立开发范围为 `packages/device_operations`，管理台及运行服务由任务“给我前后端全部跑起来”负责。本文随组件实现更新；原生代理清理、受管解除及整机擦除另需交付。

## 设计与信息结构

复用[管理台视觉参考](design/management-console.png)：浅灰背景 `#F5F7FB`、白色面板、海军蓝 `#19335C` 主操作、正文 `#172238`、辅助文字 `#67758A`、边线 `#E2E8F0`；面板圆角 12、间距 8/16/24，按钮最小高度 44。标准 Flutter Material 3 控件承担焦点、键盘、语义和触控行为。

设备详情中的退出面板依次展示：设备与管理模式 → 明确后果 → 确认勾选 → 操作提交 → 云端访问与本地清理双状态 → 有边界的取消。窄屏纵向排布，正文自然换行，外层由可滚动页面或对话框承载。

| 状态 | 文案与操作 |
|---|---|
| 尚未预览 | 查看退出后果 |
| 预览有效 | 逐项展示后果与限制；勾选“我已了解退出后的影响”才启用“确认退出” |
| 预览过期或版本变化 | 重新获取预览并再次确认 |
| 提交网络失败/响应无法验证 | 提交结果待确认；保留原请求键，用“核对上次提交”重放原请求 |
| 已创建操作 | 云端访问：已撤销；本地清理独立展示 |
| 设备报告清理 | 设备自报已清理（未独立验证） |
| 取消 | 说明不恢复云端凭证，无法召回离线缓存命令 |

未知后果、缺失限制、未知状态与跨设备响应禁用破坏性操作，不能把未知字段翻译成成功。角色范围来自已验证的管理端会话，服务器仍为授权权威。组件不收集或保存用户密码、令牌、设备私钥。

## 实施验证

先编写模型、HTTP 契约、状态机及组件测试并观察失败，再实现。重点覆盖：响应绑定、版本头、请求键复用、持久化失败、撤权、预览过期、取消边界、窄屏及字体放大。桌面与窄屏实际渲染证据后补，未验证项不得标为已交付。

## 管理台接入

管理台使用本地路径依赖，无第二套登录与网络框架：

```yaml
# apps/guardian/pubspec.yaml，由管理台任务负责接入
dependencies:
  device_operations:
    path: ../../packages/device_operations
```

```dart
import 'package:device_operations/device_operations.dart';

// session 来自现有已验证的 /me 与 /membership。
// device 是真实设备详情响应，禁止从 URL 或角色下拉框构造成人身份。
final controller = ExitController(
  scope: ExitScope(
    actorId: session.profile!['subject'] as String,
    tenantId: session.tenant!['id'] as String,
    deviceId: device['id'] as String,
    registrationId: device['registrationId'] as String,
    role: session.role,
  ),
  gateway: DeviceOperationsClient(
    apiRoot: Uri.parse(apiRoot), // 正式环境为受信任 HTTPS /api/v1
    clientFactory: session.authenticatedClient,
    allowLoopbackHttp: localDevelopment, // 仅 localhost/127.0.0.1/::1 可用
  ),
  journal: PreferencesExitJournal(),
);
await controller.initialize();

// 放入 SingleChildScrollView 页面或可滚动、受宽度约束的对话框。
DeviceExitPanel(
  controller: controller,
  deviceName: device['displayName'] as String,
  reauthenticate: () async { session.login(stepUp: true); },
);
// 宿主页面 dispose、退出登录、切换租户、注册或角色时：controller.dispose()。
```

重新验证回调只进入验证流程；返回或浏览器重载后，仍需用户明确点击“核对上次提交”。禁止回调自动调用 confirm/cancel。actor 的命名空间必须包含身份服务上下文；当前单一 issuer 的 subject 可直接使用，多 issuer 应使用经验证的 issuer + subject。

本包不接管客户端的关闭、刷新令牌或 OIDC 状态。宿主负责失去当前成员关系后销毁旧控制器。服务器对每次请求和幂等重放重新授权，因此本地角色只改善交互，不能提供安全授权。

## 恢复与实现边界

- `http` 处理网络，`uuid` 生成请求键，`crypto` 仅生成恢复命名空间摘要，`shared_preferences` 保存非秘密恢复元数据。解析严格校验 UUID、毫秒时间、整数版本、预览哈希、设备与注册绑定；HTTP 超时覆盖凭证获取、响应头和有界响应正文。
- 恢复记录在发送写请求前保存。记录损坏或保存失败时禁写；结果未知时保留原请求，不自动重新预览或换键。服务端返回合法操作后再 GET 当前状态，避免把幂等缓存快照当作最新回执。
- 本地偏好存储不保证写入返回即完成落盘，不能承担关键数据的唯一保存；服务端幂等及审计为权威。清理浏览器存储、换设备或多进程写入可能失去恢复元数据。一个会话/设备注册只保留一个活动控制器；该适配器没有跨标签页原子锁，不能声称支持多窗口并发写入保证。[官方存储说明](https://pub.dev/packages/shared_preferences)
- `replayWindow` 默认为 24 小时，部署时不得长于服务端幂等保留窗口；本地时钟异常或超期时停止自动重放入口，允许查看状态并联系管理员。服务端的期限和重新认证仍为权威。
- 仅实现 BYOD `AGENT_UNENROLL` 管理界面。原生代理执行/密钥删除、系统受管解除、整机擦除、移动端 OIDC 和真实设备联调未在本组件中完成。
- 示例目录 `packages/device_operations/example` 为明确标识的组件验收夹具，不请求业务 API，不证明真实设备已退出；生产库 `lib` 不含夹具或示例网关。

接口以[现有后端契约](device-deprovision-contract.md)为准。管理台的 MFA 方法应使用当前 Session 公共签名；上述回调需与真实登录函数对齐后接入。
