import 'package:child/core/session.dart';
import 'package:device_policy/device_policy.dart' as policy;
import 'package:flutter_test/flutter_test.dart';
import 'support/identity_fixture.dart';

class PendingRuleReceiver implements ChildRuleReceiver {
  bool saved = false;
  @override
  Future<ChildRules> restore() async =>
      ChildRules(cursor: saved ? 42 : 0, pendingReceipts: saved ? 1 : 0);
  @override
  Future<ChildRules> synchronize() async {
    saved = true;
    throw const policy.DeviceTransportFailure('NETWORK_UNAVAILABLE',
        retryable: true, outcomeUnknown: true);
  }

  @override
  Future<void> close() async {}
}

void main() {
  test(
      'receipt transport failure still exposes committed local cursor and pending work',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = PendingRuleReceiver();
    final session = fixture.session(rules: (_) => Future.value(receiver));
    addTearDown(session.dispose);
    await session.initialize();
    expect(session.rules.cursor, 0);
    expect(await session.synchronizeRules(), isFalse);
    expect(session.rules.cursor, 42);
    expect(session.rules.pendingReceipts, 1);
    expect(session.systemEnforced, isFalse);
  });
}
