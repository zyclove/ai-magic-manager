"""CreateNew control/metadata copies only; never imports candidate or SDK."""
from pathlib import Path
import ast
import difflib
import hashlib
import os
import re

ROOT = Path(__file__).absolute().parent
REPO = ROOT.parents[1]
PREVIOUS = REPO / '.cache/guardian-browser31-20261023-r2'
NAMES = REPO / '.cache/guardian-browser31-20261023-r1/source_name_contract.py'


def create(name, raw):
    path = ROOT / name
    assert path.parent == ROOT
    with path.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


def main():
    assert not (ROOT / 'attempt').exists()
    originals = {}
    for name in ['controller.py', 'heap1536_windows_job.py', 'owned_chrome_observer.py', 'reporter_contract_reviewed.py']:
        originals[name] = (PREVIOUS / name).read_bytes()
    controller = originals['controller.py'].decode('utf-8').replace('GUARDIAN_BROWSER31', 'GUARDIAN_BROWSER38')
    reporter = originals['reporter_contract_reviewed.py'].decode('utf-8')
    reporter = re.sub(r'\b31\b', '38', reporter)
    reporter = re.sub(r'\b3\b', '4', reporter)
    reporter = reporter.replace('three physical suites', 'four physical suites').replace('EXACT_BROWSER31', 'EXACT_BROWSER38')
    before_tree = ast.parse(originals['reporter_contract_reviewed.py'].decode('utf-8'))
    after_tree = ast.parse(reporter)
    before_cache = next(node for node in before_tree.body if isinstance(node, ast.FunctionDef) and node.name == 'validate_cache_refresh')
    after_cache = next(node for node in after_tree.body if isinstance(node, ast.FunctionDef) and node.name == 'validate_cache_refresh')
    assert ast.dump(before_cache, include_attributes=False) == ast.dump(after_cache, include_attributes=False)
    names = NAMES.read_text('utf-8').replace('the three selected Guardian source files', 'the four selected Guardian source files')
    old = "             'test/approval_help_flow_browser_test.dart']\nCOUNTS = [8, 4, 19]"
    new = "             'test/approval_help_flow_browser_test.dart',\n             'test/notification_help_scope_browser_test.dart']\nCOUNTS = [8, 4, 19, 7]"
    assert names.count(old) == 1
    names = names.replace(old, new)
    old = "{'loss': ['actor ABA', 'generation', 'dispose'],"
    new = "{'loss': (['real selection then failure', 'dispose']\n                             if selector == 'test/notification_help_scope_browser_test.dart'\n                             else ['actor ABA', 'generation', 'dispose']),"
    assert names.count(old) == 1
    names = names.replace(old, new)
    outputs = {'controller.py': controller.encode('utf-8'), 'heap1536_windows_job.py': originals['heap1536_windows_job.py'],
               'owned_chrome_observer.py': originals['owned_chrome_observer.py'],
               'reporter_contract_reviewed.py': reporter.encode('utf-8'), 'reporter_contract.py': reporter.encode('utf-8'),
               'source_name_contract.py': names.encode('utf-8')}
    for name, raw in outputs.items():
        ast.parse(raw.decode('utf-8'), filename=name)
        create(name, raw)
    comparisons = [('controller.py', originals['controller.py'], outputs['controller.py']),
                   ('native-helper.py', originals['heap1536_windows_job.py'], outputs['heap1536_windows_job.py']),
                   ('observer.py', originals['owned_chrome_observer.py'], outputs['owned_chrome_observer.py']),
                   ('reporter.py', originals['reporter_contract_reviewed.py'], outputs['reporter_contract_reviewed.py']),
                   ('name-contract.py', NAMES.read_bytes(), outputs['source_name_contract.py'])]
    for name, before, after in comparisons:
        diff = ''.join(difflib.unified_diff(before.decode('utf-8').splitlines(keepends=True), after.decode('utf-8').splitlines(keepends=True),
            fromfile='browser31-html-r2/' + name, tofile='browser38/' + name))
        create('mechanical-' + name + '.diff', diff.encode('utf-8'))
    assert hashlib.sha256(outputs['heap1536_windows_job.py']).hexdigest() == '4965e39eecfe70c7eeeb7ce317c0c06f4ae484d36f025706fff3a669cec4ab12'
    print('STATIC_BROWSER38_CONTROLS_CREATED_NO_IMPORT_NO_SDK')


if __name__ == '__main__':
    main()
