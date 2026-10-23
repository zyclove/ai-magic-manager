"""Independent synthetic metadata checks; no candidate module is imported.

Only five reviewed pure reporter function AST definitions and three literal
constants are evaluated. These are metadata fixtures, never application tests.
The inherited primary-source read is attributed to the original r1 receipt.
"""
from pathlib import Path
import ast
import copy
import datetime
import hashlib
import json
import ntpath
import os
import re

ROOT = Path(__file__).absolute().parent
PRIOR = ROOT.parent / 'guardian-browser31-20261023-r1'
FUNCTIONS = {'demand', 'integer', 'suite_path', 'validate_cache_refresh', 'validate_report'}
CONSTANTS = {'BOOTSTRAP_LINE', 'CACHE_BASE_SHA256', 'BROWSER_CACHE_STATUS'}
SELECTORS = ['test/workspace_flow_entry_browser_test.dart', 'test/audit_export_route_test.dart',
             'test/approval_help_flow_browser_test.dart', 'test/notification_help_scope_browser_test.dart']
NEW_NAMES = [
    'real selection invalidates late inbox GET and Help count before membership resolves, and failure cannot restore them',
    'late markRead and retained actions stay inert after real selection then failure',
    'late markRead and retained actions stay inert after dispose',
    'a fresh repository can read while the old read is pending; retained View callbacks and old completion keep their owner',
    'fixed host keys fail closed when Session instance changes; fresh host keys attach and dispose listeners correctly',
    'fresh shell entries navigate, read and open current approval after real successful workspace selection',
    'SYNTHETIC optional actor ABA never revives held host scopes',
]
EXPECTED_SOURCE_PINS = [
    (11874, '15fb4c531970c6488438d78e4c35265c51286159c8c462a3f8938ad39c995736'),
    (6429, 'beff27499cbf2a10eeb469c930027218a56c8094a803f2e471fdb76f16659d20'),
    (13713, '845cb4f4b5a65cf126080861b7e29bd579a0101f5b3be437c1394bf7c0be0127'),
    (22316, '7db37e189d9e162ee901b8d536a6e6845ae42a00ec3ce01a0108956902e3016e'),
]


def pin(path):
    raw = path.read_bytes()
    return {'path': str(path), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def write_new(path, value):
    with path.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def reviewed_pure_functions(source):
    tree = ast.parse(source.decode('utf-8'))
    functions, constants, nodes = {}, {}, []
    allowed_calls = FUNCTIONS | {'type', 'isinstance', 'len', 'set', 'sorted', 'all',
                                'enumerate', 'str', 'ValueError'}
    allowed_methods = {'add', 'get', 'update', 'loads', 'dumps', 'normcase', 'normpath',
                       'isabs', 'join', 'commonpath', 'relpath', 'replace', 'fullmatch',
                       'decode', 'splitlines', 'strip', 'append', 'values', 'items'}
    for node in tree.body:
        if isinstance(node, ast.Import):
            assert all(alias.name in {'json', 'ntpath', 're'} and alias.asname is None for alias in node.names)
        elif isinstance(node, ast.Assign):
            assert len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
            assert node.targets[0].id in CONSTANTS
            ast.literal_eval(node.value)
            constants[node.targets[0].id] = node
            nodes.append(node)
        elif isinstance(node, ast.FunctionDef):
            assert node.name in FUNCTIONS and not node.decorator_list
            for child in ast.walk(node):
                assert not isinstance(child, (ast.Import, ast.ImportFrom, ast.Global, ast.Nonlocal))
                if isinstance(child, ast.Name):
                    assert child.id not in {'open', 'exec', 'eval', 'compile', '__import__', 'subprocess', 'os', 'sys', 'Path'}
                if isinstance(child, ast.Attribute):
                    assert not child.attr.startswith('__')
                if isinstance(child, ast.Call):
                    assert (isinstance(child.func, ast.Name) and child.func.id in allowed_calls
                            or isinstance(child.func, ast.Attribute) and child.func.attr in allowed_methods)
            functions[node.name] = node
            nodes.append(node)
        else:
            assert isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)
    assert set(functions) == FUNCTIONS and set(constants) == CONSTANTS
    safe_builtins = {name: value for name, value in {
        'type': type, 'int': int, 'str': str, 'bytes': bytes, 'bool': bool, 'list': list,
        'dict': dict, 'set': set, 'len': len, 'isinstance': isinstance, 'sorted': sorted,
        'all': all, 'enumerate': enumerate, 'ValueError': ValueError, 'TypeError': TypeError,
    }.items()}
    pure = {'__builtins__': safe_builtins, 'json': json, 'ntpath': ntpath, 're': re}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), 'reviewed-pure-browser38-metadata-functions', 'exec'), pure)
    return pure, functions


