# 回归平台清单 r2：补齐全部当前包测试

静态导入与源码身份清单，全部 **UNRUN**。当前 Git HEAD 只读确认 `a2b5ca6ef2398397e4208065090b7c1d65992358`。r1 原件保持不变。

| 范围 | mustbrowser | mustVM | platformneutral | 待查 |
| --- | ---: | ---: | ---: | ---: |
| Guardian 142（沿用 r1，逐根重哈希一致） | 39 | 1 | 102 | 0 |
| 全部 Main 包测试 37（原 9 + 新 28） | 0 | 11 | 26 | 0 |
| 单列外部 Spring HTTP 工具 2 | 0 | 2 | 0 | 0 |

HEAD tree、index stage0、排除缓存/构建目录的当前源码扫描三者均精确 37 个包测试；packages 状态为空，37 个 raw 或 LF 规范化 Git blob 身份全部匹配。新增 28 个均为正常跟踪源码，不是 ignored 生成物或历史副本。各文件 SHA、pubspec/config 根及 pin 在 summary.json。

## 关键边界

- 新增 28 个：10 VM、18 平台中立，全部使用 Dart package:test；没有新增浏览器测试。
- `device_access/test/journal_view_test.dart:5` 的 `show ack` 导入仍带入 journal_test 的 `dart:io`，因此为 VM。它自己的内存数据库夹具不能消除库依赖限制；不表示 imported main 会执行。
- VM 自建 HttpServer 测试用 loopback 临时端口和自建夹具；它们与两个需预先启动 Spring/准备业务身份的 HTTP 工具不同。后者仍单列人工夹具预检，不可自动混跑。
- 文件数据库测试以后需按 AGENTS 使用进程本地任务 TEMP/TMP；本轮没有设置环境、创建数据库、绑定端口或清理目录。
- 中立类别只说明本地必要导入未发现平台冲突。jose/sembast/http 等外部依赖停在现有配置边界，不能称已编译兼容。
- 142 + 37 + 2 = 181 根；critical80 只是一部分。本轮没有测试、SDK、浏览器、进程检查、网络、Main 或 Git 写入。

## 新增 28 个跟踪测试

