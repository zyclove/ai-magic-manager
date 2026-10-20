"""One deadline-limited command on the frozen CURRENT_MAIN frontend R4 source.

Prepared only. Observations never accept a campaign or deployment. Root owns
the complete native terminal, external raw clocks, and independent log review.
Expiry permanently rejects the attempt; the same process tree is observed to
natural termination without killing, restarting, or resetting its deadline.
"""
from pathlib import Path, PurePosixPath
import argparse, ctypes, hashlib, importlib.util, json, math, os, re, shutil, subprocess, sys, time
from urllib.parse import unquote, urlparse
from urllib.request import url2pathname

ROOT = Path('D:/codes/mobile/ai-manager')
SPEC = ROOT / '.cache/publication-recovery/frontend-shared-execution-preparation-r4/execution-spec-r4.json'
HELPER = ROOT / '.local/complete_recovery_job.py'
HELPER_SHA = '3d1f4dda5e99e471d447c9f38145f40b9a32ec6e66e6dee8ce17d05d9eab5988'
CANARY = ROOT / '.local/complete-recovery-job-check-20261016-r2.json'
CANARY_SHA = '236c4873afd5bcf3586a8b7c8de1576a08520c63e3b4d23bb2acebb446faf644'
META_NAMES = ['.dart_tool/package_config.json', '.dart_tool/package_graph.json',
              '.dart_tool/package_config_subset', '.dart_tool/version',
              '.flutter-plugins', '.flutter-plugins-dependencies']
PLUGIN_LINK_ROOTS = {
    'windows/flutter/ephemeral/.plugin_symlinks': 'windows',
    'linux/flutter/ephemeral/.plugin_symlinks': 'linux',
    'macos/Flutter/ephemeral/.symlinks/plugins': 'macos',
    'ios/.symlinks/plugins': 'ios',
}
GENERATED_LINKS = {}


