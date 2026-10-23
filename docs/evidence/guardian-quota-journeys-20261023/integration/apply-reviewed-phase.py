"""Apply one explicit static-reviewed six-source plan and archive selected evidence.

This runs only text/hash/JSON/diff/Git-read operations. It does not execute the app.
"""
from pathlib import Path
import hashlib, json, subprocess

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.cache/guardian-quota-journeys-application-20261023'
SELECTION = WORK / 'integration-selection.json'
selection = json.loads(SELECTION.read_bytes())
BASE = 'bb93c0b0bacfea622e50828e635aa61d738f342b'
FOREIGN = 'docs/managed-publication-admission-plan.md'
FOREIGN_SHA = '4994781cf65a736611e648fe693d0bec9b5aef6cc4315b818a036447dff22d9d'
ARCHIVE = ROOT / 'docs/evidence/guardian-quota-journeys-20261023'
REVIEW = ROOT / 'docs/reviews/guardian-quota-journeys-20261023.md'
for fixed_path in (WORK, SELECTION, ARCHIVE, REVIEW):
    assert fixed_path.resolve().is_relative_to(ROOT)
assert selection['parent'] == BASE and selection['allApplicationScenarios'] == 'UNRUN'
assert not ARCHIVE.exists() and not REVIEW.exists()

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def checked_path(relative):
    path = (ROOT / relative).resolve()
    assert path.is_relative_to(ROOT)
    return path

def pin(path, relative=None):
    raw = path.read_bytes()
    return {'path': relative or path.relative_to(ROOT).as_posix(), 'bytes': len(raw),
            'sha256': hashlib.sha256(raw).hexdigest(),
            'gitRawBlobSha1': hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()}

def verify(row, parent=ROOT):
    path = Path(row['path'])
    path = path if path.is_absolute() else parent / path
    path = path.resolve()
    assert path.is_relative_to(ROOT), path
    actual = pin(path)
    assert actual['bytes'] == row['bytes'] and actual['sha256'] == row['sha256'], path
    return path

def write_json(path, value):
    assert not path.exists()
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')

assert git('rev-parse', 'HEAD').decode().strip() == BASE
assert not git('diff', '--cached', '--name-only')
assert set(git('diff', '--name-only').decode().splitlines()) == {FOREIGN}
assert pin(ROOT / FOREIGN)['sha256'] == FOREIGN_SHA

# Bind every accepted report/candidate artifact before touching a source file.
for row in selection['approvedInputs']:
    verify(row)
for row in selection['deliveries']:
    path = verify(row)
    data = json.loads(path.read_bytes())
    expected = set()
    for descriptor in data['files']:
        member = verify(descriptor, path.parent)
        assert member.parent == path.parent
        expected.add(member.name)
    actual = {p.name for p in path.parent.iterdir() if p.is_file()}
    assert actual == expected | {path.name}, (path.parent, actual, expected)

source_rows = selection['sources']
assert len(source_rows) == 6 and len({r['path'] for r in source_rows}) == 6
expected_sources = {
    'apps/guardian/lib/pages/quota_page.dart',
    'apps/guardian/lib/pages/quota_plans_page.dart',
    'apps/guardian/lib/pages/quota_plan_editor.dart',
    'apps/guardian/lib/pages/console_pages.dart',
    'apps/guardian/lib/ui/resource_page.dart',
    'apps/guardian/lib/ui/view_lifetime.dart',
}
assert {r['path'] for r in source_rows} == expected_sources
assert {r['path'] for r in source_rows if r['before'] is None} == {
    'apps/guardian/lib/ui/view_lifetime.dart'
}
for row in source_rows:
    target = checked_path(row['path'])
    after = verify(row['after'])
    if row['before'] is None:
        assert not target.exists()
        assert row['path'] == 'apps/guardian/lib/ui/view_lifetime.dart'
    else:
        before = verify(row['before'])
        assert target.read_bytes() == before.read_bytes() == git('show', BASE + ':' + row['path'])
    assert after.is_relative_to(ROOT / '.cache')
for descriptor in selection['patches']:
    patch = verify(descriptor)
    subprocess.run(['git', 'apply', '--check', str(patch)], cwd=ROOT, check=True)

for row in source_rows:
    checked_path(row['path']).write_bytes(checked_path(row['after']['path']).read_bytes())
for row in source_rows:
    assert checked_path(row['path']).read_bytes() == checked_path(row['after']['path']).read_bytes()

tracked_expected = {r['path'] for r in source_rows if r['before'] is not None} | {FOREIGN}
assert set(git('diff', '--name-only').decode().splitlines()) == tracked_expected
assert pin(ROOT / FOREIGN)['sha256'] == FOREIGN_SHA
assert not git('diff', '--cached', '--name-only')

