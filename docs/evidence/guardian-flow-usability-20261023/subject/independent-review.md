# 儿童档案弹窗最终静态独审

**结论：所审最终双文件未发现静态阻断项。全部交互场景 UNRUN，未渲染，也未进行 Dart 分析、编译或测试。**

## 最终绑定

- 完整审阅 r1 双文件补丁；r1 恰 8 件、7 条交付指纹与 5 项真实依赖均匹配。
- r2 恰 5 件，4 条交付与 6 条复用 r1 指纹匹配；完整差异只有 `_subjectForm` 的显式空值早返回及已提升局部变量去 `!`。
- Root integration 仅在详情 GET 后、`actionDetails(context, ...)` 前恢复显式 `context.mounted` 检查。原 `onTop()` 已间接检查挂载；此处为清晰性增强，不宣称观察到 lint。
- 三层文本补丁均重建为字节一致。最终 Main 两目标匹配原件；原 before 两目标逐字等于 e303580 原始 Git blob。已知并行 ResourcePage 改动在此次两目标外，未声称整个 Main 干净。

| 最终目标 | 字节数 | SHA-256 |
|---|---:|---|
| console_pages.dart | 93378 | `89fac14a4d5930b8398c29b5e0955a86740dce3fae8eaf59c955e989e31d0657` |
| design.dart | 31270 | `456ffeb3de558e824d47ac3bf9841cda8dd6790349fd522e5c7bb7857942e5fc` |

## 具体依据

1. `console-final.dart:632–680` 保留公开 `Future<void> subject([Json? existing])`，由私有结果 helper 区分取消与保存。初始挂载、原父路由 current/active/available、原 Session/租户/角色及 scope 门槛在 await 前捕获；持久访问检查不要求父路由始终在顶层。原字段、body、requestId 与 version 语义保持。通用 `_tenantForm` 和 subject 区域外代码逐字未变。
2. `:683–734` 确认取消返回 false，POST 位于明确确认和再次访问检查之后。取消不发归档请求；归档仍用原路径和 version，不新增请求 key、自动重放或取消已发请求。
3. `:736–795` 编辑/归档动作都设置 `closeOnSuccess: false`。仅非空保存结果或归档 true 且原 owner 仍有效时，调用捕获的原详情 completion。完成门槛保留 active/available，不以顶层要求吞掉合法发送后被覆盖的成功。真实 `OwnedDialogRoute.finish` 只完成所属路由，保留覆盖窗口。
4. 详情、确认和编辑 UI 只监听各自 flow 的 `DialogAccessBinding.changes`。绑定先观察 scope/原父信号，活到对应路由 Future 结束后清理；未把可先于根弹窗销毁的原页面 notifier 重新暴露给保留 UI。真实共享 binding、owned route、form/EditDialog 与 Api.scoped 的前后检查已逐段对照。失权后旧操作不转绑新工作空间。
5. `design.dart` 仅调整通用失权提示的窗口措辞，未改表单/详情控制流程。没有测试源码变更；原 api_test 仅为未改依赖指纹，不代表 Subject 行为验证。

## 边界

只做本地文本、JSON、哈希与只读 Git 核对；未执行 SDK、候选函数、AST、测试、格式化、进程检查或网络，未修改 Main/Git/作者原件。手工类型与数据流审阅不是 Dart 编译证明。未声称解决任意 Session 对象替换、无通知纯 bool ABA 或撤回已发请求。完整原件指纹与基线/最终目标记录见 `review-pins.json`。
