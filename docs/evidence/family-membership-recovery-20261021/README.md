# 家庭会员订单恢复验证记录

本记录保存本阶段已结束的原始证据。当前状态为 **TARGETED_8_PASSED / FULL_PARENT_INCOMPLETE_TIMEOUT / ANALYSIS_NOT_RUN / NOT_DEPLOYED**。本次仅确认 8 项定向测试通过，不作为 Parent 全量或产品全功能验收。

## 产品修复范围

1. 闭售后仍可核对原下单请求，继续使用原幂等键、方案和报价版本；不会因恢复操作改用新报价或创建另一笔请求。
2. 从会员订单列表打开详情时共享付款协调器。已确认终态订单完成恢复清理后，返回会员页不再保留过时提示或阻止新的购买。
3. 原创建请求尚未取得订单号时，阻止支付其他订单，显示“请先返回会员页核对原订单请求，确认结果后再支付其他订单。”，保留原请求和返回后的恢复入口。
4. 已合法读取并核对终态订单后，付款恢复清理先于退款进度读取；退款接口失败仍显示售后错误并禁用退款动作，不阻断已确认付款的本地恢复清理。

## 已结束阶段

| 阶段 | 实际结果 | 分类与限制 | 原始证据 |
| --- | --- | --- | --- |
| old-ui 初始尝试 | 2 通过、2 失败 | 2 个产品失败；未排除随后显现的成功路径平台夹具隐患，不能签绿 | [清单](historical-inventory.json)、[原始目录](raw/old-ui/out/) |
| pre-fix 初始尝试 | 3 通过、5 失败 | 3 个产品失败、2 个平台夹具不变量失败，不能签绿 | [清单](historical-inventory.json)、[原始目录](raw/pre-fix/out/) |
| old-ui-v2 反证 | 3 通过、5 失败 | 5 个均为预期产品失败；采用官方平台 variant 后，不再混入前述平台夹具不变量错误 | [完整日志](v2-initial/old-ui-v2/out/01-old-ui-v2.log) |
| pre-fix-v2 反证 | 5 通过、3 失败 | 3 个均为预期产品失败：退款读取失败阻断付款恢复、未知结果原请求的支付拦截及对应协调器保护 | [完整日志](v2-initial/pre-fix-v2/out/02-pre-fix-v2.log) |
| 官方五文件格式化 | 退出码 0；5 文件中 3 文件改变 | 仅格式化结果，不代表测试通过 | [完整日志](v2-initial/pre-fix-v2/out/03-format-main-five.log) |
| 首轮 post-fix 定向 | 7 通过、1 失败 | 剩余失败是支付按钮 Finder 精确运行时类型匹配问题，未匹配 `_FilledButtonWithIcon`；不能将该轮记为通过 | [完整日志](v2-initial/post-fix/out/05-post-fix-targeted.log) |
| 最新单会员测试文件格式化 | 退出码 0；1 文件、0 改变 | 测试文件 SHA256 为 `56fdc89bcfdafb31ad144196a862e2e00b2c9c97c412548d88fc22c73e33465d` | [完整日志](green-tail/post-fix/out/01-green-tail-format-member.log) |
| post-fix-v2 冻结 | 400 个源码文件 | manifest、源码树、包配置及覆盖文件摘要均登记；未修改旧冻结输入 | [完整 manifest](green-tail/post-fix-v2/input-manifest.json) |
| post-fix-v2 定向 | 8 通过、0 失败；自然退出码 0 | **TARGETED_8_PASSED** | [完整日志](green-tail/post-fix-v2/out/03-targeted-eight.log) |
| Parent 全量 | 120 秒命令上限后受控取消；退出码 124，`naturalExit=false` | **FULL_PARENT_INCOMPLETE_TIMEOUT**。日志末条进度为 `+501`，未观察到失败标记，但未完成且不是全量通过 | [完整日志](green-tail/post-fix-v2/out/04-full-parent.log) |
| 五文件静态分析 | 未运行 | **ANALYSIS_NOT_RUN**，没有分析通过结论 | [终态执行收据](green-tail/green-tail-receipt.json) |
| 新服务部署 | 未执行 | **NOT_DEPLOYED** | 本阶段范围不含部署 |

