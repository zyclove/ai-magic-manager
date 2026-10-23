# 按钮子类型断言候选独立可整合性审阅

## 结论

**可按当前基线整合为 4 个测试文件的 14 处机械 matcher 修正。此结论仅为源码可整合性，不是测试通过或产品漏洞已复现。**

基线为 `80a7c896c17166e8667270cda0ba8c5b6a28b8e4`。实际独立只读回读 `ec8098` 自然退出 0：原候选 9 份仓库来源 pins、4 份 SDK 源码 pins、9 份交付 pins 全部仍匹配；4 份 Main 测试与当前 HEAD 规范化文本一致；4 份候选各自 SHA 与原回执一致。没有应用或重写原候选，没有修改 Main/Git，没有调用 SDK、formatter、编译、测试或网络。

原 patch 3750 字节，SHA256 `7889849f5a096634dfd58a96f4b667ce6164e31991dafd64de20370e50d4f765`。

## 当前 Flutter 源码与导入支持

- Main `apps/guardian/.dart_tool/package_config.json:107–109` 将 `flutter_test` 绑定至 `D:/softwares/flutter/packages/flutter_test`，Flutter 绑定至同一 SDK，描述版本 `3.22.2`。
- 该 SDK `packages/flutter_test/lib/flutter_test.dart:67` 导出 `src/finders.dart`。
- `finders.dart:219` 已提供 `Finder bySubtype<T extends Widget>({bool skipOffstage = true})`；`:1446` 实现为 `candidate.widget is T`。原 `byType` `:240` 与 `:1460` 使用 `runtimeType == widgetType`，不包含子类。
- 当前 SDK 非空 icon 工厂：`filled_button.dart:90–120` 返回 `_FilledButtonWithIcon`，`:532` 声明它 `extends FilledButton`；`outlined_button.dart:94–120` 返回 `_OutlinedButtonWithIcon`，`:452` 继承 `OutlinedButton`；`text_button.dart:103–133` 返回 `_TextButtonWithIcon`，`:494` 继承 `TextButton`。
- 四个测试已有 `package:flutter/material.dart` 与 `package:flutter_test/flutter_test.dart` 导入；候选不增减导入或依赖。`bySubtype` 的默认 `skipOffstage=true` 与原 `byType` 相同。

上述为本机缓存源码证明，不需要运行或升级 SDK，亦不能代替 Dart 编译证明。

## 精确 14 处改动

下列行号在 before/after 相同，全部只把 `find.byType(T)` 换成 `find.bySubtype<T>()`。没有 `ButtonStyleButton` 更改；现有正向可用按钮 helper 在 `device_subflow_scope_test.dart:267–273` 使用 `widget is ButtonStyleButton`，保持原样。

| # | 测试文件 | 行号 | 类型 | 原语义与子类必要性 |
|---|---|---:|---|---|
| 1 | `device_subflow_scope_test.dart` | 333 | FilledButton | 限于 DiagnosticPreviewView 后代，检查失权后剩余诊断按钮 onPressed 为 null。实际刷新/读取按钮是生产 `diagnostic_preview_view.dart:281–284` 的非空 icon 工厂，因此原 exact type 会漏过 `_FilledButtonWithIcon`。 |
| 2 | 同上 | 350 | OutlinedButton | 限于 DiagnosticPackagesView 后代，失权后应无任务操作按钮。实际“刷新任务列表”是 `diagnostic_packages_view.dart:337–340` 的 OutlinedButton.icon；原 exact type 会漏过该私有子类。 |
| 3 | `policy_preview_control_scope_test.dart` | 94 | FilledButton | `_noExecutionOrWriteClaim()` 的只读视图无此类按钮断言，补齐 FilledButton.icon 子类。 |
| 4 | 同上 | 95 | OutlinedButton | 同一否定断言补齐 OutlinedButton.icon 子类。 |
| 5 | 同上 | 96 | TextButton | 同一否定断言补齐 TextButton.icon 子类。 |
| 6 | `policy_preview_rule_details_test.dart` | 132 | FilledButton | `_expectPreviewBoundary()` 的只读预览边界断言，补齐 FilledButton.icon 子类。 |
| 7 | 同上 | 133 | OutlinedButton | 同一否定断言补齐 OutlinedButton.icon 子类。 |
| 8 | 同上 | 134 | TextButton | 同一否定断言补齐 TextButton.icon 子类。 |
| 9 | `policy_preview_evidence_view_test.dart` | 251 | FilledButton | unavailable guidance 测试中无核验/写操作按钮，补齐 FilledButton.icon 子类。 |
| 10 | 同上 | 252 | OutlinedButton | 同一否定断言补齐 OutlinedButton.icon 子类。 |
| 11 | 同上 | 253 | TextButton | 同一否定断言补齐 TextButton.icon 子类。 |
| 12 | 同上 | 350 | FilledButton | 50 台/5000 检查的只读展示测试中无按钮断言，补齐 FilledButton.icon 子类。 |
| 13 | 同上 | 351 | OutlinedButton | 同一否定断言补齐 OutlinedButton.icon 子类。 |
| 14 | 同上 | 352 | TextButton | 同一否定断言补齐 TextButton.icon 子类。 |

