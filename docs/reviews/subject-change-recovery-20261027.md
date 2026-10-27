# 档案创建编辑原结果查询

日期：2026-10-27。基础提交：`dae852814529582b6938de97dc2287a3b8a1af98`。状态：静态候选；SDK、分析、测试、构建与真实界面/API验收均 NOT_RUN，未推送或更新服务。

管理台创建/编辑原来使用不同变更接口，未知结果缺少原操作查询。本批统一使用既有 subjects/changes 与 UUID 请求键，CREATE不传编号/版本，UPDATE固定原编号/版本；通过已有表单查询钩子，以原键和完全相同正文查询 operation-results，不重放变更、不传写入幂等头。昵称必填与UTF-16长度在字段旁说明，表情长度的提示与实际限制对齐；权限和近期认证仍由服务端校验。

SubjectChangeDraft 统一创建、编辑、归档的不可变正文及快照/回执核对，SubjectArchiveOperation 仅保留原状态与异步生命周期，移除重复解析。原回执精确匹配操作、编号、状态、版本增量、昵称和年龄段；查询当前快照可显示后续编辑/归档，但版本不得倒退，同版本内容不得变更。原回执和当前事实分别保留，不能将当前值当作原提交成功证据。

创建/编辑查询成功仍返回原回执并核对列表；当前记录有后续编辑或归档时，仅在原权限/窗口仍有效且父窗口置顶时提示实际状态，不宣称刚保存后的值仍是当前值。管理详情读取同时校验原编号和完整快照。普通取消、未知关闭、ResourceActionLease、版本冲突及不可恢复结果保护继续沿用；没有新增后端、依赖、迁移或跨窗口资料副本。

## 核对事实与接续

- 静读 SubjectManagementService，确认CREATE/UPDATE/ARCHIVE正文、原版本、家庭成人日常变更及其余近期MFA要求、原结果查询与实时授权；补齐API状态表的已有管理路径。没有执行真实身份或后端请求。
- 根核对提交前准备/尝试标记、查询原正文、原快照冻结、当前事实提示与权限/顶层窗口门禁。旧归档状态机只委托公共草稿，原归档用例静读兼容。限定差异、源码空白及新文档链接已核对；不据此证明编译或运行通过。
- 新增3条核心聚合源码：三类正文/不可变性/昵称边界，原回执错配，后来编辑或归档及同版本篡改/倒退/操作不符拒绝。全部 NOT_RUN。
- 浏览器文件保留原7条并新增1条聚合，循环创建/编辑：空昵称及31个表情的长度错误零HTTP；503→查询404保持锁→匹配结果，只有一次变更、两次原正文查询、一次列表核对。分别给更高版本归档/后续编辑，检查实际提示和当前列表，不将原回执当作当前值；旧创建/编辑/归档、应用、切页租约与分页/搜索断言保留。均为合成替身，全部 NOT_RUN。

本轮未运行 SDK、格式化、分析、测试、构建、真实浏览器/API或资源采样。窗口恢复后沿既有离线准备格式化/分析本批5个Dart文件，优先运行 subject_change_test.dart、既有 subject_archive_test.dart、console_creation_review_browser_test.dart；有实际问题再扩大，不重复无关验证。稳定规则见 [SPEC](../SPEC.md)、[API状态](../backend-api-status.md)与[项目记忆](../project-memory.md)。

源码摘要（仅定位静态候选）：

- `apps/guardian/lib/core/subject_change.dart`：`db48101e2cca351606869f4db65ed4a3c98dfe9a95e668c946dc4fb7dd529570`
- `apps/guardian/lib/core/subject_archive.dart`：`854a822ad6104b47f13bc6d5137fc2977604ca2fa2e4bd2ef22f792f89aa521e`
- `apps/guardian/lib/pages/console_pages.dart`：`753982190810dbd306261c00ec7d155f08b65b6becba4872a654ae429297a6fe`
- `apps/guardian/test/subject_change_test.dart`：`32404af3290d5510992a07a3fb40d4b7aa73662c16b255589a2ab7191d661050`
- `apps/guardian/test/console_creation_review_browser_test.dart`：`71aeadd4875bfa2e0f37497515055b45cf0563807d05d8dd9e2e26119b294d01`
