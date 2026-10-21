"""One granted offline identity compilation; all mutations stay in this task."""
import sys
if sys.stdin.readline().strip() != 'OWNED_JOB_READY':
    raise SystemExit('Owned job handshake missing; no SDK started')
import zipfile
import datetime as dt
import ctypes
import ctypes.wintypes as w
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET
import psutil

CANDIDATE = Path(__file__).absolute().parent
TASK = CANDIDATE / 'attempt'
REPO = CANDIDATE.parents[1]
BASELINE = CANDIDATE / 'frozen'
OLD = REPO / '.cache/committed-validation-20261021-r1'
COMMIT = '984ae0f9ab4354b16ba6834a836c55ca2351db27'
START = time.monotonic()
TASK_SETTINGS = CANDIDATE / 'offline-settings.xml'
EXPECTED_TESTS_SHA256 = '5f9418212f6f876085befea8bd2c8186894dae87a8c63b5c63fedc0f146c1dff'
FROZEN_MANIFEST_SHA256 = 'd767966a7c875e1fedfe304e8de2ffd91758574ad2fed182a26f90c0ef6d5d58'
APP_ENV_NAMES = ['ALIYUN_SMS_ACCESS_KEY_ID', 'ALIYUN_SMS_ACCESS_KEY_ID_FILE', 'ALIYUN_SMS_ACCESS_KEY_SECRET', 'ALIYUN_SMS_ACCESS_KEY_SECRET_FILE', 'ALIYUN_SMS_SECURITY_TOKEN', 'ALIYUN_SMS_SECURITY_TOKEN_FILE', 'ALIYUN_SMS_SIGN_NAME', 'ALIYUN_SMS_TEMPLATE_CODE', 'CONSUMER_ACCOUNT_SECURITY_ENABLED', 'CONSUMER_OTP_HMAC_KEY', 'CONSUMER_OTP_HMAC_KEY_FILE', 'CONSUMER_PHONE_ENABLED', 'CONSUMER_WECHAT_ENABLED', 'IDENTITY_PROVIDER_ENVIRONMENT_ID', 'IDENTITY_PROVIDER_INSTANCE_ID', 'IDENTITY_PROVIDER_OBSERVATION_KEY_FILE', 'IDENTITY_PROVIDER_OPERATION_ID', 'IDENTITY_PROVIDER_VERSION_ID', 'WECHAT_NATIVE_APP_ID', 'WECHAT_NATIVE_APP_SECRET', 'WECHAT_NATIVE_APP_SECRET_FILE']
TASK_SETTINGS_SHA256 = '4925e1bcc0d37d71a3f2f751737aceb3d89d2c58346a0ac8ce8710778ee5f5e4'

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def save(name, value):
    with (TASK / name).open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=True, indent=2)

def git(*args):
    env = os.environ.copy()
    env['GIT_OPTIONAL_LOCKS'] = '0'
    return subprocess.check_output(['git', *args], cwd=REPO, env=env)

def safe(path, root):
    path.relative_to(root)
    for node in (path, *path.parents):
        if node.is_symlink() or node.is_junction():
            raise ValueError('Linked input: ' + str(node))
        if node == root:
            return
    raise ValueError('Missing boundary')

class Memory(ctypes.Structure):
    _fields_ = [('length',w.DWORD),('load',w.DWORD)] + [(name,ctypes.c_ulonglong) for name in ('total','available','pageTotal','pageAvailable','virtualTotal','virtualAvailable','extended')]

def resources():
    memory = Memory(); memory.length = ctypes.sizeof(memory)
    if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(memory)):
        raise OSError('Memory observation failed')
    sdk = []
    for process in psutil.process_iter(['pid','name']):
        if process.info['name'] is None and process.pid not in (0,4):
            sdk.append({'pid':process.pid,'name':None,'unknownProcessName':True})
        if (process.info['name'] or '').lower() in ('java.exe','javaw.exe','javac.exe','dart.exe','dartaotruntime.exe','go.exe','gofmt.exe','flutter.exe','flutter_tester.exe','gen_snapshot.exe','aapt2.exe','qemu-system-x86_64.exe','compile.exe','link.exe','asm.exe','cgo.exe'):
            sdk.append(process.info)
    return {'utc':dt.datetime.now(dt.timezone.utc).isoformat(),'availablePhysicalBytes':memory.available,
            'diskFreeBytes':{drive:shutil.disk_usage(drive).free for drive in ('C:/','D:/')},'sdkProcesses':sdk}

