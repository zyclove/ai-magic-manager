# 执行记录：Flutter 接入契约

状态：客户端模型、Repository 与设备详情可选入口已通过 157 项定向回归及冻结管理端的静态分析。完整列表/详情界面、宿主接入和真实服务联调另行验收。后端来源为 `b7547e2`，见[接口与验证记录](managed-execution-console-api.md)。本阶段代码提交不自动更新运行服务。

## 用户流程

机构管理员从设备详情的“执行记录”进入，沿用设备名称与当前工作空间，不要求再寻找企业绑定。列表默认该设备，支持状态筛选；打开记录查看当前状态、原因及时间线。明确的准备阶段可以取消；结果不确定时说明“已登记取消，仍需复核”。已应用记录通过新策略调整。

审计员只读；OWNER、ORG_ADMIN 可管理；其他角色不显示入口，后端仍独立授权。历史注册记录可以查看，但当前设备窗口不允许取消旧注册的任务。切换租户、角色、账号或设备注册后，隐藏旧数据并退出原操作上下文。

当前设备列表后端明确不授予 AUDITOR 读取权限，因此不能只放宽前端设备菜单。协作界面计划复用受管 Android 页面已有的只读“查看儿童端关联”入口，为 AUDITOR 提供同一执行记录弹窗；该接入尚待实施验证。设备详情入口继续使用既有设备访问权限，不扩大设备资料的可见范围。

## 文件分工与复用

- 本任务：`core/managed_execution.dart`、`core/managed_execution_repository.dart`、模型/传输契约测试与夹具；设备详情仅增加可选 `onExecutions` 回调及现有样式按钮。
- 协作任务：新列表/详情/时间线与取消确认组件、近期 MFA、工作空间监听，以及 `console_pages.dart` 中的授权入口接入。共享文件在明确归属后修改。
- 保留现有 Flutter Material、Provider/ChangeNotifier、http、Api、boundedJson 和设备详情子流程，不迁移状态管理或路由，不新增传输框架。

## 对外 Dart 接口

以下签名已实现并通过本阶段定向测试；宿主仍须提供完整的作用域生命周期保护。

```dart
bool canReadManagedExecutions(String role); // OWNER, ORG_ADMIN, AUDITOR
bool canManageManagedExecutions(String role); // OWNER, ORG_ADMIN

class ManagedExecution {
  // 不可变；仅通过严格解析创建。
  final String id, publicationId, deviceId, registrationId, state, reason;
  final int revision, createdAt, updatedAt;
  final bool cancellationRequested;
  String get stateLabel;
  String get reasonLabel;
  static ManagedExecution parse(Object? raw, {required String deviceId});
}

class ManagedExecutionPage {
  final List<ManagedExecution> items;
  final String? nextCursor;
}

class ManagedExecutionEvent {
  final int revision, occurredAt;
  final String state, reason;
  String get stateLabel;
  String get reasonLabel;
}

class ManagedExecutionEventPage {
  final List<ManagedExecutionEvent> items;
  final String? nextCursor;
}

class ManagedExecutionRepository {
  ManagedExecutionRepository({
    required Api api,
    required String tenantId,
    required String deviceId,
    required String registrationId,
    required bool writable,
    required bool Function() current,
  });
  void ensureCurrent();
  bool canCancel(ManagedExecution task);
  Future<ManagedExecutionPage> list({
    String? cursor, String? state, String? publicationId,
  });
  Future<ManagedExecution> detail(ManagedExecution selected);
  Future<ManagedExecutionEventPage> events(
    ManagedExecution selected, {String? cursor},
  );
  Future<ManagedExecution> cancel(ManagedExecution selected);
}
```

模型保留整数 UTC 毫秒时间，由既有格式化函数展示；列表不可变。状态与原因标签由模型提供，界面不需要展示内部代码。`current` 必须由 host 绑定账号、租户、角色、scopeGeneration、对话框生命周期和目标设备注册；不能恒为 true。Repository 借用 `api.scoped(current)`，沿用既有 ScopeBindingClient 和 Session 的 ScopeGuardedClient，让作用域检查覆盖 OAuth 刷新后的实际发送边界及私有响应流；不会关闭会话拥有的传输连接。

## 请求与数据约束

1. 所有路径固定在 `/tenants/{tenantId}/managed-android/executions`；列表必须带 `deviceId`，每页 50 项。UUID 使用小写完整形式，查询参数经标准 URI 编码。
2. 任务 JSON 精确对应后端十个字段；不接受额外内部字段。校验设备归属、UUID、受支持状态/原因、布尔值及 `createdAt <= updatedAt`。版本范围为 1–9007199254740990；时间为非负整数 UTC 毫秒，最大 8640000000000000，确保可被 Dart DateTime 表示。
3. 列表允许该设备的历史注册记录；按创建时间、ID 倒序，页内不重复。非空游标必须是当前页最后一个任务 ID，空页不得带下一页游标。传入游标不能在新页再次出现。UI 合并页面时另外检查跨页重复，并在筛选改变时丢弃旧游标。
4. 详情必须保持所选任务的 ID、发布、设备、注册、创建时间，版本不能倒退；相同版本的状态、原因、更新时间及取消标志必须保持一致。不能将另一个任务的响应显示到原详情。
5. 事件仅有版本、状态、原因、发生时间四个字段；每页最多 50 项，版本严格递增且大于请求游标；下一游标为页尾版本的标准十进制文本。事件可晚于先前读取的详情版本，界面提示刷新详情，不丢弃合法的新进展。
6. 只读请求复用 boundedJson，响应上限分别为列表 256 KiB、详情/取消 16 KiB、事件 64 KiB。不跟随重定向，不自动遍历全部页。
7. 取消前检查工作空间、写权限、同设备、当前注册和可取消状态。携带所选 `revision` 生成强 If-Match，复用后端近期 MFA。请求不自动重试。
8. 取消成功必须对应同一任务并保持不可变字段；版本前进、取消标志为真，状态为 CANCELLED 或 NEEDS_REVIEW。旧版本/旧内容不能当作成功。
9. 响应不合法使用 `INVALID_MANAGED_EXECUTION_RESPONSE`；参数或目标不合法在发送前拒绝。401/403/412 等后端状态保持原义，不替换成泛化成功结果。

