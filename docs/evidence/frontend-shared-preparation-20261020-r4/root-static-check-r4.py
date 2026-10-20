"""Read-only source/spec review and exclusive evidence preservation; never execute the runner."""
from pathlib import Path, PurePosixPath
from datetime import datetime, timezone
from collections import Counter
import argparse
import ast
import hashlib
import json
import os
import re
import subprocess

ROOT = Path('D:/codes/mobile/ai-manager')
PREP = ROOT / '.cache/publication-recovery/frontend-shared-execution-preparation-r4'
OUT = ROOT / 'docs/evidence/frontend-shared-preparation-20261020-r4'

def require(value, message):
    if not value:
        raise ValueError(message)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key')
        result[key] = value
    return result

def read(path):
    return json.loads(path.read_bytes(), object_pairs_hook=unique)

def safe(path):
    return isinstance(path, str) and path and PurePosixPath(path).as_posix() == path \
        and not PurePosixPath(path).is_absolute() and '..' not in PurePosixPath(path).parts \
        and ':' not in path and '\\' not in path

def inventory(path):
    return dict(path=path.relative_to(ROOT).as_posix(), sha256=digest(path), bytes=path.stat().st_size)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runner-sha', required=True)
    args = parser.parse_args()
    initial_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip()
    require(initial_head == 'db18daa275a1098f497527697f8ff0a0808d5778', 'Base HEAD changed')
    require(not subprocess.check_output(['git', 'diff', '--cached', '--name-only'], cwd=ROOT), 'Index not empty')
    spec_path, input_path, runner_path = (PREP / p for p in
        ('execution-spec-r4.json', 'source-inventory-r4.json', 'run-frontend-r4.py'))
    require(digest(spec_path) == 'ce761ca34712352c1f36cb124f3cfcc444ce891ca2caa54fa93062b85256f0c0', 'Spec changed')
    require(digest(input_path) == 'cd45876f5dcfa40d8a1121243f589de61665a98ccf95382733bcbc4106e603bc', 'Inventory changed')
    require(digest(runner_path) == args.runner_sha, 'Runner changed')
    tree = ast.parse(runner_path.read_text('utf-8'), filename=str(runner_path))
    forbidden_calls = {'kill', 'terminate', 'terminate_and_wait', 'TerminateJobObject', 'TerminateProcess', 'taskkill'}
    require(not any(isinstance(node, ast.Call) and
        ((isinstance(node.func, ast.Attribute) and node.func.attr in forbidden_calls) or
         (isinstance(node.func, ast.Name) and node.func.id in forbidden_calls)) for node in ast.walk(tree)),
        'Runner contains a forced-termination call')
    spec, source = read(spec_path), read(input_path)
    rows = spec['selectedSources']
    pins = {row['path']: row['sha256'] for row in rows}
    require(len(rows) == len(pins) == 510 and pins == spec['mainSourceSha256'], 'Source pins not exact')
    require(pins == {row['path']: row['sha256'] for row in source['files']}, 'Inventory/spec mismatch')
    require(spec['baseCommit'] == initial_head and spec['schemaVersion'] == '1.0.0', 'Base metadata mismatch')
    require(len(spec['inputRoots']) == 13 and len(set(spec['projectRoots'])) == 14, 'Root counts differ')
    require(set(spec['projectRoots']) == set(spec['generatedProjectRoots']) ==
        {row['root'] for row in spec['projects']}, 'Project sets differ')
    require(set(spec['projectRoots']) == {p[:-len('/pubspec.yaml')] for p in pins if p.endswith('/pubspec.yaml')},
        'Pubspec projects differ')
    git_paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard',
        '--', *spec['inputRoots']], cwd=ROOT).decode('utf-8').split('\0')
    actual_paths = set(filter(None, git_paths)) - set(spec['mainExcludedIdeFiles'])
    require(actual_paths == set(pins), 'Tracked/nonignored actual source file set differs')
    for row in rows:
        relative = row['path']
        require(safe(relative) and row['sourcePath'] == relative and row['origin'] == 'CURRENT_MAIN', 'Source alias')
        path = ROOT / relative
        for part in (path, *path.parents):
            require(not part.is_symlink() and not getattr(part.stat(follow_symlinks=False), 'st_file_attributes', 0) & 0x400,
                'Source hierarchy contains a link')
        require(path.is_file() and path.stat().st_size == row['bytes'] and digest(path) == row['sha256'], 'Source bytes differ')
    targets = spec['formatDartPaths']
    require(len(targets) == len(set(targets)) == 437 and set(targets) == {p for p in pins if p.endswith('.dart')},
        'Whole-file format selection differs')
    require(spec['formatCommand'] == [spec['dartExecutable'], 'format', *targets], 'Format command differs')
    format_units = len(subprocess.list2cmdline(spec['formatCommand']).encode('utf-16-le')) // 2 + 1
    require(format_units == 22024 and format_units < 32767, 'Windows format argv size differs')
    require((spec['formatBudgetSeconds'], spec['preparationBudgetSeconds'], spec['runBudgetSeconds']) == (60, 180, 180),
        'Original budgets differ')
    by_path = {row['path']: row for row in rows}
    for project in spec['projects']:
        root = project['root']
        require(project['pubspec'] == by_path[root + '/pubspec.yaml'] and
            project['lock'] == by_path.get(root + '/pubspec.lock'), 'Project row does not bind source')
        content = (ROOT / root / 'pubspec.yaml').read_text('utf-8')
        require(project['framework'] == ('flutter' if re.search(r'^\s+sdk:\s*flutter\s*$', content, re.M) else 'dart'),
            'Framework differs from actual pubspec')
    stages = spec['stages']
    stage_map = {stage['id']: stage for stage in stages}
    require(len(stages) == len(stage_map) == 55 and Counter(s['kind'] for s in stages) ==
        dict(pub=11, analyze=11, test=32, production=1), 'Stage count differs')
    conventional = {p for p in pins if p.endswith('_test.dart') and '/test/' in p}
    tested = [p for stage in stages if stage['kind'] == 'test' for p in stage['sourcePaths']]
    require(len(tested) == len(set(tested)) == 171 and set(tested) == conventional == set(spec['testFiles']),
        'Missing or duplicate conventional test file')
    platform_counts = Counter('chrome' if stage['platform'] == 'chrome' else 'vm'
        for stage in stages if stage['kind'] == 'test' for _ in stage['sourcePaths'])
    require(platform_counts == dict(vm=139, chrome=32), 'Test platform counts differ')
    for stage in stages:
        root, kind = stage['cwdRelativeToFormattedSrc'], stage['kind']
        require(root in spec['projectRoots'], 'Stage project missing')
        prefix = [spec['dartExecutable']] + ([] if stage['platform'] == 'dart-vm' else [spec['flutterSnapshot']])
        if kind == 'pub':
            require(stage['requiredSuccessfulPubStage'] is None and root + '/pubspec.lock' in pins and
                stage['command'] == prefix + ['pub', 'get', '--offline', '--enforce-lockfile'], 'Unlocked or online pub')
        else:
            dependency = stage_map[stage['requiredSuccessfulPubStage']]
            require(dependency['kind'] == 'pub' and dependency['cwdRelativeToFormattedSrc'] == root, 'Wrong pub dependency')
        if kind == 'test':
            require(stage['sourcePaths'] == [root + '/' + path for path in stage['files']], 'Test source/argv mismatch')
            test_prefix = prefix + ['test'] + ([] if stage['platform'] == 'dart-vm' else ['--no-pub']) + ['--reporter=json']
            test_prefix += ['--platform=chrome', '--web-renderer=html'] if stage['platform'] == 'chrome' else ['--concurrency=1']
            require(stage['command'] == test_prefix + stage['files'], 'Unexpected test argv')
            require(len(stage['files']) <= (4 if stage['platform'] == 'chrome' else 8), 'Test batch exceeds declared bound')
    required_defines = ['--dart-define=API_URL=http://localhost:18101/api/v1',
        '--dart-define=OIDC_ISSUER=http://localhost:18101/identity/realms/ai-manager', '--dart-define=ALLOW_LOCAL_HTTP=true']
    require(spec['productionDartDefines'] == required_defines and spec['publicOrigin'] == 'http://localhost:18101', 'Runtime origin differs')
    production = next(stage for stage in stages if stage['kind'] == 'production')
    require(production['command'][-3:] == required_defines and '--no-pub' in production['command'] and
        '--release' in production['command'], 'Production command differs')
    require('productionRequiredAssets' in runner_path.read_text('utf-8'), 'Runner ignores required assets')
    require(all(safe(p) for p in spec['productionRequiredAssets']) and
        len(set(spec['productionRequiredAssets'])) == len(spec['productionRequiredAssets']), 'Unsafe required assets')
    for absolute, expected in spec['runtimePins'].items():
        require(Path(absolute).is_file() and digest(Path(absolute)) == expected, 'Runtime entry pin differs')
    require(len(spec['runtimePins']) == 4, 'Unexpected runtime pin scope')
    document_hashes = {
        'docs/idempotency-result-retention-design.md': '85d42d9fe355ec487ceaa7b34eca201d096a6e5c73b08790586548aeed7c1711',
        'docs/guardian-result-expiry-interaction-design.md': '49bb0fea12c045daf39e9b00407ef437cc363bebac5cc9a0ca1f44814d42d11a',
    }
    for path, expected in document_hashes.items():
        require(digest(ROOT / path) == expected, 'Design document changed')
    design = (ROOT / 'docs/idempotency-result-retention-design.md').read_text('utf-8')
    require('DESIGN_CONFIRMED_PENDING_IMPLEMENTATION' in design and '7,776,000,000' in design and
        'IDEMPOTENCY_RESULT_EXPIRED' in design and 'IDEMPOTENCY_RESPONSE_ERASED' in design and
        'DRAFT_PENDING_RETENTION_DECISION' not in design, 'Product decision not captured')
    for row in rows:
        require(digest(ROOT / row['path']) == row['sha256'], 'Source drift during static review')
    require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip() == initial_head, 'HEAD drift')
    preserved = []
    for path in (input_path, spec_path, runner_path, Path(__file__)):
        destination = OUT / path.name
        payload = path.read_bytes()
        with destination.open('xb') as handle:
            handle.write(payload)
        require(destination.read_bytes() == payload, 'Evidence copy differs')
        preserved.append(dict(original=inventory(path), preserved=inventory(destination)))
    receipt = dict(schemaVersion='1.0.0', status='STATIC_REVIEW_COMPLETED_NOT_EXECUTION_ACCEPTANCE',
        createdAtUtc=datetime.now(timezone.utc).isoformat(), baseCommit=initial_head,
        sourceCount=len(rows), wholeDartFileCount=len(targets), projectCount=len(spec['projects']),
        testFileCount=len(tested), testFilePlatforms=dict(platform_counts),
        stageCounts=dict(Counter(stage['kind'] for stage in stages)), windowsFormatArgvUtf16UnitsIncludingNul=format_units,
        originalBudgetsSeconds=dict(preparation=180, format=60, run=180),
        artifacts=preserved, designFiles=[inventory(ROOT / path) for path in document_hashes],
        reviewedBy=['Root static source/spec/AST review', 'independent agent source inventory and design review',
                    'independent agent runner text review'],
        limitations=['Runner was not executed; AST parse does not validate Windows Job or process races',
                     'Four entry pins do not freeze complete SDK, engine, or dependency cache contents',
                     'Resolved dependency source-content pins are required before future execution acceptance',
                     '510 working-tree source bytes include 9 shared semantic WIP and 2 Guardian EOL differences',
                     'No production code implements the new 90-day retention design yet'],
        runnerExecuted=False, sdkStarted=False, testsAdded=False, testsRun=False, pubRun=False,
        formatRun=False, analyzeRun=False, buildRun=False, servicesUpdated=False, databaseUpdated=False,
        acceptedForExecution=False, wholeProductComplete=False, deployed=False)
    output = OUT / 'root-static-review.json'
    with output.open('xb') as handle:
        handle.write((json.dumps(receipt, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))
    print(json.dumps(dict(status=receipt['status'], receipt=inventory(output), artifacts=len(preserved),
        sources=len(rows), formatFiles=len(targets), sdkStarted=False), ensure_ascii=True))

if __name__ == '__main__':
    main()