def gate_snapshot(stage, resource, pins_verified):
    elapsed = time.monotonic() - START
    return {
        'stage': stage, 'resource': resource, 'elapsedCompleteSeconds': elapsed,
        'thresholds': {'minimumAvailablePhysicalBytes': 2**31, 'minimumFreeBytesEachDisk': 2**31,
                       'maximumPreflightSeconds': 60, 'completeOuterBudgetSeconds': 180},
        'conditions': {'observedSdkNamesEmpty': not resource['sdkProcesses'],
                       'ramAtLeastThreshold': resource['availablePhysicalBytes'] >= 2**31,
                       'eachDiskAtLeastThreshold': all(value >= 2**31 for value in resource['diskFreeBytes'].values()),
                       'elapsedWithinPreflightBudget': elapsed <= 60,
                       'completeSourceToolConfigurationAndCachePinsVerified': pins_verified},
        'diskConditions': {drive: free >= 2**31 for drive, free in resource['diskFreeBytes'].items()},
        'resourceGatePassed': not resource['sdkProcesses'] and resource['availablePhysicalBytes'] >= 2**31 and all(value >= 2**31 for value in resource['diskFreeBytes'].values()),
        'enforcedAtResourceGate': ['observedSdkNamesEmpty', 'ramAtLeastThreshold', 'eachDiskAtLeastThreshold'],
        'pinsState': 'VERIFIED' if pins_verified else 'NOT_YET_CHECKED',
        'pinsStateFromControlFlow': True,
        'elapsedAndPinsAreRecordedHereNotAddedToInitialResourceGate': True,
        'machineOrUserEnvironmentValuesRecorded': False,
    }


def verify_tests_and_jar(module):
    expected = json.loads((CANDIDATE/'expected-tests.json').read_text('utf-8'))
    wanted = {s['className']: set(s['methods']) for s in expected['suites']}
    seen = {}; reports = []; issues = []
    totals = dict(tests=0, failures=0, errors=0, skipped=0)
    for path in sorted((module/'target/surefire-reports').glob('TEST-*.xml')):
        try:
            root = ET.parse(path).getroot()
            if root.tag != 'testsuite': raise ValueError('Unexpected report root')
            name = root.attrib['name']; rows = root.findall('testcase')
            counts = {key: int(root.attrib.get(key, '0')) for key in totals}
            names = []
            for row in rows:
                method = row.attrib['name']; method = method[:-2] if method.endswith('()') else method
                names.append(method)
                if row.attrib.get('classname') != name or row.find('failure') is not None or row.find('error') is not None or row.find('skipped') is not None:
                    issues.append('Case failed, skipped or unexpected class: '+name+'.'+method)
            if name in seen or len(names) != len(set(names)) or counts['tests'] != len(rows):
                issues.append('Duplicate or inconsistent report: '+name)
            seen[name] = set(names)
            for key in totals: totals[key] += counts[key]
            reports.append({'path':str(path),'sha256':sha(path),'suite':name,'counts':counts,'methods':names})
        except Exception as error:
            issues.append('Invalid XML '+path.name+': '+type(error).__name__)
    tests_ok = seen == wanted and totals == dict(tests=76, failures=0, errors=0, skipped=0) and len(reports)==13 and not issues
    jar = module/'target/consumer-identity-1.0.0.jar'
    jar_info = {'path':str(jar),'produced':jar.is_file(),'accepted':False}
    if jar.is_file():
        try:
            payload={p.relative_to(module/'target/classes').as_posix():p for p in (module/'target/classes').rglob('*') if p.is_file()}
            metadata={'META-INF/MANIFEST.MF','META-INF/maven/com.aimanager/consumer-identity/pom.xml','META-INF/maven/com.aimanager/consumer-identity/pom.properties'}
            with zipfile.ZipFile(jar) as archive:
                names=[v.filename for v in archive.infolist() if not v.is_dir()]
                unique=len(names)==len(set(names))==len(set(v.casefold() for v in names))
                complete=set(payload).issubset(names) and set(names)-set(payload) <= metadata
                byte_matches=complete and all(archive.read(name)==path.read_bytes() for name,path in payload.items())
                classes=[name for name in payload if name.endswith('.class')]
                resource_entries=[name for name in payload if not name.endswith('.class')]
                class_headers=all(archive.read(name)[:4]==b'\xca\xfe\xba\xbe' and int.from_bytes(archive.read(name)[6:8],'big')<=61 and int.from_bytes(archive.read(name)[4:6],'big')!=65535 for name in classes) if complete else False
                # All shipped module classes and all four SPI/CDI resources must be present.
                only_module=all(name.startswith('com/aimanager/identity/') for name in classes)
                jar_info.update(sha256=sha(jar),bytes=jar.stat().st_size,files=len(names),mainClasses=len(classes),resources=len(resource_entries),uniqueEntries=unique,exactMainPayload=complete,mainPayloadBytesMatch=byte_matches,classHeadersCompatibleWith17=class_headers,onlyModuleClasses=only_module)
                jar_info['accepted']=unique and complete and byte_matches and class_headers and only_module and len(classes)==33 and len(resource_entries)==4
        except Exception as error:
            jar_info['errorType']=type(error).__name__
    return {'accepted':tests_ok and jar_info['accepted'],'testsAccepted':tests_ok,'actualTotals':totals,'expectedSuites':13,'expectedCases':76,'reports':reports,'issues':issues,'jar':jar_info}

