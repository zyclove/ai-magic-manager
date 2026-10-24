"""File-only JSON reporter validation for the fixed four-root VM35 selection.

No runner, process, SDK or network API is used.  A rejected report raises
ValueError; an accepted report still needs the caller's native exit/Job checks.
"""
from pathlib import Path
import hashlib
import json
import math
import ntpath
import os
import stat


BOOTSTRAP_LINE = 'Flutter assets will be downloaded from http://127.0.0.1:9. Make sure you trust this source!'
SELECTORS = ('test/workbench_view_test.dart', 'test/dialog_submit_guard_test.dart', 'test/failure_view_test.dart', 'test/login_view_test.dart')
MAX_LOG_BYTES = 16 * 1024 * 1024


def _require(value, message):
    if value is not True:
        raise ValueError(message)


def _integer(value):
    return type(value) is int and value >= 0


def _pairs(items):
    result = {}
    for key, value in items:
        _require(key not in result, 'Duplicate JSON key: ' + key)
        result[key] = value
    return result


def _constant(value):
    raise ValueError('Nonfinite JSON constant: ' + value)


def _finite_json(value):
    pending = [value]
    while pending:
        item = pending.pop()
        if type(item) is float:
            _require(math.isfinite(item), 'Nonfinite JSON number')
        elif type(item) is dict:
            pending.extend(item.values())
        elif type(item) is list:
            pending.extend(item)


def _metadata(value):
    _require(type(value) is dict and set(value) == {'skip', 'skipReason'}
             and value['skip'] is False and value['skipReason'] is None,
             'Skipped or malformed reporter metadata')


def _module_path(module):
    _require(isinstance(module, Path), 'Module must be a Path')
    text = os.fspath(module)
    drive, tail = ntpath.splitdrive(text)
    _require(bool(drive) and ntpath.isabs(text) and not text.startswith(('\\\\', '//'))
             and ':' not in tail and '\x00' not in text,
             'Module must be a local absolute non-ADS path')
    return ntpath.normcase(ntpath.normpath(text))


def _suite_path(value, base):
    _require(type(value) is str and bool(value) and '\x00' not in value
             and '://' not in value and not value.startswith(('\\\\', '//')),
             'Suite path must be a local path')
    drive, tail = ntpath.splitdrive(value)
    _require(':' not in tail and (not drive or ntpath.isabs(value)),
             'Drive-relative or ADS suite path refused')
    target = ntpath.normcase(ntpath.normpath(
        value if ntpath.isabs(value) else ntpath.join(base, value)))
    try:
        contained = ntpath.commonpath([base, target]) == base and target != base
    except ValueError as error:
        raise ValueError('Suite drive differs from the frozen module') from error
    _require(contained, 'Suite lies outside the frozen Guardian module')
    return ntpath.relpath(target, base).replace('\\', '/')


def _read_log(log):
    _require(isinstance(log, Path), 'Log must be a Path')
    text = os.fspath(log)
    drive, tail = ntpath.splitdrive(text)
    _require(bool(drive) and ntpath.isabs(text) and not text.startswith(('\\\\', '//'))
             and ':' not in tail and '\x00' not in text,
             'Log must be a local absolute non-ADS path')
    for item in (log, *log.parents):
        if os.path.lexists(item):
            info = item.lstat()
            _require(not stat.S_ISLNK(info.st_mode)
                     and not (getattr(info, 'st_file_attributes', 0) & 0x400),
                     'Linked/reparse log path refused')
    first = log.stat()
    _require(stat.S_ISREG(first.st_mode) and 0 < first.st_size <= MAX_LOG_BYTES,
             'Missing/nonregular/empty/oversized JSON reporter log')
    raw = log.read_bytes()
    last = log.stat()
    identity = lambda row: (row.st_dev, row.st_ino, row.st_nlink,
                            row.st_size, row.st_mtime_ns)
    _require(identity(first) == identity(last) and len(raw) == first.st_size,
             'Reporter log changed while reading')
    _require(raw.endswith(b'\n'), 'Truncated JSONL reporter line')
    return raw


