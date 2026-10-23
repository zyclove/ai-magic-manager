# 批量选择器 Root 独立静态复核

候选 SHA256 9efcda7088e2937a6d63a3375b2195f239567c94631acb17158e25342eb6feea。
Root逐段读回新筛选/确认和完整UI，并与原scope、生命周期、load校验和cursor语义比对；未发现本增量的静态阻断。

- 新搜索、清空和筛选动作重查current；其条件保留active/current route及Owned availability。
- toggle仍即时核对50台，confirm新增非空/50及当前loaded id/registration/ACTIVE复查；不会靠旧按钮的enabled判定完成。
- 搜索不改变devices或跨页selected；load仍校验响应/去重并保留cursor失败恢复。分页按钮在过滤列表之外。
- 撤权内容隐藏、定向Owned finish、宿主scope/版本/registration/请求key与后端原子校验保持。
- 新controller/focus各dispose一次；scrollable标准对话框内为min Column与有限高lazy列表，没有旧固定头部+Expanded争抢。

全部未格式化/编译/测试/渲染。静态观察不证明物理交互、所有短屏或接口旅程成功。
