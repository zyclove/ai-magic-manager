# 新增浏览器用例：提交调度候选（全部 UNRUN）

## 已证事实与推断

Root实际Browser80-r2在`standalone void dialog permits a covered retry…`开始后无done，最终触发原command210上限；不改变这份RED记录。

源码路径是：`usage_reports_scope_browser_test.dart:571`直接等待submit；`usage_report_job_dialog.dart:100`等待repository.create；`usage_report_jobs.dart:272–281`调用`boundedJson`；`bounded_json.dart:43/46/72–100`依次等待client、send及response-stream Completer，149处有25秒timeout。此路径**不调用Api.send**。FixtureSession的61行直接返回MockClient；已读生产链没有自动retry或503退避计时器。

本机Flutter binding的1468–1496行表明testBody处于FakeAsync，先flush假微任务，再仅在有runAsync任务时桥接真实异步；1281–1304行的runAsync将微任务/Timer调度到真实zone。现有workspace.flushReads的98–104行正是runAsync(real zero-duration)与8次50ms pump的有界组合。

**静态诊断：** 8处有效网络提交先await结束，才可能进入这个既有排空步骤，存在等待真实stream事件/后继假zone continuation而不再推进测试的闭环；与实际停点及同文件已使用的_Invocation→flush模式一致。没有拿到被挂Future的执行堆栈，且本轮读取本机http/testing.dart被权限拒绝，因此不声称已证明某个具体底层stream事件或重试Timer是唯一原因。没有运行复现/SDK/测试。

## 最小补丁

仅两个测试文件，各加一个小函数：

```dart
final invocation = _Invocation(submit());
await workspace.flushReads(tester);
expect(invocation.completed, isTrue);
expect(invocation.failure, isNull);
```

复用现有_Invocation及排空工具，没有新测试框架。真实submit仍立即调用，Future的完成和未捕获失败被明确检查，没有仅unawaited丢弃异常，也没有等待一个尚未完成的Future而再次卡住。原来紧随网络await的重复flush由helper中的一次flush替代。

| 源文件 | 改动前位置 | 原因 |
| --- | --- | --- |
| usage_reports_scope_browser_test.dart | 571 | covered standalone<void>真实POST503，必须读完失败并退出busy后才能close |
| 同上 | 607 / 614 | 原draft/key首次POST428及重试POST202 |
| observation_route_scope_browser_test.dart | 163 | 合法原因和确认后的正常PUT |
| 同上 | 230 | PUT401并展示重新认证 |
| 同上 | 393 / 396 | 未知503后原payload/key/version重试 |
| 同上 | 412（首次submit） | PUT412进入终态，随后第二次submit仍同步拒绝 |

## 明确保留的直接等待

- reports396/438：失效或已结束旅程；457/491/530/578：close或foreground ABA后同步拒绝。无pump断言及请求次数顺序不动。
- observation149/158：原因/确认不足的表单同步返回；218/247/282/334/367：closed/disposed/失效/busy旅程；413：已terminal的第二次提交。全部保留原直接await和无pump契约。
- 已经使用_Invocation后flush、受控Completer完成后flush的场景，以及共享Api读取不做泛化替换。

## 静态完整性

2文件、8处网络提交，0生产文件。全部原expect、fixture503/428/401/412/202、原draft、Idempotency-Key、If-Match、callback和closed同步断言保持；仅移除与helper重复的既有flush。把8处替换及新增helper反向还原后，逐字节等于原Main；名称字面提取相同，原循环未动，所以80名称/7suite保持。声明行号会因新增helper变化，未来新source合同应重新绑定实际行号。

`application-manifest.json`记录精确before/after和patch摘要。Main、冻结source、旧执行包和RED证据均未修改。格式化/Dart解析/分析/编译/浏览器全部UNRUN；这份补丁仍需Root独审及后续实际验证，不宣称已修复通过。
