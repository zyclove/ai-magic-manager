# 身份扩展离线编译原始证据归档

本目录保全 2026-10-21 r4 的 **11 项公开原始资料**。结论仍为完整 `test-compile` 通过、JUnit/打包/运行验收未完成；主说明见 [编译验收记录](../identity-extensions-offline-compile-20261021.md)。

## 使用方式

1. 查看 [inventory.json](inventory.json) 的原路径、归档路径、字节数与 SHA-256。
2. 按归档文件的原始字节计算摘要，与清单以及原验收 JSON 的 `evidenceFiles` 比较。原 JSON 没有修改。
3. 结合收据、启动记录和编译器范围解读结果。身份业务模块源码、缓存文件和 class 文件仅以摘要出现，不在本目录复制。

资料包含公开 runner、离线仓库配置、输入摘要、资源采样、收据和原始编译日志；未发现实际密钥、令牌或私有配置正文。编译日志的本机诊断文本可能混合编码，归档保留原始字节及换行，没有重新编码。`.gitattributes` 对 `r4/**` 关闭 Git 文本转换、过滤及工作区编码转换，以使提交和检出后的原始摘要仍可复核。

本目录的 `.gitignore` 只为已审查的 `r4/out/maven.log` 取消根目录的日志忽略规则，便于将该项公开原件一并提交。

`r4/run.py` 是历史验证代码证据，其内部路径指向原任务目录；本目录用于审计，后续执行需按当前仓库规则生成新的独立任务。归档没有运行 SDK、构建、测试或服务。

## 原件映射

| 原始相对路径 | 归档路径 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| `.cache/id17-20261021-r4/initial-gate.json` | [r4/initial-gate.json](r4/initial-gate.json) | 1152 | `3454dc73b18fb422ebfccd275a778e1a12897f257c7e4c17e331c0b37d224f66` |
| `.cache/id17-20261021-r4/input-manifest.json` | [r4/input-manifest.json](r4/input-manifest.json) | 806269 | `a0042d42f84d6660b6e7f543c821e7fcb32579c1dc63766656d47c78f3c1bfcc` |
| `.cache/id17-20261021-r4/launch-gate.json` | [r4/launch-gate.json](r4/launch-gate.json) | 1144 | `cc7929ea24e8dc92c9b561135a6ef5edaa59dab2eb7a5f638ef94f91df1ee4e7` |
| `.cache/id17-20261021-r4/launch.json` | [r4/launch.json](r4/launch.json) | 744 | `ae96f97e6b2c54a1c29b3b37710443019acb33f2b0ab1fe3c8b2ea7b65c2672f` |
| `.cache/id17-20261021-r4/offline-settings.xml` | [r4/offline-settings.xml](r4/offline-settings.xml) | 1677 | `4925e1bcc0d37d71a3f2f751737aceb3d89d2c58346a0ac8ce8710778ee5f5e4` |
| `.cache/id17-20261021-r4/out/compiled-artifact-manifest.json` | [r4/out/compiled-artifact-manifest.json](r4/out/compiled-artifact-manifest.json) | 13928 | `429b9767d0cab2a74e9ddaa21cd9e7d8f68070f2168ef18970bc6ca7cf1fd4ca` |
| `.cache/id17-20261021-r4/out/maven.log` | [r4/out/maven.log](r4/out/maven.log) | 3459 | `358bcefacd54687ba514b4156a8ebd4893976aff51afcb336333bf9983a459a0` |
| `.cache/id17-20261021-r4/out/postflight-source-observation.json` | [r4/out/postflight-source-observation.json](r4/out/postflight-source-observation.json) | 693 | `dc2281f302724ece56b3936389e68516af068c821435c69593f17a9bd919a806` |
| `.cache/id17-20261021-r4/proposal.json` | [r4/proposal.json](r4/proposal.json) | 2423 | `3625e9a88d49ea630f499a6c0200138bca1379cb02d747ac282ef5c9f5152a63` |
| `.cache/id17-20261021-r4/receipt.json` | [r4/receipt.json](r4/receipt.json) | 895 | `657dcbd910be10a85fa8ee95fc43f21db99f82d2fab7f13a4dbd6be037cecb94` |
| `.cache/id17-20261021-r4/run.py` | [r4/run.py](r4/run.py) | 13255 | `60b0a75d3e6d992757e69661a75893425c8dd2d509e35385606786068630fdde` |
