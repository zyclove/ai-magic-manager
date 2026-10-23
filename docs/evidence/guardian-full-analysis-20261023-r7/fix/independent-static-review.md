# 观察授权页面：单字符静态修订复核

支持仅删除 observation_page.dart:31:52 的 `!`：右侧分支只会在 `observationRoute == null` 为 false 时执行，同一同步表达式中没有 await、回调或赋值；该次局部变量读取已由 null guard 排除空值。实际 r7 唯一诊断也明确为 unnecessary_non_null_assertion。

删后仍保留 scope.current、初始 null 分支及原 route.available 语义。有效/覆盖 route 可继续；finished/inactive route 仍拒绝。无需改成 `?.available ?? true`、isCurrent 或引入其他流程设计。

这是静态确认，不是 Dart 编译或测试通过。本轮没有改 Main/Git，也没有改旧 a558 快照或 browser80r1，未准备新快照/r2；后续由 Root 最小修订并重新提交后另行绑定。
