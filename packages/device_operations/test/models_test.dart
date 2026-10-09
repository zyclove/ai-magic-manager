import 'package:device_operations/device_operations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fixtures.dart';

void main() {
  test('canonical path identifier rejects traversal and uppercase', () {
    expect(canonicalId(deviceId), deviceId);
    expect(() => canonicalId('../operations'), throwsFormatException);
    expect(() => canonicalId('AAAAAAAA-0000-4000-8000-000000000000'),
        throwsFormatException);
  });
  test('device version must be an integer and registration must be bound', () {
    expect(() => DeviceSnapshot.fromJson(deviceJson()), returnsNormally);
    expect(() => DeviceSnapshot.fromJson({...deviceJson(), 'version': '7'}),
        throwsFormatException);
    expect(
        () =>
            DeviceSnapshot.fromJson({...deviceJson(), 'registrationId': null}),
        throwsFormatException);
  });
  test('preview must carry a hash and UTC milliseconds', () {
    expect(() => ExitPreview.fromJson(previewJson()), returnsNormally);
    expect(() => ExitPreview.fromJson({...previewJson(), 'hash': 'invalid'}),
        throwsFormatException);
    expect(
        () =>
            ExitPreview.fromJson({...previewJson(), 'expiresAt': '2026-10-09'}),
        throwsFormatException);
  });
  test('reported local cleanup requires unverified evidence', () {
    expect(
        () => ExitOperation.fromJson(operationJson(state: 'CLEANUP_REPORTED')),
        returnsNormally);
    expect(
        () => ExitOperation.fromJson({
              ...operationJson(state: 'CLEANUP_REPORTED'),
              'localEvidence': 'NONE'
            }),
        throwsFormatException);
  });
}
