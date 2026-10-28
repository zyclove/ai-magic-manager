# Guardian 离线依赖解析

基线：`61aa4143009c3634c2b2978d4a006fedc63a3f22`。本轮只补齐源码已声明的本地路径依赖，不证明应用功能通过，不更新服务。

## 实际变化

Guardian的 `pub get --offline` 使用项目锁定的既有 `https://pub.flutter-io.cn` 缓存完成解析；`pubspec.lock` 只新增 `schedule_contracts` 路径包1.0.0，现有包无升级、移除或内容变化。生成的package_config已包含 `../../../packages/schedule_contracts`，languageVersion=3.4；没有手写包配置。

复用已入库且摘要为 `4FE9AF9EFDA326986044163BB48AC1447813CAB07730FDFAA689A9C7307CA5EC` 的OwnedJob工具，保持RAM／C／D各2GiB、SDK空闲、60／65秒期限和原生自然终态条件。TEMP/TMP仅对该进程指向本任务.cache；没有运行下载、SDK升级、平台构建、后端或服务更新。

## 执行结果

| 次序 | 实际结果 |
| --- | --- |
| 首次离线解析 | NOT_ACCEPTED；SDK1次，自然exit69。验证入口误用pub.dev，而原锁及缓存来自既有镜像，未找到qr_flutter；锁和限定源码无变化。原驱动／输出保留 |
| 修正镜像后的准入 | NO_START；SDK0次，另一窗口Dart在运行；未抢占或停止进程 |
| 对方明确释放后再解析 | PASSED；SDK1次，6.5秒自然exit0、私有Job成员0、forceRequested=false、限定源码无漂移，后置SDK空闲；锁仅新增本地包 |
| 随后的6文件格式化准入 | NO_START；SDK0次，检测到Go/link/vet；不重复盲试，已按既有授权仅协调排期与结果 |
| 格式化／严格分析／VM／浏览器／构建 | NOT_RUN；上述解析不能代替这些检查，后续继续按原串行门槛执行 |

仅更新Guardian锁、本交付状态和必要执行证据；未推送、未部署。Parent或其他仓库的结果不作为本轮通过证据。

## 原始证据

保留[成功回执](../evidence/guardian-offline-dependencies-20261028/offline-result.json)、[成功输出](../evidence/guardian-offline-dependencies-20261028/offline-output.log)及[对应驱动源码](../evidence/guardian-offline-dependencies-20261028/offline-driver.py)。驱动为原.cache路径执行时的字节归档，不从交付目录直接执行。

首次失败的[回执](../evidence/guardian-offline-dependencies-20261028/initial-result.json)、[输出](../evidence/guardian-offline-dependencies-20261028/initial-output.log)、[原驱动](../evidence/guardian-offline-dependencies-20261028/initial-driver.py)保持原样；两次未启动分别见[镜像解析准入](../evidence/guardian-offline-dependencies-20261028/cache-busy-result.json)、[格式化准入](../evidence/guardian-offline-dependencies-20261028/format-busy-result.json)。未改写历史失败或重做工具资格。
