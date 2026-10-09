import 'package:device_access/device_access.dart';
import 'package:test/test.dart';
import 'fixtures.dart';
import 'verifier_test.dart' show failure;

void main() {
  Map<String, dynamic> reference([Map<String, dynamic> changes = const {}]) => {
        'requestId': request,
        'approvalVersion': 1,
        'approvalState': 'APPROVED_PENDING_DELIVERY',
        'absoluteNotAfter': now + 299000,
        ...changes
      };
  test(
      'reference pages keep immutable items and explicit complete-scan continuation',
      () {
    final page = AccessReferencePage.fromJson({
      'items': [reference()],
      'nextCursor': request
    }, after: null, limit: 1);
    expect(page.nextCursor, request);
    expect(() => page.items.clear(), throwsUnsupportedError);
  });
  test('page context itself must have canonical bounds', () {
    for (final limit in [0, 101]) {
      expect(
          () => AccessReferencePage.fromJson({'items': [], 'nextCursor': null},
              after: null, limit: limit),
          throwsArgumentError);
    }
  });
  test('non-approved states and unsafe or fractional versions are refused', () {
    for (final changes in [
      {'approvalState': 'PENDING'},
      {'approvalVersion': 1.5},
      {'approvalVersion': 9007199254740992},
      {'absoluteNotAfter': null},
      {'requestId': '../other'}
    ]) {
      expect(() => AccessReference.fromJson(reference(changes)),
          throwsA(failure('TRANSPORT_INVALID')));
    }
  });
  test(
      'retry attempts must be JSON integers and correlate to their predecessor',
      () {
    for (final attempt in [2.5, 1, 3]) {
      expect(
          () => AccessRetryResult.fromJson({
                'documentId': document,
                'deliveryAttempt': attempt,
                'createdAt': now,
                'current': true
              }, documentId: document, failedAttempt: 1),
          throwsA(failure('TRANSPORT_INVALID')));
    }
  });
  test('historical successful retry still identifies its exact successor', () {
    final retry = AccessRetryResult.fromJson({
      'documentId': document,
      'deliveryAttempt': 2,
      'createdAt': now,
      'current': false
    }, documentId: document, failedAttempt: 1);
    expect(retry.current, isFalse);
    expect(retry.deliveryAttempt, 2);
  });
  test(
      'reference accepts a later revocation but refuses earlier or altered grants',
      () async {
    final key = newKey();
    final verifier = AccessWindowVerifier(
        scope: scope, trustedKeys: publicRing(key), nowMillis: () => now);
    final ref = AccessReference.fromJson(reference());
    final removed = await verifier.verify(sign(
        key,
        envelope({
          'documentId': tenant,
          'approvalVersion': 2,
          'action': 'REMOVE_ACCESS_WINDOW',
          'approvalState': 'REVOKED'
        })));
    ref.requireMatch(removed);
    expect(
        () => AccessReference.fromJson(reference({'approvalVersion': 3}))
            .requireMatch(removed),
        throwsA(failure('TRANSPORT_MISMATCH')));
    expect(
        () => AccessReference.fromJson(
                reference({'absoluteNotAfter': now + 300000}))
            .requireMatch(removed),
        throwsA(failure('TRANSPORT_MISMATCH')));
  });
}