第 3–14 处不是“当前产品里已发现漏检按钮”的证据：当前 `PolicyPreviewResults` 本来是只读展示，源码 `:11–21` 无写操作回调契约；`:131`、`:169`、`:591` 的展开入口是 `ExpansionTile`。这些替换让原“无三类按钮”的断言也覆盖图标样式，防止未来样式变化掩盖断言，不声称已复现越权。

## 是否误选其他控件

- 第 1、2 处保留原 `find.descendant(of: ...)` 边界，选择器范围没有扩张至其他对话框。FilledButton 的 `tester.widgetList<FilledButton>` 对其子类也类型成立；原“视图已移除可为空，否则剩余刷新按钮必须禁用”的含义不变，没有擅自新增必须保留按钮的数量要求。
- 第 3–14 处保留原全挂载树范围；三个测试 `_mount()` 只挂 `MaterialApp → Scaffold → SingleChildScrollView → PolicyPreviewResults`，没有额外页面/关闭按钮。匹配同一三类按钮的子类符合原否定断言意图，不会把普通 `ExpansionTile`、`IconButton`、`ElevatedButton` 或文本当作这三类按钮。
- 如果将来只读预览合法增加 TextButton 导航，该全局否定断言可能需要重新按行为限定；当前不能为了预防该未知改动而忽略已有 icon 按钮。这次没有隐藏产品控件或把所有交互一律视为写操作。
- 三类按钮匹配不等于证明“没有任何种类的交互或写入口”；原权限、HTTP、不执行承诺及事实隐藏断言仍必须保留并实际执行。

## before / after 原始字节 SHA256

| 测试文件 | before 字节数 / SHA256 | after 字节数 / SHA256 |
|---|---|---|
| `device_subflow_scope_test.dart` | 19713 / `a9112faa51f845bb338f8d4ab6ec50567bc9b7af3703e543d740fb5c05960fe3` | 19723 / `c951fa672e6cf781717436782b7f15630c6b84dcacdb825fb17ce30678af0975` |
| `policy_preview_control_scope_test.dart` | 13189 / `bc787aacaa4d59da7ba3f41cfcdadc8df12ad7d5fea31976ee4a4b66143de299` | 13204 / `074dba4e9874c34107b45b0646a0bde7ab9af594d39be55bbea8f41b19606d35` |
| `policy_preview_rule_details_test.dart` | 20200 / `d50f69adc5959a84f9f2ba1086ff57df761842f068c68abea2020a64291326b9` | 20215 / `d41e109ae0f10a688d94810b4a294f5dd6b1c95cae91a6259bbb137b016b17f6` |
| `policy_preview_evidence_view_test.dart` | 17053 / `0da792104bdac1e7c464ef53f6cc11072a75b3ef4217dce98770670d14a2a814` | 17083 / `320723031be8dfcdc1675a1c6fdd464596e9c0ec8cf1dcd86d97a3bb4fd41b41` |

独立回读对每份候选只反向执行上述机械表达式替换，恢复整份规范化 before 文本完全一致，再在内存重建四文件完整 diff，与原 patch 原始字节完全一致。这比只比测试名数量更强：测试名/循环展开条件、fixture、业务断言、skip/timeout、导入与所有非 matcher 文本均保持。源码 `testWidgets(` 声明数分别为 7 / 10 / 14 / 16；这是声明位置数量，不等于循环展开后的实际测试数，不据此宣称运行 47 项。

## 交付与剩余验证

`readback.json` 记录全部来源、候选、SDK、交付 pins 与精确 14 处表达式；`readback.py` 是独立文件/文本回读器，不导入或执行原 prepare 工具。原候选保持未应用。

Root 可据固定 pins 进行单独集成与阶段提交。当前所有 Flutter analyze/编译/校准/四文件完整测试均 **UNRUN**；仍需正式窗口执行。不可把此前其他测试或源码审阅结果当成本候选已通过。
