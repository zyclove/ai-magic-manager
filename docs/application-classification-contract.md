# 应用分类（候选实现，尚未部署）

分类用于工作空间内的报表整理，复用应用目录、Spring 事务、版本校验、幂等服务、审计和 Flutter Material。数据库为 V24；部署前需一并纳入已提交的 V23 设备申请版本，当前本机运行仍为 V22。

## 身份和来源

- 分类键为精确的平台、系统资料和包名，不按包名猜测类别。平台 ANDROID／ANDROID_TV、资料 PRIMARY／WORK／SECONDARY／UNKNOWN 分开，包名大小写保留。
- 同键的不同签名目录项共享分类。SHA-256 复合键避免数据库不区分大小写的排序规则错误合并名称；读取时再次检查身份字段。
- 分类枚举为 UNCLASSIFIED、EDUCATION、PRODUCTIVITY、GAMES、SOCIAL、ENTERTAINMENT、TOOLS、OTHER。没有配置时 category=UNCLASSIFIED、source=NONE、version=0、updatedAt=null，不生成数据库行。
- 配置过的记录 source=ADMIN_DECLARED；主动清除为 UNCLASSIFIED 仍保留非零版本和更新时间。此来源表示可追溯的工作空间声明，不是安装证明、签名认证、安全评级或外部供应商验证。
- 分类独立于不可变应用身份、策略和硬额度，不修改设备执行行为。当前分类用于历史时段报告时，明确说明不是历史分类快照。

## 管理接口

`GET /api/v1/tenants/{tenantId}/applications/{applicationId}/classification`

`PUT /api/v1/tenants/{tenantId}/applications/{applicationId}/classification`

PUT 请求体为 `{ "category": "EDUCATION" }`，要求强 `If-Match: "<version>"`；可提供 `Idempotency-Key`。返回 identity、category、source、version、updatedAt，含 ETag、no-store 和 Vary: Authorization。

- OWNER、GUARDIAN、ORG_ADMIN 可修改；AUDITOR 只读。CHILD、TEACHER 和其他租户成员不能借此读取应用目录。
- 修改先锁定当前成员授权；原子建立配置头，再锁定版本。不同管理员同时从版本 0 更新只有一个成功，另一个返回 412，不静默覆盖。
- 缺少版本返回 428；弱标签或非法类别返回 400；过期版本返回 412；当前权限失败返回 403。授权在重放缓存结果前检查。
- 幂等请求指纹包括应用、版本和类别；配置、审计和响应存储处于同一事务。分类变更审计为 APPLICATION_CLASSIFICATION_CHANGED，资源为被操作的应用目录编号。

## 报表读取

报表通过 catalog 公共 `ApplicationCategories` 边界读取已授权设备实际观测到的身份，最多 2000 个不同身份，分批查询。边界要求同一事务内已持有当前报表成员、设备和使用授权，不向儿童枚举整个目录。

每个应用报告附带 classification 完整来源信息。客户端核对其平台、资料、包名与所选设备／应用一致；未知来源、非法版本或缺失字段拒绝展示。

“结果内应用类别”只筛选本次已加载结果，不产生额外查询。筛选不改变设备查询覆盖率、源批次数或保留状态。类别无匹配与未授权、无数据、未分类分别展示，不把无匹配解释为零使用。

## 管理界面

应用目录详情提供分类入口，展示来源、版本、更新时间及同键共享范围。只读角色不显示保存动作。编辑失败保留选择；网络或服务器错误造成结果未知时冻结原请求和幂等键，只允许重试相同修改。版本冲突需显式重新加载，再由用户决定是否修改，不自动覆盖。工作空间或角色变化后关闭当前分类窗口并丢弃迟到结果。

## 验收范围

接口、并发、来源一致性、类别筛选、浏览器和迁移证据随 [报表实施记录](usage-report-plan.md) 更新。当前实现不包含外部分类供应商、自动识别、历史分类重建、类别汇总唯一在线时长或设备端强制执行能力。