def check(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe(value):
    return isinstance(value, str) and bool(value) and PurePosixPath(value).as_posix() == value \
        and not PurePosixPath(value).is_absolute() and '..' not in PurePosixPath(value).parts \
        and '\\' not in value and ':' not in value


def real(path, directory=False):
    check(path.is_absolute() and os.path.lexists(path), 'Missing absolute path: ' + str(path))
    info = path.stat(follow_symlinks=False)
    check(hasattr(info, 'st_file_attributes') and not info.st_file_attributes & 0x400
          and not path.is_symlink(), 'Link/reparse point forbidden: ' + str(path))
    check(os.path.normcase(str(path.resolve())) == os.path.normcase(os.path.abspath(path)),
          'Path redirect forbidden: ' + str(path))
    check(path.is_dir() if directory else path.is_file(), 'Wrong path type: ' + str(path))


def hierarchy(path):
    for parent in reversed([path, *path.parents]):
        real(parent, directory=True)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        check(key not in result, 'Duplicate JSON key: ' + key)
        result[key] = value
    return result


def read(path):
    return json.loads(path.read_bytes(), object_pairs_hook=unique_object)


def inventory(path):
    real(path)
    return dict(path=path.relative_to(ROOT).as_posix(), sha256=sha(path), bytes=path.stat().st_size)


def write_new(path, value):
    with path.open('xb') as handle:
        handle.write((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))


def ref_guard(ref):
    check(isinstance(ref, dict) and safe(ref.get('path')), 'Unsafe evidence reference')
    path = ROOT / ref['path']
    hierarchy(path.parent)
    check(inventory(path) == ref, 'Evidence reference changed: ' + ref['path'])
    return path


def is_link(path):
    info = path.stat(follow_symlinks=False)
    return path.is_symlink() or bool(getattr(info, 'st_file_attributes', 0) & 0x400)


def plugin_link_guard(path, src, generated_roots):
    relative_parent = path.parent.relative_to(src).as_posix()
    candidates = [(project, platform) for project in generated_roots
                  for suffix, platform in PLUGIN_LINK_ROOTS.items()
                  if relative_parent == ((project + '/') if project else '') + suffix]
    check(len(candidates) == 1 and re.fullmatch(r'[a-z][a-z0-9_]*', path.name),
          'Link outside an explicit generated plugin directory: ' + str(path))
    project, platform = candidates[0]
    project_dir = src / project
    hierarchy(path.parent)
    metadata_path = project_dir / '.flutter-plugins-dependencies'
    config_path = project_dir / '.dart_tool/package_config.json'
    for metadata in (metadata_path, config_path):
        hierarchy(metadata.parent)
        real(metadata)
    plugins = read(metadata_path).get('plugins', {}).get(platform, [])
    matches = [plugin for plugin in plugins if plugin.get('name') == path.name]
    check(len(matches) == 1 and isinstance(matches[0].get('path'), str),
          'Generated plugin link has no unique dependency metadata')
    expected = Path(matches[0]['path'])
    check(expected.is_absolute(), 'Plugin dependency target must be absolute')
    hierarchy(expected)
    packages = read(config_path).get('packages', [])
    packages = [package for package in packages if package.get('name') == path.name]
    check(len(packages) == 1 and isinstance(packages[0].get('rootUri'), str),
          'Generated plugin link has no unique package_config identity')
    uri = urlparse(packages[0]['rootUri'])
    check(uri.scheme in ('', 'file') and not uri.netloc and not uri.query and not uri.fragment,
          'Plugin package root must be a local file URI')
    package_root = Path(url2pathname(uri.path)) if uri.scheme == 'file' else config_path.parent / unquote(uri.path)
    package_root = Path(os.path.abspath(package_root))
    hierarchy(package_root)
    link_text = os.readlink(path)
    target_text = link_text[4:] if link_text.startswith('\\\\?\\') else link_text
    target = Path(os.path.abspath(path.parent / target_text))
    hierarchy(target)
    check(os.path.normcase(str(target)) == os.path.normcase(str(expected.resolve(strict=True)))
          == os.path.normcase(str(package_root.resolve(strict=True))) and target.is_dir(),
          'Generated plugin target differs from locked package metadata')
    record = dict(path=path.relative_to(ROOT).as_posix(), target=str(target), linkText=link_text,
                  platform=platform, package=path.name, excludedFromSource=True,
                  pluginMetadata=inventory(metadata_path), packageConfig=inventory(config_path))
    key = os.path.normcase(str(path))
    check(key not in GENERATED_LINKS or GENERATED_LINKS[key] == record,
          'Generated plugin link or metadata changed during this command')
    GENERATED_LINKS[key] = record


def generated_link_records():
    return sorted(GENERATED_LINKS.values(), key=lambda row: row['path'])


def disk_files(src, generated_roots=(), excluded_files=()):
    hierarchy(src)
    ignored_dirs = {(r + '/' if r else '') + suffix for r in generated_roots for suffix in ('.dart_tool', 'build')}
    ignored_files = {(r + '/' if r else '') + suffix for r in generated_roots
                     for suffix in ('.flutter-plugins', '.flutter-plugins-dependencies')} | set(excluded_files)
    result = set()
    for parent, directories, files in os.walk(src, topdown=True, followlinks=False):
        kept = []
        for name in directories:
            child = Path(parent) / name
            if is_link(child):
                plugin_link_guard(child, src, generated_roots)
                continue
            real(child, directory=True)
            kept.append(name)
        directories[:] = kept
        for name in files:
            child = Path(parent) / name
            check(not is_link(child), 'File link forbidden: ' + str(child))
            real(child)
            rel = child.relative_to(src).as_posix()
            if rel not in ignored_files and not any(rel.startswith(root + '/') for root in ignored_dirs):
                result.add(rel)
    return result


def source_guard(src, pins, generated_roots=()):
    check(pins and all(safe(p) and re.fullmatch(r'[0-9a-f]{64}', h)
                       for p, h in pins.items()), 'Nonempty safe source pins required')
    check(len({os.path.normcase(p) for p in pins}) == len(pins), 'Source case alias collision')
    check(disk_files(src, generated_roots) == set(pins), 'Exact source disk file set differs')
    check(all(sha(src / p) == h for p, h in pins.items()), 'Frozen source bytes changed')


def copy_new(src_rows, destination, budget):
    check(not os.path.lexists(destination), 'Preserve any previous or partial source: ' + str(destination))
    hierarchy(destination.parent)
    destination.mkdir()
    for rel, origin, expected in src_rows:
        budget()
        check(safe(rel), 'Unsafe copy destination')
        hierarchy(origin.parent)
        real(origin)
        data = origin.read_bytes()
        check(hashlib.sha256(data).hexdigest() == expected, 'Copy input changed: ' + rel)
        target = destination / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        hierarchy(target.parent)
        budget()
        with target.open('xb') as handle:
            handle.write(data)
        budget()


def main_source_snapshot(spec):
    result = {}
    for root in spec['inputRoots']:
        check(safe(root), 'Unsafe Main input root')
        relative_generated = [p[len(root) + 1:] if p != root else ''
                              for p in spec['generatedProjectRoots'] if p == root or p.startswith(root + '/')]
        excluded = [p[len(root) + 1:] for p in spec['mainExcludedIdeFiles'] if p.startswith(root + '/')]
        for rel in disk_files(ROOT / root, relative_generated, excluded):
            path = root + '/' + rel
            check(path not in result, 'Overlapping Main source roots')
            result[path] = sha(ROOT / path)
    return result


def metadata_snapshot(src, project):
    check(safe(project), 'Unsafe project root')
    result = {}
    for suffix in META_NAMES:
        rel = project + '/' + suffix
        path = src / rel
        if os.path.lexists(path):
            hierarchy(path.parent)
            result[rel] = inventory(path)
        else:
            result[rel] = dict(absent=True)
    check('sha256' in result[project + '/.dart_tool/package_config.json'],
          'Actual pub package_config.json required')
    return result


def metadata_guard(src, expected):
    for rel, value in expected.items():
        check(safe(rel), 'Unsafe pub metadata path')
        path = src / rel
        if value == dict(absent=True):
            check(not os.path.lexists(path), 'Previously absent pub metadata appeared: ' + rel)
        else:
            hierarchy(path.parent)
            check(inventory(path) == value, 'Same-project pub metadata changed: ' + rel)


def reporter_facts(path, stage, src):
    events, raw = [], []
    for line in path.read_text('utf-8').splitlines():
        try:
            row = json.loads(line, object_pairs_hook=unique_object)
        except json.JSONDecodeError:
            check(not line.lstrip().startswith('{'), 'Malformed/truncated JSON reporter')
            raw.append(line)
            continue
        if isinstance(row, dict) and 'type' in row:
            events.append(row)
    check(events and events[0].get('type') == 'start'
          and sum(e.get('type') == 'start' for e in events) == 1, 'Missing/duplicate reporter start')
    ident = lambda value: type(value) is int and value >= 0
    suites_list = [e['suite'] for e in events if e.get('type') == 'suite']
    suites = {x['id']: x for x in suites_list}
    platform = 'chrome' if stage['platform'] == 'chrome' else 'vm'
    check(len(suites_list) == len(suites) == len(stage['sourcePaths'])
          and all(ident(x['id']) and x.get('platform') == platform for x in suites_list),
          'Missing/duplicate/unrelated reporter suite')
    selected = {os.path.normcase(str((src / p).resolve())): p for p in stage['sourcePaths']}
    observed, file_by_suite = {}, {}
    def canonical(value):
        candidate = Path(value)
        if not candidate.is_absolute():
            candidate = src / stage['cwdRelativeToFormattedSrc'] / candidate
        return os.path.normcase(str(candidate.resolve()))
    for sid, suite in suites.items():
        actual = canonical(suite['path'])
        check(actual in selected and actual not in observed, 'Unexpected/duplicate suite path')
        observed[actual] = selected[actual]
        file_by_suite[sid] = selected[actual]
    check(set(observed) == set(selected), 'Selected physical suites omitted')
    check([e.get('count') for e in events if e.get('type') == 'allSuites'] == [len(suites)],
          'Missing/duplicate suite declaration')
    group_list = [e['group'] for e in events if e.get('type') == 'group']
    groups = {x['id']: x for x in group_list}
    check(len(group_list) == len(groups) and all(ident(x['id']) and x.get('suiteID') in suites
          and x.get('metadata', {}).get('skip') is False for x in group_list), 'Invalid/skipped reporter group')
    test_list = [e['test'] for e in events if e.get('type') == 'testStart']
    tests = {x['id']: x for x in test_list}
    check(tests and len(test_list) == len(tests) and all(ident(x['id']) and x.get('suiteID') in suites
          and x.get('metadata', {}).get('skip') is False
          and all(g in groups and groups[g]['suiteID'] == x['suiteID'] for g in x.get('groupIDs', []))
          for x in test_list), 'Invalid/duplicate/skipped reporter test start')
    finish_list = [e for e in events if e.get('type') == 'testDone']
    finishes = {x['testID']: x for x in finish_list}
    check(len(finish_list) == len(finishes) and set(finishes) == set(tests), 'Unfinished/duplicate reporter test ids')
    mapping = {p: dict(platform=platform, actualCases=[]) for p in stage['sourcePaths']}
    loads = {p: 0 for p in mapping}
    for tid, result in finishes.items():
        test, rel = tests[tid], file_by_suite[tests[tid]['suiteID']]
        check(result.get('skipped') is False and result.get('result') == 'success',
              'Reporter skipped or unsuccessful case')
        if result.get('hidden') is True:
            check(test['name'].startswith('loading ')
                  and canonical(test['name'][8:]) == canonical(str(src / rel)),
                  'Hidden compile/loading event belongs to another suite')
            loads[rel] += 1
        else:
            check(result.get('hidden') is False, 'Selected real test was hidden')
            mapping[rel]['actualCases'].append(dict(id=tid, name=test['name'], result=result['result']))
    for rel, value in mapping.items():
        cases = value['actualCases']
        actual = [case['name'] for case in cases]
        check(loads[rel] == 1 and cases and len(actual) == len(set(actual)),
              'Selected suite needs one successful load and unique visible cases: ' + rel)
    check(not any(e.get('type') == 'error' for e in events), 'Reporter error cannot count as GREEN')
    forbidden = re.compile(r'EXCEPTION CAUGHT BY|A Timer is still pending|Pending timers:|pending timer|pumpAndSettle timed out|setState\(\) or markNeedsBuild\(\)|!_debugLocked|Multiple exceptions|Test timed out|TimeoutException|Compilation failed|Failed to compile', re.I)
    check(all(not forbidden.search(line) for line in raw)
          and all(not forbidden.search(e.get('message', '')) for e in events if e.get('type') == 'print'),
          'Framework/fixture/compile diagnostic cannot count as GREEN')
    done = [e for e in events if e.get('type') == 'done']
    check(len(done) == 1 and done[0].get('success') is True and events[-1].get('type') == 'done',
          'Reporter completion missing/failed/nonfinal')
    return dict(rawEventCount=len(events), nonJsonLineCount=len(raw), selectedSuiteCount=len(mapping),
                visibleCaseCount=sum(len(v['actualCases']) for v in mapping.values()), fileToCases=mapping,
                zeroSkip=True, zeroError=True, doneSuccess=True, classifiedOrAccepted=False)


def elapsed_valid(value, limit):
    return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= limit


def main():
    started, wall = time.monotonic(), time.time()
    sys.dont_write_bytecode = True
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare-raw', 'prepare-format-input', 'format', 'run'])
    parser.add_argument('--expected-runner-sha256', required=True)
    parser.add_argument('--expected-spec-sha256', required=True)
    parser.add_argument('--expected-raw-manifest-sha256')
    parser.add_argument('--expected-formatted-manifest-sha256')
    parser.add_argument('--expected-prepared-manifest-sha256')
    parser.add_argument('--format-root-facts-path')
    parser.add_argument('--expected-format-root-facts-sha256')
    parser.add_argument('--stage')
    parser.add_argument('--attempt')
    parser.add_argument('--pub-attempt')
    args = parser.parse_args()
    for key, value in vars(args).items():
        if 'sha256' in key and value is not None:
            check(re.fullmatch(r'[0-9a-f]{64}', value), 'Actual explicit lowercase64 SHA required')
    own = Path(__file__)
    hierarchy(own.parent)
    check(Path(sys.executable) == Path('C:/Python313/python.exe'), 'Pinned Python executable required')
    check(sha(own) == args.expected_runner_sha256 and sha(SPEC) == args.expected_spec_sha256,
          'Actual runner/spec pins differ')
    spec = read(SPEC)
    check(spec['schemaVersion'] == '1.0.0' and type(spec['sourceCount']) is int and spec['sourceCount'] > 0,
          'Actual shared frontend specification required')
    check(spec['preparationBudgetSeconds'] == 180 and spec['formatBudgetSeconds'] == 60
          and spec['runBudgetSeconds'] == 180, 'Exact complete-command R4 budgets required')
    required_assets = spec['productionRequiredAssets']
    check(isinstance(required_assets, list) and required_assets
          and all(safe(path) for path in required_assets)
          and len(required_assets) == len(set(required_assets)),
          'Production required asset paths must be safe and unique')
    check(spec['campaignRoot'] == '.cache/publication-recovery/frontend-shared-campaign-r4',
          'Exact fresh R4 campaign root required')
    base = ROOT / spec['campaignRoot']
    raw, formatted = base / 'raw', base / 'formatted'
    raw_manifest, formatted_manifest = raw / 'source.json', formatted / 'source.json'
    raw_src, formatted_src = raw / 'src', formatted / 'src'
    generated_roots = spec['generatedProjectRoots']
    check(generated_roots and len(generated_roots) == len(set(generated_roots))
          and all(safe(p) for p in generated_roots), 'Unique safe generated project roots required')
    project_roots = spec['projectRoots']
    projects = spec['projects']
    check(len(project_roots) == len(set(project_roots)) == len(projects) == len(generated_roots)
          and set(project_roots) == set(generated_roots) == {p['root'] for p in projects},
          'Measured project/generated project sets must agree')
    selected = spec['selectedSources']
    check(isinstance(selected, list) and selected and all(
          isinstance(row, dict) and safe(row.get('path')) and row.get('sourcePath') == row['path']
          and row.get('origin') == 'CURRENT_MAIN' and type(row.get('bytes')) is int
          and row['bytes'] >= 0 and isinstance(row.get('sha256'), str)
          and re.fullmatch(r'[0-9a-f]{64}', row['sha256']) for row in selected),
          'R4 requires only actual same-path CURRENT_MAIN inputs')
    pins = {r['path']: r['sha256'] for r in selected}
    check(len(selected) == len(pins) == spec['sourceCount'] and pins == spec['mainSourceSha256'],
          'Actual exact CURRENT_MAIN source set and bytes required')
    rows_by_path = {row['path']: row for row in selected}
    check(set(generated_roots) == {path[:-len('/pubspec.yaml')] for path in pins
                                   if path.endswith('/pubspec.yaml')},
          'Every actual current pubspec must declare its generated project root')
    for project in projects:
        project_root = project['root']
        pubspec_path, lock_path = project_root + '/pubspec.yaml', project_root + '/pubspec.lock'
        check(project['framework'] in {'dart', 'flutter'}
              and project['pubspec'] == rows_by_path[pubspec_path]
              and project['lock'] == rows_by_path.get(lock_path),
              'Measured project framework/pubspec/lock references differ')
    targets = spec['formatDartPaths']
    check(targets and len(targets) == len(set(targets))
          and set(targets) == {p for p in pins if p.endswith('.dart')},
          'Every selected whole CURRENT_MAIN Dart file required')
    check(spec['formatCommand'] == [spec['dartExecutable'], 'format', *targets],
          'Exact whole-file Dart format argv required')
    stages = {s['id']: s for s in spec['stages']}
    check(len(stages) == len(spec['stages']), 'Duplicate stage id')
    projects_by_root = {project['root']: project for project in projects}
    test_files = [p for s in stages.values() if s['kind'] == 'test' for p in s['sourcePaths']]
    conventional = {p for p in pins if any(p.startswith(r + '/test/') for r in generated_roots)
                    and p.endswith('_test.dart')}
    check(test_files and len(test_files) == len(set(test_files))
          and set(test_files) == set(spec['testFiles']) == conventional,
          'Every actual conventional test file must be explicitly scheduled exactly once')
    for stage in stages.values():
        check(stage['kind'] in {'pub', 'test', 'analyze', 'production'}, 'Unknown stage kind')
        check(safe(stage['cwdRelativeToFormattedSrc']) and stage['cwdRelativeToFormattedSrc'] in generated_roots,
              'Undeclared stage project')
        project = projects_by_root[stage['cwdRelativeToFormattedSrc']]
        check(stage['platform'] in ({'dart-vm'} if project['framework'] == 'dart' else {'vm', 'chrome'}),
              'Stage platform differs from current project framework')
        dependency = stage['requiredSuccessfulPubStage']
        check((dependency is None) == (stage['kind'] == 'pub'),
              'Each SDK stage must declare its same-project offline pub prerequisite')
        if dependency is not None:
            check(dependency in stages and stages[dependency]['kind'] == 'pub'
                  and stages[dependency]['cwdRelativeToFormattedSrc'] == stage['cwdRelativeToFormattedSrc']
                  and stage['kind'] != 'pub', 'Pub prerequisite must belong to this current project')
        if stage['kind'] == 'test':
            check(all(p in pins for p in stage['sourcePaths']), 'Unpinned test source')
            check(stage['sourcePaths'] == [stage['cwdRelativeToFormattedSrc'] + '/' + f for f in stage['files']],
                  'Stage argv/file paths differ')
            check(stage['command'][-len(stage['files']):] == stage['files'], 'Exact explicit test argv required')
            check('--reporter=json' in stage['command'], 'JSON reporter required')
            check(('--concurrency=1' not in stage['command']) if stage['platform'] == 'chrome'
                  else ('--concurrency=1' in stage['command']), 'Wrong platform concurrency arguments')
            prefix = [spec['dartExecutable']]
            if stage['platform'] != 'dart-vm':
                prefix += [spec['flutterSnapshot']]
            prefix += ['test'] + ([] if stage['platform'] == 'dart-vm' else ['--no-pub'])
            prefix += ['--reporter=json']
            prefix += ['--platform=chrome', '--web-renderer=html'] if stage['platform'] == 'chrome' else ['--concurrency=1']
            check(stage['command'] == prefix + stage['files'], 'Unexpected test selection/SDK argv')
        elif stage['kind'] == 'pub':
            prefix = [spec['dartExecutable']] + ([] if stage['platform'] == 'dart-vm' else [spec['flutterSnapshot']])
            check(stage['command'] == prefix + ['pub', 'get', '--offline', '--enforce-lockfile']
                  and stage['cwdRelativeToFormattedSrc'] + '/pubspec.lock' in pins,
                  'Locked exact offline pub argv required')
    protected = {own: args.expected_runner_sha256, SPEC: args.expected_spec_sha256,
                 HELPER: HELPER_SHA, CANARY: CANARY_SHA}
    runtime_pins = {Path(p): h for p, h in spec['runtimePins'].items()}
    check({Path(sys.executable), Path(spec['dartExecutable']), Path(spec['flutterSnapshot']),
           Path(spec['chromeExecutable'])} <= set(runtime_pins), 'All actual runtime executables must be pinned')
    protected.update(runtime_pins)
    for ref in spec['provenanceRefs']:
        protected[ref_guard(ref)] = ref['sha256']

    def fixed_guard():
        for path, expected in protected.items():
            hierarchy(path.parent)
            real(path)
            check(sha(path) == expected, 'Source/tool/evidence pin changed: ' + str(path))
        canary = read(CANARY)
        check(canary.get('status') == 'PASSED' and canary.get('helperSha256') == HELPER_SHA
              and len(canary.get('cases', [])) == 2
              and all(c.get('passed') is True and c.get('treeTerminal') is True
                      and c.get('activeAfterExit') == 0 for c in canary['cases']), 'OwnedJob canary differs')

    def input_guard():
        fixed_guard()
        check(main_source_snapshot(spec) == spec['mainSourceSha256'], 'Main source set/bytes changed')
        for row in selected:
            check(safe(row['path']) and safe(row['sourcePath']), 'Unsafe selected source path')
            path = ROOT / row['sourcePath']
            hierarchy(path.parent)
            real(path)
            check(sha(path) == row['sha256'] and path.stat().st_size == row['bytes'],
                  'Selected input changed: ' + row['path'])

    def preparation(action):
        check(args.attempt is not None and re.fullmatch(r'[a-z][a-z0-9-]{0,63}', args.attempt),
              'Fresh preparation attempt required')
        check(all(getattr(args, key) is None for key in ['expected_formatted_manifest_sha256',
              'expected_prepared_manifest_sha256', 'format_root_facts_path',
              'expected_format_root_facts_sha256', 'stage', 'pub_attempt']), 'Preparation has no SDK outputs')
        def prep_budget():
            check(elapsed_valid(time.monotonic() - started, 180) and elapsed_valid(time.time() - wall, 180)
                  and time.monotonic() < started + 180 and time.time() < wall + 180,
                  'PREPARATION_ORIGINAL_DUAL_DEADLINE_EXHAUSTED')
        input_guard()
        prep_budget()
        if action == 'prepare-raw':
            check(args.expected_raw_manifest_sha256 is None, 'Raw preparation has no prior output hash')
            check(not os.path.lexists(base), 'Preserve previous/partial campaign')
            hierarchy(base.parent)
            base.mkdir()
            for name in ('raw', 'out', 'tmp'):
                (base / name).mkdir()
            destination, manifest = raw_src, raw_manifest
            rows = [(r['path'], ROOT / r['sourcePath'], r['sha256']) for r in selected]
        else:
            check(not os.path.lexists(formatted), 'Preserve previous/partial format input')
            destination, manifest = formatted_src, formatted / 'prepared-source.json'
            formatted.mkdir()
            rows = [(p, raw_src / p, h) for p, h in pins.items()]
        result = base / 'out' / (args.attempt + '-result.json')
        check(not os.path.lexists(result), 'Preserve earlier preparation result')
        observation = dict(status='PREPARATION_REJECTED', action=action, attempt=args.attempt,
            invocationCommand=list(sys.orig_argv), runner=inventory(own), spec=inventory(SPEC),
            sdkStarted=False, gateReleased=False, childProcessStarted=False, forcedTerminationUsed=False,
            treeTerminal=True, nativeExitCode=None, accepted=False, wholeProductComplete=False, deployed=False)
        try:
            copy_new(rows, destination, prep_budget)
            source_guard(destination, pins)
            input_guard()
            prep_budget()
            value = dict(schemaVersion='1.0.0', status='PREPARED_RAW_SDK_NOT_STARTED' if action == 'prepare-raw'
                else 'PREPARED_UNFORMATTED_SDK_NOT_STARTED', sourceCount=len(pins), sourceSha256=pins,
                runner=inventory(own), spec=inventory(SPEC), preparationAttempt=args.attempt,
                preparationPhase=action, sdkInvoked=False, formatted=False, accepted=False,
                wholeProductComplete=False, deployed=False)
            if action != 'prepare-raw':
                value.update(rawManifest=inventory(raw_manifest), rawPreparationResult=inventory(raw_preparation_result))
            write_new(manifest, value)
            source_guard(destination, pins)
            input_guard()
            prep_budget()
            observation.update(status='PREPARATION_OBSERVED_PENDING_EXTERNAL_EXIT', sourceManifest=inventory(manifest),
                               sourceUnchanged=True)
        except Exception as error:
            observation.update(reason=repr(error), sourceUnchanged=False)
        finally:
            try:
                input_guard()
            except Exception as error:
                observation.update(status='PREPARATION_REJECTED', finalGuardError=repr(error), sourceUnchanged=False)
            observation.update(elapsedMonotonicSeconds=time.monotonic() - started,
                               elapsedWallSeconds=time.time() - wall)
            observation['generatedPluginLinks'] = generated_link_records()
            if not all(elapsed_valid(observation[k], 180) for k in ('elapsedMonotonicSeconds', 'elapsedWallSeconds')):
                observation.update(status='PREPARATION_REJECTED', reason='COMPLETE_INTERNAL_PREPARATION_CLOCK_EXCEEDED')
            write_new(result, observation)
            print(json.dumps(dict(status=observation['status'], result=inventory(result), sdkStarted=False,
                elapsedMonotonicSeconds=observation['elapsedMonotonicSeconds'],
                elapsedWallSeconds=observation['elapsedWallSeconds'], accepted=False)), flush=True)
        return 0 if observation['status'] == 'PREPARATION_OBSERVED_PENDING_EXTERNAL_EXIT' else 1

    def preparation_result(manifest, value, action):
        attempt = value.get('preparationAttempt')
        check(isinstance(attempt, str) and re.fullmatch(r'[a-z][a-z0-9-]{0,63}', attempt),
              'Actual preparation attempt missing')
        path = base / 'out' / (attempt + '-result.json')
        real(path)
        observed = read(path)
        check(observed.get('status') == 'PREPARATION_OBSERVED_PENDING_EXTERNAL_EXIT'
              and observed.get('action') == action and observed.get('sourceManifest') == inventory(manifest)
              and observed.get('runner') == inventory(own) and observed.get('spec') == inventory(SPEC)
              and observed.get('sdkStarted') is False and observed.get('gateReleased') is False
              and observed.get('childProcessStarted') is False and observed.get('treeTerminal') is True
              and observed.get('forcedTerminationUsed') is False and observed.get('sourceUnchanged') is True
              and all(elapsed_valid(observed.get(k), 180) for k in ('elapsedMonotonicSeconds', 'elapsedWallSeconds')),
              'Actual same-source successful no-SDK preparation required')
        protected[path] = sha(path)
        return path

    fixed_guard()
    if args.action == 'prepare-raw':
        return preparation(args.action)

    check(args.expected_raw_manifest_sha256 is not None, 'Actual raw manifest SHA is required')
    hierarchy(base)
    real(raw_manifest)
    check(sha(raw_manifest) == args.expected_raw_manifest_sha256, 'Raw manifest pin differs')
    raw_value = read(raw_manifest)
    check(raw_value.get('status') == 'PREPARED_RAW_SDK_NOT_STARTED' and raw_value.get('sourceSha256') == pins
          and raw_value.get('spec') == inventory(SPEC) and raw_value.get('runner') == inventory(own),
          'Raw manifest provenance differs')
    protected[raw_manifest] = args.expected_raw_manifest_sha256
    source_guard(raw_src, pins)
    raw_preparation_result = preparation_result(raw_manifest, raw_value, 'prepare-raw')
    if args.action == 'prepare-format-input':
        return preparation(args.action)
    check(args.attempt is not None and re.fullmatch(r'[a-z][a-z0-9-]{0,63}', args.attempt),
          'Explicit fresh safe attempt required')
    stage = None
    formatted_pins = None
    prior_metadata = None
    prepared_manifest = formatted / 'prepared-source.json'
    check(args.expected_prepared_manifest_sha256 is not None
          and sha(prepared_manifest) == args.expected_prepared_manifest_sha256, 'Explicit actual prepared input SHA required')
    prepared = read(prepared_manifest)
    check(prepared.get('status') == 'PREPARED_UNFORMATTED_SDK_NOT_STARTED'
          and prepared.get('sourceSha256') == pins and prepared.get('rawManifest') == inventory(raw_manifest)
          and prepared.get('rawPreparationResult') == inventory(raw_preparation_result)
          and prepared.get('runner') == inventory(own) and prepared.get('spec') == inventory(SPEC),
          'Prepared unformatted source provenance differs')
    prepared_result = preparation_result(prepared_manifest, prepared, 'prepare-format-input')
    protected[prepared_manifest] = args.expected_prepared_manifest_sha256
    claim_path = base / 'out' / 'format-attempt.json'
    if args.action == 'format':
        check(all(getattr(args, key) is None for key in ['expected_formatted_manifest_sha256',
            'format_root_facts_path', 'expected_format_root_facts_sha256', 'stage', 'pub_attempt']),
            'Format has no invented formatted/root-facts/prerequisite hashes')
        check(not os.path.lexists(formatted_manifest) and not os.path.lexists(claim_path),
              'Preserve previous/partial SDK format attempt')
        source_guard(formatted_src, pins)
        limit = 60
        command = spec['formatCommand']
        cwd = formatted_src
    else:
        check(args.stage in stages and args.expected_formatted_manifest_sha256 is not None
              and args.expected_format_root_facts_sha256 is not None and safe(args.format_root_facts_path),
              'Actual stage/formatted/root-facts inputs are mandatory')
        check(sha(formatted_manifest) == args.expected_formatted_manifest_sha256, 'Formatted manifest differs')
        hierarchy(formatted)
        real(formatted_manifest)
        value = read(formatted_manifest)
        check(value.get('status') == 'DRAFT_FORMATTED_PENDING_EXTERNAL_EXIT'
              and value.get('rawManifest') == inventory(raw_manifest)
              and value.get('spec') == inventory(SPEC) and value.get('runner') == inventory(own)
              and value.get('preparedManifest') == inventory(prepared_manifest), 'Formatted source provenance differs')
        claim = read(ref_guard(value['formatAttempt']))
        check(value['formatAttempt'] == inventory(claim_path)
              and claim.get('status') == 'FORMAT_ATTEMPT_STARTED' and claim.get('runner') == inventory(own)
              and claim.get('spec') == inventory(SPEC) and claim.get('preparedManifest') == inventory(prepared_manifest),
              'Actual exclusive format attempt differs')
        protected[claim_path] = sha(claim_path)
        formatted_pins = value['sourceSha256']
        source_guard(formatted_src, formatted_pins, generated_roots)
        check(all(formatted_pins[p] == h for p, h in pins.items() if p not in targets),
              'Formatter changed a non-target source')
        protected[formatted_manifest] = args.expected_formatted_manifest_sha256
        facts_path = ROOT / args.format_root_facts_path
        hierarchy(facts_path.parent)
        check(sha(facts_path) == args.expected_format_root_facts_sha256, 'Actual Root format facts differ')
        facts = read(facts_path)
        check(facts.get('origin') == 'ROOT_ACTUAL_COMPLETE_COMMAND' and facts.get('stage') == 'format'
              and facts.get('nativeExitCode') == 0 and all(elapsed_valid(facts.get(k), 60)
                for k in ('elapsedMonotonicSeconds', 'elapsedWallSeconds')), 'Actual complete Root format0/60 required')
        format_result_path = ref_guard(facts['result'])
        format_log_path = ref_guard(facts['log'])
        check(facts['sourceManifest'] == inventory(formatted_manifest), 'Root facts formatted source differs')
        format_result = read(format_result_path)
        check(format_result.get('status') == 'OBSERVATION_PENDING_EXTERNAL_EXIT'
              and format_result.get('action') == 'format' and format_result.get('nativeExitCode') == 0
              and format_result.get('sdkStarted') is True and format_result.get('gateReleased') is True
              and format_result.get('timedOut') is False
              and format_result.get('sourceManifest') == inventory(formatted_manifest)
              and format_result.get('attempt') == claim.get('attempt')
              and format_result.get('preparedManifestSha256') == args.expected_prepared_manifest_sha256
              and format_result.get('rawManifestSha256') == args.expected_raw_manifest_sha256
              and format_result.get('specSha256') == args.expected_spec_sha256
              and format_result.get('runnerSha256') == args.expected_runner_sha256
              and format_result.get('invocationCommand') == facts.get('command')
              and format_result.get('log') == inventory(format_log_path)
              and format_result.get('sourceUnchanged') is True
              and format_result.get('treeExitedWithoutTermination') is True
              and format_result.get('activeProcessesBeforeCleanup') == 0
              and format_result.get('forcedTerminationUsed') is False
              and format_result.get('treeTerminal') is True, 'Pending format result/facts chain differs')
        protected.update({facts_path: args.expected_format_root_facts_sha256,
                          format_result_path: facts['result']['sha256'], format_log_path: facts['log']['sha256']})
        stage = stages[args.stage]
        limit, command = 180, stage['command']
        cwd = formatted_src / stage['cwdRelativeToFormattedSrc']

    result_path, log_path = base / 'out' / (args.attempt + '-result.json'), base / 'out' / (args.attempt + '.log')
    deadline_path = base / 'out' / (args.attempt + '-deadline-exceeded.json')
    runtime = base / 'tmp' / args.attempt
    check(not any(os.path.lexists(p) for p in (result_path, log_path, runtime, deadline_path)),
          'Preserve earlier attempt artifacts')
    report = dict(status='OBSERVATION_REJECTED', action=args.action, stage=args.stage, attempt=args.attempt,
        command=command, cwd=str(cwd), invocationCommand=list(sys.orig_argv),
        rawManifestSha256=args.expected_raw_manifest_sha256,
        formattedManifestSha256=args.expected_formatted_manifest_sha256,
        formatRootFactsSha256=args.expected_format_root_facts_sha256,
        preparedManifestSha256=args.expected_prepared_manifest_sha256,
        runnerSha256=args.expected_runner_sha256, specSha256=args.expected_spec_sha256,
        nativeExitCode=None, sdkStarted=False, gateReleased=False, stageTimeoutSeconds=limit,
        timedOut=False, budgetExceeded=False, gateReleaseAttempted=False,
        launcherCreationAttempted=False, launcherCreationReturned=False,
        ownedJobCanaryCoversR4NaturalMode=False,
        forcedTerminationUsed=False, treeTerminal=False, observationErrors=[],
        finalVerified=False, classified=False, accepted=False, wholeProductComplete=False, deployed=False)
    current_metadata = None

    def unchanged():
        input_guard()
        source_guard(raw_src, pins)
        if formatted_pins is not None:
            source_guard(formatted_src, formatted_pins, generated_roots)
        elif args.action == 'format' and not report['sdkStarted']:
            source_guard(formatted_src, pins)
        if prior_metadata is not None:
            metadata_guard(formatted_src, prior_metadata)
        if current_metadata is not None:
            metadata_guard(formatted_src, current_metadata)
        return True

    deadline_mono, deadline_wall = started + limit, wall + limit
    report.update(deadlineMonotonicSeconds=deadline_mono, deadlineWallSeconds=deadline_wall, timingMarks=[])

    def budget(phase):
        mono, clock = time.monotonic() - started, time.time() - wall
        report['timingMarks'].append(dict(phase=phase, elapsedMonotonicSeconds=mono, elapsedWallSeconds=clock))
        check(elapsed_valid(mono, limit) and elapsed_valid(clock, limit) and mono < limit and clock < limit,
              phase + ': SDK_DEADLINE_EXHAUSTED')
        return min(limit - mono, limit - clock)

    job = process = None
    assigned = False
    deadline_written = False

    def observation_error(phase, error):
        report['status'] = 'OBSERVATION_REJECTED'
        detail = phase + ': ' + repr(error)
        if detail not in report['observationErrors'] and len(report['observationErrors']) < 64:
            report['observationErrors'].append(detail)

    def observe_deadline(phase):
        nonlocal deadline_written
        mono, clock = time.monotonic(), time.time()
        if started <= mono < deadline_mono and wall <= clock < deadline_wall:
            return
        report.update(status='OBSERVATION_REJECTED', timedOut=True, budgetExceeded=True,
                      reason='ORIGINAL_COMPLETE_COMMAND_DEADLINE_EXCEEDED')
        if deadline_written:
            return
        deadline_written = True
        receipt = dict(status='DEADLINE_EXCEEDED_OBSERVING_SAME_PROCESS_TREE', phase=phase,
                       attempt=args.attempt, ownedPid=report.get('ownedPid'), assignedToJob=assigned,
                       treeTerminal=report['treeTerminal'],
                       deadlineMonotonicSeconds=deadline_mono, deadlineWallSeconds=deadline_wall,
                       observedMonotonicSeconds=mono, observedWallSeconds=clock,
                       elapsedMonotonicSeconds=mono - started, elapsedWallSeconds=clock - wall,
                       timedOut=True, budgetReset=False, reexecuted=False,
                       forcedTerminationUsed=False, accepted=False)
        try:
            write_new(deadline_path, receipt)
            report['deadlineReceipt'] = inventory(deadline_path)
        except BaseException as error:
            observation_error('deadline-receipt', error)
        try:
            print(json.dumps(receipt, ensure_ascii=True), flush=True)
        except BaseException as error:
            observation_error('deadline-notification', error)

    def observe_natural(phase):
        # No timeout here may release a live Job handle or restart a command.
        while True:
            observe_deadline(phase)
            native, active = None, None
            try:
                native = process.poll() if process is not None else None
            except BaseException as error:
                observation_error('same-process-poll', error)
            try:
                active = job.active() if job is not None else 0
            except BaseException as error:
                observation_error('same-job-accounting', error)
            report['lastObservedActiveProcesses'] = active
            if (process is None or native is not None) and active == 0:
                report.update(nativeExitCode=native, treeTerminal=True,
                              treeExitedWithoutTermination=True, activeProcessesBeforeCleanup=0,
                              naturalTerminationObservedAfterDeadline=report['timedOut'])
                return
            try:
                time.sleep(0.05)
            except BaseException as error:
                observation_error('natural-observation-wait', error)

    def close_launcher_input():
        # Before gate release, EOF makes this launcher exit 93 on its own.
        while process is not None and process.stdin is not None and not process.stdin.closed:
            try:
                process.stdin.close()
            except BaseException as error:
                observation_error('launcher-stdin-close', error)
                observe_deadline('waiting-for-launcher-stdin-close')
                try:
                    time.sleep(0.05)
                except BaseException as wait_error:
                    observation_error('launcher-stdin-close-wait', wait_error)
    try:
        if args.action == 'run' and stage['requiredSuccessfulPubStage'] is not None:
            check(args.pub_attempt is not None and re.fullmatch(r'[a-z][a-z0-9-]{0,63}', args.pub_attempt),
                  'Explicit actual same-project pub attempt required')
            prior_path = base / 'out' / (args.pub_attempt + '-result.json')
            hierarchy(prior_path.parent)
            real(prior_path)
            prior = read(prior_path)
            pub_stage = stages[stage['requiredSuccessfulPubStage']]
            check(prior.get('status') == 'EXIT_OBSERVED_UNCLASSIFIED' and prior.get('stage') == pub_stage['id']
                  and prior.get('command') == pub_stage['command']
                  and prior.get('cwd') == str(formatted_src / pub_stage['cwdRelativeToFormattedSrc'])
                  and prior.get('rawManifestSha256') == args.expected_raw_manifest_sha256
                  and prior.get('formattedManifestSha256') == args.expected_formatted_manifest_sha256
                  and prior.get('preparedManifestSha256') == args.expected_prepared_manifest_sha256
                  and prior.get('formatRootFactsSha256') == args.expected_format_root_facts_sha256
                  and prior.get('runnerSha256') == args.expected_runner_sha256
                  and prior.get('specSha256') == args.expected_spec_sha256 and prior.get('nativeExitCode') == 0
                  and prior.get('sdkStarted') is True and prior.get('gateReleased') is True
                  and prior.get('sourceUnchanged') is True and prior.get('timedOut') is False
                  and prior.get('treeExitedWithoutTermination') is True and prior.get('treeTerminal') is True
                  and prior.get('activeProcessesBeforeCleanup') == 0 and prior.get('forcedTerminationUsed') is False
                  and all(elapsed_valid(prior.get(k), 180) for k in ('elapsedMonotonicSeconds', 'elapsedWallSeconds')),
                  'Actual same-project/source/tool natural pub0 required')
            prior_log = ref_guard(prior['log'])
            prior_metadata = prior['pubRuntimePins']
            check(prior.get('pubProjectRoot') == stage['cwdRelativeToFormattedSrc'], 'Different project pub prerequisite')
            check(set(prior_metadata) == {stage['cwdRelativeToFormattedSrc'] + '/' + p for p in META_NAMES},
                  'Exact same-project pub metadata footprint required')
            metadata_guard(formatted_src, prior_metadata)
            protected.update({prior_path: sha(prior_path), prior_log: prior['log']['sha256']})
            report['prerequisitePub'] = inventory(prior_path)
        else:
            check(args.pub_attempt is None, 'Pub has no preceding pub attempt')
        unchanged()
        budget('after-current-source-and-prerequisite-guards')
        class Memory(ctypes.Structure):
            _fields_ = [('length', ctypes.c_ulong), ('load', ctypes.c_ulong)] + [
                (n, ctypes.c_ulonglong) for n in ('total', 'available', 'page', 'freepage', 'virtual', 'freevirtual', 'extended')]
        memory = Memory()
        memory.length = ctypes.sizeof(memory)
        check(ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(memory)), 'Memory observation failed')
        report.update(availableMemoryBytes=memory.available, availableCDiskBytes=shutil.disk_usage('C:/').free,
            availableDDiskBytes=shutil.disk_usage('D:/').free, pythonPointerBits=ctypes.sizeof(ctypes.c_void_p) * 8)
        check(memory.available >= 2 * 1024**3 and report['availableCDiskBytes'] >= 1024**3
              and report['availableDDiskBytes'] >= 2_000_000_000 and report['pythonPointerBits'] == 64,
              'RESOURCE_GATE_REJECTED; SDK_NOT_STARTED')
        if args.action == 'format':
            budget('before-exclusive-format-attempt')
            write_new(claim_path, dict(status='FORMAT_ATTEMPT_STARTED', attempt=args.attempt, runner=inventory(own),
                spec=inventory(SPEC), preparedManifest=inventory(prepared_manifest), sdkStartedAtClaim=False, accepted=False))
            protected[claim_path] = sha(claim_path)
        runtime.mkdir()
        hierarchy(runtime)
        cli_config = runtime / 'dart-cli-config'
        cli_config.mkdir()
        env = dict(os.environ, TEMP=str(runtime), TMP=str(runtime), APPDATA=str(cli_config), CI='true',
            PYTHONDONTWRITEBYTECODE='1', CHROME_EXECUTABLE=spec['chromeExecutable'],
            FLUTTER_ROOT='D:/softwares/flutter', FLUTTER_SUPPRESS_ANALYTICS='true', DART_SUPPRESS_ANALYTICS='true')
        helper_spec = importlib.util.spec_from_file_location('frontend_r4_owned_job', HELPER)
        helper = importlib.util.module_from_spec(helper_spec)
        helper_spec.loader.exec_module(helper)
        unchanged()
        budget('after-prelaunch-current-source-guards')
        job = helper.OwnedJob()
        # The helper defaults to KILL_ON_JOB_CLOSE. Remove that flag before
        # creating any process, so even an external observer failure cannot kill
        # the tree merely by ending this runner and closing its Job handle.
        check(job.active() == 0, 'New owned Job must be empty before configuring natural observation')
        natural_limits = helper.ExtendedLimits()
        check(job.api.SetInformationJobObject(job.handle, 9, ctypes.byref(natural_limits),
                                             ctypes.sizeof(natural_limits)),
              'Could not clear KILL_ON_JOB_CLOSE before process creation')
        observed_limits = helper.ExtendedLimits()
        check(job.api.QueryInformationJobObject(job.handle, 9, ctypes.byref(observed_limits),
                                               ctypes.sizeof(observed_limits), None)
              and not (observed_limits.Basic.Flags & 0x2000),
              'Natural observation Job must not retain KILL_ON_JOB_CLOSE')
        report['killOnJobCloseDisabled'] = True
        launcher = ("import sys,json,subprocess,time; gate=sys.stdin.readline(); "
            "sys.exit(93) if gate!='OWNED_JOB_READY\\n' else None; "
            "clock=json.loads(sys.argv[2]); "
            "expired=not (clock[0]<=time.monotonic()<clock[2] and clock[1]<=time.time()<clock[3]); "
            "print('OWNED_JOB_SDK_DEADLINE_REJECTED',flush=True) if expired else None; "
            "sys.exit(94) if expired else None; "
            "sys.exit(subprocess.call(json.loads(sys.argv[1])))")
        with log_path.open('xb') as log:
            budget('before-owned-launcher-popen')
            report['launcherCreationAttempted'] = True
            process = subprocess.Popen([sys.executable, '-I', '-B', '-c', launcher, json.dumps(command),
                json.dumps([started, wall, deadline_mono, deadline_wall])], cwd=cwd, env=env,
                stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT, bufsize=0,
                creationflags=subprocess.CREATE_NO_WINDOW)
            report['launcherCreationReturned'] = True
            report['ownedPid'] = process.pid
            job.assign(process)
            assigned = True
            budget('before-sdk-gate-release')
            report['gateReleaseAttempted'] = True
            gate = b'OWNED_JOB_READY\n'
            check(process.stdin.write(gate) == len(gate), 'Incomplete launcher gate delivery')
            report.update(gateReleased=True, sdkStarted=True)
            close_launcher_input()
            observe_natural('same-owned-command-observation')
            report['launcherDeadlineRejected'] = report['nativeExitCode'] == 94 and (
                log_path.read_text('utf-8').splitlines() == ['OWNED_JOB_SDK_DEADLINE_REJECTED'])
            if report['launcherDeadlineRejected']:
                report['sdkStarted'] = False
        check(report['nativeExitCode'] == 0 and report['timedOut'] is False
              and report['treeExitedWithoutTermination'] is True and report['activeProcessesBeforeCleanup'] == 0
              and report['forcedTerminationUsed'] is False and report['treeTerminal'] is True
              and not report['observationErrors'],
              'Natural bounded SDK0/process-tree gate failed')
        if args.action == 'format':
            actual = {p: sha(formatted_src / p) for p in pins}
            source_guard(formatted_src, actual)
            check(all(actual[p] == h for p, h in pins.items() if p not in targets), 'Format changed a non-target source')
            formatted_pins = actual
            write_new(formatted_manifest, dict(schemaVersion='1.0.0', status='DRAFT_FORMATTED_PENDING_EXTERNAL_EXIT',
                sourceCount=len(pins), sourceSha256=actual, rawManifest=inventory(raw_manifest), spec=inventory(SPEC),
                runner=inventory(own), preparedManifest=inventory(prepared_manifest), formatAttempt=inventory(claim_path),
                formatCommand=command, formatTargets=targets, formatLog=inventory(log_path), formatted=True,
                formatCompleteCommandExternallyAccepted=False, frozenForAcceptance=False, accepted=False,
                wholeProductComplete=False, deployed=False))
            report['sourceManifest'] = inventory(formatted_manifest)
            protected[formatted_manifest] = sha(formatted_manifest)
            report['status'] = 'OBSERVATION_PENDING_EXTERNAL_EXIT'
        else:
            if stage['kind'] == 'pub':
                current_metadata = metadata_snapshot(formatted_src, stage['cwdRelativeToFormattedSrc'])
                report.update(pubProjectRoot=stage['cwdRelativeToFormattedSrc'], pubRuntimePins=current_metadata)
            elif stage['kind'] == 'test':
                report['reporterFacts'] = reporter_facts(log_path, stage, formatted_src)
            elif stage['kind'] == 'production':
                assets = formatted_src / 'apps/guardian/build/production-web'
                files = disk_files(assets)
                check(set(required_assets) <= files, 'Declared required production assets missing')
                check(not any(p.endswith(('.map', '.tmp', '.log')) for p in files), 'Unexpected production scratch/source map')
                report.update(productionAssetCount=len(files), productionRequiredAssets=required_assets)
                report['productionAssets'] = [inventory(assets / p) for p in sorted(files)]
            report['status'] = 'EXIT_OBSERVED_UNCLASSIFIED'
    except BaseException as error:
        report.update(status='OBSERVATION_REJECTED', reason=repr(error))
    finally:
        close_launcher_input()
        observe_natural('same-owned-tree-final-observation')
        if report['launcherCreationAttempted'] and not report['launcherCreationReturned']:
            report.update(status='OBSERVATION_REJECTED', treeTerminal=False,
                          lifecycleIndeterminate=True,
                          reason='LAUNCHER_CREATION_DID_NOT_RETURN_AN_OBSERVABLE_HANDLE')
        if job is not None:
            while True:
                try:
                    active = job.active()
                except BaseException as error:
                    observation_error('before-empty-job-close', error)
                    observe_natural('retry-same-job-accounting-before-close')
                    continue
                if active != 0:
                    observe_natural('same-job-still-active-before-close')
                    continue
                report['activeProcessesBeforeFinalCleanup'] = 0
                try:
                    job.close()
                except BaseException as error:
                    report.update(status='OBSERVATION_REJECTED', cleanupError=repr(error))
                break
        try:
            report['sourceUnchanged'] = unchanged()
            if log_path.exists():
                report['log'] = inventory(log_path)
        except Exception as error:
            report.update(status='OBSERVATION_REJECTED', sourceUnchanged=False, finalGuardError=repr(error))
        report['generatedPluginLinks'] = generated_link_records()
        observe_deadline('after-final-source-and-link-guards')
        report.update(elapsedMonotonicSeconds=time.monotonic() - started, elapsedWallSeconds=time.time() - wall)
        if not all(elapsed_valid(report[k], limit) for k in ('elapsedMonotonicSeconds', 'elapsedWallSeconds')):
            report.update(status='OBSERVATION_REJECTED', reason='COMPLETE_INTERNAL_STAGE_CLOCK_EXCEEDED')
        write_new(result_path, report)
        print(json.dumps(dict(status=report['status'], result=inventory(result_path),
            nativeExitCode=report['nativeExitCode'], sourceUnchanged=report.get('sourceUnchanged'),
            treeTerminal=report['treeTerminal'], forcedTerminationUsed=report['forcedTerminationUsed'],
            elapsedMonotonicSeconds=report['elapsedMonotonicSeconds'], elapsedWallSeconds=report['elapsedWallSeconds'],
            accepted=False), ensure_ascii=True), flush=True)
    return 0 if report['status'] in ('OBSERVATION_PENDING_EXTERNAL_EXIT', 'EXIT_OBSERVED_UNCLASSIFIED') else 1


if __name__ == '__main__':
    sys.exit(main())
