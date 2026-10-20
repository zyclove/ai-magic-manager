# 本机验证环境内存回收与恢复

日期：2026-10-19。用户明确要求由助手释放内存。本记录仅描述本机验证环境，不能视为产品功能验收。

## 已执行的操作

- 对 `docker-desktop` 执行数据同步、文件缓存回收及空闲页整理，未修改持久 WSL 配置。方法依据[微软 WSL 内存回收说明](https://devblogs.microsoft.com/commandline/memory-reclaim-in-the-windows-subsystem-for-linux-2/)。
- 使用 Windows [EmptyWorkingSet](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-emptyworkingset) 对两个后台 GitKraken 进程做一次工作集回收；前台应用被跳过。没有结束桌面应用进程。工作集回收是临时效果，页面在再次使用时可能重新加载。
- 按依赖顺序温和停止下表中的旧本地验证与手机预览容器。使用无限期等待的正常退出，不设置强制杀进程期限；两个停止任务均实际退出码 0，容器未被删除、未出现 OOM 或退出码 137，挂载关系保留。

## 当前环境边界

| 环境 | 当前状态 | 恢复要求 |
| --- | --- | --- |
| `ai-manager-v1-refresh-20261016-r1`，主入口 `18101` | 六个原容器保持运行，身份不变；停止操作后 `/healthz` 返回 200 | 保持现状；健康入口只证明当前入口可用，不代替业务联合验收 |
| `ai-manager-local`，`8081` / `3308` | 身份、数据库两个容器临时停止 | 后续 MySQL 验证前恢复原数据库、检查健康并重新核实服务 UUID，再建立新的验证 schema；需要该身份入口时另行启动原身份容器 |
| `ai-manager-mobile-quick`，手机预览 `18102` | 六个容器临时停止，当前不能使用该预览入口 | Android/手机验证前恢复原数据库、身份、后端和入口；随后检查健康与登录流程 |
| 其他项目环境 | 未停止、未重启 | 本次没有修改 |

`local` 数据库仍是后续 MySQL 验证依赖，不能记为永久无用环境。手机预览临时停止对应用户已确定的 Android 验证延后安排。两套环境的容器、卷、源码和已有数据均保留，未进行数据库初始化、迁移或清理。

## 恢复顺序

恢复前读取本机忽略目录中的原始记录，核对容器 ID、Compose 项目标签、数据挂载与记录一致；若容器被替换或挂载变化，先重新核实，不能直接初始化新的数据库替代旧数据。

1. 旧本地验证：启动原 `ai-manager-local-database-1`，等待健康；需要身份服务时再启动原 `ai-manager-local-identity-1`。
2. 手机预览：先启动原 `ai-manager-mobile-quick-database-1`、`identity-database-1`、`erasure-database-1`；等待健康后依次启动该项目的 `identity-1`、`backend-1`、`edge-1`。
3. 所有恢复均使用已有容器的 `docker start`，不使用删除卷、重建环境或初始化命令。恢复后按所需验证范围重新检查健康、入口、身份与数据库；不能把容器启动等同于验收通过。

原容器 ID、挂载和恢复命令保存在 `.cache/managed-memory-reclaim/legacy-local-stop-r1.json` 与 `mobile-preview-stop-r1.json`；记录不包含数据库密码或令牌。停止任务分别为 session 52204 和 63553，均已自然结束。

## 实测效果与后续验证

08:45:40—08:45:55 UTC 的六次 Windows 采样，可用内存最低为 3,803,848,704 字节，约 3.54 GiB。随后定向回归实际以 3,765,055,488 字节可用内存启动并运行 34.5 秒。资源阻碍已得到缓解，但每次验证仍须重新执行原有资源检查；该采样不能保证未来始终有同等可用内存。

首次回归发现测试夹具错误，原始失败证据已保留。修正夹具后，已准确复现 27 项业务断言缺口；修复后的相同 29 项定向用例全部通过，测试启动时可用内存为 3,164,098,560 字节。后续仍需完成领域及联合验证，详见[受管执行阶段修正记录](managed-execution-review-corrections.md#10-最新结果四类修正的定向回归通过)。

后续再次出现内存波动。后台 Chrome/WorkBuddy 工作集回收的首次尝试因访问权限不足全部跳过；在用户既有“自己释放”授权下，经自动审批允许后调用 Windows `EmptyWorkingSet`，跳过前台应用，未关闭程序、标签页或服务，也未改变持久配置。09:38:21—09:38:26 UTC 可用内存从 2,029,277,184 增至 3,045,662,720 字节。原始记录为 `.cache/managed-memory-reclaim/background-working-set-trim-r2.json`（跳过）和 `background-working-set-trim-r3.json`（实际回收）。工作集可能随应用使用重新增长，后续运行仍须重新检查资源。

## 2026-10-20 恢复后的资源处理

协作任务恢复原有运行环境后，本任务没有启动、停止或重建任何容器。只读检查发现 Docker WSL 文件缓存与缓冲约 2 GiB，执行 `sync`、文件缓存回收和空闲页整理后，八次采样为 2.62—2.71 GB。随后对后台 Chrome/WorkBuddy 执行已授权的工作集回收，仍排除前台应用并保留所有进程、页面和服务；本次实际可用内存从 1,814,626,304 增至 6,110,404,608 字节。

回收后的六次两秒间隔采样最低为 5,509,386,240 字节，满足此次共享编译额外设置的 4 GiB 入口要求。02:56:07 UTC 独立读取现有 `18101` 根页及 `/healthz` 均返回 200。入口正常响应不代替新候选的编译、业务或联合验收。

原始记录为 `.cache/managed-memory-reclaim/docker-startup-reclaim-20261020-r1.json`、`background-working-set-trim-r5.json` 和 `stable-4g-sample-20261020-r1.json`；摘要及原件校验值见[资源回收记录](evidence/local-memory-recovery-20261020.json)。这些是已完成操作及采样的记录，不承诺内存以后不会随应用使用再次增长；没有改变系统持久配置、清理数据或恢复此前停用的本地/手机验证副本。
