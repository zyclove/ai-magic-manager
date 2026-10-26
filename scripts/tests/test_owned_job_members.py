"""Pure fake-kernel regressions; no native API, processes or environment reads."""
from collections import Counter
from contextlib import ExitStack
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / "verification" / "owned_job.py"
SPEC = importlib.util.spec_from_file_location("retained_owned_job", SOURCE)
OWNED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OWNED)


class FakeKernel:
    ROOT_PID = 101
    ROOT_HANDLE = 5001
    THREAD_HANDLE = 5002
    JOB_HANDLE = 7000

    def __init__(self):
        self.error = 0
        self.pids = [self.ROOT_PID, 201]
        self.records = {self.ROOT_PID: self.record(1000), 201: self.record(5000)}
        self.handles = {self.ROOT_HANDLE: self.ROOT_PID}
        self.opens = []
        self.closed = []
        self.membership_checks = []
        self.times_checks = []
        self.open_errors = {}
        self.membership_errors = set()
        self.times_errors = set()
        self.set_limit_ok = True
        self.next_handle = 10000

    @staticmethod
    def record(creation):
        return {"creation": creation, "member": True, "exited": False}

    def CreateJobObjectW(self, *_):
        return self.JOB_HANDLE

    def SetInformationJobObject(self, handle, kind, data, _size):
        assert handle == self.JOB_HANDLE and kind == 9
        limits = OWNED.C.cast(data, OWNED.C.POINTER(OWNED.ExtendedLimits)).contents
        assert limits.basic.flags == 0x2000
        self.error = 5
        return self.set_limit_ok

    def QueryInformationJobObject(self, handle, kind, data, _size, _returned):
        assert handle == self.JOB_HANDLE and kind == 3
        result = OWNED.C.cast(data, OWNED.C.POINTER(OWNED.ProcessIds32)).contents
        result.assigned = result.listed = len(self.pids)
        for index, pid in enumerate(self.pids[:32]):
            result.ids[index] = pid
        return True

    def OpenProcess(self, access, inherit, pid):
        self.opens.append((access, inherit, pid))
        if pid in self.open_errors:
            self.error = self.open_errors[pid]
            return 0
        self.next_handle += 1
        self.handles[self.next_handle] = pid
        return self.next_handle

    def IsProcessInJob(self, handle, job, result):
        assert job == self.JOB_HANDLE and handle not in self.closed
        self.membership_checks.append(handle)
        if handle in self.membership_errors:
            self.error = 5
            return False
        pid = self.handles[handle]
        OWNED.C.cast(result, OWNED.C.POINTER(OWNED.W.BOOL)).contents.value = (
            self.records[pid]["member"]
        )
        return True

    def GetProcessTimes(self, handle, *values):
        assert handle not in self.closed
        self.times_checks.append(handle)
        if handle in self.times_errors:
            self.error = 5
            return False
        record = self.records[self.handles[handle]]
        for pointer, value in zip(values, (
                record["creation"], 9000 if record["exited"] else 0, 0, 0)):
            result = OWNED.C.cast(pointer, OWNED.C.POINTER(OWNED.W.FILETIME)).contents
            result.dwLowDateTime = value & 0xFFFFFFFF
            result.dwHighDateTime = value >> 32
        return True

    def WaitForSingleObject(self, handle, milliseconds):
        assert milliseconds == 0 and handle not in self.closed
        return 0 if self.records[self.handles[handle]]["exited"] else 258

    def GetExitCodeProcess(self, handle, result):
        assert handle not in self.closed
        OWNED.C.cast(result, OWNED.C.POINTER(OWNED.D)).contents.value = 0
        return True

    def QueryFullProcessImageNameW(self, handle, flags, buffer, size):
        assert flags == 0 and handle not in self.closed
        buffer.value = r"C:\fake\owned-member.exe"
        OWNED.C.cast(size, OWNED.C.POINTER(OWNED.D)).contents.value = len(buffer.value)
        return True

    def CloseHandle(self, handle):
        assert handle not in self.closed, "a handle was closed twice"
        self.closed.append(handle)
        return True