def cache_postflight(base, entries):
    expected={e['path'] for e in entries};actual=set()
    for directory, folders, files in os.walk(base,followlinks=False):
        for name in (*folders,*files):safe(Path(directory)/name,base)
        actual.update((Path(directory)/name).relative_to(base).as_posix() for name in files)
    mismatch=[e['path'] for e in entries if not (base/e['path']).is_file() or (base/e['path']).stat().st_size!=e['bytes'] or sha(base/e['path'])!=e['sha256']]
    return {'files':len(actual),'fileSetExact':actual==expected,'mismatches':mismatch,'unchanged':actual==expected and not mismatch}

HISTORICAL_METADATA_SHA256 = {'tool-and-cache-input-observations.json': '0302aa5873bf0965a78a45446d0835cde829c3d24a098308f04db48bf589fbcc', 'existing-project-maven-cache-pins.json': '1ccbf25d1793fb7c76f91e4f1fb5c76edbb6f66c8877fd5d137664d06fb057b7', 'launch-source-observation-r1.json': '824459476795e6ac2813adc19258d3a085cad99b4567ac8fe41854d36f7ee055'}

last_gate_sample = None
child = None
try:
    before = resources()
    last_gate_sample = gate_snapshot('initial', before, False)
    save('initial-gate.json', last_gate_sample)
    if before['sdkProcesses'] or before['availablePhysicalBytes'] < 2**31 or min(before['diskFreeBytes'].values()) < 2**31:
        raise RuntimeError('Fresh SDK/RAM/disk gate failed')
    for name,digest in HISTORICAL_METADATA_SHA256.items():
        path=OLD/name;safe(path,REPO)
        if sha(path)!=digest:raise RuntimeError('Frozen historical metadata changed: '+name)
    pins = json.loads((OLD/'tool-and-cache-input-observations.json').read_text('utf-8'))
    cache = json.loads((OLD/'existing-project-maven-cache-pins.json').read_text('utf-8'))
    safe(BASELINE,REPO)
    if sha(BASELINE/'input-manifest.json') != FROZEN_MANIFEST_SHA256:
        raise RuntimeError('Frozen current33 manifest changed')
    frozen_input = json.loads((BASELINE/'input-manifest.json').read_text('utf-8'))
    source_entries = frozen_input['source']
    if sha(OLD/'tool-and-cache-input-observations.json') != frozen_input['toolPinsSha256']:raise RuntimeError('Tool observations differ from r4 anchor')
    if len(cache['entries'])!=3788 or cache['entries']!=frozen_input['cacheEntries']:raise RuntimeError('Cache inventory differs from r4 frozen3788')
    if git('rev-parse',COMMIT+':identity-extensions').decode().strip() != '7796f5aaf6a38ff87b8a2ca77113bb8ef5ded321':
        raise RuntimeError('Fixed Git module tree changed')
    if len(source_entries) != 33:
        raise RuntimeError('Unexpected complete module source boundary')
    paths = git('ls-tree','-r','--name-only',COMMIT,'--','identity-extensions/').decode().splitlines()
    if set(paths) != {entry['path'] for entry in source_entries}:
        raise RuntimeError('Module file set changed')
    for label in ('java','maven'):
        installation = Path(pins[label]['root'])
        actual = set()
        for directory, folders, files in os.walk(installation, followlinks=False):
            for name in (*folders,*files): safe(Path(directory)/name, installation)
            for name in files: actual.add((Path(directory)/name).relative_to(installation).as_posix())
        if actual != {entry['path'] for entry in pins[label]['entries']}:
            raise RuntimeError('Tool file set changed: ' + label)
        for entry in pins[label]['entries']:
            path = installation/entry['path']
            if path.stat().st_size != entry['bytes'] or sha(path) != entry['sha256']:
                raise RuntimeError('Tool bytes changed: ' + label)
    home = Path(os.environ['USERPROFILE'])
    for name in ('settings.xml','toolchains.xml','settings-security.xml'):
        if os.path.lexists(home/'.m2'/name):
            raise RuntimeError('Unreviewed user Maven configuration')
    for entry in pins['mavenSettingsPresenceAndDigests']:
        path = Path(entry['path'])
        if path.exists() != entry['present'] or (entry['present'] and sha(path) != entry['sha256']):
            raise RuntimeError('Maven settings changed')
    cmd = Path(os.environ['SystemRoot'])/'System32/cmd.exe'
    launch_pin = json.loads((OLD/'launch-source-observation-r1.json').read_text('utf-8'))
    if sha(cmd) != launch_pin['fixedCmdSha256']:
        raise RuntimeError('Command interpreter changed')
    for name in ('src','out','tmp','m2'):
        (TASK/name).mkdir()
    for entry in source_entries:
        original = BASELINE/'src'/entry['path']; safe(original,BASELINE/'src')
        content = original.read_bytes()
        if len(content) != entry['bytes'] or hashlib.sha256(content).hexdigest() != entry['sha256']:
            raise RuntimeError('Fixed module bytes changed')
        target = TASK/'src'/entry['path']; target.parent.mkdir(parents=True,exist_ok=True)
        with target.open('xb') as stream: stream.write(content)
    module = TASK/'src/identity-extensions'
    for name in ('maven.config','jvm.config','extensions.xml'):
        if (module/'.mvn'/name).exists(): raise RuntimeError('Unreviewed module launch configuration')
    cache_source = OLD/'execution-m2'
    safe(cache_source,REPO)
    actual = set()
    for directory, folders, files in os.walk(cache_source,followlinks=False):
        for name in (*folders,*files): safe(Path(directory)/name,cache_source)
        for name in files: actual.add((Path(directory)/name).relative_to(cache_source).as_posix())
    if actual != {entry['path'] for entry in cache['entries']}:
        raise RuntimeError('Pinned cache file set changed')
    for entry in cache['entries']:
        path = cache_source/entry['path']; first = path.stat()
        if first.st_size != entry['bytes'] or sha(path) != entry['sha256']:
            raise RuntimeError('Pinned cache content changed')
        target = TASK/'m2'/entry['path']; target.parent.mkdir(parents=True,exist_ok=True)
        with path.open('rb') as original, target.open('xb') as copy: shutil.copyfileobj(original,copy,1024*1024)
        if target.stat().st_size != entry['bytes'] or sha(target) != entry['sha256']:
            raise RuntimeError('Copied cache mismatch')
        last = path.stat()
        if (first.st_size,first.st_mtime_ns) != (last.st_size,last.st_mtime_ns):
            raise RuntimeError('Cache source changed during copy')
    if sha(TASK_SETTINGS) != TASK_SETTINGS_SHA256:
        raise RuntimeError('Pinned task Maven configuration changed')
    ready = resources()
    last_gate_sample = gate_snapshot('launch', ready, True)
    save('launch-gate.json', last_gate_sample)
    if ready['sdkProcesses'] or ready['availablePhysicalBytes'] < 2**31 or min(ready['diskFreeBytes'].values()) < 2**31:
        raise RuntimeError('Launch-time gate failed')
    if time.monotonic()-START > 60:
        raise RuntimeError('Preflight used too much of the complete budget')
    if sha(CANDIDATE/'expected-tests.json') != EXPECTED_TESTS_SHA256:
        raise RuntimeError('Expected test inventory changed')
    # Exclude fixed credential/configuration names before reading their values.
    env = {name:os.environ[name] for name in os.environ if name not in APP_ENV_NAMES}
    for name in ('MAVEN_ARGS','MAVEN_DEBUG_OPTS','JVM_CONFIG_MAVEN_PROPS','JDK_JAVA_OPTIONS','JAVA_TOOL_OPTIONS','_JAVA_OPTIONS','MAVEN_BATCH_ECHO','MAVEN_BATCH_PAUSE','MAVEN_TERMINATE_CMD','MAVEN_CONFIG','MAVEN_PROJECTBASEDIR'):
        env[name] = ''
    env.update(JAVA_HOME=pins['java']['root'],MAVEN_BASEDIR=str(module),MAVEN_SKIP_RC='true',
               MAVEN_OPTS='-Xmx512m -Dfile.encoding=UTF-8 -Djava.io.tmpdir='+str(TASK/'tmp'),
               TEMP=str(TASK/'tmp'),TMP=str(TASK/'tmp'),COMSPEC=str(cmd))
    env['JAVA_TOOL_OPTIONS']='-Xmx512m -Dfile.encoding=UTF-8 -Djava.io.tmpdir='+str(TASK/'tmp')
    executable = str(Path(pins['maven']['root'])/'bin/mvn.cmd')
    tail = executable+' -V -o -B -ntp -s '+str(TASK_SETTINGS)+' -f '+str(module/'pom.xml')+' -Dmaven.repo.local='+str(TASK/'m2')+' -DskipTests=false -Dmaven.test.skip=false verify'
    if any(c in tail for c in '&|<>^%!"\r\n'): raise RuntimeError('Unsafe command characters')
    save('input-manifest.json',{'commit':COMMIT,'source':source_entries,'cacheEntries':cache['entries'],
                              'toolPinsSha256':sha(OLD/'tool-and-cache-input-observations.json'),'taskSettings':{'path':str(TASK_SETTINGS),'sha256':TASK_SETTINGS_SHA256},'resourceBefore':before,'resourceAtLaunch':ready})
    launch={'utc':dt.datetime.now(dt.timezone.utc).isoformat(),'executable':str(cmd),'arguments':['/d','/v:off','/s','/c',tail],
            'workingDirectory':str(module),'completeBudgetSeconds':180,'preflightSeconds':time.monotonic()-START,'testsRequested':True,'applicationEnvironmentNamesRemoved':APP_ENV_NAMES}
    with (TASK/'out/maven.log').open('wb') as output:
        child = subprocess.Popen([str(cmd),'/d','/v:off','/s','/c',tail],cwd=module,env=env,stdout=output,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
        launch['pid']=child.pid; save('launch.json',launch)
        print(json.dumps({'state':'STARTED_ONE_FULL_VERIFY','pid':child.pid,**launch}),flush=True)
        exceeded=False
        while child.poll() is None:
            if time.monotonic()-START>180 and not exceeded:
                exceeded=True; print(json.dumps({'state':'BUDGET_EXCEEDED_SAME_HANDLE_ONLY','pid':child.pid}),flush=True)
            time.sleep(0.5)
    elapsed=time.monotonic()-START
    scope={}
    for kind,section in (('compile','main'),('testCompile','test')):
        expected={str(module/Path(entry['path']).relative_to('identity-extensions')) for entry in source_entries if entry['path'].startswith('identity-extensions/src/'+section+'/java/') and entry['path'].endswith('.java')}
        listing=module/'target/maven-status/maven-compiler-plugin'/kind/('default-compile' if kind=='compile' else 'default-testCompile')/'inputFiles.lst'
        found=set(listing.read_text('utf-8-sig').splitlines()) if listing.exists() else set()
        scope[section]={'expected':len(expected),'actual':len(found),'exactSourceSet':{os.path.normcase(str(Path(x))) for x in found}=={os.path.normcase(x) for x in expected}}
    source_same=all(sha(TASK/'src'/entry['path'])==entry['sha256'] for entry in source_entries)
    descendants=[]
    for process in psutil.process_iter(['pid','name']):
        if (process.info['name'] or '').lower() in ('java.exe','javac.exe'):
            descendants.append(process.info)
    validation=verify_tests_and_jar(module)
    original_cache=cache_postflight(cache_source,cache['entries'])
    execution_cache=cache_postflight(TASK/'m2',cache['entries'])
    frozen_source_same=all(sha(BASELINE/'src'/entry['path'])==entry['sha256'] for entry in source_entries)
    post_tool_mismatches=[]
    for label in ('java','maven'):
        root=Path(pins[label]['root'])
        actual=set()
        for directory,folders,files in os.walk(root,followlinks=False):
            for name in (*folders,*files):safe(Path(directory)/name,root)
            actual.update((Path(directory)/name).relative_to(root).as_posix() for name in files)
        if actual != {entry['path'] for entry in pins[label]['entries']}:post_tool_mismatches.append(label+':file-set')
        for entry in pins[label]['entries']:
            path=root/entry['path']
            if not path.is_file() or path.stat().st_size!=entry['bytes'] or sha(path)!=entry['sha256']:post_tool_mismatches.append(label+':'+entry['path'])
    post_configuration_unchanged=(sha(TASK_SETTINGS)==TASK_SETTINGS_SHA256 and sha(CANDIDATE/'expected-tests.json')==EXPECTED_TESTS_SHA256 and sha(BASELINE/'input-manifest.json')==FROZEN_MANIFEST_SHA256) and all(sha(OLD/name)==digest for name,digest in HISTORICAL_METADATA_SHA256.items())
    elapsed=time.monotonic()-START
    passed=child.returncode==0 and elapsed<=180 and source_same and frozen_source_same and all(part['exactSourceSet'] for part in scope.values()) and not descendants and validation['accepted'] and original_cache['unchanged'] and execution_cache['unchanged'] and not post_tool_mismatches and post_configuration_unchanged
    receipt={'status':'FULL_VERIFY_WORKER_PASSED' if passed else 'NOT_ACCEPTED','pid':child.pid,'exitCode':child.returncode,
             'elapsedCompleteSeconds':elapsed,'withinBudget':elapsed<=180,'compilerScope':scope,'sourceInputsUnchanged':source_same,
             'javaProcessesAfter':descendants,'logSha256':sha(TASK/'out/maven.log'),'resourceAfter':resources(),'sdkCalls':1,'testsRequested':True,'testsRun':validation['actualTotals']['tests']>0,'testAndJarValidation':validation,'originalCacheAfter':original_cache,'executionCacheAfter':execution_cache,'frozenBaselineSourceUnchanged':frozen_source_same,'postToolMismatches':post_tool_mismatches,'postConfigurationUnchanged':post_configuration_unchanged,
             'servicesStarted':False,'mainOrSharedCacheWrites':False,'forcedTermination':False}
    save('receipt.json',receipt); print(json.dumps(receipt),flush=True)
except Exception as error:
    failure={'status':'PREFLIGHT_NOT_STARTED' if child is None else 'ERROR_PRESERVE_SAME_HANDLE','errorType':type(error).__name__,
             'reason':str(error),'sdkCalls':0 if child is None else 1,'elapsedCompleteSeconds':time.monotonic()-START,'lastRecordedGate':last_gate_sample}
    save('failure.json',failure);print(json.dumps(failure),flush=True)
    if child is not None and child.poll() is None:
        while child.poll() is None:time.sleep(1)
        print(json.dumps({'sameHandleExitCode':child.returncode,'pid':child.pid}),flush=True)
    raise SystemExit(1)
