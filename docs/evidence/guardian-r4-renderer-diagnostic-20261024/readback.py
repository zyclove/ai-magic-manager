"""After Root release only: bounded file-only proof of the owned cached wrapper.

No browser, process, socket, SDK, candidate import, directory walk or fallback
profile. Only the profile and URL digest in the fixed B3 evidence can select data.
Unknown cache layouts or non-unique associations are rejected, never guessed.
"""
from pathlib import Path
import argparse
import hashlib
import json
import ipaddress
import math
import ntpath
import os
import re
import stat
import struct
from urllib.parse import urlsplit

HERE = Path(__file__).absolute().parent
REPO = HERE.parents[1]
BASE = REPO / '.cache/guardian-browser13-20261024-r4-canonical-git'
ATTEMPT = BASE / 'attempt'
TEMPORARY = ATTEMPT / 'tmp'
EVIDENCE = ATTEMPT / 'owned-chrome-evidence.json'
SELECTOR = 'editor_submit_guard_test.dart'
REPARSE = 0x400
MAX_WRAPPER_BYTES = 2048
MAX_ENTRY_FILE_BYTES = 16 * 1024 * 1024
MAX_TOTAL_CACHE_READ = 32 * 1024 * 1024
BLOCK_HEADER_BYTES = 8192
BLOCK_MAGIC = 0xC104CAC3
BLOCK_VERSION = 0x20000


class ReadbackRejected(RuntimeError):
    pass


def require(condition, code):
    if not condition:
        raise ReadbackRejected(code)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    require(type(value) is str and 0 < len(value) <= 32766
            and re.match(r'^[A-Za-z]:[\\/]', value) is not None
            and not any(ord(char) < 32 for char in value)
            and '..' not in value.replace('/', '\\').split('\\'), 'UNSAFE_LOCAL_PATH')
    _, tail = ntpath.splitdrive(value)
    require(':' not in tail, 'ADS_PATH_REFUSED')
    return ntpath.normcase(ntpath.normpath(value))


def safe_existing(path, inside=None):
    path = Path(path)
    normalized = canonical(str(path))
    if inside is not None:
        parent = canonical(str(inside))
        require(normalized.startswith(parent.rstrip('\\') + '\\'), 'OUTSIDE_EXACT_OWNED_DIRECTORY')
    for item in (path, *path.parents):
        information = item.lstat()
        require(not stat.S_ISLNK(information.st_mode)
                and not getattr(information, 'st_file_attributes', 0) & REPARSE, 'REPARSE_PATH_REFUSED')
    return path


def identity(information):
    return (information.st_dev, information.st_ino, information.st_size,
            information.st_mtime_ns, information.st_ctime_ns)


def bounded_file(path, maximum):
    path = safe_existing(path)
    before = path.stat()
    require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
            and 0 < before.st_size <= maximum, 'INPUT_FILE_BOUNDARY_REFUSED')
    with path.open('rb') as stream:
        require(identity(os.fstat(stream.fileno())) == identity(before), 'INPUT_FILE_OPEN_IDENTITY_CHANGED')
        raw = stream.read(maximum + 1)
        require(len(raw) == before.st_size
                and identity(os.fstat(stream.fileno())) == identity(before), 'INPUT_FILE_CHANGED')
    safe_existing(path)
    require(identity(path.stat()) == identity(before), 'INPUT_PATH_CHANGED')
    return raw