def _expected(contract):
    _require(type(contract) is dict and type(contract.get('schemaVersion')) is int
             and contract['schemaVersion'] == 1
             and contract.get('module') == 'apps/guardian'
             and contract.get('platform') == 'default Flutter VM tester'
             and type(contract.get('selectors')) is list
             and contract['selectors'] == list(SELECTORS)
             and type(contract.get('expectedVisibleCases')) is int
             and contract['expectedVisibleCases'] == 35
             and type(contract.get('expectedTestRoots')) is int
             and contract['expectedTestRoots'] == 4
             and type(contract.get('sourceCaseCounts')) is list
             and all(type(value) is int for value in contract['sourceCaseCounts'])
             and contract['sourceCaseCounts'] == [15, 6, 9, 5],
             'The exact four-root VM35 contract is required')
    rows = contract.get('cases')
    _require(type(rows) is list and len(rows) == 35, 'Expected thirty-five case rows')
    expected = set()
    for row in rows:
        _require(type(row) is dict and type(row.get('selector')) is str
                 and row['selector'] in SELECTORS and type(row.get('name')) is str
                 and bool(row['name'].strip()), 'Invalid expected case row')
        pair = (row['selector'], row['name'])
        _require(pair not in expected, 'Duplicate expected case')
        expected.add(pair)
    _require([sum(path == selector for path, name in expected)
              for selector in SELECTORS] == [15, 6, 9, 5], 'Expected suite counts differ')
    return expected