## 界面状态处理

| 结果 | 界面行为 |
| --- | --- |
| 401 REAUTH_REQUIRED | 清除取消确认，调用既有重新认证流程；认证后重新读取并由用户再次确认 |
| 其他 401 / 403 | 清除私有数据与确认状态，转向登录或可访问页面 |
| 412 | 取消旧确认并重新读取详情；不得拿新版本自动补发取消 |
| 网络中断 / 取消返回无法校验 | 显示“尚不能确认取消结果”，只提供读取核对；不自动重发 |
| INVALID_CURSOR | 保持筛选，清空分页数据，从第一页重新读取 |
| WORKSPACE_CHANGED | 使原请求结果失效，清除列表、详情和确认，不切到新租户继续原操作 |
| 历史注册 | 显示“历史注册记录”，可查看详情与事件，隐藏取消 |

近期认证属于宿主会话流程；本仓库不维护第二套账号或登录。对话框关闭与迟到响应使用现有生命周期检查；重试读取不会重放写操作。

## 验收与证据

客户端需实际验证请求路径/过滤、任务与事件分页、取消 If-Match、不可变身份/版本校验、历史注册只读、角色入口、请求前/响应后上下文失效、401/403/412 和不确定取消处理。界面需覆盖窄屏、键盘、加载/空/失败状态、禁止重复点击、重认证后重新确认及关闭后的迟到响应。

本阶段证据见[客户端验证记录](evidence/managed-execution-flutter-20261017.json)。通过的范围为模型、Repository、可选入口及既有设备管理回归；HTTP 为本地夹具，OAuth 刷新使用实际 OAuth 客户端和可观察的本地传输。正式后端与浏览器端到端接通、真实设备反馈以及 Android 验证各自记录，不以本阶段测试代替这些验收。

### 验证过程与结果（2026-10-17）

早期依赖准备因缓存写权限和内存不足未执行测试。随后获得缓存访问授权，资源恢复，完成下列实际验证。原失败记录保留，未改写为成功。

| 阶段 | 实际结果 | 结论范围 |
| --- | --- | --- |
| 原功能 RED r2 | 4 项预期失败，原生退出 1，无编译失败 | 未实现模型/查询及缺失入口可被用例发现 |
| 作用域修复前 RED r1 | 2 项断言失败，原生退出 1 | OAuth 刷新期间失效的查询/取消仍触达业务传输，确认原缺陷 |
| GREEN r3 静态分析 | 7 项缺少花括号的风格提示，退出 1 | 已逐项修正，保留原记录 |
| 最终 GREEN r4 | 157 项通过、0 失败、0 跳过，退出 0，80.1 秒 | 新执行记录、入口及既有设备管理和传输回归 |
| 最终 GREEN r4 静态分析 | No issues found，退出 0，36.6 秒 | 同一冻结管理端源码，包含本阶段变更 |

原功能 RED 的报告格式分别为 1 项普通断言失败、1 项预期异步未实现错误、2 项 Flutter 包装的界面断言错误。原收集器要求全部标记为 `failure`，因此原收集结果仍保留 `VERIFICATION_FAILED`；独立读取固定日志、用例 ID、堆栈及界面断言后，另写分类记录确认四项均为预期失败，未把编译失败或无关异常当作行为验证。

独立静态审查发现的 OAuth 刷新发送边界问题已修正；两项修复前用例和最终 GREEN 验证了差异。取消仍只有一次发送，不自动重试；借用 Api 不关闭会话传输。

因初期资源阻碍，顺序是先静态实现，再回放冻结未实现/修复前副本和修复后副本。因此历史 `TEST_FIRST_NOT_EXECUTED` 保留，不能宣称严格测试先行。最终验证是实际 RED/GREEN 回放，而非静态推断。

每个最终运行阶段均自然退出，所属进程树为 0；414 个冻结源文件摘要未变。新副本统一位于项目 `.cache/execution-client/`，旧 `.local` 文件仅保留历史证据。活动集成结束前保留唯一源码副本和日志，清理前先盘点、摘要和归档，不遍历目录链接目标。

### 复现与剩余验收

在包含本阶段提交的独立工作副本中，使用项目锁定的 SDK/依赖运行：

```text
cd apps/guardian
flutter pub get --offline --enforce-lockfile
flutter test --no-pub --concurrency=1 test/managed_execution_test.dart test/managed_execution_entry_test.dart test/device_management_test.dart test/device_management_dialog_test.dart test/bounded_json_test.dart
flutter analyze --no-pub
```

离线复现需要已缓存的锁定依赖。完整页面的窄屏/键盘/状态交互、AUDITOR 既有只读入口接入、真实后端浏览器联调、真实提供方以及 Android/TV 验证仍未由本阶段证明；实施整体目标保持未完成。
