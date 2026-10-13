import copy
import unittest
from unittest.mock import Mock
from run_cleanup_https_android import validate_fixture, validate_result, validate_handoff, read_installation

RUN = '11111111-1111-4111-8111-111111111111'
BASE = {'schemaVersion': 1, 'runId': RUN, 'tenantId': RUN, 'subjectId': RUN,
        'phase': 'enroll', 'apiRoot': 'https://127.0.0.1:12345/api/v1',
        'serverCertificateDerBase64': 'YWJj',
        'ticket': {'tenantId': RUN, 'id': RUN, 'token': 'synthetic', 'expiresAt': 1800000000000}}

class HttpsCleanupChecks(unittest.TestCase):
    def test_read_only_metadata_recovers_from_temporary_transport_failure(self):
        query = Mock(side_effect=[RuntimeError('temporary transport'),
            'appId=10190\nfirstInstallTime=2026-10-13 05:00:00'])
        result, retries = read_installation(query, pause=Mock())
        self.assertEqual(result['uid'], '10190')
        self.assertEqual(retries, 1)
        self.assertEqual(query.call_count, 2)

    def test_metadata_retry_is_bounded_and_never_hides_ambiguous_data(self):
        query = Mock(side_effect=RuntimeError('unavailable'))
        with self.assertRaises(RuntimeError):
            read_installation(query, pause=Mock())
        self.assertEqual(query.call_count, 3)
        query = Mock(return_value='appId=10190\nuserId=10191\nfirstInstallTime=one')
        with self.assertRaises(ValueError):
            read_installation(query, pause=Mock())
        self.assertEqual(query.call_count, 1)

    def test_only_exact_owned_https_origin_and_schema_are_accepted(self):
        self.assertEqual(validate_fixture(BASE).port, 12345)
        for url in ['http://127.0.0.1:12345/api/v1', 'https://example.com:12345/api/v1',
                    'https://127.0.0.1/api/v1', 'https://user@127.0.0.1:12345/api/v1',
                    'https://127.0.0.1:12345/api/v1?token=x', 'https://127.0.0.1:12345/api/v1/']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                validate_fixture({**BASE, 'apiRoot': url})
        for key, val in [('schemaVersion', 2), ('phase', 'destroy'), ('runId', 'bad'),
                         ('serverCertificateDerBase64', '*bad*')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_fixture({**BASE, key: val})

    def test_ticket_is_only_allowed_for_enroll_and_all_scopes_are_explicit(self):
        value = {**BASE, 'phase': 'cleanup', 'deviceId': RUN, 'registrationId': RUN,
                 'operationId': RUN, 'commandHash': 'a' * 64}
        with self.assertRaises(ValueError):
            validate_fixture(value)
        del value['ticket']
        self.assertEqual(validate_fixture(value).scheme, 'https')
        for key in ['deviceId', 'registrationId', 'operationId', 'commandHash']:
            invalid = copy.deepcopy(value)
            del invalid[key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_fixture(invalid)

    def test_native_result_requires_strict_phase_pid_and_boundaries(self):
        valid = {'phase': 'cleanup', 'pid': 42, 'realTls': True,
                 'untrustedCertificateRejected': True, 'realAndroidKey': True,
                 'cloudResponsesAreReal': True, 'adultIdentityIsFixture': True,
                 'cleanupCompleted': True, 'journalRetained': True,
                 'originalKeyDeleted': True, 'cachesDeleted': True, 'physicalWipeProven': False}
        validate_result(valid, 'cleanup', 42)
        for key, val in [('pid', 41), ('pid', True), ('phase', 'active'),
                         ('realTls', 1), ('journalRetained', False), ('cloudResponsesAreReal', False),
                         ('physicalWipeProven', True)]:
            with self.subTest(key=key, val=val), self.assertRaises(ValueError):
                validate_result({**valid, key: val}, 'cleanup', 42)
        with self.assertRaises(ValueError):
            validate_result({**valid, 'secret': 'forbidden'}, 'cleanup', 42)

    def test_pairing_handoff_is_scoped_and_never_contains_credentials(self):
        valid = {'deviceId': RUN, 'registrationId': RUN, 'pairingCode': 'A1B2C3D4'}
        validate_handoff(valid)
        for value in [{}, {**valid, 'deviceId': 'invalid'}, {**valid, 'pairingCode': 'secret'},
                      {**valid, 'credential': 'forbidden'}]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_handoff(value)

if __name__ == '__main__':
    unittest.main()
