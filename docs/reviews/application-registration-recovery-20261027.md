# 应用登记输入与原结果查询

日期：2026-10-27。基础提交：`a2260c4d22f68d2314b5203b13c15212dc245e60`。状态：静态候选；SDK、分析、测试、构建及真实界面/API验收均 NOT_RUN，未推送或更新服务。

## 实现

管理台原登记表单只解释格式，非法包名和摘要要提交后才报错；未知结果只能重试写入。本批复用既有应用身份契约和 Material 表单，在字段旁校验包名与签名。包名保留大小写；摘要接受64位十六进制或标准32字节冒号指纹，支持逗号、中文逗号、CRLF/LF，提交前转小写并排序。整体空白表示无摘要，内部空项、非法、超过8份及规范化后重复都拒绝，不静默去重。原默认平台/资料保持，输入长度提高以容纳8份冒号指纹。

application_registration.dart 只处理本地规范化、冻结正文与完整回执核对，复用 ApplicationClassificationIdentity。应用使用 UUID 请求键与既有 creation-results 查询，原结果未知后只读查询，不再次创建；请求正文由不可变原表单确定性生成，查询不传写入幂等头。结果须匹配完整原声明、合法编号及 ADMIN_DECLARED，仍不表示设备已安装或签名已核验。未改后端、依赖或数据库。

共享 FieldSpec 增加可选纯 validator，保留必填/数值规则，文本、选项、时区均可就近解释领域错误。EditDialog/formDialog 及租户表单增加显式只读恢复钩子，查询模式成对捕获首次提交与恢复回调、标签及不可变原值；模式切换退役。未知恢复跳过当前控件校验和数字解析，不因查询404/401解除锁定；HTTP408亦视为未知。版本冲突、结果不可恢复、失权与关闭确认沿现有保护。不提供钩子的表单保留原重试入口，本地 canCommit=false 准备仍验证新输入并可修改。

## 核对事实与接续

- 静读 CatalogController/Service 与 Parent 已有恢复逻辑，确认规范UUID查询路径、原登记正文及不可变应用回执语义；复用规则，没有复制 Parent 的持久化日志或另建创建控制器。
- 根核对规范化与实际POST/查询接线、首次UUID、无查询幂等头、结果匹配和列表核对信号。独立静读共享表单的成对捕获、模式退役、冻结值、默认/本地准备语义及停止/失权路径，未见可证的合同问题。限定差异、空白与新增本地文档链接已静态核对；这不证明编译或运行通过。
- 新增3条核心聚合用例：枚举/包名边界与大小写、指纹格式/空项/重复/数量与不可变性、完整结果错配。新增2条共享表单聚合用例：三种字段校验；408后查询404/401至成功、原值只读、一次写入和旧事件门禁。
- 浏览器文件保留原5条并新增1条登记旅程：两类非法输入均零HTTP；修正后冒号大写指纹转标准、包名保留大小写；503→查询404保持锁→匹配查询成功，仅一次创建、两次原正文查询和一次列表核对。既有普通取消/成功/未知明确关闭继续覆盖。全部为源码和合成替身，均 NOT_RUN。

本轮没有运行 SDK、格式化、分析、测试、构建、真实浏览器/API或资源采样。窗口恢复后沿既有离线准备格式化/分析本批7个Dart文件，优先运行 application_registration_test.dart、dialog_submit_guard_test.dart、console_creation_review_browser_test.dart；共享表单出现实际问题再扩大，不重复无关全量测试。稳定规则见[应用契约](../policy-application-schedule-contract.md)、[SPEC](../SPEC.md)与[项目记忆](../project-memory.md)。

源码摘要（仅定位静态候选）：

- `apps/guardian/lib/core/api.dart`：`0185f7bfff3ff6c4d5b77f9c35327aff80edaed74673290b7e38c96d0d325d53`
- `apps/guardian/lib/core/application_registration.dart`：`f84e4de1d63093de5f71cb3cafe74771fbad74c9d8f64f64c1534e3e3b965fd6`
- `apps/guardian/lib/ui/design.dart`：`c6d9d5d09a7172d188c136e15de5a107f6eb9ef88f07c7ff9acb34633083e6cf`
- `apps/guardian/lib/pages/console_pages.dart`：`99c39a0bb446edd16eba6ebe441d288b099e995226910840872c34686892d9eb`
- `apps/guardian/test/application_registration_test.dart`：`3b84b2d1415dc0a84fdfb719f22eab0ec17115b0790c4fbdae86a9158ded8f5f`
- `apps/guardian/test/dialog_submit_guard_test.dart`：`8d354415bf084569f5e3b1860e6f06669cda1588fd561b00ab30bf7a05742b19`
- `apps/guardian/test/console_creation_review_browser_test.dart`：`c1c7cc24ee538bcb53cc43f5c6de47fd41b908d8aebd56d2f9da3895c25f9cd9`
