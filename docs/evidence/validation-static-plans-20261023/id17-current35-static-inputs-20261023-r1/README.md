# identity 当前35/98离线输入静态计划

状态：**UNCOMPILED / ALL98 UNRUN / NO EXECUTION GRANT**。未创建新 controller/worker，没有运行 Java、javap、Maven、SDK、编译器或测试。

- commit `a2b5ca6ef2398397e4208065090b7c1d65992358`；module tree `96ab1e0f33eb3696fd715bfe482b9708ce6869e4`；Git HEAD/index精确35文件、Main模块状态为空。
- `src/identity-extensions` 是35个精确Git归档blob：14 main Java、14 test Java、4 SPI/CDI资源及README/POM/settings。每个Main raw均核对Git；LF差异单列，不回写Main。
- 14测试类精确98个@Test方法名仅经注释/字面量屏蔽的静态词法提取。原76名字全部保留、新Provider22；旧3个4MiB overlay测试不纳入，当前提交自己的尺寸/时限/取消测试完整保留。
- 当前POM Main raw4713B/SHA73c7fe28469d1a06e4278ec6e63317d8ae9bdb6ba070bb9b1fdc41a38f680722；Git规范LF4607B/SHA28f16e1bf4f68048034dbcc585696c85a2699f04b07c02b98326463ea8032a2c。106处CRLF解释长度差异，与旧逻辑POM相同；绝不把旧4607当当前raw或回滚依赖。
- 模块无parent，仓库根无父pom.xml。仅冻结直接依赖/插件/历史resources插件及其父链的43份POM文本；逐份匹配既有3788缓存metadata。不等于完整Maven有效模型/传递依赖解析或缓存新鲜验证。
- `out/static-plan.json`列旧controller/worker精确原pin与必须调整行号；此轮未改任何硬编码。旧33baseline+1overlay须改为完整35，13main须14，79cases须98，33 JAR classes须预期35，保留4资源/Java17/零跳过/无selector/完整verify。
- 180总预算、174工作截止、60预检、6收尾、512MiB及RAM/双盘2GiB门槛只作为继承待审参数，没有扩大或授予执行。98含至少三处5.1秒等待、两条约5秒实际时限和约5秒并发取消；旧79约50.114秒并不能证明当前98可在预算内完成。预算不足必须拒绝，不擅扩或拆减完整测试。
- 3788缓存只复用原metadata；没有全cache或runtime/JAR二进制复制。以后仍须新鲜完整输入/工具/缓存/资源门禁和独立窗口授权。

## 文件

- `out/source-manifest.json` / `out/main-raw-observation.json`：35 Git/LF/Main raw身份。
- `out/expected-tests.json` / `out/test-name-extraction.json`：98名字及行号，非JUnit发现/行为通过。
- `out/input-manifest.json`：可供后续机械接合的完整35源+原3788metadata，非新执行器。
- `out/required-pom-inputs.json` / `inputs/required-poms`：最小POM父链输入与边界。
- `out/inherited-control-pins.json` / `out/static-plan.json`：历史原pin、旧RED实际事实及具体控制差异。

旧body79的NOT_ACCEPTED和所有既有目录不改；35/98全部未运行，不作成功、SDK可用或完整预算足够的声明。
