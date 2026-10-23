"""Pure metadata validation for exactly the 80 selected browser cases.

Protocol 0.1.1 was checked against the existing test_core 0.6.0 JSON reporter.
This module starts no process and reads no files; callers supply bytes/metadata.
"""
import json
import ntpath
import re

BOOTSTRAP_LINE = 'Flutter assets will be downloaded from http://127.0.0.1:9. Make sure you trust this source!'
CACHE_BASE_SHA256 = '0027b4f8d65b9054e273b3c98a8b62f8de963fe9b59e054bf750eaae1cc6f3c2'
BROWSER_CACHE_STATUS = 'BROWSER_CHROME_REFRESH_FROM_FIXED_BASE_NOT_RUNTIME_VALIDATION'


def demand(value, message):
    if not value:
        raise ValueError(message)


def integer(value):
    return type(value) is int and value >= 0


def suite_path(value, module):
    demand(isinstance(value, str) and value and '\x00' not in value,
           'Suite path must be a nonempty local path')
    demand('://' not in value, 'Unexpected suite URI instead of a local path')
    base = ntpath.normcase(ntpath.normpath(module))
    target = ntpath.normcase(ntpath.normpath(value if ntpath.isabs(value) else ntpath.join(base, value)))
    demand(ntpath.commonpath([base, target]) == base and target != base,
           'Suite lies outside the frozen Guardian package')
    return ntpath.relpath(target, base).replace('\\', '/')


def validate_cache_refresh(base, derived, approved_chrome):
    demand(base.get('status') == 'READ_ONLY_CONTENT_COLLECTION_COMPLETE_NOT_SDK_VALIDATION'
           and base.get('totals', {}).get('files') == 3537,
           'Unexpected original cache collection boundary')
    demand(len(base.get('trees', [])) == 70 and len(base.get('fixedFiles', [])) == 33,
           'Original cache tree/runtime boundary differs')
    chrome = ntpath.normcase(ntpath.normpath(approved_chrome['path']))
    indices = [index for index, row in enumerate(base['fixedFiles'])
               if ntpath.normcase(ntpath.normpath(row['path'])) == chrome]
    demand(len(indices) == 1, 'Exactly one Chrome executable row must be replaced')
    index = indices[0]
    before = base['fixedFiles'][index]
    expected = json.loads(json.dumps(base))
    after = expected['fixedFiles'][index]
    demand(type(approved_chrome['bytes']) is int and approved_chrome['bytes'] > 0
           and re.fullmatch('[0-9a-f]{64}', approved_chrome['sha256']) is not None,
           'Approved Chrome executable pin is malformed')
    after.update(bytes=approved_chrome['bytes'], sha256=approved_chrome['sha256'])
    if 'expectedSha256' in after:
        after['expectedSha256'] = approved_chrome['sha256']
    expected['totals']['bytes'] += after['bytes'] - before['bytes']
    expected['status'] = BROWSER_CACHE_STATUS
    change = derived.get('browserChromeRefresh')
    demand(type(change) is dict and change.get('baseManifestSha256') == CACHE_BASE_SHA256
           and change.get('onlyExistingChromeExecutableRowRefreshed') is True
           and change.get('otherPinnedFilesKeptWithoutRebaseline') == 3536
           and change.get('originalChromeRow') == before
           and change.get('approvedChromeExecutable') == approved_chrome,
           'Derived Chrome-only provenance is incomplete')
    expected['browserChromeRefresh'] = change
    demand(derived == expected, 'Derived manifest changed an entry outside the single approved Chrome row')
    return {'status':'SINGLE_CHROME_ROW_REFRESH_METADATA_MATCHES', 'baseManifestSha256':CACHE_BASE_SHA256,
            'changedFixedRows':1, 'unchangedPinnedFiles':3536, 'allCacheFilesStillRequiredAtRuntime':3537,
            'chromeExecutable':approved_chrome, 'entireChromeInstallationPinned':False}


