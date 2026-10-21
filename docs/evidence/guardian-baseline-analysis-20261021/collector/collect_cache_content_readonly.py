"""Unrun, fixed-scope, read-only content collector. Never starts any SDK/code.

Root must review the frozen script and allowlist before running it. It creates
exactly one manifest with CREATE_NEW semantics and never replaces an old result.
"""
import sys
sys.dont_write_bytecode = True

import ctypes
from ctypes import wintypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import time

TASK = Path(r'D:\codes\mobile\ai-manager\.cache\guardian-current-20261021-r1')
SCRIPT = TASK / 'collect_cache_content_readonly.py'
ALLOWLIST = TASK / 'cache-content-read-allowlist.json'
ALLOWLIST_SHA256 = 'c5e6ed5ff030a6e4f06432312f8cedb1e3761c46613760a931c9701d3d1e046b'
SEED = TASK / 'out/dependency-library-pins.json'
SEED_SHA256 = 'e7b577c7790a24721ab81280948ec0118c1b9e3a096350bbfe81fe98b49f0d7f'
OUTPUT = TASK / 'out/cache-content-20261021-r1.json'
MAX_ELAPSED_SECONDS = 180
MAX_TOTAL_FILES = 40000
MAX_TOTAL_BYTES = 3 * 1024**3
REPARSE_POINT = 0x400
DIRECTORY = 0x10
INVALID_HANDLE = ctypes.c_void_p(-1).value


def check(value, message):
    if not value:
        raise RuntimeError(message)


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def normalized(path):
    value = os.path.abspath(str(path))
    check(not value.startswith('\\\\') and ':' not in value[2:], 'UNC/device/ADS path refused')
    check('..' not in Path(value).parts, 'Parent traversal refused')
    return os.path.normcase(value)


class FileInformation(ctypes.Structure):
    _fields_ = [('attributes', wintypes.DWORD), ('creation', wintypes.FILETIME),
                ('access', wintypes.FILETIME), ('write', wintypes.FILETIME),
                ('volume', wintypes.DWORD), ('sizeHigh', wintypes.DWORD),
                ('sizeLow', wintypes.DWORD), ('links', wintypes.DWORD),
                ('indexHigh', wintypes.DWORD), ('indexLow', wintypes.DWORD)]


class LockedInput:
    """Open the exact object without following reparse points; deny mutation."""
    def __init__(self, api, path, directory=False):
        self.api, self.path, self.handle = api, Path(path), None
        # Share READ only. In particular, directory rename/delete is denied while
        # its handle and all ancestors are retained during a traversal.
        flags = 0x00200000 | (0x02000000 if directory else 0)
        access = 0x80 if directory else 0x80000000
        handle = api.CreateFileW(str(self.path), access, 1, None, 3, flags, None)
        if handle == INVALID_HANDLE:
            raise ctypes.WinError(ctypes.get_last_error())
        self.handle = handle
        try:
            info = self.info()
            check(not info.attributes & REPARSE_POINT, 'Reparse/link input refused: ' + str(self.path))
            check(bool(info.attributes & DIRECTORY) == directory, 'Unexpected input type: ' + str(self.path))
            if not directory:
                check(info.links == 1, 'Hard-linked input refused: ' + str(self.path))
            buffer = ctypes.create_unicode_buffer(32768)
            length = api.GetFinalPathNameByHandleW(handle, buffer, len(buffer), 0)
            check(0 < length < len(buffer), 'Cannot read final handle path')
            actual = buffer.value
            check(actual.startswith('\\\\?\\') and not actual.startswith('\\\\?\\UNC\\'), 'Unexpected final path form')
            check(normalized(actual[4:]) == normalized(self.path), 'Input handle escaped its exact allowed path')
        except BaseException:
            self.close()
            raise

    def info(self):
        info = FileInformation()
        if not self.api.GetFileInformationByHandle(self.handle, ctypes.byref(info)):
            raise ctypes.WinError(ctypes.get_last_error())
        return info

    def close(self):
        if self.handle is not None:
            if not self.api.CloseHandle(self.handle):
                raise ctypes.WinError(ctypes.get_last_error())
            self.handle = None

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()