def owned_target(raw):
    value = json.loads(raw)
    require(type(value) is dict and set(value) == {
        'schemaVersion', 'status', 'chromeRoots', 'problems', 'sampleCalls',
        'pinnedBrowserPath', 'temporaryRoot', 'commandCreationFiletime',
        'observationDeadlineQpc', 'commandLineSource', 'debugBindingProof',
        'foreignCommandLinesRead', 'processesTerminated', 'environmentRead',
        'nativeReadPathQualificationSeparate'}, 'UNKNOWN_TOP_EVIDENCE_FIELDS')
    require(type(value['schemaVersion']) is int and type(value['sampleCalls']) is int
            and 0 < value['sampleCalls'] <= 100000
            and value['nativeReadPathQualificationSeparate'] is True,
            'RED_DIAGNOSTIC_TOP_TYPES_REFUSED')
    require(type(value) is dict and value.get('schemaVersion') == 1
            and value.get('status') == 'NOT_ACCEPTED'
            and value.get('problems') == ['OWN_JOB_MEMBER_IDENTITY_UNPROVED']
            and value.get('foreignCommandLinesRead') is False
            and value.get('processesTerminated') is False and value.get('environmentRead') is False
            and value.get('commandLineSource') == 'SAME_RETAINED_HANDLE_PBI0_READPROCESSMEMORY'
            and value.get('debugBindingProof') == 'PID_FILTERED_LISTEN_ROWS_BRACKETED_BY_SAME_HANDLE_IDENTITY'
            and canonical(value.get('temporaryRoot')) == canonical(str(TEMPORARY)),
            'ACCEPTED_FIXED_OWN_CHROME_EVIDENCE_REQUIRED')
    roots = value.get('chromeRoots')
    require(type(roots) is list and len(roots) == 1, 'ONE_UNAMBIGUOUS_OWN_PROFILE_REQUIRED')
    root = roots[0]
    require(type(root) is dict and set(root) == {
        'pid', 'creationFiletime', 'commandCreationFiletime', 'imagePath', 'profile',
        'debuggingPort', 'testServerOrigins', 'testTargets', 'managerTarget', 'headless',
        'argvTestTargetLoopback', 'flutterManagerTargetSameLoopbackOrigin',
        'commandLineUtf16Sha256', 'commandLineReadBeforeQpc', 'commandLineReadAfterQpc',
        'sameReadHandleVerified', 'ownedMembershipVerifiedBeforeAndAfter', 'liveBeforeAndAfter',
        'observedQpc', 'debugListenerAddresses', 'listenerReadBeforeQpc', 'listenerReadAfterQpc',
        'listenerSameHandleIdentityVerifiedBeforeAndAfter', 'debugBindingLoopbackObserved'},
        'UNKNOWN_ROOT_EVIDENCE_FIELDS')
    require(type(root['pid']) is int and root['pid'] > 0
            and type(root['creationFiletime']) is int and type(value['commandCreationFiletime']) is int
            and root['creationFiletime'] >= value['commandCreationFiletime'] > 0
            and type(root['commandCreationFiletime']) is int
            and root['commandCreationFiletime'] == value['commandCreationFiletime']
            and type(root['commandLineUtf16Sha256']) is str
            and re.fullmatch('[0-9a-f]{64}', root['commandLineUtf16Sha256']) is not None,
            'ROOT_IDENTITY_EVIDENCE_REFUSED')
    times = [root[key] for key in ('commandLineReadBeforeQpc', 'commandLineReadAfterQpc',
        'listenerReadBeforeQpc', 'listenerReadAfterQpc', 'observedQpc')]
    require(all(type(item) is float and math.isfinite(item) for item in times)
            and type(value['observationDeadlineQpc']) is float and math.isfinite(value['observationDeadlineQpc'])
            and 0 <= times[0] <= times[1] <= times[2] <= times[3] == times[4] < value['observationDeadlineQpc'],
            'ROOT_ORIGINAL_OBSERVATION_TIMES_REFUSED')
    require(type(root['debuggingPort']) is int and 0 < root['debuggingPort'] < 65536,
            'ROOT_DEBUG_PORT_REFUSED')
    listeners = root['debugListenerAddresses']
    require(type(listeners) is list and 1 <= len(listeners) <= 32, 'ROOT_LISTENER_EVIDENCE_MISSING')
    seen = set()
    for listener in listeners:
        require(type(listener) is dict and set(listener) == {'address', 'port', 'family', 'status'}
                and type(listener['address']) is str and type(listener['port']) is int
                and listener['port'] == root['debuggingPort'] and listener['status'] == 'LISTEN'
                and listener['family'] in ('AF_INET', 'AF_INET6'), 'ROOT_LISTENER_SCHEMA_REFUSED')
        address = ipaddress.ip_address(listener['address'])
        require(address.is_loopback and ((address.version == 4 and listener['family'] == 'AF_INET')
                or (address.version == 6 and listener['family'] == 'AF_INET6')), 'ROOT_LISTENER_NOT_LOOPBACK')
        entry = (str(address), listener['port'], listener['family'], listener['status'])
        require(entry not in seen, 'ROOT_LISTENER_DUPLICATE')
        seen.add(entry)
    require(type(root) is dict and all(root.get(key) is True for key in (
        'headless', 'argvTestTargetLoopback', 'flutterManagerTargetSameLoopbackOrigin',
        'sameReadHandleVerified', 'ownedMembershipVerifiedBeforeAndAfter', 'liveBeforeAndAfter',
        'listenerSameHandleIdentityVerifiedBeforeAndAfter', 'debugBindingLoopbackObserved')),
        'OWN_CHROME_BOUNDARIES_NOT_ESTABLISHED')
    require(canonical(root.get('imagePath')) == canonical(value.get('pinnedBrowserPath')),
            'OWN_CHROME_IMAGE_MISMATCH')
    profile = safe_existing(Path(root.get('profile')), TEMPORARY)
    require(profile.is_dir(), 'OWN_PROFILE_NOT_DIRECTORY')
    targets = root.get('testTargets')
    require(type(targets) is list and len(targets) == 1, 'ONE_TEST_TARGET_REQUIRED')
    target = targets[0]
    require(type(target) is dict and set(target) == {'scheme', 'host', 'port', 'path', 'urlSha256'}
            and target['scheme'] == 'http' and target['host'] in ('localhost', '127.0.0.1', '::1')
            and type(target['port']) is int and 0 < target['port'] < 65536
            and target['path'] == '/static/index.html'
            and type(target['urlSha256']) is str
            and re.fullmatch('[0-9a-f]{64}', target['urlSha256']) is not None, 'TEST_TARGET_SCHEMA_REFUSED')
    manager = root.get('managerTarget')
    require(type(manager) is dict and set(manager) == {'scheme', 'host', 'port'}
            and manager['scheme'] == 'ws' and manager['host'] == target['host']
            and type(manager['port']) is int and manager['port'] == target['port'],
            'MANAGER_ORIGIN_NOT_THE_EXACT_TEST_ORIGIN')
    origins = root.get('testServerOrigins')
    require(type(origins) is list and len(origins) == 1 and type(origins[0]) is str,
            'ONE_OWN_TEST_ORIGIN_REQUIRED')
    origin = urlsplit(origins[0])
    require(origin.scheme == 'http' and origin.hostname == target['host'] and origin.port == target['port']
            and origin.path == '' and not origin.query and not origin.fragment
            and origin.username is None and origin.password is None, 'OWN_TEST_ORIGIN_MISMATCH')
    return profile, target, origins[0]


