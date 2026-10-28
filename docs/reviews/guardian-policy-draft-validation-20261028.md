# Guardian 策略草稿与分支阶段验证

基线：`942fd379d435e3b02cd85dfbf93ee820a35012c6`。本阶段限定草稿保存、模板复制及回滚的原结果核对；后续按静态优先要求停止 SDK 执行，没有构建、推送或更新服务。

## 实际结果与边界

| 范围 | 结果 |
| --- | --- |
| 初次 6 文件格式化 | PASSED；实际输出 `Formatted 6 files (6 changed) in 0.48 seconds.`，自然 exit0、成员归零、未请求强制终止，后置 SDK 空闲 |
| 初次 6 文件严格分析 | NOT_ACCEPTED；自然 exit1、成员归零、未请求强制终止，源码无漂移；原输出仅 3 条 info，没有编译 error/warning |
| 源码静态修订 | 两处条件分支补花括号、异步提示增加 `dialog.mounted` 检查；3 处现有测试声明增加 `policy-draft-results` 标签，不改变测试名称或断言 |
| 修订后格式化／严格分析 | NOT_RUN；初次格式化通过只覆盖其当时输入，不外推到后续手动修订 |
| VM 模型回归 | NOT_RUN；计划为 `policy_draft_change_test.dart` 与 `policy_draft_branch_test.dart` 各 3 个聚合 |
| 浏览器原结果旅程 | NOT_RUN；3 处标签声明计划产生 4 条测试：复制与回滚查询聚合、未知复制经 MFA 关闭、201 空对象与 null 回执各 1 条；标签未运行验证 |

原始严格分析的 3 条提示保留如下，行号对应当时输入：

| 文件位置 | 提示 |
| --- | --- |
| `lib/core/policy_draft_change.dart:159:5` | `curly_braces_in_flow_control_structures` |
| `lib/pages/policy_details_entry.dart:395:19` | `use_build_context_synchronously` |
| `test/policy_draft_branch_test.dart:105:5` | `curly_braces_in_flow_control_structures` |

上述提示已作源码修订，但修复后的严格分析未重跑。静态核对不代表测试、浏览器、真实接口或全产品验收通过；其他阶段的通过结果不作为本轮证据。

## 原始证据

本轮仅收存[格式化回执](../evidence/guardian-policy-draft-validation-20261028/format-result.json)、[格式化原输出](../evidence/guardian-policy-draft-validation-20261028/format-output.txt)、[严格分析原回执](../evidence/guardian-policy-draft-validation-20261028/analysis-initial-result.json)、[严格分析原输出](../evidence/guardian-policy-draft-validation-20261028/analysis-initial-output.txt)及[实际执行驱动](../evidence/guardian-policy-draft-validation-20261028/validation-driver.py)，共 5 份文件，均与原 `.cache` 文件逐字节一致。未复制产品源码或另建重复 manifest，原始 `NOT_ACCEPTED` 回执未改动。

驱动 SHA256 为 `16ce087d952754bc86da3f5aeb7c91b7552b5743a942f814f5cc97c0bd6832b4`，与两份原回执的 `driverSha256` 完全一致。驱动是原执行位置的字节归档，不从证据目录直接执行；回执内 `sourcePins` 继续绑定各次实际输入。

## 当前静态修订 SHA256

以下为修订后的 6 文件绑定，已与实际文件核对；不是修订后运行通过的证明。

| 文件 | SHA256 |
| --- | --- |
| apps/guardian/lib/core/policy_draft_change.dart | 3914665FC81D48B1820BDFA6E89E0FCA81807F2838423402E7E06CD736875960 |
| apps/guardian/lib/core/policy_draft_branch.dart | 200758B37225C4EC99F90B4A01526E522FA677F9F6F1F34E63985C09961AAEE0 |
| apps/guardian/lib/pages/policy_details_entry.dart | 8CC4D345A141A304431EE7E0F0BD05BC5C8712C64A2DEC7DF05AE5C5E0C4B6AE |
| apps/guardian/test/policy_draft_change_test.dart | 33E9A21C9669918671D8B793235E59B6ABB35B1CFFEDD2121E7331EC6F8616A2 |
| apps/guardian/test/policy_draft_branch_test.dart | 8281F3F3DCC4F66FC8F1B04EBF8D31C57F1FACB13F6B4209CAB67B865E5A55D6 |
| apps/guardian/test/policy_details_scope_test.dart | 67FD065D22168AD3D3BB5F8D117A2F6AE666D71AD73B9E5A87A716EAD418634E |
