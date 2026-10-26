# Windows 私有进程验证

`owned_job.py` 为本任务原子创建私有 Job、保留根句柄，并按原期限判断自然退出。
成员只能来自同一 Job 的有界列表；首次通过同句柄成员及创建时间核验后，保留
只读成员句柄，后续仍核验同一 Job 和创建时间，不再次按 PID 打开。

最多保留 256 个成员或首次拒绝记录，不驱逐旧记录来获取通过。首次无法证明、
身份改变、查询失败或容量耗尽均拒绝；关闭时释放成员句柄并记录关闭错误。
缓存成员句柄只要求受限查询与同步权限，没有终止或内存读取权限。

以下文件由原合格版本逐字节移入源码管理，判定没有改动：

- `owned_chrome_evidence.py`：同 Job 身份、浏览器调试绑定、原始账本与终态判断。
- `chrome-evidence-json-guard.fragment`：完整浏览器证据校验。
- `worker-command-finality-hook.fragment`：原命令内的半秒终态事务。

纯模拟回归（不启动进程或调用真实 WinAPI）：

```powershell
python scripts/tests/test_owned_job_members.py
```

Windows 原生资格探针使用固定任务目录下的全新输出子目录，保留原 RAM、C、D
均至少 2 GiB 的门槛。它仅创建受控 Python 根和子进程，核对退出后的同句柄身份，
并调用原分类器及终态检查；不读取外部进程、命令行或子环境，也不启动 SDK：

```powershell
New-Item -ItemType Directory -Force .cache/retained-member-20261026-r1 | Out-Null
python scripts/verification/probe_owned_job_members.py --output .cache/retained-member-20261026-r1/native-next
```

探针通过不代替浏览器资格。后续浏览器驱动应固定这些源码的摘要，使用原证据
检查与期限，记录释放后的成员数和关闭错误；不能把旧的未通过记录改写为通过。
实际资格范围及原始输出见[本轮记录](../../docs/reviews/retained-member-20261026.md)。

保留句柄同时保留进程对象及编号的依据见[微软说明](https://devblogs.microsoft.com/oldnewthing/20110107-00/?p=11803)；
句柄在进程终止后仍有效，见[进程句柄文档](https://learn.microsoft.com/en-us/windows/win32/procthread/process-handles-and-identifiers)。