class CacheReads:
    """Read bounded ranges from fixed block files under only the owned profile."""
    def __init__(self, profile):
        self.directory = safe_existing(profile / 'Default/Cache/Cache_Data', profile)
        require(self.directory.is_dir(), 'OWN_BLOCK_CACHE_DIRECTORY_MISSING')
        self.files = {}
        self.total_read = 0

    def open_file(self, selector, expected_block_size):
        require(selector in (1, 2, 3), 'UNSUPPORTED_BLOCK_FILE_SELECTOR')
        if selector not in self.files:
            path = safe_existing(self.directory / ('data_' + str(selector)), self.directory)
            before = path.stat()
            require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                    and BLOCK_HEADER_BYTES <= before.st_size <= MAX_ENTRY_FILE_BYTES,
                    'CACHE_FILE_BOUNDARY_REFUSED')
            stream = path.open('rb')
            try:
                require(identity(os.fstat(stream.fileno())) == identity(before), 'CACHE_OPEN_IDENTITY_CHANGED')
                self.files[selector] = {'path': path, 'before': before, 'stream': stream}
                header = self.read(selector, 0, BLOCK_HEADER_BYTES)
                require(struct.unpack_from('<II', header, 0) == (BLOCK_MAGIC, BLOCK_VERSION),
                        'UNKNOWN_CACHE_BLOCK_HEADER')
                block_size = struct.unpack_from('<I', header, 12)[0]
                self.files[selector].update(blockSize=block_size, headerSha256=digest(header))
            except BaseException:
                stream.close()
                self.files.pop(selector, None)
                raise
        require(self.files[selector]['blockSize'] == expected_block_size, 'UNEXPECTED_CACHE_BLOCK_SIZE')
        return self.files[selector]

    def read(self, selector, offset, length):
        item = self.files[selector]
        require(type(offset) is int and type(length) is int and offset >= 0 and 0 < length <= 8192
                and offset + length <= item['before'].st_size, 'CACHE_RANGE_REFUSED')
        require(self.total_read + length <= MAX_TOTAL_CACHE_READ, 'CACHE_TOTAL_READ_LIMIT')
        item['stream'].seek(offset)
        raw = item['stream'].read(length)
        self.total_read += len(raw)
        require(len(raw) == length, 'CACHE_SHORT_READ')
        return raw

    def stream(self, address, length, maximum):
        require(type(address) is int and address & 0x80000000 and 0 < length <= maximum,
                'CACHE_STREAM_ADDRESS_OR_LENGTH_REFUSED')
        kind = (address >> 28) & 7
        require(kind in (2, 3, 4), 'EXTERNAL_OR_UNKNOWN_CACHE_STREAM_REFUSED')
        block_size = {2: 256, 3: 1024, 4: 4096}[kind]
        selector = (address >> 16) & 255
        blocks = ((address >> 24) & 3) + 1
        require(length <= blocks * block_size, 'CACHE_STREAM_EXCEEDS_ALLOCATION')
        item = self.open_file(selector, block_size)
        offset = BLOCK_HEADER_BYTES + (address & 65535) * block_size
        raw = self.read(selector, offset, length)
        return raw, {'file': str(item['path']), 'addressHex': hex(address), 'offset': offset,
                     'bytes': length, 'blockSize': block_size, 'sha256': digest(raw)}

    def close_and_verify(self):
        checked = []
        try:
            for selector, item in self.files.items():
                require(identity(os.fstat(item['stream'].fileno())) == identity(item['before']), 'CACHE_HANDLE_CHANGED')
                safe_existing(item['path'], self.directory)
                require(identity(item['path'].stat()) == identity(item['before']), 'CACHE_PATH_CHANGED')
                checked.append({'path': str(item['path']), 'bytesObserved': item['before'].st_size,
                                'blockSize': item['blockSize'], 'headerSha256': item['headerSha256'],
                                'stableReadIdentity': True, 'wholeFileHashed': False})
        finally:
            for item in self.files.values():
                item['stream'].close()
        return checked


