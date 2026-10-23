# Guardian r9 / e303580：源码输入独立静态回读

## 结论

约定字节与范围内未发现阻断。固定输入绑定 e303580030192497a63492d1147156e465082706；所有应用分析、测试及渲染仍 UNRUN。本次不运行准备脚本，不产生 SDK 执行资格或新验证包。

## 实际核对

- seal 425 个描述项、包含 seal 的 426 文件精确库存、delivery 423 项及其三项排除规则均匹配；末次全量复核无漂移。
- 七 roots 的 410 文件 / 3,998,096B，全部 frozen raw SHA/Git blob object 身份、实际 HEAD 路径/mode 与 Main raw/LF 对照一致；七 Git root tree 匹配。仅原 quota_balance.dart 与 Guardian pubspec.yaml 有 CRLF 原始字节差异，逐项 LF 比较无差异。
- r8→r9 为 8 个生产文件修改、1 个新 ViewLifetime helper、1 个既有测试文件修改，400 个源码不变、无删除；逐项 delta before/after 与真实 manifest 相符。helper 为既审 1068B/c68c7457…9815。
- 7 selectors / 80 可见名称、loopBinding、declarationLine 以及 8/4/19/7/8/21/13 分组与 r8 相同。六个 selected 源码及完整元数据不变；notification_help_scope_browser_test.dart 唯一重绑定源码 pin，537 行中只在 361–363、371–372、375 改注释/断言。六条声明的各八行区块、原两项 loss 循环文字、七项展开声明元数据保持。没有重新调用 AST、名字解析器或运行时发现；这不是测试通过证明。
- 全 181 个回归入口均对真实 Main raw/Git 身份核对：142 Guardian、37 package、2 独立 live-HTTP tools。180 行完全不变，notification 一行仅更新源码身份和 baseline-match 标记，路径/类别/执行状态保持。28 个额外包测试仍在完整计划中、确为 tracked Main，未复制进七-root 410 快照；不能把该快照称为覆盖全部181的执行包。两项 HTTP 工具仍需另外显式 fixture/preflight。
- package_config 70 行，生成模板与候选配置逐字一致；仅7内部 root URI 重绑，其余字段与 Main原配置/旧快照一致，63外部行不变。依赖元数据只改7个 proposed internal URI，所有历史 libraryTrees/错误记录保持。未读取外部 cache payload，没有 fresh runtime/cache closure 或可执行性结论。
- 37 个源码目录、全部 tracked 路径和唯一额外生成 package_config 路径一致。所有主要 pins 与 Root 给定值一致。

## 固定指纹

- seal：80882B / 8fcfa6a49ecec81a1a5eb2f9449234abfd1c5622a8b84f7adebd77f7d813c03c
- manifest：245064B / 4ca3c2285abcfdb27b877fa39ad956cfbc2a372655591bc3c61710b43f4bfa14
- delivery：79489B / e2d76096b90d9140284664f2d7104f3e4d0bd5e9e79a0ad6a8fa543e5b4c612b
- source tree：6b7db8abb07a71682010f2735098387057e018afe6657766617cf2f73ca54fd2

## 边界

独立固定读取器仅做本地文本/hash/JSON及 rev-parse/ls-tree 只读 Git（d1f270 natural exit0）；未执行候选、prepare、名字 helper、业务/资格谓词、SDK、测试、AST/解析器/编译/formatter、进程检查/WinAPI 或网络，Main/Git/原件未写入。该 exit0 是静态核对完成，不是应用运行结果。

四项无SDK资格的后续实际证据另有独审，不能追写本快照准备时的历史状态，也不自动启用其 sdkAllowed=false 控件或当前 SDK方案。critical80 只属完整181计划的子集，平台分类仍是静态继承；全部应用验证 UNRUN。