def validate_report(log: Path, contract: dict, module: Path) -> dict:
    """Validate fixed JSONL evidence without running tests or acceptance code."""
    expected = _expected(contract)
    base = _module_path(module)
    try:
        raw = _read_log(log)
    except OSError as error:
        raise ValueError('Reporter log could not be read safely') from error
    try:
        text = raw.decode('utf-8-sig', errors='strict')
    except UnicodeDecodeError as error:
        raise ValueError('Reporter log is not strict UTF-8') from error
    lines = text.split('\n')
    _require(lines[-1] == '', 'Reporter JSONL terminator missing')
    lines.pop()
    _require(len(lines) <= 100000, 'Too many reporter lines')
    events, bootstrap = [], 0
    for index, original in enumerate(lines):
        line = original[:-1] if original.endswith('\r') else original
        if index == 0 and line == BOOTSTRAP_LINE:
            bootstrap = 1
            continue
        _require(bool(line.strip()), 'Blank non-JSON reporter line')
        try:
            event = json.loads(line, object_pairs_hook=_pairs,
                               parse_constant=_constant)
        except (json.JSONDecodeError, RecursionError) as error:
            raise ValueError('Malformed/truncated reporter JSON line ' + str(index + 1)) from error
        _finite_json(event)
        _require(type(event) is dict and type(event.get('type')) is str,
                 'Reporter event must be an object with a type')
        events.append(event)
    _require(bool(events) and events[0]['type'] == 'start'
             and events[-1]['type'] == 'done', 'Complete start-to-done stream required')

    suites, groups, tests, finished = {}, {}, {}, {}
    allocated, completed_pairs = set(), set()
    starts = discovered = done_count = print_count = 0
    previous_time = -1
    for event in events:
        kind, when = event['type'], event.get('time')
        _require(_integer(when) and when >= previous_time,
                 'Reporter time is invalid or moved backwards')
        previous_time = when
        _require(done_count == 0, 'Event appeared after terminal done')
        if kind == 'start':
            starts += 1
            _require(starts == 1 and event is events[0]
                     and event.get('protocolVersion') == '0.1.1'
                     and _integer(event.get('pid')) and event['pid'] > 0
                     and 'runnerVersion' in event
                     and (event['runnerVersion'] is None
                          or (type(event['runnerVersion']) is str
                              and bool(event['runnerVersion']))), 'Invalid/duplicate reporter start')
        elif kind == 'allSuites':
            discovered += 1
            _require(discovered == 1 and type(event.get('count')) is int
                     and event['count'] == 4, 'Exactly four discovered suites required')
        elif kind == 'suite':
            row = event.get('suite')
            _require(type(row) is dict and _integer(row.get('id'))
                     and row['id'] not in allocated and row.get('platform') == 'vm',
                     'Invalid/duplicate/non-VM suite')
            path = _suite_path(row.get('path'), base)
            _require(path in SELECTORS and path not in suites.values(),
                     'Unknown or duplicate source selector')
            suites[row['id']] = path
            allocated.add(row['id'])
        elif kind == 'group':
            row = event.get('group')
            _require(type(row) is dict and _integer(row.get('id'))
                     and row['id'] not in allocated and _integer(row.get('suiteID'))
                     and row['suiteID'] in suites and type(row.get('name')) is str
                     and _integer(row.get('testCount')), 'Invalid/duplicate group')
            parent = row.get('parentID')
            _require(parent is None or (_integer(parent) and parent in groups
                     and groups[parent]['suiteID'] == row['suiteID']),
                     'Group parent ownership differs')
            _metadata(row.get('metadata'))
            groups[row['id']] = {'suiteID': row['suiteID'], 'parentID': parent}
            allocated.add(row['id'])
        elif kind == 'testStart':
            row = event.get('test')
            _require(type(row) is dict and _integer(row.get('id'))
                     and row['id'] not in allocated and _integer(row.get('suiteID'))
                     and row['suiteID'] in suites and type(row.get('name')) is str
                     and bool(row['name'].strip()), 'Invalid/duplicate test start')
            _metadata(row.get('metadata'))
            memberships = row.get('groupIDs')
            _require(type(memberships) is list and all(_integer(value) for value in memberships)
                     and len(set(memberships)) == len(memberships), 'Invalid test group IDs')
            parent = None
            for group in memberships:
                _require(group in groups and groups[group]['suiteID'] == row['suiteID']
                         and groups[group]['parentID'] == parent,
                         'Test group chain differs from its suite')
                parent = group
            tests[row['id']] = {'selector': suites[row['suiteID']],
                                'name': row['name'], 'groupIDs': memberships}
            allocated.add(row['id'])
        elif kind == 'testDone':
            test_id = event.get('testID')
            _require(_integer(test_id) and test_id in tests and test_id not in finished,
                     'Unknown or duplicate test completion')
            _require(event.get('result') == 'success' and event.get('skipped') is False
                     and type(event.get('hidden')) is bool,
                     'Failed/errored/skipped/malformed test completion')
            row = tests[test_id]
            pair = (row['selector'], row['name'])
            _require(pair not in completed_pairs, 'Duplicate completed case name')
            completed_pairs.add(pair)
            if event['hidden']:
                _require(pair not in expected, 'Expected VM35 case was hidden')
            else:
                _require(pair in expected, 'Unexpected visible case name')
            finished[test_id] = event['hidden']
        elif kind == 'print':
            _require(_integer(event.get('testID')) and event['testID'] in tests
                     and event.get('messageType') == 'print'
                     and type(event.get('message')) is str,
                     'Unknown test output or skip diagnostic')
            print_count += 1
        elif kind == 'error':
            raise ValueError('Reporter error event, including errors after test completion')
        elif kind == 'done':
            done_count += 1
            _require(event.get('success') is True, 'Terminal done was false/null/missing success')
        else:
            raise ValueError('Unknown reporter event type: ' + kind)

    _require(starts == discovered == done_count == 1 and len(suites) == 4,
             'Incomplete start/suite discovery/terminal completion')
    _require(set(tests) == set(finished), 'Started test did not complete')
    visible, hidden = [], []
    for test_id, row in tests.items():
        entry = {'selector': row['selector'], 'name': row['name'], 'testID': test_id,
                 'result': 'success', 'skipped': False, 'hidden': finished[test_id]}
        (hidden if finished[test_id] else visible).append(entry)
    visible.sort(key=lambda row: (row['selector'], row['name']))
    hidden.sort(key=lambda row: (row['selector'], row['name']))
    actual = [(row['selector'], row['name']) for row in visible]
    _require(len(actual) == 35 and len(set(actual)) == 35 and set(actual) == expected,
             'Visible names do not match all thirty-five expected VM cases')
    return {'status': 'EXACT_VM35_REPORT_ACCEPTED', 'protocolVersion': '0.1.1',
            'expectedSuiteCount': 4, 'actualSuiteCount': 4, 'suiteCount': 4,
            'suitePaths': sorted(suites.values()), 'expectedVisibleTests': 35,
            'visibleTests': 35, 'successfulVisibleTests': 35,
            'failures': 0, 'errors': 0, 'skipped': 0,
            'actualVisibleCases': visible, 'hiddenSuccessfulTests': hidden,
            'allStartedTestsCompleted': True, 'terminalDoneSuccess': True,
            'eventCount': len(events), 'printEvents': print_count,
            'bootstrapNotices': bootstrap,
            'logPin': {'path': str(log), 'bytes': len(raw),
                       'sha256': hashlib.sha256(raw).hexdigest()},
            'nativeExitAndJobChecksRemainCallerResponsibility': True}