def response_headers(raw):
    starts = list(re.finditer(rb'HTTP/1\.[01] [1-5][0-9]{2} [^\x00\r\n]{0,80}\x00', raw))
    require(len(starts) == 1, 'ONE_CACHE_HTTP_HEADER_BLOCK_REQUIRED')
    start = starts[0].start()
    end = raw.find(b'\x00\x00', start)
    require(end > start, 'CACHE_HTTP_HEADER_TERMINATOR_MISSING')
    lines = raw[start:end].split(b'\x00')
    require(re.fullmatch(rb'HTTP/1\.[01] 200 [^\r\n\x00]{1,80}', lines[0]) is not None,
            'WRAPPER_RESPONSE_NOT_HTTP_200')
    values = {}
    for line in lines[1:]:
        require(b':' in line, 'CACHE_HTTP_HEADER_MALFORMED')
        name, value = line.split(b':', 1)
        name = name.decode('ascii').lower()
        require(re.fullmatch('[a-z0-9-]+', name) is not None, 'CACHE_HTTP_HEADER_NAME_REFUSED')
        if name in ('content-type', 'content-length', 'date', 'content-encoding', 'cache-control'):
            require(name not in values, 'DUPLICATE_RESPONSE_HEADER')
            text = value.strip().decode('ascii')
            require(len(text) <= 256 and not any(ord(c) < 32 for c in text), 'RESPONSE_HEADER_VALUE_REFUSED')
            values[name] = text
    require(values.get('content-type', '').lower().startswith('text/html'), 'WRAPPER_NOT_HTML_CONTENT_TYPE')
    require(values.get('content-encoding', 'identity').lower() == 'identity', 'ENCODED_WRAPPER_NOT_SUPPORTED')
    return {'statusLine': lines[0].decode('ascii'), 'headers': values}


def wrapper_configuration(raw):
    require(0 < len(raw) <= MAX_WRAPPER_BYTES and b'\x00' not in raw, 'WRAPPER_BODY_BOUNDARY_REFUSED')
    text = raw.decode('utf-8')
    require(text.lstrip().lower().startswith('<!doctype html>') and '<html>' in text.lower(), 'WRAPPER_NOT_EXPECTED_HTML')
    require(not any(token in text.lower() for token in ('managerurl', 'ws://', 'wss://', 'http://', 'https://', '?')),
            'WRAPPER_UNEXPECTED_URL_OR_QUERY_REFUSED')
    tests = {
        'selector': re.findall(r'window\.testSelector\s*=\s*[\"\']([^\"\']+)[\"\']\s*;', text),
        'renderer': re.findall(r'\brenderer\s*:\s*[\"\']([^\"\']+)[\"\']', text),
        'canvasKitBaseUrl': re.findall(r'\bcanvasKitBaseUrl\s*:\s*[\"\']([^\"\']+)[\"\']', text),
        'compileTarget': re.findall(r'\bcompileTarget\s*:\s*[\"\']([^\"\']+)[\"\']', text),
        'mainJsPath': re.findall(r'\bmainJsPath\s*:\s*[\"\']([^\"\']+)[\"\']', text),
    }
    require(tests == {'selector': [SELECTOR], 'renderer': ['html'], 'canvasKitBaseUrl': ['/canvaskit/'],
                      'compileTarget': ['dartdevc'], 'mainJsPath': ['main.dart.browser_test.dart.js']},
            'WRAPPER_CONFIGURATION_NOT_THE_FIXED_HTML_TARGET')
    require('<title>' + SELECTOR + ' Test</title>' in text, 'WRAPPER_TITLE_MISMATCH')
    return {key: rows[0] for key, rows in tests.items()}


