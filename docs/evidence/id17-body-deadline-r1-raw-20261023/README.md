# 身份通道正文期限：耐久原始 RED 归档

状态：**OBSERVED_LEGACY_DEADLINE_RED_NOT_VERIFY_PASS**。原运行 `NOT_ACCEPTED`
保持不变，本目录没有执行新的 SDK、测试、网络调用或重试。

本目录逐字节保存原 14 份 Surefire XML、Maven/worker 两份日志，以及测试覆盖层、
sealed proposal、精确测试名清单、source-anchor 四份元数据，共 20 份原件。
另有 `.gitattributes`、本说明和 `inventory.json`，总计 23 文件。
`.gitattributes` 的 `* -text` 禁止本目录文件在 Git 暂存时进行文本换行转换；
原始 XML/log/source/JSON 未归一化、未脱敏改写，复制后已逐字节核对。

## 实际结果与解释边界

- 原同一 session `49080`，`133ef4` → `187c62`；outer exit 1，50.5029392 秒。
- 14 套、79 项：**77 pass、2 assertion failures、0 errors、0 skipped**。
  原有 76 项通过，新增调用方中断 guard 通过。Maven exit 1，worker exit 0，
  未产出 JAR；私有 Job 最终 0，未强制清理/看门狗终止。
- 两个 `WHOLE_BODY_DEADLINE_REQUIRED` 断言分别观察到 5 秒期限的调用在
  6612 ms / 7271 ms 后返回 200、4,194,304 字节正文，无 `HttpTimeoutException`。
  两者 `writeFailedBeforeCleanup=false`，**不能声称超时取消已经奏效**。
- 中断项保留中断标志、调用线程退出且清理前观察到对端写入失败；只能证明本次
  自有 loopback HTTP/1.1 交换的可观察收敛，不外推所有 JDK/网络条件。
- **原 fixture 的 4 MiB 正文不是未来有界实现必须接受的验收大小**。未来应分别
  验证限额内正文的整次期限、超限提前拒绝和取消后的实际 I/O 收敛；不能把原
  无界 transport 的这份反例直接当作新 SDK/有界实现的完整验收。

相关原 request/launch/receipt/result、实际工具终态和 79 项派生读取记录保持在
[既有元数据目录](../id17-body-deadline-r1-root-20261023/)；本次没有修改其中任何文件。
原说明见[身份正文时限验证](../../reviews/identity-body-deadline-verification-20261023.md)。
`inventory.json` **只列本新目录的内容**，明确排除自身以避免循环哈希。
旧 11 + 新 23 的合并精确暂存清单另存于本任务 cache review，供 Root 独立读回。

## 有限敏感信息核对

本次复制前检查了全部 20 份指定原件，未发现私钥、典型实值访问键、JWT、Bearer
或凭据赋值；XML 敏感命名属性在此前独立审核中为空。机器绝对路径、类路径、
进程号和已移除环境变量的名称属于执行元数据。没有复制真实 provider 配置、
凭据文件、`.env`、`.local`、JDK/Maven 或依赖缓存。本结论为限定原件文本检查，
不能代替所有可能形式的秘密审计。

## 原件绝对路径与 SHA-256