class OwnedJobMemberTest(unittest.TestCase):
    def setUp(self):
        self.kernel = FakeKernel()
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(OWNED, "api", return_value=self.kernel))
        self.stack.enter_context(patch.object(OWNED.time, "monotonic", return_value=100.0))
        self.stack.enter_context(patch.object(
            OWNED.C, "get_last_error", lambda: self.kernel.error, create=True))
        self.stack.enter_context(patch.object(
            OWNED.C, "WinError", lambda error, label: OSError(error, label), create=True))
        self.job = OWNED.OwnedJob()
        self.job.process = self.kernel.ROOT_HANDLE
        self.job.thread = self.kernel.THREAD_HANDLE
        self.job.pid = self.kernel.ROOT_PID
        self.job.identity = 1000
        self.addCleanup(self.job.close)

    def sample(self):
        return self.job.member_identities(200.0)

    @staticmethod
    def row(snapshot, pid=201):
        return next(row for row in snapshot["identities"] if row["pid"] == pid)

    def test_repeated_sample_reuses_proven_handle_without_early_close(self):
        first = self.sample()
        self.kernel.open_errors[201] = 87
        self.kernel.records[201]["exited"] = True
        second = self.sample()
        row = self.row(second)
        self.assertEqual({
            "openCount": len(self.kernel.opens),
            "closedChildHandles": [h for h in self.kernel.closed if h >= 10000],
            "creation": row.get("creationFiletime"),
            "openError": row.get("openError"),
        }, {"openCount": 1, "closedChildHandles": [], "creation": 5000,
            "openError": None})
        self.assertEqual(self.kernel.opens, [(0x1000 | 0x100000, False, 201)])
        self.assertTrue(row["verifiedOwnMembership"])
        self.assertTrue(row["signaled"])
        self.assertEqual(row["exitCode"], 0)
        self.assertFalse(row["retainedRootHandleUsed"])
        self.assertTrue(self.row(first, 101)["retainedRootHandleUsed"])
        self.assertEqual(set(second), set(first))
        self.assertEqual(set(row), set(self.row(first)) | {"exitCode"})

    def test_first_open_error_87_is_unproved_and_never_retried_by_pid(self):
        self.kernel.open_errors[201] = 87
        row = self.row(self.sample())
        self.assertEqual(row["openError"], 87)
        self.assertFalse(row["verifiedOwnMembership"])
        self.assertNotIn("creationFiletime", row)
        with self.assertRaisesRegex(RuntimeError, "not proved"):
            self.sample()
        self.assertEqual(len(self.kernel.opens), 1)

    def test_cached_identity_change_or_query_failure_never_reopens(self):
        self.sample()
        handle = self.kernel.next_handle
        self.kernel.records[201]["creation"] = 6000
        self.assertTrue(self.row(self.sample())["retainedIdentityMismatch"])
        self.kernel.records[201]["creation"] = 5000
        self.kernel.membership_errors.add(handle)
        self.assertEqual(self.row(self.sample())["membershipQueryError"], 5)
        self.kernel.membership_errors.clear()
        self.kernel.times_errors.add(handle)
        self.assertEqual(self.row(self.sample())["timesError"], 5)
        self.assertEqual(len(self.kernel.opens), 1)
        self.assertNotIn(handle, self.kernel.closed)
        self.assertGreaterEqual(self.kernel.membership_checks.count(handle), 4)

    def test_nonmember_is_not_admitted_and_cannot_be_reopened(self):
        self.kernel.records[201]["member"] = False
        row = self.row(self.sample())
        self.assertFalse(row["verifiedOwnMembership"])
        self.assertTrue(row["membershipRaceOrChange"])
        self.assertNotIn("creationFiletime", row)
        self.assertIn(self.kernel.next_handle, self.kernel.closed)
        with self.assertRaisesRegex(RuntimeError, "not proved"):
            self.sample()
        self.assertEqual(len(self.kernel.opens), 1)

    def test_fixed_capacity_rejects_without_eviction_or_partial_success(self):
        for start in range(0, 256, 31):
            pids = list(range(1000 + start, 1000 + min(start + 31, 256)))
            for pid in pids:
                self.kernel.records[pid] = self.kernel.record(10000 + pid)
            self.kernel.pids = [101, *pids]
            self.sample()
        self.kernel.pids = [101, 9000]
        self.kernel.records[9000] = self.kernel.record(20000)
        with self.assertRaisesRegex(RuntimeError, "256"):
            self.sample()
        self.assertEqual(len(self.kernel.opens), 256)
        self.assertEqual(self.kernel.closed, [])
        stats = self.job.member_cache_stats
        self.assertEqual(stats["retained"], 256)
        self.assertEqual(stats["capacityFailures"], 1)
        stats["retained"] = 0
        self.assertEqual(self.job.member_cache_stats["retained"], 256)

    def test_close_is_idempotent_and_constructor_failure_releases_resources(self):
        self.sample()
        self.sample()
        self.job.close()
        self.job.close()
        self.assertEqual(Counter(self.kernel.closed), Counter({
            self.kernel.JOB_HANDLE: 1, self.kernel.ROOT_HANDLE: 1,
            self.kernel.THREAD_HANDLE: 1, self.kernel.next_handle: 1,
        }))
        self.assertEqual(self.job.member_cache_stats["retained"], 0)
        self.assertEqual(self.job.member_cache_stats["closeErrors"], 0)
        self.kernel.closed.clear()
        self.kernel.set_limit_ok = False
        with self.assertRaises(OSError):
            OWNED.OwnedJob()
        self.assertEqual(self.kernel.closed, [self.kernel.JOB_HANDLE])


if __name__ == "__main__":
    unittest.main()