def inspect_cache(profile, target, origin):
    cache = CacheReads(profile)
    candidates = []
    body = header = None
    try:
        entries = cache.open_file(1, 256)
        total_blocks = (entries['before'].st_size - BLOCK_HEADER_BYTES) // 256
        needle = (origin + target['path']).encode('ascii')
        for block in range(total_blocks):
            offset = BLOCK_HEADER_BYTES + block * 256
            entry = cache.read(1, offset, 96)
            state, key_length, long_key = struct.unpack_from('<I', entry, 20)[0], struct.unpack_from('<I', entry, 32)[0], struct.unpack_from('<I', entry, 36)[0]
            if state != 0 or long_key != 0 or not 1 <= key_length <= 928:
                continue
            if offset + 96 + key_length > entries['before'].st_size:
                continue
            key = cache.read(1, offset + 96, key_length)
            location = key.find(needle)
            if location < 0:
                continue
            require(key.find(needle, location + 1) < 0, 'AMBIGUOUS_CACHE_KEY_TARGET')
            url = key[location:].decode('utf-8')
            request = urlsplit(url)
            require(request.scheme == 'http' and request.hostname == target['host'] and request.port == target['port']
                    and request.path == target['path'] and request.username is None and request.password is None
                    and not request.fragment, 'CACHE_KEY_ORIGIN_OR_PATH_MISMATCH')
            require(digest(url.encode('utf-8')) == target['urlSha256'], 'CACHE_URL_DIGEST_NOT_THE_OWN_ARGV_TARGET')
            metadata_size, body_size = struct.unpack_from('<II', entry, 40)
            metadata_address, body_address = struct.unpack_from('<II', entry, 56)
            metadata, metadata_pin = cache.stream(metadata_address, metadata_size, 4096)
            candidate_body, body_pin = cache.stream(body_address, body_size, MAX_WRAPPER_BYTES)
            response = response_headers(metadata)
            if 'content-length' in response['headers']:
                require(response['headers']['content-length'] == str(body_size), 'WRAPPER_CONTENT_LENGTH_MISMATCH')
            config = wrapper_configuration(candidate_body)
            candidates.append({'entryFile': str(entries['path']), 'entryOffset': offset,
                'entryHeaderBytes': 96, 'entryHeaderSha256': digest(entry),
                'keyOffset': offset + 96, 'keyBytes': key_length, 'keySha256': digest(key),
                'request': {'urlWithoutQuery': origin + target['path'], 'urlSha256': target['urlSha256'],
                            'queryOmitted': True, 'digestMatchesOwnedArgvTarget': True},
                'metadataStream': metadata_pin, 'bodyStream': body_pin, 'response': response,
                'wrapperConfiguration': config})
            body, header = candidate_body, entry
        require(len(candidates) == 1, 'ONE_PRECISE_CACHE_ENTRY_WRAPPER_ASSOCIATION_REQUIRED')
    finally:
        files = cache.close_and_verify()
    return candidates[0], body, header, files, cache.total_read


def create(name, raw):
    path = HERE / name
    require(not path.exists(), 'READBACK_OUTPUT_ALREADY_EXISTS')
    with path.open('xb') as stream:
        stream.write(raw)
    return {'path': str(path), 'bytes': len(raw), 'sha256': digest(raw)}


