# 设备退出组件验收

此目录是明确标识的测试夹具页面，不请求业务 API、不持有用户会话、不操作真实设备。生产接入必须使用父目录库和真实管理台的 OIDC 会话。

运行 flutter pub get、flutter test、flutter build web --release --web-renderer html --no-web-resources-cdn 后，可用本地静态服务器查看 build/web。

场景：后果预览和显式确认；首次提交结果未知后的原键核对；设备自报清理但未经独立验证。夹具恢复记录只保存在内存，不代表浏览器重载或原生存储已经认证。

详见 ../../../docs/device-operations-ui-contract.md。
