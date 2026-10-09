import 'dart:async';
import 'package:child/core/access.dart';
import 'package:child/core/session.dart';
import 'package:device_access/device_access.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../packages/device_access/test/fixtures.dart' as grants;
import 'support/identity_fixture.dart';

class SessionAccessReceiver implements ChildAccessReceiver {
  final IdentityFixture fixture;
  int syncs = 0, restores = 0, pauses = 0;
  bool closed = false, denied = false;
  SessionAccessReceiver(this.fixture);
  ChildAccessSnapshot snapshot() =>
      ChildAccessSnapshot(contextReady: true, entries: [
        ChildAccessEntry(
            AccessJournalEntry(
                VerifiedAccessWindow.internal(
                    'test-only-not-transport',
                    grants.envelope({
                      'grantIssuedAt': IdentityFixture.now - 1,
                      'documentIssuedAt': IdentityFixture.now - 1,
                      'absoluteNotAfter': IdentityFixture.now + 1000
                    })),
                fixture.clock >= IdentityFixture.now + 1000
                    ? AccessEntryState.expired
                    : AccessEntryState.stored,
                pendingAcknowledgement: false),
            '单元测试应用')
      ]);
  @override
  Future<ChildAccessSnapshot> restore() async {
    restores++;
    return snapshot();
  }

  @override
  Future<ChildAccessSnapshot> synchronize() async {
    syncs++;
    if (denied) {
      throw const AccessTransportFailure('DEVICE_UNAUTHENTICATED', status: 401);
    }
    return snapshot();
  }

  @override
  void pause() {
    pauses++;
  }

  @override
  void resume() {}
  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  test('receiver created after background transition is closed before restore',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = SessionAccessReceiver(fixture);
    final creating = Completer<void>();
    final created = Completer<ChildAccessReceiver>();
    final session = ChildSession(
        identity: fixture.identity,
        nowMillis: () => fixture.clock,
        accessFactory: (_, baseline) {
          creating.complete();
          return created.future;
        });
    addTearDown(session.dispose);
    final initialized = session.initialize();
    await creating.future;
    await session.setForeground(false);
    created.complete(receiver);
    await initialized;
    expect(receiver.closed, isTrue);
    expect(receiver.restores, 0);
    expect(receiver.syncs, 0);
    expect(session.access.entries, isEmpty);
  });
  testWidgets(
      'clock failure inside an expiry timer is contained and hides cached access',
      (tester) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = SessionAccessReceiver(fixture);
    var clockWorks = true;
    final session = ChildSession(
        identity: fixture.identity,
        nowMillis: () {
          if (!clockWorks) throw StateError('synthetic unavailable clock');
          return fixture.clock;
        },
        accessFactory: (_, baseline) async => receiver);
    addTearDown(session.dispose);
    await session.initialize();
    await tester.pump();
    clockWorks = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(session.access.entries, isEmpty);
    expect(session.accessErrorCode, 'CLOCK_UNTRUSTED');
  });
  Future<void> idle(ChildSession session) async {
    for (var i = 0; i < 20 && session.busy; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(session.busy, isFalse);
  }

  test(
      'active host restores, syncs and keeps failures specific to temporary access',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = SessionAccessReceiver(fixture);
    final session = ChildSession(
        identity: fixture.identity,
        nowMillis: () => fixture.clock,
        accessFactory: (_, baseline) async => receiver);
    addTearDown(session.dispose);
    await session.initialize();
    await idle(session);
    expect(receiver.syncs, greaterThan(0));
    expect(session.access.entries.length, 1);
    receiver.denied = true;
    expect(await session.synchronizeAccess(), isFalse);
    expect(session.access.entries, isEmpty,
        reason: '401 must not restore the fake receiver cache');
    expect(session.accessErrorCode, 'DEVICE_UNAUTHENTICATED');
    expect(session.errorCode, isNull);
  });
  test(
      'background hides all access and a rejected device connection closes its receiver',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = SessionAccessReceiver(fixture);
    final session = ChildSession(
        identity: fixture.identity,
        nowMillis: () => fixture.clock,
        accessFactory: (_, baseline) async => receiver);
    addTearDown(session.dispose);
    await session.initialize();
    await idle(session);
    await session.setForeground(false);
    expect(session.access.entries, isEmpty);
    expect(receiver.pauses, greaterThan(0));
    await session.setForeground(true);
    await idle(session);
    expect(session.access.entries.length, 1);
    fixture.rejectAuthentication = true;
    expect(await session.checkConnection(), isFalse);
    expect(session.access.entries, isEmpty);
    expect(receiver.closed, isTrue);
  });
  testWidgets(
      'original deadline refreshes locally and never triggers an automatic network mutation',
      (tester) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = SessionAccessReceiver(fixture);
    final session = ChildSession(
        identity: fixture.identity,
        nowMillis: () => fixture.clock,
        accessFactory: (_, baseline) async => receiver);
    addTearDown(session.dispose);
    await session.initialize();
    await tester.pump();
    final syncs = receiver.syncs;
    expect(session.access.entries.single.record.state, AccessEntryState.stored);
    fixture.clock = IdentityFixture.now + 1000;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(
        session.access.entries.single.record.state, AccessEntryState.expired);
    expect(receiver.syncs, syncs);
    expect(session.systemEnforced, isFalse);
  });
}