def validate_report(raw, contract, module, native_exit_code):
    demand(type(native_exit_code) is int and native_exit_code == 0,
           'Natural native exit zero is required')
    demand(isinstance(raw, bytes) and len(raw) <= 16 * 1024**2, 'Report exceeds the fixed evidence limit')
    expected = {(row['selector'], row['name']) for row in contract['cases']}
    selectors = set(contract['selectors'])
    demand(len(expected) == 80 and len(contract['cases']) == 80 and len(selectors) == 7,
           'Expected contract must contain exactly 80 distinct cases in seven physical suites')
    demand({path for path, name in expected} == selectors, 'Expected case/suite contract differs')
    text = raw.decode('utf-8-sig', errors='strict')
    lines = text.splitlines()
    demand(len(lines) <= 100000, 'Too many reporter lines')
    events = []
    bootstrap = 0
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        if line == BOOTSTRAP_LINE:
            demand(not events and bootstrap == 0, 'Bootstrap notice repeated or appeared during reporter output')
            bootstrap += 1
            continue
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, TypeError) as error:
            raise ValueError('Unexpected non-JSON or malformed reporter line ' + str(number)) from error
        demand(type(event) is dict and isinstance(event.get('type'), str), 'Reporter event must be an object with a type')
        events.append(event)
    demand(events and events[0]['type'] == 'start' and events[-1]['type'] == 'done',
           'One complete start-to-done reporter stream is required')
    suites, groups, tests, finished = {}, {}, {}, {}
    seen_ids = set()
    starts = suite_counts = done_count = 0
    previous_time = -1
    printed = 0
    for event in events:
        kind = event['type']
        when = event.get('time')
        demand(integer(when) and when >= previous_time, 'Reporter time is invalid or moved backwards')
        previous_time = when
        demand(done_count == 0, 'Event appeared after terminal done')
        if kind == 'start':
            starts += 1
            demand(starts == 1 and event is events[0] and event.get('protocolVersion') == '0.1.1',
                   'Unexpected protocol version or duplicate start')
            demand(integer(event.get('pid')) and event['pid'] > 0, 'Missing reporter process identity')
        elif kind == 'allSuites':
            suite_counts += 1
            demand(suite_counts == 1 and type(event.get('count')) is int and event['count'] == 7,
                   'Exactly one allSuites event for seven physical suites is required')
        elif kind == 'suite':
            row = event.get('suite')
            demand(type(row) is dict and integer(row.get('id')) and row['id'] not in seen_ids,
                   'Duplicate or invalid suite ID')
            demand(row.get('platform') == 'chrome', 'A selected suite did not run on Chrome')
            path = suite_path(row.get('path'), module)
            demand(path in selectors and path not in suites.values(), 'Unexpected or duplicate suite path')
            suites[row['id']] = path
            seen_ids.add(row['id'])
        elif kind == 'group':
            row = event.get('group')
            demand(type(row) is dict and integer(row.get('id')) and row['id'] not in seen_ids,
                   'Duplicate or invalid group ID')
            demand(row.get('suiteID') in suites, 'Group refers to an unknown suite')
            parent = row.get('parentID')
            demand(parent is None or (parent in groups and groups[parent] == row['suiteID']),
                   'Group parent ownership differs')
            groups[row['id']] = row['suiteID']
            seen_ids.add(row['id'])
        elif kind == 'testStart':
            row = event.get('test')
            demand(type(row) is dict and integer(row.get('id')) and row['id'] not in seen_ids,
                   'Duplicate or invalid test ID')
            demand(row.get('suiteID') in suites and isinstance(row.get('name'), str),
                   'Test refers to an unknown suite or lacks a name')
            memberships = row.get('groupIDs')
            demand(type(memberships) is list and all(integer(group) and groups.get(group) == row['suiteID'] for group in memberships),
                   'Test group membership differs from its suite')
            tests[row['id']] = {'selector':suites[row['suiteID']], 'name':row['name']}
            seen_ids.add(row['id'])
        elif kind == 'testDone':
            test_id = event.get('testID')
            demand(integer(test_id) and test_id in tests and test_id not in finished,
                   'Unknown or duplicate test completion')
            demand(event.get('result') == 'success' and event.get('skipped') is False
                   and type(event.get('hidden')) is bool,
                   'Failed, errored, skipped or malformed test completion')
            finished[test_id] = event['hidden']
        elif kind == 'print':
            demand(event.get('testID') in tests and event.get('messageType') == 'print'
                   and isinstance(event.get('message'), str),
                   'Unknown test output or skip diagnostic')
            printed += 1
        elif kind == 'error':
            raise ValueError('Reporter error event; late errors also reject the complete run')
        elif kind == 'done':
            done_count += 1
            demand(event.get('success') is True, 'Terminal done did not report success')
        else:
            raise ValueError('Unexpected reporter event type: ' + kind)
    demand(starts == suite_counts == done_count == 1 and len(suites) == 7,
           'Start, suite discovery or terminal completion is incomplete')
    demand(set(tests) == set(finished), 'A started test never completed')
    visible, hidden = [], []
    for test_id, row in tests.items():
        pair = (row['selector'], row['name'])
        if finished[test_id]:
            demand(pair not in expected, 'An expected application case was hidden instead of executed visibly')
            hidden.append({'testID':test_id, **row})
        else:
            visible.append({'testID':test_id, **row})
    pairs = [(row['selector'], row['name']) for row in visible]
    demand(len(pairs) == 80 and len(set(pairs)) == 80 and set(pairs) == expected,
           'Actual visible test names do not match the exact 80-case contract')
    return {'status':'EXACT_BROWSER80_REPORT_ACCEPTED', 'protocolVersion':'0.1.1',
            'suitePaths':sorted(suites.values()), 'suiteCount':7, 'visibleTests':80,
            'successfulVisibleTests':80, 'failures':0, 'errors':0, 'skipped':0,
            'actualVisibleCases':visible, 'hiddenSuccessfulTests':hidden,
            'allStartedTestsCompleted':True, 'terminalDoneSuccess':True,
            'naturalNativeExitCode':native_exit_code, 'printEvents':printed,
            'eventCount':len(events), 'bootstrapNotices':bootstrap}