ARCHIVE.mkdir()
copies = []
for row in selection['archive']:
    source = verify(row)
    destination = ARCHIVE / row['archivePath']
    assert destination.resolve().is_relative_to(ARCHIVE.resolve()) and not destination.exists()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(source.read_bytes())
    copies.append({**pin(destination), 'original': row['path']})
selection_copy = ARCHIVE / 'integration-selection.json'
selection_copy.write_bytes(SELECTION.read_bytes())
copies.append({**pin(selection_copy), 'original': SELECTION.relative_to(ROOT).as_posix()})

receipt = {
    'status': 'SIX_REVIEWED_SOURCES_APPLIED_STATIC_ONLY', 'parent': BASE,
    'sources': [pin(checked_path(row['path'])) for row in source_rows],
    'sourceSelections': source_rows, 'approvedInputs': selection['approvedInputs'],
    'selectedArchiveOnly': True, 'copiedEvidence': copies,
    'notAnEntireCandidateDirectoryOrSourceClone': True,
    'foreignTrackedWip': {'path': FOREIGN, 'sha256': FOREIGN_SHA, 'preserved': True},
    'allApplicationScenarios': 'UNRUN', 'newTestCasesAdded': 0, 'testSourcesChanged': 0,
    'sdkFormatterAstCompilerOrApplicationTestsRun': False,
    'rendered': False, 'deployed': False, 'pushed': False,
    'freshExecutionInputRequiredBeforeFutureSdkValidation': True,
    'goalComplete': False,
}
write_json(ARCHIVE / 'integration-receipt.json', receipt)
REVIEW.write_text('''# 额度管理操作链完善（2026-10-23）

## 本阶段改动

- 额度列表、重复计划、日历、详情、账本与历史均绑定最初的页面和工作空间。权限或身份变化后，旧窗口隐藏内容并拒绝旧操作。
- 查看账本、计划历史后返回原详情，减少重新查找。
- 取消调整额度保留原详情；保存成功才结束原详情并由列表刷新。
- 重复计划保存和取消使用所属窗口；合法保存完成时保留盖在上面的其他窗口。
- 日期例外继续使用完整 Material 日期选择器，保留日历与手工输入；子流程增加操作锁和所属窗口检查。
- 原请求标识、版本校验、不确定结果的原内容重试、七天额度秒数、时区与生效日期规则保持。

## 范围与证据

本阶段为六个产品源文件（五修改、一新增），不修改测试、后端、依赖或服务。复用现有 Material、DialogAccessBinding、DeviceSubflowScope、OwnedDialogRoute。证据目录保存选定的完整补丁、作者及独立静态审阅、指纹和整合记录；它不是整个候选目录的副本。QuotaPage 的 CRLF 转 LF 如实记录在审阅中。

本地静态整合只核文本、指纹、Git 原始字节及明确的跨文件接口，不执行产品代码。新操作的顶层窗口检查与已接受请求的持续归属分开，合法覆盖不会被误当成撤权。

## 未验证项

全部应用场景仍未运行，未渲染、未编译、未部署、未推送。当前源代码需要在内存和验证窗口恢复后重新封存输入，再进行完整验证；既有历史通过结果不代表本轮通过。

后续仍需完整 181 个前端根项（80 项为关键子集），本轮新增的窗口/工作空间/取消返回场景、身份验证 98 测试与 14 类、后端联合验证以及真实设备与服务验证。日期桥的布局、输入切换、键盘、返回、焦点和读屏尤其需要实际检查。

全项目完善目标继续进行，本阶段提交不是上线验收。
''', encoding='utf-8', newline='\n')
archive_files = sorted(p for p in ARCHIVE.rglob('*') if p.is_file())
write_json(ARCHIVE / 'manifest.json', {'status': 'SELECTED_STATIC_EVIDENCE_ARCHIVE',
    'files': [pin(p) for p in archive_files], 'selfExcluded': 'manifest.json',
    'allApplicationScenarios': 'UNRUN'})
all_files = [checked_path(row['path']) for row in source_rows] + [REVIEW] + sorted(p for p in ARCHIVE.rglob('*') if p.is_file())
write_json(WORK / 'stage-pins.json', {'parent': BASE, 'files': [pin(p) for p in all_files]})
assert len({p for p in all_files}) == len(all_files)
print(json.dumps({'status': 'APPLIED_AND_EXACT_STAGE_PLAN_PREPARED_UNRUN',
    'sourceFiles': len(source_rows), 'archiveFiles': len(archive_files) + 1,
    'stageFiles': len(all_files), 'stagePlan': pin(WORK / 'stage-pins.json'),
    'foreignWipPreserved': True, 'testsRun': False, 'deployed': False, 'pushed': False}))
