# 回归入口与验证准备阶段记录（2026-10-24）

这是选定证据的阶段记录，完整交付位于 [证据目录](../evidence/guardian-regression-intake-20261024/README.md)。后续新增测试数及最终源码提交由阶段负责人补充；此文不宣称本阶段已验收。

## 范围

181个文件入口保留：140 VM、39浏览器、2个独立live HTTP工具；28个package测试在七根冻结外。当前13例只选择其中2个VM入口，全部UNRUN。原分类sourceCommit与13合同analysis-basis为c90，R1/R2执行准备实际绑定35a；原件不改写，旧scope具体SHA/argv不能当后续新HEAD执行清单。

## 实际验证边界

- R1 Root a2baab自然退出1；SDK0、testsRun=false。foreign go/vet及后置go/*.test触发资源门槛，应用测试命令未启动。post 7bf221退出1；release cf6e2a退出1但windowReleased=true/SDK0/unknown0，testAccepted=false。
- R2 Root 378540启动前拒绝，root/worker attempt均不存在。0661fa约2.79GiB只是一条资源观测；随后约1.3GiB内存不足，没有SDK或测试执行。R2计划现已退休，后续源码/测试新提交必须重新绑定并取得新的Root窗口，不能执行旧grant。
- 三份独审仅为静态准备/实际文件读回，不等于运行通过；13例、完整181、浏览器子集、UI/后端/设备验证仍未获本轮通过。历史3143/605不能作为本轮结果。

## 已识别的后续验证需求

原Workbench/表单缺口报告逐字归档：旧统计仍存在时的读取错误/刷新状态、共享编辑器HTTP412草稿与旧版本锁、真实常用入口到表单及取消返回等，不由当前回调计数或通用route用例自动覆盖。本记录不编造新增用例数，不把prepared-only静态代码描述为已验证。

原件副本和manifest记录精确bytes/SHA；未复制大型cache、runtime二进制或控制代码。本次仅创建本证据和自有归档回执，无SDK/测试/AST/candidate/进程/网络/Git动作，无生产或测试源码更改。
