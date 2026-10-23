# ResourcePage 搜索候选独立静态审阅

结论：**STATIC_NO_BLOCKER**。基线 HEAD 实读为 `e303580030192497a63492d1147156e465082706`。候选 after19437B/SHA `ac3667fff335d8105c5e10e7e3b5b45dc0b5bbb8bc00eb0d94175ee432ed9ed3` 与作者 pins 一致；1615B 完整 patch 从 Main before18737B 和 after 的真实 UTF-8/LF 字节重新生成后精确相同。原件和 Main 未改。

## 手工核对

- 候选 `resource_page.dart:8–17` 的私有函数接受 `Object?`、返回 `String`。null 先返回空串；Map 只递归 values，Iterable 递归元素，各层 join 返回字符串；普通 JSON 字符串/数字/布尔值走原值与现有 `label(dynamic)` 的合并分支。String 本身不是 Iterable。两处 map 的回调能接受对应的动态 JSON 元素，未见手工可确认的 Dart 类型或空值阻断；这不是编译证明。
- `core/api.dart:292–295,322–338` 的真实加载链先 JSON 解码再构造行 Map；因此此递归沿用 API JSON 无环树前提。没有为任意人为构造的循环 Dart 容器新增支持，也不以该非生产假设报缺陷。
- `resource_page.dart:241–251` 先统一小写并按连续空白拆出非空词；`terms.every(text.contains)` 符合跨字段 AND 的指定设计。空输入或仅空白不调用投影，直接使用 rows；后续窄屏卡片与表格只迭代 filtered，不原地修改它或 rows。
- 真实状态链为设备列表 `console_pages.dart:325` → `StatusTag`（`design.dart:120–140`）→ `label(value)`；`labels.dart` 明确将 `ACTIVE` 映射为“已注册”。新投影同时包含小写原状态和该中文标签；未知值仍走 label 的原字符串回退，空值不投影成误导性的 `null`。
- 修改仅新增现有 labels 导入/私有投影和 filtered 计算；完整 patch 未改 owner、canInteract、异步 generation、网络分页、错误恢复、创建/打开动作、清除搜索、加载更多或其守卫。依赖仍为已有标签 helper，无新 public API/框架/包。

## 范围与未验证项

只保证原 JSON 值与统一 label 的搜索文本；不扩称 dateLabel 的本地化日期、shortId 的省略号或任意 ColumnSpec 自定义 Widget 文本均可搜索。仍只搜索已加载记录，原空结果提示和加载更多入口保留。

既有 `resource_page_resilience_test.dart:270–285` 源码覆盖搜索空结果后继续分页；没有覆盖本次新增的中文状态、多词跨字段、嵌套对象/列表与 null 分支。本轮未新增或运行测试；这些场景、SDK 分析、格式化和渲染全部 **UNRUN**。只进行了源码阅读及字节/hash/JSON/完整 patch 文本核对，没有执行候选函数、AST、SDK、进程或网络操作。
