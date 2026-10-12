# 网站与内容安全：执行适配器准入契约

更新：2026-10-12。首发范围为中国大陆机构合同，家庭自有设备并行规划。此文规定下一阶段网站过滤如何接入和验收；当前代码只有 `DOMAIN_ACCESS` 规则、签名配置与可解释展示，**没有**跨应用网络过滤、受控浏览器或内容分类执行器。

## 1. 产品承诺按执行范围分开

| 模式 | 允许声明的能力 | 不得声明的能力 | 上线证据 |
|---|---|---|---|
| 机构受管网络/浏览器 | 经合格 EMM、OEM 或客户网络提供方确认的设备、浏览器、SSID/网络范围内的域名策略 | 未覆盖的应用、蜂窝/其他网络、HTTPS 路径和媒体应用内部内容 | 提供方资格、合同、目标设备绑定、策略版本、设备/网络实际执行与旁路测试 |
| 家庭 BYOD 本地 VPN | 用户单独授权并保持连接时，已验证流量范围内的域名级过滤 | 防卸载、防强制停止、所有 VPN/DoH/代理旁路，或用户撤销后仍持续过滤 | 系统授权、当前连接状态、冲突/撤销处理、离线重启及机型矩阵 |
| 应用内受控浏览器 | 仅在浏览器自身完整请求路径已验证后，声明该浏览器内的导航限制 | 对设备其他浏览器、应用或全设备流量的限制 | 主导航、重定向、POST、子资源、Service Worker、外部 Intent 与文件方案逐项验收 |

界面分别呈现 `CONFIGURED`、`PROVIDER_ACCEPTED`、`DEVICE_OBSERVED_ACTIVE`、`STALE`、`UNSUPPORTED` 和 `USER_DISABLED`。配置或提供方 HTTP 成功都不能显示“网站已被拦截”。未获授权、网络切换、VPN 被替换、提供方超时或设备长时间离线时，状态退回未知/失效；不把未知展示为安全。儿童侧给出具体原因与监护人恢复入口。

## 2. 为什么不直接把 WebView 导航回调当过滤器

Android 的 `WebViewClient.shouldOverrideUrlLoading` 并不覆盖所有请求；官方文档指出它不处理部分方案和 POST，请求重定向也存在回调范围限制。`shouldInterceptRequest` 仍不覆盖 `javascript:`、`blob:` 和部分本地资源；Service Worker 另有 `ServiceWorkerClient` 请求路径。因此仅用 Flutter WebView 导航回调加域名白名单，不能成为安全浏览器的执行证据。[WebViewClient 官方接口](https://developer.android.com/reference/android/webkit/WebViewClient)、[ServiceWorkerClient 官方接口](https://developer.android.com/reference/android/webkit/ServiceWorkerClient)。

`webview_flutter` 是优先评估的官方 Flutter 插件，但现行最新版的最低 Dart 版本高于本仓库声明的 Dart 3.4 基线；接入须先锁定与项目 Flutter/Dart、Android 最低版本和可用 WebView 实现兼容的维护版本，并完成上述原生请求路径验收。[插件版本与支持范围](https://pub.dev/packages/webview_flutter/versions)。Google WebView Safe Browsing 可提供已知威胁提示，但其可用性依赖设备 WebView 环境；它不是本产品自定义类别规则的替代品，也不能作为中国大陆所有型号均可用的默认假设。[Android WebView 安全浏览说明](https://developer.android.com/develop/ui/views/layout/webapps/managing-webview)。

首发不交付一个只能拦截主导航、却命名为“安全浏览”的入口。若选择浏览器路径，先完成 URL/请求范围、沙箱、下载/上传、证书错误、外部跳转、Cookie、历史清理、遥控器焦点和设备资源预算的设计及真机验收。

## 3. 可替换适配器与数据契约

`DOMAIN_ACCESS` 保持规范 ASCII 域名和 `ALLOW`/`DENY` 意图；当前没有隐式子域名或 URL 路径语义。未来执行器需显式声明 `adapterId`、版本、设备模式、网络/浏览器作用域、支持的规则类型、当前授权、最近检查时间及限制原因。服务器发布不可变策略版本，适配器只接受与当前租户、设备和注册周期一致的已验证版本。

执行记录至少区分请求 ID、策略版本、设备注册周期、适配器版本、发送时间、提供方接受时间、设备/网络观测时间、结果和限制代码。重复命令幂等；旧版本、过期命令和撤销后的回执只入历史，不提升当前状态。失联时沿用已验证的最后策略且不自动延长临时例外；失效判断由该模式实际可获得的时间与状态证据决定。

过滤诊断默认只保留规则 ID、规范化域名或受控摘要、命中类别、动作、时间和关联 ID；不采集完整 HTTPS URL、查询参数、页面正文、搜索词、Cookie 或原始浏览记录。类别规则必须记录来源、许可证、版本、更新时间、误报申诉与回滚。供应商不可用时不得把未知域名静默判为“已安全”。

## 4. VPN 与机构首发门槛

Android `VpnService.prepare()` 需要当前用户授权；同一用户只有一个已准备的 VPN，已有安全 VPN 与本产品会冲突。用户可停用 VPN。Always-on 可由用户设置；设备/资料所有者才能通过受管 API 配置 Always-on 与 lockdown。普通 BYOD 应用不能自行承诺重启后不可停用或不可绕过。[VPN 开发指南](https://developer.android.com/develop/connectivity/vpn)、[VpnService 官方接口](https://developer.android.com/reference/android/net/VpnService)、[DevicePolicyManager 官方接口](https://developer.android.com/reference/android/app/admin/DevicePolicyManager#setAlwaysOnVpnPackage(android.content.ComponentName,java.lang.String,boolean))。

中国大陆机构签约前先选定可用的合格 EMM/OEM/网络提供方，核对权属、数据处理、许可证、目标型号和客户网络条件。没有合作方时保持过滤功能不可售；已保存的域名规则只作配置意图展示。网站分类、安全搜索与平台内媒体评级分别验收，不把域名命中推断为页面内容识别。

## 5. 进入开发的最小验收矩阵

1. **权限与范围：** 管理员、儿童、失权成员及跨租户访问；设备重注册、策略撤销和紧急恢复；用户授权、拒绝、撤回和 VPN 冲突。
2. **域名语义：** 精确域名/子域名、IDN、IP 直连、端口、重定向、DoH、QUIC、IPv6、CDN 共用域、缓存和离线策略；每项报告支持、未知或旁路。
3. **浏览器路径：** GET/POST、iframe/子资源、Service Worker、`blob:`/`file:`、新窗口、下载、外部应用跳转、证书错误、混合内容与 TV 遥控器操作。
4. **执行证据：** 提供方接受与设备实际应用分离；多版本乱序、重复回执、长时间离线、重启、升级、OEM 差异和恢复失败，均保持不夸大的状态。
5. **隐私与运营：** 不记录完整浏览内容；类别库许可与更新失败、误报纠错、申诉、限流、容量、客户支持及地区审查通过后，才允许标记生产支持。