| 本目录文件 | 可靠源绝对路径 | 原件与副本共同 SHA-256 |
| --- | --- | --- |
| `xml/TEST-com.aimanager.identity.AliyunSmsTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.AliyunSmsTest.xml` | `ab9da01686d78a6e70eadf1f3007c1ba79d13285eb7c5f809f93983c76d77215` |
| `xml/TEST-com.aimanager.identity.ConsumerAccountFlowTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ConsumerAccountFlowTest.xml` | `db907d16f5fa93f180cb3d1b7c8fe8b64d9a8c57019b43e62c8d969724b08206` |
| `xml/TEST-com.aimanager.identity.ConsumerAccountSpiPackagingTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ConsumerAccountSpiPackagingTest.xml` | `d059f56c8514a36c3e883faef5abe8797e7a0b51c6bd42a4da09ae12ad81622d` |
| `xml/TEST-com.aimanager.identity.ConsumerAccountStatusTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ConsumerAccountStatusTest.xml` | `c3590ee1ecd3a4df7b284c793cde3a4fa7844bc4b03131f20949cc2683c38b37` |
| `xml/TEST-com.aimanager.identity.ConsumerAuthenticatorTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ConsumerAuthenticatorTest.xml` | `f02721b8260c0ea942ebaace269afbc2941e82ef1177b7e7447339514e2bb0dd` |
| `xml/TEST-com.aimanager.identity.ConsumerClaimsSerializationTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ConsumerClaimsSerializationTest.xml` | `9883c0c1501f15e4d51aaf179613525f867105381b9c7ddcae46b9fec3d63398` |
| `xml/TEST-com.aimanager.identity.ConsumerConfigurationTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ConsumerConfigurationTest.xml` | `32b0e4d0a89d3ed836d2ab8b60347baefacd4bf630eea90299524440d5760e82` |
| `xml/TEST-com.aimanager.identity.ConsumerHttpClientReuseTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ConsumerHttpClientReuseTest.xml` | `b10ceb6a5966dc89cbafb52049590269f25bd4d5e1996f3cd488184164b84986` |
| `xml/TEST-com.aimanager.identity.ConsumerIdentityTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ConsumerIdentityTest.xml` | `6c27262695e4cd6fd7413f97074bbf0c29c8333e85339d0b8c117e8c86e85b42` |
| `xml/TEST-com.aimanager.identity.ConsumerIdentityTransactionsTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ConsumerIdentityTransactionsTest.xml` | `a8e6a5c652b76c0ccb1e9b502273ff5fddd1e45e35b22a3f5281b549332b076c` |
| `xml/TEST-com.aimanager.identity.ConsumerProviderRuntimeTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ConsumerProviderRuntimeTest.xml` | `f0333a71ce0cdd72988ad3de35ba601daada9e4e4090f753349315c221890adf` |
| `xml/TEST-com.aimanager.identity.ConsumerRuntimeSnapshotTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ConsumerRuntimeSnapshotTest.xml` | `ff2efd21fac5b13137419149c134e92c4cb6fc2462cc494938ae19f7dabbbb04` |
| `xml/TEST-com.aimanager.identity.PhoneOtpTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.PhoneOtpTest.xml` | `3b1e933f936e6b9ea1594025bf2024959fbef3b247102aa7fef9afa8cddeeccb` |
| `xml/TEST-com.aimanager.identity.ProviderHttpBodyDeadlineTest.xml` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\src\identity-extensions\target\surefire-reports\TEST-com.aimanager.identity.ProviderHttpBodyDeadlineTest.xml` | `8d388b31effd82509a66dae14d59f42b405fcbf32def6d7afc5547529aff714c` |
| `logs/maven.log` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\out\maven.log` | `a9bee8b94e2a1ec924354b633600bc1310909954acc0f733d1eca66e589b4655` |
| `logs/worker-console.log` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\attempt\worker-console.log` | `a237b9afc623e19c260a0acbb48626eae90a99d6d7bcdd78c6be509326f5d245` |
| `source/ProviderHttpBodyDeadlineTest.java` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\overlay\ProviderHttpBodyDeadlineTest.java` | `ad76aaae45c356d2fe4b54c188d8e0fdc9a471d99dde8f84b571dd4a5f9e50f5` |
| `execution/proposal.json` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\proposal.json` | `937366e2d31ed718c751688cc678cd888b5ad478e53c5f903c198f2218535175` |
| `execution/expected-tests.json` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\expected-tests.json` | `fabb53756ecd38de1c9b04f860cf5e76be471d86163b225a5ed789a0d998e629` |
| `execution/source-anchor.json` | `D:\codes\mobile\ai-manager\.cache\id17-body-deadline-20261021-r1\source-anchor.json` | `1d1cbed14d5bfc1fb962b6cbe9d52c60b81b54849bb6100b52b86e23902d73a2` |
