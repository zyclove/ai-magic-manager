# Android 应用权限观察与受管执行契约

状态：后端独立授权、单应用快照接口和保留清理已进入代码；Android 原生单应用权限读取、Pigeon 模型、儿童端按需上传及监护人端授权/结果界面已接入。**主体删除覆盖的并行改动尚未提交核对，真实设备/网络端到端与系统权限执行尚未完成**。后端新路由默认关闭，只有显式设置 `manager.observation.permissions.enabled=true` 且儿童端和监护人端构建均设置 `PERMISSION_OBSERVATION_ENABLED=true` 才开放联调；三端开关应在保留删除和设备验证后一起发布。现有应用清单授权不能自动扩展成权限状态授权。首期针对 Android 手机/平板与经兼容确认的 Android TV；中国大陆机构合同优先。没有合规 EMM 时，受管执行入口保持不可用。

## 1. 用户要完成的事

监护人/机构管理员在设备详情中选一个应用，看到它向 Android 请求了哪些可识别的运行时权限、设备最近一次观察到的授予状态、观察时间、来源和盲区；随后可创建“希望允许/拒绝”的规则，并明确看到该设备是否有系统执行能力。规则发布、提供方受理、设备回报和实际生效分开显示。儿童可查看规则解释和申请限时使用，不能更改权限或关闭观察授权。

按设备模式呈现动作：

| 模式 | 可查看 | 可执行 | 界面主动作 |
| --- | --- | --- | --- |
| 普通家庭 Android 应用 | 当前用户可见应用中、经单独同意的权限观察；不保证完整性 | 本代理不能替其他应用修改 Android 运行时权限 | 查看状态、打开系统应用详情、提示家长在系统中操作 |
| 机构合格受管设备 | 经提供方和本地回读的对应资料 | 经合格 EMM 的权限策略，具体范围按提供方、Android 版本及管理模式确认 | 预览影响、近期认证、发布、查看规则级回执和回读 |
| Android TV / Google TV | 经厂商、系统版本和启动器兼容矩阵确认后展示 | 仅展示实际支持的受管权限项 | 不支持时显示“此设备不能远程修改此权限” |