def events_for(contract):
    events = [{'type': 'start', 'time': 0, 'pid': 12345, 'protocolVersion': '0.1.1'},
              {'type': 'allSuites', 'time': 1, 'count': len(contract['selectors'])}]
    for suite_id, selector in enumerate(contract['selectors']):
        events.append({'type': 'suite', 'time': 2, 'suite': {'id': suite_id, 'platform': 'chrome', 'path': selector}})
    next_id = 10
    for suite_id, selector in enumerate(contract['selectors']):
        events += [{'type': 'testStart', 'time': 3, 'test': {'id': next_id, 'suiteID': suite_id, 'name': 'loading ' + selector, 'groupIDs': []}},
                   {'type': 'testDone', 'time': 4, 'testID': next_id, 'result': 'success', 'skipped': False, 'hidden': True}]
        next_id += 1
    for row in contract['cases']:
        suite_id = contract['selectors'].index(row['selector'])
        events += [{'type': 'testStart', 'time': 5, 'test': {'id': next_id, 'suiteID': suite_id, 'name': row['name'], 'groupIDs': []}},
                   {'type': 'testDone', 'time': 6, 'testID': next_id, 'result': 'success', 'skipped': False, 'hidden': False}]
        next_id += 1
    for when, event in enumerate(events):
        event['time'] = when
    events.append({'type': 'done', 'time': len(events), 'success': True})
    return events


def encode(events):
    return ('\n'.join(json.dumps(row, ensure_ascii=False) for row in events) + '\n').encode('utf-8')


