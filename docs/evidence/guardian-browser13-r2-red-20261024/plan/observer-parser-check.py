"""Pure parsers only: importing evidence does not initialize its native reader."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

HERE = Path(__file__).absolute().parent
spec = importlib.util.spec_from_file_location('chrome_evidence_pure_check', HERE/'owned_chrome_evidence.py')
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)
chrome = r'C:\Program Files\Google\Chrome\Application\chrome.exe'
temp = r'D:\codes\mobile\ai-manager\.cache\guardian-browser13-20261024-r2-manager-proof\attempt\tmp'
url = 'http://localhost:12345/static/index.html?managerUrl=ws%3A%2F%2Flocalhost%3A12345%2Ffixture-manager&debug=false'
good = [chrome, '--user-data-dir='+temp+r'\flutter_tools.fixture\profile',
        '--remote-debugging-port=23456', '--headless', url]
rows = [{'address':'127.0.0.1','port':23456,'family':'AF_INET','status':'LISTEN'},
        {'address':'::1','port':23456,'family':'AF_INET6','status':'LISTEN'}]
accepted = e.parse_chrome_argv(good, chrome, temp)
assert accepted['debuggingPort'] == 23456 and accepted['headless'] is True
assert accepted['testTargets'] == [{'scheme':'http','host':'localhost','port':12345,
    'path':'/static/index.html','urlSha256':hashlib.sha256(url.encode()).hexdigest()}]
assert 'managerUrl' not in json.dumps(accepted)
assert accepted['managerTarget'] == {'scheme':'ws','host':'localhost','port':12345}
assert set(accepted['managerTarget']) == {'scheme','host','port'}
assert accepted['managerTarget']['host'] == accepted['testTargets'][0]['host']
assert accepted['managerTarget']['port'] == accepted['testTargets'][0]['port']
assert len(e.parse_listener_rows(rows, 23456)) == 2
assert e.parse_chrome_argv([chrome,'--type=renderer'],chrome,temp) is None
rejections = []
def reject(name, action):
    try:
        action()
    except e.EvidenceRejected:
        rejections.append(name)
    else:
        raise AssertionError('Expected rejection: '+name)
for name, argv in [
    ('outside-profile', [chrome,'--user-data-dir=D:\\outside','--remote-debugging-port=23456','--headless',url]),
    ('same-temp-profile', [chrome,'--user-data-dir='+temp,'--remote-debugging-port=23456','--headless',url]),
    ('parent-profile', [chrome,'--user-data-dir='+temp+r'\x\..\profile','--remote-debugging-port=23456','--headless',url]),
    ('duplicate-profile', good+['--user-data-dir='+temp+r'\second']),
    ('duplicate-port', good+['--remote-debugging-port=34567']),
    ('zero-port', [x.replace('=23456','=0') for x in good]),
    ('non-headless', [x for x in good if x!='--headless']),
    ('external-target', good[:-1]+['https://outside.invalid/static/index.html']),
    ('external-uppercase-extra', good+['HTTPS://outside.invalid/']),
    ('about-blank', good[:-1]+['about:blank']),
    ('wrong-target-path', good[:-1]+[url.replace('/static/index.html?','/other?')]),
    ('manager-other-host', good[:-1]+[url.replace('ws%3A%2F%2Flocalhost','ws%3A%2F%2Foutside.invalid')]),
    ('wrong-debug-state', good[:-1]+[url.replace('debug=false','debug=true')]),
    ('duplicate-debug-query', good[:-1]+[url+'&debug=false']),
    ('target-fragment', good[:-1]+[url+'#secret']),
]:
    reject(name, lambda argv=argv:e.parse_chrome_argv(argv,chrome,temp))
for address in ['0.0.0.0','192.0.2.1','::','::ffff:127.0.0.1']:
    bad = [dict(rows[0],address=address)]
    reject('non-loopback-listener-'+address, lambda bad=bad:e.parse_listener_rows(bad,23456))
reject('wrong-listener-port',lambda:e.parse_listener_rows([dict(rows[0],port=23457)],23456))
reject('listener-extra-field',lambda:e.parse_listener_rows([dict(rows[0],unrelated='not saved')],23456))
for length,maximum,address in [(-2,4,16),(0,0,16),(3,4,16),(65534,65534,16),(4,2,16),(2,4,0)]:
    reject('unicode-'+str((length,maximum,address)),lambda l=length,m=maximum,a=address:e.checked_unicode(l,m,a))
for address,count in [(0,4),(16,0),(16,-1),(16,65537),((1<<64)-2,4)]:
    reject('span-'+str((address,count)),lambda a=address,c=count:e.checked_read_span(a,c))
result = {'status':'PURE_OBSERVER_PARSERS_ACCEPT_VALID_AND_REJECT_INVALID',
          'acceptedCases':3,'rejectedCases':len(rejections),'rejections':rejections,
          'observerPin':{'bytes':(HERE/'owned_chrome_evidence.py').stat().st_size,
                        'sha256':hashlib.sha256((HERE/'owned_chrome_evidence.py').read_bytes()).hexdigest()},
          'processQueries':False,'nativeReaderInitialized':False,'socketQueries':False,
          'networkRequests':False,'sdkOrChromeStarted':False,'chromeLifecycleQualified':False}
out = HERE/(sys.argv[1] if len(sys.argv)==2 else 'observer-parser-result.json')
assert out.parent == HERE and out.name.startswith('observer-parser-result') and out.suffix=='.json'
with out.open('x',encoding='utf-8') as stream:
    json.dump(result,stream,ensure_ascii=False,indent=2)
    stream.write('\n')
print(json.dumps(result,ensure_ascii=False))