首轮 post-fix 的剩余失败通过修正第六个 widget case 的 Finder 解决：在原有业务断言之后，按标签查找祖先并使用 `is FilledButton` 判断。提示、禁用状态、原 JSON、返回恢复入口及零写操作等业务断言均保留；生产按钮没有为夹具改成另一种按钮。最新定向日志确认全部 8 项通过。

## 执行收据与证据完整性

- [初始 runner 失败收据](v2-initial/final-batch-receipt.json) 保持原样。首 runner 的展开日志解析器在 `[E]` 处提前结束异步错误块，误将产品失败分类为夹具问题并停止后续执行；这是验证脚本问题。
- [续段收据](v2-initial/continuation-receipt.json) 绑定上述失败收据的 SHA256，读取已有阶段①完整日志修正分类，沿用原 300 秒 deadline；阶段①没有重跑。
- 原始释放采样保留为 [batch-stopped-release.json](v2-initial/old-ui-v2/out/batch-stopped-release.json) 和 [stopped-release.json](v2-initial/post-fix/out/stopped-release.json)。它们分别记录对应冻结源码匹配、包配置摘要及采样时 SDK 进程为空，不代表后续批次已完成。
- [第二批清单](v2-initial/inventory.json) 记录 8 个完整原始文件的路径、字节数、SHA256，并摘录首轮 post-fix 冻结 manifest、源码树、包配置及 Main 覆盖文件摘要。每个副本均与复制前后的源文件哈希一致；未复制整份源码或临时大文件。
- [最新终态执行收据](green-tail/green-tail-receipt.json) 的 SHA256 为 `0423014f6cde036fb9ae234191576149afe0f8c1ddec2dd74c10458a82579d82`。该批次在全量命令 120 秒上限后停止，Root 交回的执行会话 92869 最终退出码为 1；仅取消该命令的自有进程子树，没有将全量超时改写为通过。
- [最新释放采样](green-tail/post-fix-v2/out/timeout-release.json) 于 `2026-10-21T03:56:46Z` 记录 SDK 进程为 0、可用物理内存 `2603511808` 字节，冻结源码匹配且六个覆盖文件与 Main 字节一致。
- [最新清单](green-tail/inventory.json) 保存 6 个完整 raw 文件（包括输入 manifest）的 SHA256、真实阶段结果及冻结摘要。前段历史清单中的 PENDING 是其归档时状态；当前终态以本节和 green-tail 收据为准，历史 raw 与清单均未覆盖。

## 冻结输入与作者范围

最新冻结基于 `3b9117b000a10d082a8f7849c41de5f69c0baa62` 加明确覆盖文件；[manifest](green-tail/post-fix-v2/input-manifest.json) 的 SHA256 为 `285b46962dc0ffdd7892148f761e44c08021faf7c0026b7987cfe93c03853e06`，登记 400 文件源码树。与首轮 post-fix 相比，仅会员测试文件改变，生产保持该轮字节不变；旧冻结树未被修改。

Root 的五个覆盖文件为三个会员/订单生产文件和两个本阶段测试文件。另有 `apps/parent/test/family_payment_test.dart`，SHA256 为 `ff226c039efdf7d5d65edd9ad17fea922e1923df018822248563115a1c0f96cd`，在冻结时属于 Family 所有、尚未提交的测试 overlay，已纳入本次测试输入。Family 随后将该文件单独提交为 `665befb1f0d68690a094b2c44f5d893594e139c3`，工作文件字节保持上述哈希；它不重复纳入 Root 本阶段提交。原始 manifest 保留冻结时的来源状态。

## 验证边界

这些证据针对 Parent 本地自动化与静态分析流程。尚未覆盖实体 Android、真实微信供应商或新的服务部署；后端及 identity 的独立验证结论不计入 Parent 通过结果。

**本阶段终态：TARGETED_8_PASSED；FULL_PARENT_INCOMPLETE_TIMEOUT；ANALYSIS_NOT_RUN；NOT_DEPLOYED。Parent 全量与静态分析仍需另行验收。本记录不预测总通过数量，不将超时前无失败的进度或后端/identity 的独立结论替代 Parent 全量通过。**