def api_bindings():
    api = ctypes.WinDLL('kernel32', use_last_error=True)
    api.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                               ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    api.CreateFileW.restype = wintypes.HANDLE
    api.GetFileInformationByHandle.argtypes = [wintypes.HANDLE, ctypes.POINTER(FileInformation)]
    api.GetFileInformationByHandle.restype = wintypes.BOOL
    api.GetFinalPathNameByHandleW.argtypes = [wintypes.HANDLE, wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD]
    api.GetFinalPathNameByHandleW.restype = wintypes.DWORD
    api.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                            ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
    api.ReadFile.restype = wintypes.BOOL
    api.CloseHandle.argtypes = [wintypes.HANDLE]
    api.CloseHandle.restype = wintypes.BOOL
    return api


def identity(info):
    return (info.attributes, info.volume, info.indexHigh, info.indexLow,
            info.sizeHigh, info.sizeLow, info.links,
            info.write.dwHighDateTime, info.write.dwLowDateTime)


def secret_name_guard(name):
    lower = name.lower()
    check(lower not in {'.local', '.git', '.aws', '.ssh', '.npmrc', '.netrc', '.pypirc', 'credentials'}
          and not lower.startswith('.env'), 'Secret/config name refused inside allowed tree')


def main():
    started = time.monotonic()
    check(os.name == 'nt' and not sys.argv[1:], 'Windows only; alternate paths/options are forbidden')
    check(normalized(__file__) == normalized(SCRIPT), 'Script must run from its fixed reviewed path')
    api = api_bindings()
    totals = {'files': 0, 'bytes': 0}

    def budget():
        check(time.monotonic() - started < MAX_ELAPSED_SECONDS, 'Read-only collection deadline exceeded')
        check(totals['files'] <= MAX_TOTAL_FILES and totals['bytes'] <= MAX_TOTAL_BYTES,
              'Fixed collection content limit exceeded')

    def lock_chain(path):
        parts = [Path(path).anchor]
        cursor = Path(parts[0])
        paths = [cursor]
        for part in Path(path).parts[1:]:
            cursor = cursor / part
            paths.append(cursor)
        handles = []
        try:
            for item in paths:
                budget()
                handles.append(LockedInput(api, item, directory=True))
            return handles
        except BaseException:
            for handle in reversed(handles):
                handle.close()
            raise

    def hash_locked(path, count=True, capture=False):
        budget()
        with LockedInput(api, path) as opened:
            before = opened.info()
            size = (before.sizeHigh << 32) | before.sizeLow
            check(size <= MAX_TOTAL_BYTES - totals['bytes'], 'File exceeds remaining byte limit')
            digest, actual, chunks = hashlib.sha256(), 0, []
            buffer = ctypes.create_string_buffer(1024 * 1024)
            read = wintypes.DWORD()
            while True:
                budget()
                if not api.ReadFile(opened.handle, buffer, len(buffer), ctypes.byref(read), None):
                    raise ctypes.WinError(ctypes.get_last_error())
                if not read.value:
                    break
                data = buffer.raw[:read.value]
                digest.update(data)
                actual += len(data)
                if capture:
                    check(actual <= 5 * 1024**2, 'Captured metadata is too large')
                    chunks.append(data)
            check(actual == size and identity(before) == identity(opened.info()), 'Input changed while hashing')
            if count:
                totals['files'] += 1
                totals['bytes'] += actual
                budget()
            row = {'bytes': actual, 'sha256': digest.hexdigest()}
            return (row, b''.join(chunks)) if capture else row

    task_handles = lock_chain(TASK / 'out')
    manifest = {'status': 'READ_ONLY_COLLECTION_RUNNING_NOT_SDK_VALIDATION', 'startedAtUtc': utc(),
                'collector': str(SCRIPT), 'readAllowlist': str(ALLOWLIST), 'output': str(OUTPUT),
                'sdkStarted': False, 'pubRun': False, 'packageCodeExecuted': False,
                'browserStarted': False, 'networkRun': False, 'cacheCopied': False,
                'trees': [], 'fixedFiles': []}
    result_stream = None
    try:
        script_pin = hash_locked(SCRIPT, count=False)
        allow_pin, allow_bytes = hash_locked(ALLOWLIST, count=False, capture=True)
        check(allow_pin['sha256'] == ALLOWLIST_SHA256, 'Frozen read allowlist changed')
        seed_pin, seed_bytes = hash_locked(SEED, count=False, capture=True)
        check(seed_pin['sha256'] == SEED_SHA256, 'Frozen 70-row package mapping changed')
        allowlist, seed = json.loads(allow_bytes), json.loads(seed_bytes)
        manifest.update(collectorPin=script_pin, allowlistPin=allow_pin, seedPin=seed_pin)
        hosted = [r for r in seed['packageMappings'] if r['category'] == 'existing-hosted-cache']
        check(len(seed['packageMappings']) == 70 and len(hosted) == 58, 'Frozen package scope changed')
        expected_hosted = {r['name']: normalized(Path(r['resolvedRoot']) / r['packageUri']) for r in hosted}
        declared_hosted = {r['package']: normalized(r['root']) for r in allowlist['hostedLibraryTrees']}
        check(len(declared_hosted) == 58 and expected_hosted == declared_hosted, 'Host cache whitelist differs from frozen mapping')
        check(allowlist['output'] == str(OUTPUT), 'Output whitelist differs')
        # Python mode xb maps to exclusive creation. A pre-existing link, partial,
        # successful or failed output therefore refuses the whole attempt.
        result_stream = OUTPUT.open('xb')

        def inventory_tree(spec):
            root = Path(spec['root'])
            root_handles = lock_chain(root)
            rows, directories = [], []
            def listing(path):
                budget()
                with os.scandir(path) as iterator:
                    return sorted(entry.name for entry in iterator)
            def walk(directory, relative):
                names = listing(directory)
                directories.append(relative.as_posix())
                for name in names:
                    budget()
                    secret_name_guard(name)
                    path, rel = directory / name, relative / name
                    # Parent directories are already locked against rename/delete.
                    # Probe with a non-following handle before choosing recursion.
                    info = path.lstat()
                    check(not getattr(info, 'st_file_attributes', 0) & REPARSE_POINT,
                          'Link/junction refused during enumeration')
                    if path.is_dir():
                        with LockedInput(api, path, directory=True):
                            walk(path, rel)
                    else:
                        row = hash_locked(path)
                        rows.append({'relativePath': rel.as_posix(), **row})
                check(listing(directory) == names, 'Directory membership changed during enumeration')
            try:
                walk(root, Path('.'))
                rows.sort(key=lambda r: r['relativePath'])
                canonical = ''.join(f"{r['relativePath']}\0{r['bytes']}\0{r['sha256']}\n" for r in rows)
                return {**spec, 'completeFileSetRecorded': True, 'directories': sorted(directories),
                        'files': len(rows), 'bytes': sum(r['bytes'] for r in rows),
                        'treeSha256': hashlib.sha256(canonical.encode()).hexdigest(), 'entries': rows}
            finally:
                for handle in reversed(root_handles):
                    handle.close()

        for spec in allowlist['hostedLibraryTrees'] + allowlist['sdkLibraryAndRuntimeTrees']:
            manifest['trees'].append(inventory_tree(spec))
        for spec in allowlist['fixedRuntimeFiles']:
            path = Path(spec['path'])
            handles = lock_chain(path.parent)
            try:
                row = hash_locked(path)
                if 'expectedSha256' in spec:
                    check(row['sha256'] == spec['expectedSha256'], 'Previously pinned runtime file changed')
                manifest['fixedFiles'].append({**spec, **row})
            finally:
                for handle in reversed(handles):
                    handle.close()
        budget()
        manifest.update(status='READ_ONLY_CONTENT_COLLECTION_COMPLETE_NOT_SDK_VALIDATION',
                        fullAllowlistCollected=True, totals=totals,
                        completeHostedLibraryTrees=58, entireSdkCollected=False)
        code = 0
    except BaseException as error:
        manifest.update(status='READ_ONLY_CONTENT_COLLECTION_FAILED_NOT_SDK_VALIDATION',
                        fullAllowlistCollected=False, error=type(error).__name__ + ': ' + str(error), totals=totals)
        code = 1
    finally:
        manifest.update(finishedAtUtc=utc(), elapsedSeconds=time.monotonic() - started)
        if result_stream is not None:
            data = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
            result_stream.write(data)
            result_stream.flush()
            os.fsync(result_stream.fileno())
            result_stream.close()
            print(json.dumps({'status': manifest['status'], 'output': str(OUTPUT),
                              'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                              'hashedFiles': totals['files'], 'hashedBytes': totals['bytes']}))
        else:
            print(json.dumps({'status': 'REFUSED_WITHOUT_NEW_OUTPUT', 'reason': manifest.get('error', 'unknown')}))
        for handle in reversed(task_handles):
            handle.close()
    return code


if __name__ == '__main__':
    raise SystemExit(main())
