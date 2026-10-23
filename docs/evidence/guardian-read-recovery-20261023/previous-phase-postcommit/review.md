# 操作体验阶段提交独立回读

**结论：提交与固定 74 文件计划精确一致，未发现整合字节或范围阻断。全部本阶段应用交互仍 UNRUN，未渲染。**

- HEAD `7cf2b2b9960db98f90a7f7630ae967e3ea99eba8`，唯一父提交 `e303580030192497a63492d1147156e465082706`。实际提交路径恰为计划的 74 项：3 个生产文件、71 个文档。
- 一次 `cat-file --batch` 读取全部 74 个 HEAD 原始 blob；每项字节、SHA-256、Git blob SHA-1 均等于 Main 与 stage-pins。三生产文件也逐项匹配最终 integration-manifest。
- 归档恰 70 件，最终清单 69 条加自身；51 份 selected 原件/前后描述/归档副本逐字匹配（295465B）。原 manifest 的历史 selected 范围和状态保留，后加 Subject 等由最终 integration-manifest 补充。文档实际相对 Markdown 链接均可解析。
- index 为空。唯一保留的 tracked 工作区修改为 `docs/managed-publication-admission-plan.md`，原始 SHA-256 为 `4994781cf65a736611e648fe693d0bec9b5aef6cc4315b818a036447dff22d9d`，未入此次提交，其 HEAD 原始内容仍与父提交一致。
- r10 仍是旧 e303 输入的 NOT_ACCEPTED、SDK 调用 0、Root 自然 exit1 且未强制、记录释放窗口；未将其提升为新源码验证。完整 181 回归入口仍待跑，80 浏览器用例仅为子集，四项无 SDK 宿主资格不代表应用通过。

本次只做本地文本/JSON/哈希及只读 Git 回读；未执行 SDK、测试、AST、候选/谓词、进程或网络操作，未写 Main/Git/旧原件。详细计数、三源及固定计划指纹见 `readback.json`。
