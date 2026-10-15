import 'dart:async';
import 'dart:convert';
import 'package:child/core/session.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/identity_fixture.dart';

class _Feedback implements ManagedAgentFeedbackPort {
  int calls = 0, pauses = 0, closes = 0;
  @override
  Future<void> submit(ManagedAgentBindingProof proof) async {
    calls++;
  }

  @override
  void pause() {
    pauses++;
  }

  @override
  void close() {
    closes++;
  }
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

void main() {
  test(
      'unconfirmed identity never polls managed feedback and disposal closes port',
      () async {
    final fixture = IdentityFixture();
    await fixture.pair();
    final feedback = _Feedback();
    final session = ChildSession(
        identity: fixture.identity,
        nowMillis: () => fixture.clock,
        managedFeedback: feedback);
    final calls = fixture.calls;
    await session.initialize();
    expect(feedback.calls, 0);
    expect(fixture.calls, calls);
    session.dispose();
    fixture.close();
    expect(feedback.closes, 1);
  });
  test('background transition drops a challenge received after suspension',
      () async {
    final fixture = IdentityFixture();
    await fixture.activate();
    final feedback = _Feedback();
    final started = Completer<void>(), response = Completer<http.Response>();
    final client = MockClient((request) async {
      started.complete();
      return response.future;
    });
    final identity = DeviceIdentityManager(
        api: DeviceIdentityApi(
            apiRoot: Uri.parse('https://service.example/api/v1'),
            client: client),
        secrets: fixture.secrets,
        nowMillis: () => fixture.clock);
    final session = ChildSession(
        identity: identity,
        nowMillis: () => fixture.clock,
        managedFeedback: feedback);
    addTearDown(() {
      session.dispose();
      client.close();
      fixture.close();
    });
    await session.initialize();
    await started.future;
    await session.setForeground(false);
    response.complete(http.Response(
        jsonEncode({
          'challengeId': '77777777-7777-4777-8777-777777777777',
          'nonce': 'A' * 43,
          'audience': managedAgentAudience,
          'createdAt': fixture.clock,
          'expiresAt': fixture.clock + 600000,
        }),
        200,
        headers: {'content-type': 'application/json'}));
    await _until(() => !session.busy);
    expect(feedback.calls, 0);
    expect(session.managedFeedbackStage, ManagedFeedbackStage.paused);
  });
  test(
      'production session automatically submits only after active initialization',
      () async {
    final fixture = IdentityFixture();
    await fixture.activate();
    final feedback = _Feedback();
    var challenges = 0;
    final client = MockClient((request) async {
      if (!request.url.path.endsWith('managed-agent-challenge')) {
        return fixture.client.send(request).then(http.Response.fromStream);
      }
      challenges++;
      return http.Response(
          jsonEncode({
            'challengeId': '77777777-7777-4777-8777-777777777777',
            'nonce': 'A' * 43,
            'audience': managedAgentAudience,
            'createdAt': fixture.clock,
            'expiresAt': fixture.clock + 600000,
          }),
          200,
          headers: {'content-type': 'application/json'});
    });
    final identity = DeviceIdentityManager(
        api: DeviceIdentityApi(
            apiRoot: Uri.parse('https://service.example/api/v1'),
            client: client),
        secrets: fixture.secrets,
        nowMillis: () => fixture.clock);
    final session = ChildSession(
        identity: identity,
        nowMillis: () => fixture.clock,
        managedFeedback: feedback);
    addTearDown(() {
      session.dispose();
      client.close();
      fixture.close();
    });
    expect(challenges, 0);
    await session.initialize();
    await _until(() => feedback.calls == 1 && !session.busy);
    expect(session.managedFeedbackStage, ManagedFeedbackStage.submitted);
    expect(session.systemEnforced, isFalse);
    await session.setForeground(false);
    expect(session.managedFeedbackStage, ManagedFeedbackStage.paused);
    expect(feedback.pauses, greaterThan(0));
    await session.setForeground(true);
    await _until(() => challenges == 2 && !session.busy);
    expect(feedback.calls, 1);
    expect(session.managedFeedbackStage,
        ManagedFeedbackStage.awaitingVerification);
  });
}
