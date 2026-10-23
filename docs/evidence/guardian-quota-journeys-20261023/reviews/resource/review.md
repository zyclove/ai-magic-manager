# ResourcePage.canInteract 最终单文件独立静态审阅

## 结论

最终六件交付未见静态阻断。完整 460 行 after、8-hunk 差异、作者 review 和最终 metadata 均已读回。after 18737B SHA256 50ca974f0b792c77d493eaf4d17c83dbe250550ac5035ae1fbd148a5758f0360；delivery.json 848B SHA256 169ebe39524cc277ae54c8dc63edd24aae83ca1e225044d9ae2e731e7e9e4be4。

所有场景 UNRUN、未渲染，人工类型合理性不是 Dart 分析或编译证明。本结论只覆盖此文件及固定 caller 合同，不预填 Editor、QuotaPage 或全体兄弟候选通过。

## 新交互与已接受完成分离

- 24/41 新增可选 bool Function()? canInteract，63 的 _canInteract 先核 mounted/owner，再核当前交互 predicate。null != false 保留旧调用者省略 hook 的默认行为。
- clearSearch:94 和 action:167 在状态、控制器/焦点及 callback 操作前增加交互门槛。viewCurrent:204–207 仍保留原 epoch/path/API/permitted，并核当前与原捕获的 interact。
- 原 create/onOpen/reauth 捕获及处理器 identical 检查保持。两处 create、三种行打开、五处 fresh refresh/retry、append、search/clear 和四处 reauth 都继续通过事件守卫，因而统一受新 hook 限制。
- refreshRecords 仍实时复查 loading/acting，append 仍复查 loading/more/acting/cursor；TextField 新增 enabled:_canInteract。部分覆盖后的控制保留原视觉 enabled 状态，但其 guarded callback 会拒绝新事件；不声称所有控制视觉均禁用。
- load:100–164 与 bb93 before 逐字相同，仅核 owner/请求代次，不读取 hook。init、明确 fresh supersede append、内部必要读取都不被新交互门槛拦住。
- action 入口之后逐字不变。current() 仍只核 mounted/原资源代次/原 permitted；callback 后的 await load、错误及 finally 没有 canInteract。合法 action 进入后被 cover，仍可在 owner 有效时完成和回读；临时非 top 不等于撤权。
- canAct 加交互条件；搜索、过滤、选择状态、payload、Api.page 与 HTTP 协议均未改。

## Caller 和类型合同

已审 Plans 草稿 621d3f71…3fdd 的两处使用吻合：列表 isCurrent=current、canInteract=onTop；history isCurrent=原 owner/binding/route.available/isActive 的 accepted，canInteract 另核 route.isCurrent。有效 covered GET 可以完成，covered 旧用户事件被拒绝。

canInteract 应表达可恢复的新交互资格，不并入 isCurrent/Api.scoped/写后检查。owner 撤销或祖先关闭仍由不可复活的原 scope/lifetime 负责；返回原 route 可恢复交互，不能复活失效 owner。原 handler、原 hook 和当前 hook 的检查仍在实际事件前进行。

新 nullable bool callback、构造参数、getter 与现有 VoidCallback 适配未见手工类型不匹配；State 方法签名不变。外部 toolbar/ColumnSpec 仍由宿主负责；任意不遵守 owner 合同的 caller、所有日期/路由竞态不在本轮证明范围。

## 原件证据与边界

精确 6 文件成员、5 delivery pins、4 metadata 文件 pins、6 baseline dependencies 指纹均匹配；pins.json2331B/19cc9a22…3fdf2 与 Root 指定一致。before 与 Main bb93c0b 的 raw Git blob c522ca2a9399c25c2cda6b8c99b4f3e12892bb8d 相同。

完整补丁重建 after 每个字节；十处精确局部文本逆替换恢复 before 每个字节。load 全文不变；action 除入口一行外不变。现有资源回归文件仅只读/pin，未新增或修改测试。

仅文本/hash/JSON/只读 Git 及自有报告写入；未执行候选、业务谓词、AST/Dart 解析器、SDK/测试/formatter、进程检查/WinAPI/网络。Main/Git、草稿/封存原件和测试未写，不授执行资格。
