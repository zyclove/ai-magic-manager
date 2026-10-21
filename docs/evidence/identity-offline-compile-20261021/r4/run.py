"""One granted offline identity compilation; all mutations stay in this task."""
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

TASK = Path(__file__).resolve().parent
REPO = TASK.parents[1]
OLD = REPO / '.cache/committed-validation-20261021-r1'
COMMIT = '3b9117b000a10d082a8f7849c41de5f69c0baa62'
START = time.monotonic()
TASK_SETTINGS = TASK / 'offline-settings.xml'
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
        if (process.info['name'] or '').lower() in ('java.exe','javac.exe','dart.exe','go.exe','flutter.exe','aapt2.exe','qemu-system-x86_64.exe'):
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

last_gate_sample = None
child = None
try:
    before = resources()
    last_gate_sample = gate_snapshot('initial', before, False)
    save('initial-gate.json', last_gate_sample)
    if before['sdkProcesses'] or before['availablePhysicalBytes'] < 2**31 or min(before['diskFreeBytes'].values()) < 2**31:
        raise RuntimeError('Fresh SDK/RAM/disk gate failed')
    pins = json.loads((OLD/'tool-and-cache-input-observations.json').read_text('utf-8'))
    cache = json.loads((OLD/'existing-project-maven-cache-pins.json').read_text('utf-8'))
    source = json.loads((REPO/'.cache/committed-validation-20261021-r2/committed-source-manifest.json').read_text('utf-8'))
    source_entries = [entry for entry in source['files'] if entry['path'].startswith('identity-extensions/')]
    if len(source_entries) != 32:
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
        content = git('show',COMMIT+':'+entry['path'])
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
    env = os.environ.copy()
    for name in ('MAVEN_ARGS','MAVEN_DEBUG_OPTS','JVM_CONFIG_MAVEN_PROPS','JDK_JAVA_OPTIONS','JAVA_TOOL_OPTIONS','_JAVA_OPTIONS','MAVEN_BATCH_ECHO','MAVEN_BATCH_PAUSE','MAVEN_TERMINATE_CMD','MAVEN_CONFIG','MAVEN_PROJECTBASEDIR'):
        env[name] = ''
    env.update(JAVA_HOME=pins['java']['root'],MAVEN_BASEDIR=str(module),MAVEN_SKIP_RC='true',
               MAVEN_OPTS='-Xmx512m -Dfile.encoding=UTF-8 -Djava.io.tmpdir='+str(TASK/'tmp'),
               TEMP=str(TASK/'tmp'),TMP=str(TASK/'tmp'),COMSPEC=str(cmd))
    executable = str(Path(pins['maven']['root'])/'bin/mvn.cmd')
    tail = executable+' -V -o -B -ntp -s '+str(TASK_SETTINGS)+' -f '+str(module/'pom.xml')+' -Dmaven.repo.local='+str(TASK/'m2')+' -DskipTests=true test-compile'
    if any(c in tail for c in '&|<>^%!"\r\n'): raise RuntimeError('Unsafe command characters')
    save('input-manifest.json',{'commit':COMMIT,'source':source_entries,'cacheEntries':cache['entries'],
                              'toolPinsSha256':sha(OLD/'tool-and-cache-input-observations.json'),'taskSettings':{'path':str(TASK_SETTINGS),'sha256':TASK_SETTINGS_SHA256},'resourceBefore':before,'resourceAtLaunch':ready})
    launch={'utc':dt.datetime.now(dt.timezone.utc).isoformat(),'executable':str(cmd),'arguments':['/d','/v:off','/s','/c',tail],
            'workingDirectory':str(module),'completeBudgetSeconds':180,'preflightSeconds':time.monotonic()-START,'testsRun':False}
    with (TASK/'out/maven.log').open('wb') as output:
        child = subprocess.Popen([str(cmd),'/d','/v:off','/s','/c',tail],cwd=module,env=env,stdout=output,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
        launch['pid']=child.pid; save('launch.json',launch)
        print(json.dumps({'state':'STARTED_ONE_TEST_COMPILE','pid':child.pid,**launch}),flush=True)
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
    passed=child.returncode==0 and elapsed<=180 and source_same and all(part['exactSourceSet'] for part in scope.values()) and not descendants
    receipt={'status':'TEST_COMPILE_PASSED_TESTS_NOT_RUN' if passed else 'NOT_ACCEPTED','pid':child.pid,'exitCode':child.returncode,
             'elapsedCompleteSeconds':elapsed,'withinBudget':elapsed<=180,'compilerScope':scope,'sourceInputsUnchanged':source_same,
             'javaProcessesAfter':descendants,'logSha256':sha(TASK/'out/maven.log'),'resourceAfter':resources(),'sdkCalls':1,'testsRun':False,
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
