# MySQL UTC 会话配置静态接合

默认连接与五处示例显式启用 Connector/J 原生 UTC 会话属性，保留账本超时和其余配置。外部 URL 覆写的要求见[配置说明](../../mysql-utc-session-configuration.md)。

**NOT_RUN / NOT_DEPLOYED**。只完成源文件和最小 HEAD 目标比较、独立静态审阅；没有实际建立连接、运行 SDK、测试、SQL、构建或更新服务。MySQL 会话/重连及 OceanBase 兼容性仍待独立验证。

head-target-manifest 分列 Main 来源与拟提交目标 SHA；application/compose 的其他工作树改动保留，未整文件混入提交。Root 已再次严格在内存应用三个补丁并核对目标字节。