现有 `application-inventory` 只能作为**候选应用列表**，最多报告当前用户可见的启动应用；不应将其空列表解释为设备没有应用。Android 11 起包可见性受系统过滤，查询其他应用需要声明相应 `<queries>`，不能依赖普通应用获得全设备完整清单。[Android 包可见性](https://developer.android.com/training/package-visibility/declaring)

## 2. 数据语义和隐私边界

采用**单独的权限观察授权**，默认关闭。管理员需要近期 MFA、设备写权限和强版本提交；界面逐项说明“收集所选可见应用的权限名称、请求/授予状态、观察时间”，可随时撤回。儿童端采集前重新在线读取当前授权，展示采集提示；离线不新采集。撤回后拒绝新报告并删除当前注册周期的权限观察快照，审计只保留操作事实，不保留具体权限列表。权限观察不包含联系人、位置、照片、应用内容、摄像头画面或原始行为事件。

Android `PackageInfo.requestedPermissions` 是应用清单声明，包含未获授予及系统未知的权限；`requestedPermissionsFlags` 只在 `GET_PERMISSIONS` 查询时填充，并可携带授予标志。它们不证明权限正在被使用，更不证明家长可以远程修改。[Android PackageInfo](https://developer.android.com/reference/android/content/pm/PackageInfo)

每个权限展示三个不同字段：`requested`（应用清单声明）、`observedGrant`（`GRANTED`/`DENIED`/`UNKNOWN`）和 `policyGrant`（`GRANTED`/`DENIED`/`DEFAULT`/`NOT_SUPPORTED`/`UNKNOWN`）。普通应用只能给出前两项的有限本地观察；不能把 `observedGrant` 解释成设备策略。Android `DevicePolicyManager.getPermissionGrantState` 在策略为 `DEFAULT` 时**不能用于判断应用实际是否获授权**，而 `setPermissionGrantState` 仅限设备所有者、资料所有者或获授权的委派方。[Android DevicePolicyManager](https://developer.android.com/reference/android/app/admin/DevicePolicyManager)

### 服务端数据与协议

- 新增独立的 `device_permission_observation_settings`：`tenant_id`、`device_id`、`registration_id`、`version`、`enabled`、`updated_at`、`last_reason`。默认关闭；设备换注册周期不继承授权。沿用现有租户/设备/凭证与审计锁序。关闭时同一事务清空该注册周期的权限快照。
- 管理端 `GET/PUT /api/v1/tenants/{tenantId}/devices/{deviceId}/permission-observation-settings`；PUT 使用近期 MFA、`If-Match` 和明确原因。设备端 `GET /api/v1/device-api/permission-observation-settings` 只回当前注册周期的版本与开关，不返回其他设备数据。
- 设备端 `POST /api/v1/device-api/permission-observations`：`reportId`、单设备递增 `sequence`、`authorizationVersion`、`packageName`、`profile`、签名摘要、版本号、`observedAt`、`source=ANDROID_PACKAGE_MANAGER`、权限条目。服务端以序号和正文哈希对**当前快照**幂等，旧序号或同序号异文返回冲突，旧授权版本拒收。当前代码要求应用匹配同注册周期**最近 15 分钟**的已授权应用清单，且版本号与签名摘要相同；服务端仍不能把代理自报当作硬件证明。
- 管理端 `GET .../devices/{deviceId}/permission-observations?packageName=...` 返回授权状态、观察时间、`RECENT`/`STALE`/`NOT_AUTHORIZED`/`UNKNOWN`、来源和逐权限结果；禁用共享缓存。每次读取重新核验成员、设备范围、当前注册周期和当前授权。儿童/教师不读取详细权限清单，机构审计员只看授权/操作审计。
- 每次只观察**管理员选定的单个应用**，上限 64 个权限、单次正文 32 KiB、单设备每 15 分钟最多 20 次。当前后端每设备只保留**最近一个应用**的快照，新应用上报会替换旧快照；前端必须对其他应用显示“尚无当前快照”，不能拿旧应用结果拼接。Android 原生异步查询待接入有界执行队列，不能阻塞 UI。超过上限显示“权限较多，需在系统设置中查看”，不悄悄截断为完整结果。
- 快照到达 24 小时后读取变为 `UNKNOWN`，后台默认每 30 秒最多删除 1,000 条过期快照，实际物理删除延迟须监控队列积压并按部署容量调整；不能把定时清理的节奏称为硬实时删除。显示年龄以服务端接收时刻为准，另展示设备观察时刻和可能的时钟偏差。设备端待上传正文继续使用现有加密、提交屏障和不可变重放思路，单独受权限授权版本约束；撤回时清除本地待发权限正文。

当前后端联调请求示例（先为设备取得**独立权限观察授权**，并保持应用清单授权开启与新鲜）：

```json
{
  "reportId": "00000000-0000-4000-8000-000000000001",
  "sequence": 1,
  "authorizationVersion": 1,
  "packageName": "org.example.reader",
  "profile": "PRIMARY",
  "signingDigests": ["0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"],
  "versionCode": 42,
  "observedAt": 1791514800000,
  "source": "ANDROID_PACKAGE_MANAGER",
  "permissions": [{
    "permissionName": "android.permission.CAMERA",
    "classification": "DANGEROUS",
    "observedGrant": "DENIED"
  }]
}
```

示例时间仅说明格式，联调必须使用真实系统时间。管理员 `PUT .../permission-observation-settings` 请求体为 `{ "enabled": true, "reason": "告知并授权查看所选应用权限" }`，要求 `If-Match`、幂等键和近期 MFA；设备 `GET .../permission-observation-settings` 取得当前授权版本。设备报告必须使用设备凭证，不能使用管理员 JWT。普通设备读取结果固定 `evidenceStatus=AGENT_REPORTED_UNVERIFIED`，不能作为系统权限修改成功的证明。

权限条目仅接受 `android.permission.*` 名称；服务端不靠固定旧版本名单推断所有新 Android 权限。原生层通过系统 `PermissionInfo` 分类，对 `dangerous` 权限提供最清楚的逐项状态；签名/特权/厂商权限可标为 `OTHER` 与 `UNKNOWN`，不在普通管控页误呈现为可调运行时权限。空权限列表表示该**可见应用**没有被观察到相应请求，不能推断系统没有其他权限。

### 受管策略和回执

策略规则应引用经核验的应用包名、签名/提供方应用 ID、权限名称、期望状态、设备目标快照和策略版本。发布前在服务端做能力判断、恢复应用保护和后果预览；需要近期认证。连接器输入使用不可变规则 ID 和幂等命令 ID；回执区分 `UNSUPPORTED`、`REQUESTED`、`PENDING`、`APPLIED`、`NON_COMPLIANT`、`FAILED`、`STALE`。仅在提供方回读同一设备、同一权限和同一策略版本后显示 `APPLIED`。Android Management API 提供应用级权限配置，但其合规接入资格和中国大陆实际可用性仍是独立发布门槛。[Android Management API policy](https://developers.google.com/android/management/reference/rest/v1/enterprises.policies)

## 3. 界面和交互状态

1. 设备详情 > 应用清单：保留“代理自报、可见范围有限”的标签。选应用后显示权限卡片；未授权时主按钮为“了解并授权权限观察”，不把旧应用清单开关复用。
2. 授权弹层：用途、数据项、保留时间、撤回后果，近期身份验证；成功后需要儿童端前台/在线确认采集，不显示虚构进度。
3. 结果页：按“相机/麦克风/位置/通知/其他”分组，但以系统权限名作为可核对细节；每行显示请求、观察授予、策略期望与实际执行四列。显示设备时间、服务器接收时间、版本、来源、资料范围和“不完整”说明。读屏标签按同样顺序读取；TV 用大字、明显焦点和遥控器返回。
4. 普通模式点“如何调整”：说明须在设备系统设置中处理，并让**设备本地用户明确操作**打开对应应用详情；服务器不发送伪装成权限变更的指令。
5. 受管模式点“设置策略”：仅列当前连接器确认可执行的权限。预览影响、保存草稿、发布、查看回执；提供方不可用或没有合同/企业审核时禁用发布并显示具体原因。
6. 撤回授权：显示将清除云端当前快照与设备端待上报正文，执行后页面变 `NOT_AUTHORIZED`；已发布的受管权限策略是另一授权面，需单独撤销或修改，避免误导。

失败/空态必须区分：设备离线、Android 锁定、包不可见、应用已卸载、权限查询失败、授权版本已变化、儿童端尚未提交、过期快照、提供方能力不支持、提供方接受但未回读、真实策略不合规。每种状态有一个可执行的下一步，不默默复用旧成功结果。

## 4. 实施顺序与发布门槛

1. 独立授权和数据生命周期：新增 Flyway 结构、范围授权、设备身份校验、撤回清理、请求限额与审计；先不更改现有观察授权语义。
2. 原生查询与客户端：Pigeon 生成通道、Android `PackageManager.GET_PERMISSIONS`、可见性校验、单应用有界查询、加密待发与授权撤回。不得请求 `QUERY_ALL_PACKAGES` 来掩盖范围问题。
3. 管理端详情与状态：真实 API、权限矩阵、时间/可信度标签、撤回操作、空态和 TV 焦点适配；普通模式只提供可执行的系统设置指引。
4. 合格 EMM 接入后增加受管规则编译、下发、回读与退管；没有合作方时保持禁用。机构合同名额与系统级权限生效是两套独立证据。
5. 发布前以真实 Android 版本/厂商/TV 样机核对权限读取与变更差异；另核验中国大陆数据处理告知、授权文案、保留删除、合同和供应商条款。当前静态分析/构建或模拟器结果都不能替代这些门槛。

本契约的边界是：**权限请求、当前观察、策略期望、系统执行分别有来源和状态**。任何一层不可用时明确显示未知或不支持，不用推断值填充成功。

## 原生查询阶段记录

儿童端 `ObservationHost.permissionSnapshot` 只接受合法包名且要求应用仍出现在当前用户的启动器可见清单中；使用 `PackageManager.GET_PERMISSIONS` 读取 `android.permission.*` 声明，并通过系统 `PermissionInfo` 区分危险权限。危险权限的 `observedGrant` 来自 `requestedPermissionsFlags` 的授予标志，其他类别返回 `UNKNOWN`；因此它**不是 AppOps 实际访问记录**，不能用于断言相机/麦克风正在使用。最多 64 项，超限整次拒绝；签名摘要、版本号和资料范围与应用清单沿用同一原生来源。Pigeon 21.2.0 的 Dart/Kotlin 生成文件随源一同维护，`PermissionSnapshot.parse` 对名称、分类、授予值、唯一性和范围做二次校验。Android debug 构建只说明代码可编译，不替代手机/电视或授权撤回验证。[PackageInfo](https://developer.android.com/reference/android/content/pm/PackageInfo)、[PermissionInfo](https://developer.android.com/reference/android/content/pm/PermissionInfo)

儿童端后续阶段已接入独立在线授权读取、加密待发正文、单调序号、原请求重放与服务器回执核对。用户需在前台明确加载可见应用、选择一个应用；客户端先刷新应用清单，再核对原生返回的资料范围、签名摘要和版本号，采集后再次检查独立授权才上传。权限授权或原有应用清单授权变化时清除旧待发和最近确认状态；本机加密记录从 schema 1 读取后以 schema 2 保存，原有应用清单和使用摘要不会因新增字段被直接丢弃。`PERMISSION_OBSERVATION_ENABLED` 默认为 `false`，当前阶段未做真实网络、Android 进程恢复或管理端端到端验收。

设备前台重试时，待发权限快照若已超过 14 分钟则丢弃并重新采集；服务端对新报告的 15 分钟采集时限不允许把过期快照当成当前事实。服务端已接受但客户端丢失回执的旧快照也可能被下一份新快照覆盖，不能据此推断旧上报从未成功。

监护人端现有设备观察窗口在相同构建开关打开时显示独立权限面板：读取注册周期专属授权；监护人/机构管理员填写理由、确认数据范围后提交带 `If-Match` 与幂等键的授权变更，服务端仍要求近期 MFA；未满足时界面提供安全验证入口。开启后从当前可见应用清单选择包名、读取最近一个应用的代理自报结果，展示设备观察/服务器收到时间、`RECENT`/`STALE`/`UNKNOWN` 等状态及逐权限授予标志；不把它展示为系统执行回执。管理端 Web 启用该构建开关的产物已编译，尚未以真实后端/浏览器操作证明交互链路。儿童端 APK 编译与静态分析同样不是端到端验收。
