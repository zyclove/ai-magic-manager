import 'dart:async';
import 'package:child/core/session.dart';
import 'package:child/ui/child_app.dart';
import 'package:device_policy/device_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/identity_fixture.dart';

/// Synthetic verified-object boundary: these tests exercise the real session's
/// lifecycle, not signature verification or native storage. Those have their
/// own SDK/native journeys. No such receiver is available to the product.
class _Rules implements ChildRuleReceiver {
  final snapshot = ChildRules(cursor: 7, configurations: [
    VerifiedConfiguration.internal('synthetic-not-a-signature', {
      'document': {'name': '合成家庭规则'}
    })
  ]);
  int restores = 0, syncs = 0, closes = 0;
  Completer<ChildRules>? synchronization;
  DeviceTransportFailure? failure;
  Completer<void>? closing;
  bool closeFails = false;
  @override
  Future<ChildRules> restore() async {
    restores++;
    return snapshot;
  }

  @override
  Future<ChildRules> synchronize() async {
    syncs++;
    if (failure != null) throw failure!;
    return synchronization?.future ?? Future.value(snapshot);
  }

  @override
  Future<void> close() async {
    closes++;
    await closing?.future;
    if (closeFails) throw StateError('controlled close failure');
  }
}

Future<void> _idle(ChildSession session) async {
  for (var i = 0; i < 100 && session.busy; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(session.busy, isFalse);
}

void main() {
  testWidgets(
      'actual child rule names hide on background and credential rejection',
      (tester) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = _Rules();
    final session = fixture.session(rules: (_) async => receiver);
    await tester.pumpWidget(ChildApp(session: session, nativeAvailable: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('规则'));
    await tester.pumpAndSettle();
    expect(find.text('合成家庭规则'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('合成家庭规则'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('合成家庭规则'), findsOneWidget);
    expect(receiver.syncs, 0);
    fixture.rejectAuthentication = true;
    await session.checkConnection();
    await tester.pumpAndSettle();
    expect(find.text('合成家庭规则'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
      'recovered identity cannot reopen the SDK database before its old owner closes',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final old = _Rules()..closing = Completer<void>(), next = _Rules();
    var creations = 0;
    final session =
        fixture.session(rules: (_) async => ++creations == 1 ? old : next);
    addTearDown(session.dispose);
    await session.initialize();
    fixture.secrets.failRead = true;
    final failure = session.reloadIdentity();
    while (old.closes == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(creations, 1);
    expect(session.busy, isTrue);
    expect(session.rules.configurations, isEmpty);
    old.closing!.complete();
    expect(await failure, isFalse);
    fixture.secrets.failRead = false;
    expect(await session.reloadIdentity(), isTrue);
    await _idle(session);
    expect(creations, 2);
    expect(session.rules.configurations, hasLength(1));
  });

  test('failed rule close blocks reopening rather than resetting a database',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = _Rules()..closeFails = true;
    var creations = 0;
    final session = fixture.session(rules: (_) async {
      creations++;
      return receiver;
    });
    addTearDown(session.dispose);
    await session.initialize();
    fixture.secrets.failRead = true;
    expect(await session.reloadIdentity(), isFalse);
    fixture.secrets.failRead = false;
    expect(await session.reloadIdentity(), isTrue);
    await _idle(session);
    expect(creations, 1);
    expect(session.rules.configurations, isEmpty);
    expect(session.errorCode, 'STORAGE_FAILURE');
  });

  test(
      'returning foreground before old factory completes installs only the fresh owner',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final old = _Rules(), next = _Rules();
    final entered = Completer<void>(),
        creation = Completer<ChildRuleReceiver>();
    var creations = 0;
    final session = fixture.session(rules: (_) {
      if (++creations == 1) {
        entered.complete();
        return creation.future;
      }
      return Future.value(next);
    });
    addTearDown(session.dispose);
    final initialization = session.initialize();
    await entered.future;
    await session.setForeground(false);
    await session.setForeground(true);
    creation.complete(old);
    await initialization;
    await _idle(session);
    expect(old.closes, 1);
    expect(old.restores, 0);
    expect(next.restores, 1);
    expect(creations, 2);
    expect(session.rules.configurations, hasLength(1));
  });
  for (final status in [401, 403]) {
    test('rule authentication $status cannot restore rejected cached facts',
        () async {
      final fixture = IdentityFixture();
      addTearDown(fixture.close);
      await fixture.activate();
      final receiver = _Rules();
      final session = fixture.session(rules: (_) async => receiver);
      addTearDown(session.dispose);
      await session.initialize();
      receiver.failure =
          DeviceTransportFailure('DEVICE_UNAUTHENTICATED', status: status);
      expect(await session.synchronizeRules(), isFalse);
      expect(session.rules.configurations, isEmpty);
      expect(receiver.closes, 1);
      expect(receiver.restores, 1,
          reason: 'Auth refusal cannot invoke fallback restoration.');
    });
  }
  test('same-registration authentication rejection hides and closes rules',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = _Rules();
    final session = fixture.session(rules: (_) async => receiver);
    addTearDown(session.dispose);
    await session.initialize();
    expect(session.rules.configurations, hasLength(1));
    fixture.rejectAuthentication = true;
    expect(await session.checkConnection(), isFalse);
    expect(session.credentialReady, isFalse);
    expect(session.rules.configurations, isEmpty);
    expect(session.rules.cursor, 0);
    expect(receiver.closes, 1);
  });

  test(
      'failed secure identity read hides cached rules without deleting storage',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = _Rules();
    final session = fixture.session(rules: (_) async => receiver);
    addTearDown(session.dispose);
    await session.initialize();
    final original = fixture.secrets.record;
    fixture.secrets.failRead = true;
    expect(await session.reloadIdentity(), isFalse);
    expect(session.rules.configurations, isEmpty);
    expect(receiver.closes, 1);
    expect(fixture.secrets.record, original);
  });

  test('background hides rules and foreground restores without network replay',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = _Rules();
    var creations = 0;
    final session = fixture.session(rules: (_) async {
      creations++;
      return receiver;
    });
    addTearDown(session.dispose);
    await session.initialize();
    await session.setForeground(false);
    expect(session.rules.configurations, isEmpty);
    expect(session.rules.cursor, 0);
    await session.setForeground(true);
    await _idle(session);
    expect(session.rules.configurations, hasLength(1));
    expect(receiver.restores, 2);
    expect(receiver.syncs, 0);
    expect(creations, 1);
  });

  test('receiver created after background is closed before any restore',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = _Rules();
    final entered = Completer<void>();
    final creation = Completer<ChildRuleReceiver>();
    final session = fixture.session(rules: (_) {
      entered.complete();
      return creation.future;
    });
    addTearDown(session.dispose);
    final initializing = session.initialize();
    await entered.future;
    await session.setForeground(false);
    creation.complete(receiver);
    await initializing;
    expect(receiver.closes, 1);
    expect(receiver.restores, 0);
    expect(session.rules.configurations, isEmpty);
  });

  test('sync completion in background cannot republish private rule names',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = _Rules();
    final session = fixture.session(rules: (_) async => receiver);
    addTearDown(session.dispose);
    await session.initialize();
    receiver.synchronization = Completer<ChildRules>();
    final synchronizing = session.synchronizeRules();
    while (receiver.syncs == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await session.setForeground(false);
    receiver.synchronization!.complete(receiver.snapshot);
    expect(await synchronizing, isFalse);
    expect(session.rules.configurations, isEmpty);
    await session.setForeground(true);
    await _idle(session);
    expect(session.rules.configurations, hasLength(1));
    expect(receiver.syncs, 1);
  });

  test('receiver created after dispose is closed and never restored', () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = _Rules();
    final entered = Completer<void>();
    final creation = Completer<ChildRuleReceiver>();
    final session = fixture.session(rules: (_) {
      entered.complete();
      return creation.future;
    });
    final initializing = session.initialize();
    await entered.future;
    session.dispose();
    creation.complete(receiver);
    await initializing;
    expect(receiver.closes, 1);
    expect(receiver.restores, 0);
    expect(session.rules.configurations, isEmpty);
  });

  test('late sync after dispose neither publishes nor closes an owner twice',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = _Rules();
    final session = fixture.session(rules: (_) async => receiver);
    await session.initialize();
    receiver.synchronization = Completer<ChildRules>();
    final synchronizing = session.synchronizeRules();
    while (receiver.syncs == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    session.dispose();
    receiver.synchronization!.complete(receiver.snapshot);
    expect(await synchronizing, isFalse);
    expect(receiver.closes, 1);
    expect(session.rules.configurations, isEmpty);
  });

  test('same valid identity refresh retains rules and a single receiver',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = _Rules();
    var creations = 0;
    final session = fixture.session(rules: (_) async {
      creations++;
      return receiver;
    });
    addTearDown(session.dispose);
    await session.initialize();
    expect(await session.reloadIdentity(), isTrue);
    expect(session.rules.configurations, hasLength(1));
    expect(receiver.closes, 0);
    expect(creations, 1);
  });
}
