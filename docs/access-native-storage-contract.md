# Android 临时访问原生存储验收契约

## 本阶段交付

基于 `2ed6a73` 的儿童端临时访问宿主，增加真实 Android 存储、不同进程和系统重启后的恢复验收。生产接收器、密码算法、存储 SDK 和业务接口不变。新增八阶段集成夹具、专用驱动、串行构建和运行脚本；结果见 [阶段证据](releases/stage-access-native-verification.json)。本阶段不是全产品完成声明。

## 真实执行和替代物

| 范围 | 实际使用 | 证据边界 |
|---|---|---|
| 安全记录 | Android 插件、Keystore 支持的偏好加密、原生持久屏障 | API 34 专用模拟器；不等于硬件不可导出身份密钥 |
| 访问日志 | path_provider、Sembast、本项目既有 SDK 加密 codec | 一个独立合成发行方/设备范围；不覆盖所有机型 |
| 生命周期 | 不同 Android PID，逐阶段强制停止后确认进程消失 | 有序进程结束；不是物理断电耐久性证明 |
| 系统重启 | 回执确认后重启 Android，核对启动标识变化，再启动下一夹具 | 证明重启后可恢复；没有证明开机自启或后台调度 |
| 云端 | MockClient、运行时签名、公钥验证、受控设备视图 | 不访问真实服务器，不构成成人批准或设备真实注册 |
| 时间 | 可控本地时钟在原截止时间边界检查 | 不证明系统时间防篡改、硬件防回滚 |
| 中断 | 调用接收器 pause 后制造受控传输失败 | 不替代真实系统生命周期回调验收 |
| 应用管控 | `systemEnforced == false` | 不宣称已拦截跨应用启动、网络或系统权限 |

既有真实 Spring HTTP 验收见 [上一阶段证据](releases/stage-access-host-verification.json)。两类证据分别记录，不将本轮模拟云响应算作真实前后端联通。

## 验收流程与判定

| 顺序 | 阶段 | 必须满足 |
|---|---|---|
| 0 | negative | 使用重放 APK；因缺少前一进程 oracle 明确失败，驱动非零退出；安装/引擎失败不算通过 |
| 1 | write_pending | 拒绝覆盖已有夹具；持久记录原回执，模拟确认丢失；保留 1 条待确认和待核对状态 |
| 2 | replay_pending | 新进程读取原记录，按字节比较原回执后重发；确认后待确认归零 |
| 2a | Android reboot | 记录重启前后 boot_id 不同及启动完成；不清空数据、不卸载 |
| 3 | offline_expire_pause | 离线读取不发 HTTP；原截止时间到期；随后一次明确中断留下 CHECKING |
| 4 | verify_checking_reject | 新进程 CHECKING 不呈现有效授权；401 后持久保存 BLOCKED |
| 5 | verify_blocked | 再次离线启动仍 BLOCKED，HTTP 计数为零 |
| 6 | apply_removal | 恢复上下文并验签接收 v2 撤回文档；撤回回执确认后无待确认 |
| 7 | verify_removed | 新进程离线读取仍为 removed/v2；原截止时间不延长 |
| 8 | cleanup | 校验已撤回且无待确认后，仅删夹具文件和三个精确 SDK 键；原身份/观察/配置保持不变 |

每次 HTTP 调用前读取真实安全存储，断言已经持久写入 CHECKING。逐请求确认丢失可保留 VALID 上下文，但该请求始终显示待核对，直到原回执成功确认；不能把传输不确定当作有效系统执行。

每个阶段均比较已有身份记录、使用记录和基础配置文件摘要。此次先使用已提交身份与观察夹具建立**非空**记录：身份激活、配置标记文件、已完成的应用目录和用量记录；保护判断不是空值对空值。清理后另行移除已经完成的观察合成记录，保留身份和基础配置，再恢复正常儿童端调试 APK。

在落盘文件和安全偏好 XML 中检查已知签名载荷、数据密钥编码、动作名及合成应用名称没有以明文出现。这只是所列标记的落盘检查，不是独立密码审计或绝对无信息泄漏证明。

## 安全与重复执行

- 发行方固定 `ai-manager-access-native-fixture-v1`，地址固定 `.invalid` 域名；不打开网络连接。运行时签名私钥只在内存生成，持久记录只有公钥、签名文档和原回执。
- 主机脚本仅允许 `AIManagerChildApi34` 模拟器及 `com.aimanager.child.debug`。未取得唯一活跃 PID、阶段/PID 不一致、结果缺失/重复、进程停止失败均立即停止，不继续下一阶段。
- Android 结果从当前 PID 的原生日志读取，解决 Flutter 控制台订阅可能漏掉早期输出的问题；不从其他运行或旧进程日志补齐成功。
- 首次写入发现合成范围已存在即拒绝，不能自动重建。失败后先分析原日志和持久状态，再按已达到的阶段继续；严禁以清数据/卸载绕过。
- 访问清理只针对一个 `access-v1-<scope>.db`、对应 access_key 和 binding/oracle 两个 access_context 键，并验证规范路径。不存在批量删除、清空偏好或删除身份的操作。
- APK、构建日志、原生日志和驱动日志保留在本地制品目录；提交脱敏结果与摘要，不提交原始安全偏好、设备凭证或调试 VM 服务地址。

## 复现步骤

前提：使用专用 API 34 调试模拟器及 Flutter/Java/Android SDK，依赖已准备好；真实用户设备不可作为测试目标。非空身份/配置及观察前置流程复用仓库已有 `identity_storage_test.dart`、`observation_storage_test.dart`，不能覆盖已有其他身份。环境中必须显式配置工具路径和依赖缓存。

```powershell
# ChildDirectory 指向冻结源码的 apps/child，ArtifactsDirectory 指向本地制品目录。
./scripts/tests/build-child-access-storage.ps1 -ChildDirectory $child -ArtifactsDirectory $artifacts -FlutterCommand $flutter
# 全部预构建完成后停止该项目构建守护进程，再启动专用模拟器。
./scripts/tests/run-child-access-storage-phase.ps1 -Phase negative -ChildDirectory $child -ArtifactsDirectory $artifacts -FlutterCommand $flutter -AdbCommand $adb
# 按上表依次运行八个阶段；replay_pending 后执行受控系统重启并保存启动标识证据。
```

驱动使用 integration_test 标准驱动、90 秒请求期限和覆盖连接阶段的 120 秒外层期限。主机每步核对 PID 并强制停止已知调试进程；不以 Flutter 驱动退出代替进程结束证明。构建和设备运行串行执行，避免在有限内存机器上同时驻留构建守护进程和模拟器。

## 仍需交付

儿童端发起真实申请、系统策略执行与受管设备兼容性、开机恢复及后台下发、真机/更多 Android 版本、物理断电与异常磁盘场景仍需独立实现或验收。商用资质、合规、计费和容量目标不能由本轮存储测试推导为已经完成。
