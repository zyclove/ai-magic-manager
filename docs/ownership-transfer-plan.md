# 所有者交接实施记录

依据：`parental-control-product-delivery-spec.md` 的双方确认所有者交接；现有 Spring Boot/JDBC/Flyway 与 Flutter Material 组件。

## 合同

- 每个租户只有一个生效中的交接申请，有效期 24 小时。只有现任 OWNER 可以发起，目标必须是已加入、无儿童范围限制的成人角色：家庭 GUARDIAN/AUDITOR，机构 ORG_ADMIN/AUDITOR。
- 发起、接受、拒绝、撤销均要求真实近期 MFA；接受还要求身份服务签发的成人资格 `tenant:create`。目标本人确认后，原所有者变成家庭 GUARDIAN 或机构 ORG_ADMIN；支付、账单责任不自动转移。
- `POST /tenants/{id}/ownership-transfers` 使用租户 If-Match，正文 `targetActorId`。列表及单项 GET 返回版本；`/{transferId}/accept|decline|cancel` 使用交接 If-Match。写操作支持 Idempotency-Key；权限先于幂等缓存检查。
- 快照包含双方成员版本和租户版本；撤销后重新加入、权限/租户版本变化均使旧申请失效。状态 PENDING/ACCEPTED/DECLINED/CANCELLED/EXPIRED/INVALIDATED。读取时持久化过期/失效及版本变化。
- 裁定：接受时发现申请刚过期或失效，返回 200 和其终态，不执行权限转移；前端必须按返回状态显示结果。这样失效状态和审计能在同一事务提交，不能把 200 等同接受成功。
- 当前所有者可以查看全部历史；其他符合角色的成人仅能查看自己参与的申请；儿童、范围受限教师、租户外人员无权限。
- 成员控制行先串行化成员、租户资料更新和交接操作，再按 actor_key 顺序锁定涉及成员。交接、唯一所有者替换、审计及敏感待办失效同事务，监听器异常整体回滚。
- 裁定：Tenant.version 仅跟踪名称/时区等租户资料；交接修改成员和交接版本，不递增租户资料版本。所有资料更新先取得同一控制行，交接读取快照期间资料不能变化。这样无需在清理策略/设备待办时独占其外键父表 tenants。真实 MySQL 并发用例已复现旧顺序下审计 INSERT 与清理预览之间的死锁；成本是使用方须重新查询 membership 获取最新权限，而不能依赖 Tenant.version 感知身份变化。管理端已经重新加载 membership。
- 原所有者未接受邀请、待确认配对、未确认退出预览和待处理临时授权失效；已发布策略和已确认退出保持已提交事实。策略预览没有发起人字段，故所有租户策略预览要求重新预览。

## 实施与证据

1. HTTP 旅程测试先证明缺少交接端点；V17、成员互斥/版本、交接服务与领域事件。
2. 并发接受/撤销、旧 JWT、移除再加入、过期、幂等、租户隔离和跨模块失效回归。
3. 管理端独立交接入口、角色差异、确认、结果/错误反馈、完成后刷新当前身份。
4. 仅在完成实际执行后填写验证记录；不得把界面或测试夹具当作真实用户 MFA。

12ui 托管设计此前因供应商地区限制返回 403；本阶段复用已实现的管理端 Material 布局，不重新请求付费生成。

## 已执行的验证

- 最终整体后端 `mvn verify` 显式启用三个设备客户端联调：212 项通过、0 失败/错误/跳过；证据 `.local/ownership-final-verify.log`。最终 Flutter analyze 无问题、21 项通过，HTML release 构建通过，分别见 `.local/ownership-ui-analyze.log`、`.local/ownership-ui-test.log`、`.local/ownership-ui-build.log`。

- 初始 8 项 HTTP 测试均在缺少接口处返回 404；实现后连同既有成员旅程共 39 项通过。
- 待确认配对清理用例先观察到 AWAITING_CONFIRMATION，补齐同步领域监听器后通过；最终交接集涵盖接受/拒绝/撤销、过期、移除再加入、租户版本变化、并发、跨域清理、监听器失败回滚、权限与幂等。
- MySQL 外键并发回归先复现 `Deadlock found when trying to get lock`；改为同一控制行协调租户资料写入、避免独占 tenants 父表后，14 项在独立 MySQL 8.4 库全部通过。临时数据库/用户已移除。证据 `.local/ownership-lock-red.log`、`.local/ownership-lock-green.log`、`.local/ownership-mysql.log`。
- 桌面 1440×1000、手机 390×844 真实 Chrome：真实管理员 GET 200；仅密码认证的交接写入返回 401 REAUTH_REQUIRED。后续明确浏览器夹具覆盖发起、503 原提交重试、取消确认返回、撤销、审计员接收、200 过期终态、接受后刷新角色。未修改真实所有权，也未伪造用户 OTP。
- 浏览器先发现“发起后立即撤销”列表仍显示待确认，修复串联弹窗的等待顺序后全流程通过。截图保存在本会话 visualizations 目录；`.local/ownership-browser.log` 区分真实 API 与浏览器夹具。
- 设备注册凭据复制使用标准 JSON 编码与字段白名单；审批 SDK 的 http_parser 范围放宽至 ^4.0.2，独立 Flutter 3.22.2 + flutter_localizations + device_access 的离线依赖解析通过，无 dependency_overrides。

## 仍待整体产品阶段完成

机构细分范围、成员角色编辑及可识别资料、通知发送、账号恢复、真正设备系统执行、正式环境 MFA/公钥轮换、容量及可用性验收不属于本交接阶段的完成证据。成员列表目前提供身份服务 subject 标识；页面展示完整标识供核对，不推断姓名或邮箱。
