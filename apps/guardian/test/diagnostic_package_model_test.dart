import 'package:flutter_test/flutter_test.dart';
import '../lib/core/api.dart';
import '../lib/core/support.dart';
import '../lib/core/diagnostic_package.dart';
import 'fixtures/diagnostic_package.dart';
import 'fixtures/diagnostic.dart' as diagnostic;
import 'fixtures/support.dart' show grantFixture;

final invalid = isA<ApiFailure>();
DiagnosticPackage parse(Json value, {bool received = false}) =>
    DiagnosticPackage.parse(value,
        actor: received ? recipient : owner,
        mode: received ? 'SUPPORT_GRANT' : 'ADMIN',
        tenant: received ? null : tenant);
void main() {
  test('package states are bounded and ready metadata is complete', () {
    for (final state in [
      'QUEUED',
      'RUNNING',
      'READY',
      'CANCELLED',
      'EXPIRED',
      'REVOKED',
      'FAILED'
    ]) expect(parse(packageFixture(state: state)).state, state);
    for (final change in <String, Object?>{
      'requesterActorId': recipient,
      'accessMode': 'PUBLIC',
      'expiresAt': diagnostic.now + 1800001,
      'version': -1,
      'byteCount': 1,
      'artifact': 'PRIVATE'
    }.entries)
      expect(() => parse(packageFixture()..[change.key] = change.value),
          throwsA(invalid));
    expect(() => parse(packageFixture(state: 'READY')..['sha256'] = 'broken'),
        throwsA(invalid));
  });
  test('refresh preserves scope and cannot revive a terminal package', () {
    final job = parse(packageFixture());
    final ready = parse(packageFixture(state: 'READY'));
    job.validateUpdate(ready);
    expect(() => ready.validateUpdate(job), throwsA(invalid));
    expect(
        () => job.validateUpdate(
            parse(packageFixture()..['registrationId'] = device)),
        throwsA(invalid));
    final cancelled =
        parse(packageFixture(state: 'CANCELLED')..['version'] = 3);
    expect(() => cancelled.validateUpdate(ready), throwsA(invalid));
  });
  test('admin download validates digest and the complete diagnostic schema',
      () {
    final document = packageDocument(),
        bytes = documentBytes(document),
        job = parse(packageFixture(state: 'READY', document: document));
    expect(
        validateDiagnosticPackageDownload(bytes, job, now: diagnostic.now)
            .length,
        bytes.length);
    final changed = documentBytes({...document, 'jobId': device});
    expect(
        () => validateDiagnosticPackageDownload(changed, job,
            now: diagnostic.now),
        throwsA(invalid));
    expect(
        () => validateDiagnosticPackageDownload(bytes, job, now: job.expiresAt),
        throwsA(invalid));
  });
  test('unknown fields are rejected even when byte count and digest match', () {
    for (final target in [
      'root',
      'diagnostic',
      'scope',
      'version',
      'device',
      'capability',
      'configuration'
    ]) {
      final document = packageDocument(),
          inner = document['diagnostic'] as Json;
      final Json object = switch (target) {
        'root' => document,
        'diagnostic' => inner,
        'scope' => inner['scope'] as Json,
        'version' => (inner['versions'] as Json)['agent'] as Json,
        'device' => inner['device'] as Json,
        'capability' => (inner['capabilities'] as List).first as Json,
        _ => (inner['configurations'] as List).first as Json
      };
      object['privateText'] = 'must not be downloaded';
      final job = parse(packageFixture(state: 'READY', document: document));
      expect(
          () => validateDiagnosticPackageDownload(documentBytes(document), job,
              now: diagnostic.now),
          throwsA(invalid),
          reason: target);
    }
  });
  test('received download requires matching current grant and only its scope',
      () {
    final document = packageDocument(received: true),
        job = parse(
            packageFixture(received: true, state: 'READY', document: document),
            received: true),
        grant = SupportGrant.parse(grantFixture(now: diagnostic.now - 1000));
    expect(
        validateDiagnosticPackageDownload(documentBytes(document), job,
            grant: grant, now: diagnostic.now),
        isNotEmpty);
    expect(
        () => validateDiagnosticPackageDownload(documentBytes(document), job,
            now: diagnostic.now),
        throwsA(invalid));
    final other = SupportGrant.parse(
        grantFixture(now: diagnostic.now - 1000)..['registrationId'] = device);
    expect(
        () => validateDiagnosticPackageDownload(documentBytes(document), job,
            grant: other, now: diagnostic.now),
        throwsA(invalid));
  });
  test('creation draft freezes device version scope and key', () {
    final draft = DiagnosticPackageDraft.admin(
        deviceId: device, registrationId: registration, deviceVersion: 3);
    expect(draft.body, {'registrationId': registration});
    expect(draft.deviceVersion, 3);
    expect(draft.key, draft.key);
    expect(() => draft.diagnosticTypes.add('PRIVATE'), throwsUnsupportedError);
    final grant = SupportGrant.parse(grantFixture(now: diagnostic.now - 1000));
    final support = DiagnosticPackageDraft.received(grant);
    expect(support.grantId, grant.id);
    expect(support.diagnosticTypes, ['DEVICE_STATUS']);
  });
}