def main():
    outputs = [ROOT / 'independent-metadata-review.json', ROOT / 'reporter-static-review.json']
    assert all(not path.exists() for path in outputs), 'Review outputs must be CreateNew.'
    source = (ROOT / 'reporter_contract_reviewed.py').read_bytes()
    old_source = (PRIOR / 'reporter_contract_reviewed.py').read_bytes()
    expected = re.sub(r'\b31\b', '38', old_source.decode('utf-8'))
    expected = re.sub(r'\b3\b', '4', expected).replace('three physical suites', 'four physical suites')
    expected = expected.replace('EXACT_BROWSER31_REPORT_ACCEPTED', 'EXACT_BROWSER38_REPORT_ACCEPTED')
    assert source.decode('utf-8') == expected, 'Reporter changes exceed the reviewed count/status adaptation.'
    pure, functions = reviewed_pure_functions(source)
    old_tree = ast.parse(old_source.decode('utf-8'))
    old_functions = {node.name: node for node in old_tree.body if isinstance(node, ast.FunctionDef)}
    unchanged_functions = FUNCTIONS - {'validate_report'}
    assert all(ast.dump(functions[name], include_attributes=False) == ast.dump(old_functions[name], include_attributes=False)
               for name in unchanged_functions)
    contract = json.loads((ROOT / 'expected-cases.json').read_bytes())
    old_contract = json.loads((PRIOR / 'expected-cases.json').read_bytes())
    assert contract['sourceCommit'] == 'fa2148954ccec749f7d58c38184a208085bfe181'
    assert contract['sourceFiles'] == 406 and contract['selectors'] == SELECTORS
    assert contract['expectedPhysicalSuites'] == 4 and contract['expectedVisibleCases'] == 38
    assert [(row['selector'], row['expectedVisibleCases']) for row in contract['selectedSources']] == list(zip(SELECTORS, [8, 4, 19, 7]))
    old_pairs = {(row['selector'], row['name']) for row in old_contract['cases']}
    assert {(row['selector'], row['name']) for row in contract['cases'] if row['selector'] in SELECTORS[:3]} == old_pairs
    assert [row['name'] for row in contract['cases'] if row['selector'] == SELECTORS[3]] == NEW_NAMES
    selected_pins = []
    for row, expected_pin in zip(contract['selectedSources'], EXPECTED_SOURCE_PINS):
        actual = pin(Path(row['file']['path']))
        assert (actual['bytes'], actual['sha256']) == expected_pin
        assert actual == row['file']
        selected_pins.append(actual)
    parser_source = Path(contract['sourceNameParser']['path']).read_bytes()
    ast.parse(parser_source.decode('utf-8'))  # Parsing only; name-parser module/functions are not executed.
    assert pin(Path(contract['sourceNameParser']['path'])) == contract['sourceNameParser']
    module = str(ROOT / 'src/apps/guardian')
    events = events_for(contract)
    validate = pure['validate_report']
    good = validate(encode(events), contract, module, 0)
    assert good['suiteCount'] == 4 and good['visibleTests'] == 38 and len(good['hiddenSuccessfulTests']) == 4
    with_bootstrap = validate((pure['BOOTSTRAP_LINE'] + '\n').encode() + encode(events), contract, module, 0)
    assert with_bootstrap['bootstrapNotices'] == 1 and with_bootstrap['visibleTests'] == 38
    negatives = []
    def reject_raw(label, payload, use_contract=contract, native=0):
        try:
            validate(payload, use_contract, module, native)
        except (ValueError, UnicodeError):
            negatives.append(label)
        else:
            raise AssertionError('Invalid synthetic metadata accepted: ' + label)
    def reject(label, change, native=0):
        rows = copy.deepcopy(events)
        change(rows)
        reject_raw(label, encode(rows), native=native)
    visible_start = next(i for i, row in enumerate(events) if row['type'] == 'testStart' and not row['test']['name'].startswith('loading '))
    done = visible_start + 1
    reject('visible failure', lambda rows: rows[done].update(result='failure'))
    reject('visible error result', lambda rows: rows[done].update(result='error'))
    reject('visible skip', lambda rows: rows[done].update(skipped=True))
    reject('hidden expected case', lambda rows: rows[done].update(hidden=True))
    reject('missing visible case', lambda rows: rows.__delitem__(slice(visible_start, done + 1)))
    reject('wrong visible name despite count', lambda rows: rows[visible_start]['test'].update(name='unexpected'))
    reject('duplicate visible name', lambda rows: rows[visible_start + 2]['test'].update(name=rows[visible_start]['test']['name']))
    reject('late reporter error', lambda rows: rows.insert(-1, {'type': 'error', 'time': rows[-2]['time'], 'testID': rows[visible_start]['test']['id'], 'error': 'late'}))
    reject('missing completion', lambda rows: rows.pop(done))
    reject('duplicate completion', lambda rows: rows.insert(done, copy.deepcopy(rows[done])))
    reject('wrong Chrome suite', lambda rows: rows[2]['suite'].update(platform='vm'))
    reject('outside frozen suite path', lambda rows: rows[2]['suite'].update(path='D:/unrelated/' + SELECTORS[0]))
    reject('duplicate physical suite', lambda rows: rows[3]['suite'].update(path=SELECTORS[0]))
    reject('allSuites count other than physical four', lambda rows: rows[1].update(count=38))
    reject('duplicate allSuites', lambda rows: rows.insert(2, copy.deepcopy(rows[1])))
    reject('missing allSuites', lambda rows: rows.pop(1))
    reject('missing terminal done', lambda rows: rows.pop())
    reject('done unsuccessful', lambda rows: rows[-1].update(success=False))
    reject('done null', lambda rows: rows[-1].update(success=None))
    reject('event after done', lambda rows: rows.append({'type': 'print', 'time': rows[-1]['time'], 'testID': 10, 'messageType': 'print', 'message': 'late'}))
    reject('invented suiteDone event', lambda rows: rows.insert(-1, {'type': 'suiteDone', 'time': rows[-2]['time'], 'suiteID': 0}))
    reject('unknown group ownership', lambda rows: rows[visible_start]['test'].update(groupIDs=[999]))
    reject('native nonzero despite perfect JSON', lambda rows: None, native=1)
    reject('native bool is not integer zero', lambda rows: None, native=False)
    reject('time moves backward', lambda rows: rows[done].update(time=0))
    reject_raw('malformed JSON', encode(events) + b'{bad\n')
    reject_raw('fatal infrastructure text', b'Unhandled exception: failed\n' + encode(events))
    reject_raw('old 31-case three-suite contract rejected', encode(events_for(old_contract)), use_contract=old_contract)
    reject_raw('old 31-case three-suite stream rejected by 38-case contract', encode(events_for(old_contract)))
    reject_raw('invalid UTF-8 reporter bytes', b'\xff\n' + encode(events))
    reject_raw('bootstrap notice repeated', ((pure['BOOTSTRAP_LINE'] + '\n') * 2).encode() + encode(events))
    for name in NEW_NAMES:
        start = next(i for i, row in enumerate(events) if row['type'] == 'testStart' and row['test']['name'] == name)
        reject('new notification case missing: ' + name,
               lambda rows, index=start: rows.__delitem__(slice(index, index + 2)))
        reject('new notification case wrong name: ' + name,
               lambda rows, index=start: rows[index]['test'].update(name=name + ' [wrong]'))
    base_path = Path(contract['cacheBaseManifest']['path'])
    assert pin(base_path) == contract['cacheBaseManifest']
    base = json.loads(base_path.read_bytes())
    derived_path = ROOT / 'cache-content-chrome-refreshed.json'
    derived = json.loads(derived_path.read_bytes())
    chrome = contract['approvedChromeExecutable']
    refresh = pure['validate_cache_refresh'](base, derived, chrome)
    chrome_index = next(i for i, row in enumerate(base['fixedFiles']) if ntpath.normcase(row['path']) == ntpath.normcase(chrome['path']))
    other_index = next(i for i in range(len(base['fixedFiles'])) if i != chrome_index)
    for label, change in [
        ('non-Chrome fixed SHA', lambda value: value['fixedFiles'][other_index].update(sha256='0' * 64)),
        ('hosted library SHA', lambda value: value['trees'][0]['entries'][0].update(sha256='0' * 64)),
        ('incorrect total bytes', lambda value: value['totals'].update(bytes=value['totals']['bytes'] + 1)),
        ('unapproved Chrome SHA', lambda value: value['fixedFiles'][chrome_index].update(sha256='0' * 64)),
        ('missing original provenance', lambda value: value.pop('browserChromeRefresh')),
    ]:
        bad = copy.deepcopy(derived)
        change(bad)
        try:
            pure['validate_cache_refresh'](base, bad, chrome)
        except ValueError:
            negatives.append(label)
        else:
            raise AssertionError('Invalid synthetic cache metadata accepted: ' + label)
    assert len(negatives) >= 48
    inherited_path = PRIOR / 'reporter-static-review.json'
    inherited = json.loads(inherited_path.read_bytes())
    assert inherited['reviewedCodeSha256'] == hashlib.sha256(old_source).hexdigest()
    assert inherited['primaryReporterSourceNotInApplicationCacheAllowlist'] is True
    assert inherited['actualToolSnapshotSeparatelyPinnedByRuntimeManifest'] is True
    assert pin(derived_path)['sha256'] == '8c0cfde01a9d6d5cb4bf002c1ed6d5069af28b0f27f110bec292f46e281f66c0'
    snapshot_rows = [row for row in derived['fixedFiles'] if row['path'].replace('\\', '/').endswith('/flutter_tools.snapshot')]
    assert len(snapshot_rows) == 1
    boundary = {'candidateModulesImported': False, 'onlyAllowlistedPureAstNodesEvaluated': True,
                'workerOrControllerOrNativeHelperLoaded': False, 'sdkStarted': False,
                'browserStarted': False, 'networkUsed': False, 'applicationTestsRun': False,
                'candidateRuntimeBehaviorVerified': False, 'attemptCreated': False}
    report = {'status': 'INDEPENDENT_AST_PURE_METADATA_FIXTURES_ONLY_NOT_APPLICATION_VALIDATION',
              'reviewedAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'independentReviewCodePin': pin(Path(__file__)), 'reporterCodePin': pin(ROOT / 'reporter_contract_reviewed.py'),
              'expectedCaseContractPin': pin(ROOT / 'expected-cases.json'), 'sourceNameParserPin': contract['sourceNameParser'],
              'selectedSourcePins': selected_pins, 'cacheBaseManifestPin': contract['cacheBaseManifest'],
              'cacheDerivedManifestPin': pin(derived_path), 'positiveReporterFixtures': 2, 'positiveCacheFixtures': 1,
              'negativeFixtures': len(negatives), 'rejectedFixtures': negatives,
              'goodSyntheticReport': good, 'goodSyntheticCache': refresh, 'bootstrapPositiveAccepted': True,
              'exactCounts': {'physicalSuites': 4, 'visibleCases': 38, 'hiddenLoadingCases': 4},
              'old31NamesUnchanged': True, 'new7IndividuallyMissingAndWrongNameRejected': True,
              'reporterStrictCountStatusAdaptationOnly': True, 'cacheValidatorAstUnchangedFromR1': True,
              'unchangedReporterFunctions': sorted(unchanged_functions), 'sourceNameParserParsedOnlyNeverExecuted': True,
              **boundary}
    protocol = {'status': 'INDEPENDENT_INHERITED_PRIMARY_REPORTER_PROTOCOL_REVIEW_NOT_APPLICATION_VALIDATION',
                'reviewedAtUtc': report['reviewedAtUtc'], 'reviewedCodePin': report['reporterCodePin'],
                'inheritedPrimaryEvidenceReceiptPin': pin(inherited_path),
                'primaryEvidenceOrigin': 'The r1 receipt records the actual original primary-source read and hash; no new primary reporter source read is claimed here.',
                'primarySourceReadThisReview': False,
                'inheritedOriginalPrimaryReadActualChunk': inherited['cachedPrimarySourceReadActualChunk'],
                'inheritedCachedPrimarySourcePins': inherited['cachedPrimarySource'],
                'primaryReporterSourceNotInApplication3537Allowlist': True,
                'allowlistBoundaryEvidence': 'Inherited from r1 with the byte-identical refreshed cache manifest; the raw pub.dev reporter source is not substituted for the runtime snapshot.',
                'actualToolSnapshotSeparatelyPinnedByRuntimeManifest': True,
                'snapshotMetadataPinFromUnchangedCacheManifest': snapshot_rows[0],
                'cacheManifestPin': report['cacheDerivedManifestPin'],
                'inheritedProtocolFactsObservedInPrimarySource': inherited['protocolFactsObservedInPrimarySource'],
                'validatorRequires': ['Exactly four physical Chrome suites and 38 exact expected visible successful names.',
                    'Every started test completes; any error, failure, skip, malformed output or nonzero native exit rejects.',
                    'Terminal successful done is required; suiteDone is neither present in protocol 0.1.1 nor invented.',
                    'Only the originally approved Chrome fixed row may differ from the original cache parent.'],
                'syntheticMetadataFixturesPassed': True, 'runtimeCompatibilityNotYetProven': True, **boundary}
    write_new(outputs[0], report)
    write_new(outputs[1], protocol)
    print(json.dumps({'status': report['status'], 'negativeFixtures': len(negatives),
                      'positiveReporterFixtures': 2, 'positiveCacheFixtures': 1,
                      'outputs': [pin(path) for path in outputs], **boundary}))


if __name__ == '__main__':
    main()
