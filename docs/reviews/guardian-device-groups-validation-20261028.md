# Guardian 设备组定点验证

基线：`99ffbb85392a27ae286ee2a94f7678538823a613`。只规范化6个相关文件、补11处条件分支花括号，并修复一个测试的主按钮定位；没有改动业务协议、删除空态入口或降低验收要求。未构建、推送或更新服务。

## 实际结果

| 范围 | 结果与边界 |
| --- | --- |
| 首次6文件格式化 | PASSED，1.6秒自然exit0；之后3文件另补11处花括号 |
| 初次6文件严格分析 | NOT_ACCEPTED，11项curly_braces信息，无编译error/warning；原报告保留 |
| 修后3文件格式化＋6文件严格复查 | PASSED，自然exit0、成员0、源码无漂移、后置SDK空闲 |
| 原两文件VM计划 | NOT_ACCEPTED；自然exit0，但选择器声明@TestOn(browser)，实际只加载模型文件。未将原5项计划追认为通过 |
| 实际模型测试 | device_group_change_test的3个聚合通过、0失败／跳过、reporterDone=true、源码无漂移；没有重复运行未改变的模型 |
| 浏览器首次准入 | NO_START、SDK0；当前Chrome与旧指纹不同。只读核对156.0.8078.48有效Google签名后固定当前SHA，未安装或升级软件 |
| 首轮两个浏览器文件／7聚合 | NOT_ACCEPTED，实际6通过／1失败；源码无漂移、成员0、后置SDK空闲。CREATE测试误同时定位主Filled按钮与合法空态Outlined按钮；原原生审计随exit1保持未通过 |
| 测试定位修正 | 使用is FilledButton谓词（含图标子类）限定主动作，首开、重开及取消后的就绪判断一致；产品及业务断言保留 |
| 修后单文件格式化 | 工具实际自然exit0并输出Formatted 1 file；原入口因单复数文本识别错误记NOT_ACCEPTED，原结果保留，修正识别后没有重复格式化 |
| 修后单文件严格分析 | PASSED；只复查唯一改变的测试文件，其余5个文件不变 |
| 唯一失败聚合浏览器复验 | PASSED，24.4秒自然exit0、1通过／0失败／跳过、源码无漂移；完整原生浏览器边界、成员身份、半秒终态与关闭审计通过，retained=0、closeErrors=0、SDK已释放 |
| 构建／部署／真实接口／全产品验收 | NOT_RUN；本阶段不作这些结论 |

首轮6通过与修后1通过分别保留，不叠加复跑数量，不追认原失败或范围不匹配记录。唯一失败聚合内部覆盖五类原操作恢复；未重复已通过的选择器、其他流程、模型、依赖解析或SDK资格。

保持RAM／C／D各2GiB、SDK空闲与串行窗口；低内存或其他工具占用时未启动SDK。保留原135／140秒及全部原生/classifier/JSONguard/终态/关闭审计条件，没有停止共享进程或降低门槛。其他项目的结果只用于排期，不作为本库通过证据。

## 原始证据

[首次格式化](../evidence/guardian-device-groups-validation-20261028/format-result.json)、[初次严格分析](../evidence/guardian-device-groups-validation-20261028/analysis-initial-result.json)绑定已有[原驱动](../evidence/guardian-offline-dependencies-20261028/offline-driver.py)；[修后格式化](../evidence/guardian-device-groups-validation-20261028/format-repair-result.json)、[严格复查](../evidence/guardian-device-groups-validation-20261028/analysis-after-braces-result.json)及[原VM计划](../evidence/guardian-device-groups-validation-20261028/vm-initial-result.json)绑定[修后驱动](../evidence/guardian-device-groups-validation-20261028/repair-driver.py)。对应原输出保留为同前缀output.txt。

浏览器的[原指纹拦截](../evidence/guardian-device-groups-validation-20261028/browser-fingerprint-result.json)、[当前安装核对](../evidence/guardian-device-groups-validation-20261028/browser-current-binding.json)、[首轮失败](../evidence/guardian-device-groups-validation-20261028/browser-initial-result.json)与其完整成员账本、终态及原生审计保持原样。首轮问题COMMAND_JOB_FINALITY_UNPROVED／OWN_JOB_MEMBER_IDENTITY_UNPROVED没有追认为通过。

定位修正后的[格式化原结果](../evidence/guardian-device-groups-validation-20261028/format-fixture-result.json)、[严格分析](../evidence/guardian-device-groups-validation-20261028/analysis-fixture-result.json)和[唯一失败聚合复验](../evidence/guardian-device-groups-validation-20261028/browser-recovery-result.json)分别绑定其driver.py。最终[原生审计](../evidence/guardian-device-groups-validation-20261028/browser-recovery-evidence.json)、[成员账本](../evidence/guardian-device-groups-validation-20261028/browser-recovery-member-ledger.json)与[终态](../evidence/guardian-device-groups-validation-20261028/browser-recovery-finality.json)齐全。驱动为原.cache执行位置的字节归档，不从交付目录直接执行。

以下为最终6文件绑定。前次6文件严格通过与后续单文件严格通过分别覆盖未变部分及测试定位修正，源码已复核无漂移；历史结果不证明全平台验收。

## 当前源码SHA256

| 文件 | SHA256 |
| --- | --- |
| apps/guardian/lib/core/device_group_change.dart | A832D10B34FFE458BBA6043BD24EC29D4B2DFFDED8732296BDD691F36AE5D7D6 |
| apps/guardian/lib/pages/device_groups_page.dart | 4791B4C6645A1D2721A43297A838FD73C7083550770A478A0EDD3B98CC0C79A7 |
| apps/guardian/lib/ui/device_group_batch_picker.dart | B9726B677606AFBD9A67AE86CFF557B7627BAAA82162FD1794347E3D34101280 |
| apps/guardian/test/device_group_change_test.dart | 8210F07263029A0AFE999389EF50C962FF50C9DBF9E3D73DC848C269410D0C79 |
| apps/guardian/test/device_group_batch_picker_test.dart | E9035E52B30D03AF35CC0E0F2C07A2AD5A4EAE518373EBBF21E8555886764687 |
| apps/guardian/test/device_group_flow_test.dart | 920890F3D06766A7B082A168FF382D4E3971EC3C4A085F75DC4599649A411249 |
