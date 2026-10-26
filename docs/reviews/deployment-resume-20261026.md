# 已有部署无构建恢复：源码阶段

日期：2026-10-26。基础提交：`b26b7060b8815547059d19dd2856cb74ed7aa1f9`。状态：源码及静态语法检查完成，参数/受控传输/真实容器回归未运行；未推送或更新服务。

原统一 `start` 入口包含 `up --build`，不适合只恢复已有容器。本批新增 `manager.ps1 resume -Directory ...`，映射到原启动入口的 ResumeExisting 分支，继续执行配置、产物来源、TLS、身份与账本校验，避免复制部署框架。

恢复前确认每个目标服务都有持久容器，核对项目/服务/编号及允许的状态；一次性容器不能冒充持久服务，缺失、暂停、重启中、删除中或死亡状态均停止。随后核对应用镜像及挂载，严格匹配旧运行记录中的应用容器完整集合。仅通过显式 AllowStopped 在恢复前接纳停止状态；原默认核验及恢复后的核验仍要求运行并健康。

执行使用 [Compose start 的已有容器启动及等待健康能力](https://docs.docker.com/reference/cli/docker/compose/start/)。基础支持版本 [2.24.4 的 start 源码](https://github.com/docker/compose/blob/v2.24.4/cmd/compose/start.go)没有等待选项，因此新动作先只读探测能力，不支持时在容器变更前停止，不自动升级或实现替代轮询。正常 start 支持范围不因此改写。

恢复后重新核对应用镜像、挂载、健康及同批容器，并比较恢复前后原运行记录的实际字节摘要。resume 不补建或重写记录，不转成 up、不创建/重建容器或镜像；失败不自动回滚，部分原容器可能已启动，应先 status/verify 核对。主机锁、受限日志及原来源复核继续复用；运行记录变更不会被新记录覆盖或修复。

## 本轮检查事实

- 三个 PowerShell 源文件、三个受控传输脚本文本通过 AST 语法检查；三个 Python 测试文件通过 AST 语法检查。解析没有执行任何入口、测试或 Docker/SDK 命令。
- 独立静态接线审查未发现可证明问题；相关源码差异、空白及文档本地链接已核对。没有读取实际身份配置或运行凭据，没有重新采样资源或争抢验证窗口。
- 新增 5 个待运行回归方法：停止容器准入、严格旧容器与记录摘要、目标持久服务齐全 3 项；真实启动脚本搭配受控 Docker/HTTP 传输的成功恢复与失败边界 2 项。失败矩阵含缺能力、缺记录、容器集合不符、启动失败、记录字节变化；断言没有 up 或记录修复。已有计划矩阵增补 resume 及不适用参数。全部未运行，不能声称可恢复实际环境。

恢复既有资源与验证窗口后，先执行新增及受影响的来源/挂载/默认验证语义、正常启动和参数计划用例，不运行无关后端或前端全量套件。真实恢复需在已核验的隔离环境检查停止再恢复、原容器编号/镜像/记录不变及最终健康；不为验证停止当前业务服务。真实网络、身份/设备能力与完整产品验收仍单独判断；前端本地依赖解析等历史未运行项未被追认为通过。

本次源码摘要（静态候选定位，不代表运行通过）：

- `scripts/manager.ps1`：`a9a9e81fdf42cb53e39dd57472c3c9e8b775deb845159076d7a45937f5d68741`
- `scripts/start-deployment.ps1`：`577ce85b6e6c9c941754ebf64323d0ca671a344c7aad381edd06fab6ad38d7e2`
- `scripts/deployment-runtime-provenance.ps1`：`069802d4a06b5aeb3b2a2c426910ac73270232edbb2290400b2e989d6a1165fe`
- `scripts/tests/test_manager_entry.py`：`c5ca68223a9e657a59ab10b892eff50e663082c1a9b06fe7c6ed131b514ea739`
- `scripts/tests/test_deployment_runtime_provenance.py`：`142f4e120eadeb9dc134665b4639a9a3740d1fe0ec7b4749838dca0c7ab30426`
- `scripts/tests/test_deployment_provenance_commands.py`：`1f5c74d2f8c290bee88f73030178b838ac9a1c9c564978fac79e6754567514c9`