| 路径 | 类别 | 简短依据 | raw SHA-256 |
| --- | --- | --- | --- |
| `packages/device_access/test/context_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `26c92a5cbb8b7da81639176ad25f63d28e811385405c88d84e83f1fdadbad900` |
| `packages/device_access/test/journal_portable_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `30af0df1a47ba033139e3032d97350307c645b18991f82a944afab6487882519` |
| `packages/device_access/test/journal_test.dart` | mustVM | 直接 dart:io:4；@TestOn('vm'):1；文件数据库或自建 loopback HTTP 需 VM | `61f98f59fa942ed7d17f968296d7df7d550d11cc00f1023d7e53de9c759a1d92` |
| `packages/device_access/test/journal_view_test.dart` | mustVM | 必要本地导入闭包含 dart:io；show 只筛选名字，不能解除被导入库的平台限制 | `20e4e0cabf58d2e523ebde4e87c9eccd7cc44bfe0b0fed7d8f90c5bfda925a48` |
| `packages/device_access/test/page_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `9a6022fc02735daa65c859999da2104e0d960d39240846f4ed8fab78a6797ab8` |
| `packages/device_access/test/submission_journal_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `9517abc41556be69fe854793e8951f2e6f8c95fd701b577b9b73673d5627b37d` |
| `packages/device_access/test/submission_recovery_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `33013d6554c17e84163e7053dff63cbbdc239781c50f0a22b120355fa4969ef9` |
| `packages/device_access/test/submission_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `fb7ddfcca41d694edcab347f7c4948f83e099992a5072a780bb0a1eb83e48eeb` |
| `packages/device_access/test/synchronizer_test.dart` | mustVM | 直接 dart:io:6；@TestOn('vm'):1；文件数据库或自建 loopback HTTP 需 VM | `ecbacaae70286a348fcfe4d09ef4e3029b153dbdc1d12a0efcb5d1f88240f0bb` |
| `packages/device_access/test/transport_test.dart` | mustVM | 直接 dart:io:6；@TestOn('vm'):1；文件数据库或自建 loopback HTTP 需 VM | `6eccf5ff3cd44ca1d8853ae1a9cb57d9ff70cff5b70cdd83c8b26990ad46e560` |
| `packages/device_access/test/verifier_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `e6d719ed04a3c901c294afdac7d1fc38ca0f44de108a371a9a69b48fc0b5416e` |
| `packages/device_cleanup/test/coordinator_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `9149b00e7a861dcd1f6d9eb9cbd2fe9d4a7cbe7d1185c96cb9df30191b66d0ba` |
| `packages/device_cleanup/test/journal_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `ab361064e4efaae8feb52a1df3991f9bf6c0beef752623c3bb161f18b4fa9036` |
| `packages/device_cleanup/test/protocol_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `dd3a589e52bc345f9e41c4e3519084ddfbd78786ac65356714bbe5cfc468a902` |
| `packages/device_cleanup/test/transport_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `4a376f1103134fc1600f45a14246a500b381dd47768f61018d1c2857a05b5869` |
| `packages/device_identity/test/api_test.dart` | mustVM | 直接 dart:io:3；文件数据库或自建 loopback HTTP 需 VM | `7393581ba1a0448e722b75b20da652c966d494615de3ecbcb0234601bd14fd10` |
| `packages/device_identity/test/identity_test.dart` | mustVM | 直接 dart:io:3；文件数据库或自建 loopback HTTP 需 VM | `1cd23ae748458238bd361f869dec11020795e0137309b714f85a7390c968de0f` |
| `packages/device_identity/test/keys_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `16ef1b4b0bc5c13cfe52703877d1aac33a872b9388eccb1c4ca72ef472fb0588` |
| `packages/device_identity/test/managed_binding_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `970acf8b70f6222ac2f7896eaf3bbf2c2650802e6e6912b1e1a1539bd022a349` |
| `packages/device_observation/test/agent_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `f2822103814848555cc7981424327c5e2ffe9eb129c1b682d46b876a1583f9f4` |
| `packages/device_observation/test/journal_cas_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `d674152b699709673682c1bc06276c9232d96baedb98c9d6e8e8a49aebc16f60` |
| `packages/device_policy/test/journal_test.dart` | mustVM | 直接 dart:io:1；文件数据库或自建 loopback HTTP 需 VM | `fec4ab6787fe2e2d9d050f0f5c07206376dc428e2af241be66f82239389ff8fc` |
| `packages/device_policy/test/observation_transport_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `bc7d9187fdf76f65ace5947d87e3a22d6773b7a91b4713f51e5097999fd065a0` |
| `packages/device_policy/test/page_test.dart` | mustVM | 直接 dart:io:1；文件数据库或自建 loopback HTTP 需 VM | `a6384f8d3056b1d46515eb2c1a8dd13aa471ffa13cd7987ea99992a8aac8cf91` |
| `packages/device_policy/test/synchronizer_test.dart` | mustVM | 直接 dart:io:3；文件数据库或自建 loopback HTTP 需 VM | `68e1217b37f085c053230b47fb3b274fbdcf52a43c49a30a5c5f5855a6e31d58` |
| `packages/device_policy/test/transport_test.dart` | mustVM | 直接 dart:io:3；文件数据库或自建 loopback HTTP 需 VM | `96ea588a878fbbb0e45d1461162d64ae6c2b0d55ad7e6827ef4e6f52a52f94f7` |
| `packages/device_policy/test/verifier_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `cba2fe286cc13bbe05170d619e23103f8f5e1c68d5717667054a7842b859f2bf` |
| `packages/device_reports/test/client_test.dart` | platformneutral | 本地必要导入闭包无 HTML/IO 平台限制；MockClient/内存夹具不构成外部包编译证明 | `68a5b624574c310b7d3e5b42c04f6e2e58c8fe92a623b2a3733acd607281a29a` |

## 文件

- `summary.json`：完整 181 根的紧凑清单，37 包的 Git/pubspec/config 身份，额外输入 pins。
- `additional-import-nodes.json`：新增范围的平面本地导入图；旧 351 节点/2.7MB 图仅引用 r1 摘要，没有复制。
- `git-package-membership.json`：只读 HEAD/index 路径与 blob、packages 状态原始记录。
- `delivery-pins.json`：r2 交付摘要。

所有分类均为静态推断，不是 Dart 编译或行为测试证明。
