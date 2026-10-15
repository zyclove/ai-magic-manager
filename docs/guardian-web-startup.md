# 管理台启动体验（1.0.0）

## 日常启动

运行 `scripts/start-active-console.ps1`，入口会读取已提交的本机版本并启动对应服务。当前入口为 <http://localhost:18101/>。

本机 Docker Desktop 的 Linux 引擎未运行时，普通启动会调用官方启动命令并等待，最长 120 秒，然后重新检查所选服务。`-CheckOnly` 只检查状态；远程 Docker 上下文或显式 `DOCKER_HOST` 需要由操作者处理连接。

账号验证继续通过同源身份服务完成。页面启动直接使用 Flutter 原生加载器，不等待后台缓存注册；已有浏览器存储和缓存保持原样。首次打开、刷新、登录返回都使用同一启动方式。

## 修复依据

本机 Flutter 3.22.2 的 `--pwa-strategy=none` 产生空的 worker 文件，而默认启动模板仍传入 `serviceWorkerSettings`。浏览器中已观察到两次 `prepareServiceWorker` 等待超过 4000 毫秒的警告。空 worker 并不能单独证明超时原因，但管理台停用后台缓存时，没有必要经过注册等待。

自定义 `web/flutter_bootstrap.js` 保留 Flutter 加载器和构建配置模板，调用 `_flutter.loader.load()`。这也是 [Flutter 官方初始化文档](https://docs.flutter.dev/platform-integration/web/initialization) 提供的基本启动方式。

## 回归检查

使用 Node 内置测试运行器，执行真实 Flutter 加载器，仅对浏览器边界提供受控替身。覆盖未响应的注册、已有 worker、缺少 worker API、子路径部署及正常引擎初始化。旧实际发布脚本先验证失败，新模板及新正式产物再验证通过。

```powershell
$env:FLUTTER_SDK = 'D:/softwares/flutter'
node --test scripts/tests/test_guardian_bootstrap.mjs
python -m unittest scripts.tests.test_start_active_console scripts.tests.test_console_activation -v
```

设置 `GUARDIAN_BOOTSTRAP_ARTIFACT` 可直接检查正式构建的 `flutter_bootstrap.js`；设置后无需替换模板。缺少输入文件或 SDK 是测试配置错误，不能算作有效的回归失败证据。

实际发布还需核对浏览器加载、刷新、登录回调、控制台和 HTTP 返回的 bootstrap 文件散列。页面速度受机器和网络影响，取消注册等待不能等同于保证所有场景固定提速四秒。构建、继承的后端验收与本轮新验收应分别记录。
