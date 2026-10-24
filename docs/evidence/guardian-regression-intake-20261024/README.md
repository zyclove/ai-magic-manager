# 回归入口与首批验证准备记录（选定证据）

本目录保存本轮选定的原始记录，范围为回归入口梳理、现有13例准备与两次未启动应用测试的尝试。它不是完整阶段验收，后续新增测试数由阶段负责人补充。全部副本逐字节保存；`manifest.json` 列出原件和副本的大小、SHA256。原始文件中的历史状态不回写。

## 范围与源码边界

- 完整范围181个文件入口：140 VM、39浏览器、2个需要独立夹具的live HTTP工具。181不是用例总数；28个package测试位于七根冻结源码之外，不能把Guardian冻结当作181的完整可执行包。
- 本轮R1/R2准备和实际R1宿主尝试均绑定 `35a4119b3d4558cf8c17c5bec3356e73243f0096`。原 `scope.json` 的 `sourceCommit`、13合同的 `sourceAnalysisBasisCommit` 是更早的 `c90b1465...`，保留原字节；35a冻结独立确认181路径/平台语义与所选测试字节保持。旧scope中的具体SHA、路径和argv仅是历史候选，不是今后新HEAD的运行清单。
- 现有13合同仅包含 `workbench_view_test.dart` 12例和 `dialog_submit_guard_test.dart` 1例，默认Flutter VM tester。13例均 **UNRUN**；其余179入口也未因本批准备而运行。80例/7selector只是浏览器范围的独立子集。
- 本轮后续修改现有测试后，181入口数可以不变，但case合同、源码与执行输入必须重新绑定。旧R2计划已经退休，不能启动旧grant。

## 实际发生的记录

| 记录 | 实际结果 | 应用测试 |
|---|---|---|
| R1 Root `a2baab` | 自然退出1，2.8078977秒，无Root强停 | SDK调用0，testsRun=false |
| R1 post `7bf221` | 退出1，`NOT_ACCEPTED_FILE_READBACK` | 因Root非自然0拒绝 |
| R1 release `cf6e2a` | 退出1，但windowReleased=true、SDK0、unknown0 | testAccepted=false，不是通过 |
| R2 Root `378540` | fresh资源门槛在启动前拒绝，root/worker attempt目录均不存在 | SDK调用0，未测试 |

R1初始门槛发现foreign `go`、`vet`；后置门槛发现foreign `go`、`platform.test`、`releasecontract.test`。未启动Flutter应用命令；`postflight-skipped.json` 明确SDK_NOT_STARTED。门槛准确拒绝共享窗口冲突，不等于13个测试失败。未控制这些外部进程。

R2较早的 `0661fa` 约2.79GiB内存观测只是资源观测；随后内存降至1,412,272,128字节（约1.3GiB）。没有成功启动或测试结果。原 `root-plan-retired.json` 明确旧计划不能复用。

## 选定内容与限制

- 保存原scope/README、13合同、Workbench/表单覆盖缺口、R1固定实际记录、三份紧凑独审原文、R2退休原文及绑定摘要、152项新增默认测试asset的来源pins。
- `assets/asset-inputs.json` 是原始152项来源记录：原70trees/32fixed基底未在准备时重新全量读回，新增152项7,997,977字节，closureComplete=false。没有复制约774KB cache投影、641MB payload、控制代码或35个runtime文件。
- R1没有command launch、测试JSONL或reporter-validation；R2没有root/worker attempt或post结果。不存在的记录没有补造。完整进程单独清单未复制，其已有引用保留在原release中。
- 独审中的“无静态阻断”仅指准备文本/字节合同，不是运行结果。未运行SDK、测试、AST、candidate/helper或网络；本次归档只作普通文件/JSON/哈希读写，未操作Git、Main源码、共享缓存或部署/推送。
- 历史3143/605等回归计数不作为本轮通过依据。已有Guardian静态分析成功不代表181测试、80浏览器、UI、后端或设备实测成功。本轮后续新源码也不得冒用旧分析结果。