def released_red_window():
    release_path = BASE / 'root-attempt/release.json'
    raw = bounded_file(release_path, 65536)
    require(digest(raw) == '79349c826905af25224eb20469f39750bc85c0f93e02ebb13b8a5d1534f7c4db',
            'FIXED_ACTUAL_RELEASE_BYTES_CHANGED')
    value = json.loads(raw)
    require(type(value) is dict and set(value) == {
        'status', 'atUtc', 'sourceCommit', 'actualRootToolTerminalChunk', 'actualRootToolExitCode',
        'actualPostToolTerminalChunk', 'actualPostToolExitCode', 'hostPid', 'hostCreationFiletime',
        'hostExitFiletime', 'fixedLauncherDisposedOwnHostHandle', 'ownLiveSdkHandle', 'sdkCount',
        'sdkProcesses', 'unknownCount', 'knownOwnedPids', 'availableRamBytes', 'disks',
        'processInventoryFile', 'processInventorySha256', 'fixedPostFile', 'fixedPostSha256',
        'resultConsistent', 'windowReleased', 'testAccepted', 'applicationTestsRun', 'deployed',
        'nextSdkGrant'}, 'UNKNOWN_RELEASE_FIELDS')
    require(value['status'] == 'BROWSER13_NOT_ACCEPTED_OR_RELEASE_INCOMPLETE'
            and value['sourceCommit'] == '006ee45850c9b6b0f90570d9478bced3beb0e0fe'
            and value['windowReleased'] is True and value['ownLiveSdkHandle'] is False
            and value['fixedLauncherDisposedOwnHostHandle'] is True
            and type(value['sdkCount']) is int and value['sdkCount'] == 0 and value['sdkProcesses'] == []
            and type(value['unknownCount']) is int and value['unknownCount'] == 0
            and value['testAccepted'] is False and value['resultConsistent'] is False,
            'ACTUAL_RELEASE_NOT_COMPLETE_RED_AND_SDK_ZERO')
    return raw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--after-root-release', action='store_true', required=True,
                        help='Root confirms the actual SDK window ended and release finished.')
    parser.parse_args()
    require(not (HERE / 'result.json').exists(), 'SINGLE_USE_READBACK_ALREADY_CONSUMED')
    result = {'schemaVersion': 1, 'status': 'NOT_ACCEPTED', 'kind': 'DIAGNOSTIC_RENDERER_FACTS_NOT_TEST_ACCEPTANCE', 'testAccepted': False,
              'overallChromeBoundariesAccepted': False, 'thirteenApplicationCasesPassed': False,
              'sdkBrowserProcessOrNetworkStarted': False, 'foreignProfilesRead': False,
              'managerQueryOrRawCommandLineSaved': False, 'wholeProfileCopiedOrHashed': False,
              'absenceOfCanvasKitCacheEntriesClaimedAsNetworkAbsence': False}
    try:
        release_raw = released_red_window()
        raw = bounded_file(EVIDENCE, 2 * 1024 * 1024)
        require(digest(raw) == 'e0dcd84c8e69fde9e81362f0294c1d029448e10d7f9a3d21df63abec4ca4105e',
                'FIXED_ACTUAL_RED_CHROME_EVIDENCE_CHANGED')
        profile, target, origin = owned_target(raw)
        association, body, header, files, count = inspect_cache(profile, target, origin)
        require(bounded_file(EVIDENCE, 2 * 1024 * 1024) == raw, 'OWN_EVIDENCE_CHANGED_DURING_READBACK')
        require(released_red_window() == release_raw, 'RELEASE_CHANGED_DURING_READBACK')
        result.update(status='DIAGNOSTIC_RENDERER_FACTS_NOT_TEST_ACCEPTANCE',
            release={'path': str(BASE / 'root-attempt/release.json'), 'bytes': len(release_raw), 'sha256': digest(release_raw)},
            overallEvidenceStatusRetained='NOT_ACCEPTED',
            stickyProblemsRetained=['OWN_JOB_MEMBER_IDENTITY_UNPROVED'],
            evidence={'path': str(EVIDENCE), 'bytes': len(raw), 'sha256': digest(raw)},
            ownedProfile=str(profile), cacheFiles=files, totalCacheBytesRead=count,
            preciseEntryAssociation=association,
            fragments=[create('entry-store-header-96.bin', header), create('generated-wrapper.html', body)],
            rawEntryKeySaved=False, rawResponseMetadataSaved=False, maximumWrapperBytes=MAX_WRAPPER_BYTES)
    except Exception as failure:
        result.update(errorType=type(failure).__name__,
                      errorCode=str(failure) if isinstance(failure, ReadbackRejected) else 'UNEXPECTED_FILE_OR_FORMAT_ERROR')
    pin = create('result.json', (json.dumps(result, indent=2, ensure_ascii=True) + '\n').encode('utf-8'))
    print(json.dumps({'status': result['status'], 'result': pin}))
    return 0 if result['status'] == 'DIAGNOSTIC_RENDERER_FACTS_NOT_TEST_ACCEPTANCE' else 1


if __name__ == '__main__':
    raise SystemExit(main())
