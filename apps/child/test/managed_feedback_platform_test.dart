import 'dart:async';
import 'package:child/platform/managed_feedback.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aimanager.child/managed_feedback');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ManagedAgentBindingProof proof;
  setUp(() async {
    const keys = JoseDeviceEnrollmentKeys();
    final handle = await keys.generateHandle();
    final now = DateTime.now().millisecondsSinceEpoch;
    proof = await keys.managedBindingProof(
        handle,
        ManagedAgentChallenge.fromJson({
          'challengeId': '77777777-7777-4777-8777-777777777777',
          'nonce': 'A' * 43,
          'audience': managedAgentAudience,
          'createdAt': now,
          'expiresAt': now + 600000,
        }),
        now);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  Matcher unavailable() => isA<DeviceIdentityFailure>()
      .having((e) => e.code, 'code', 'MANAGED_FEEDBACK_UNAVAILABLE');
  test('channel accepts only a minimal SUBMITTED acknowledgement', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'submit');
      expect(call.arguments, {'proof': proof.compact});
      return {'status': 'SUBMITTED'};
    });
    await AndroidManagedFeedback().submit(proof);
  });
  for (final invalid in [
    null,
    {'status': 'VERIFIED'},
    {'status': 'SUBMITTED', 'systemEnforced': true}
  ]) {
    test('rejects unexpected native acknowledgement $invalid', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => invalid);
      await expectLater(
          AndroidManagedFeedback().submit(proof), throwsA(unavailable()));
    });
  }
  test('native errors never expose raw exception details', () async {
    messenger.setMockMethodCallHandler(
        channel,
        (_) async =>
            throw PlatformException(code: 'PRIVATE', message: proof.compact));
    await expectLater(
        AndroidManagedFeedback().submit(proof), throwsA(unavailable()));
  });
  test('close invalidates a late acknowledgement and refuses another send',
      () async {
    final started = Completer<void>(), result = Completer<Object?>();
    var pauses = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'pause') {
        pauses++;
        return null;
      }
      started.complete();
      return result.future;
    });
    final port = AndroidManagedFeedback();
    final sent = port.submit(proof);
    final expected = expectLater(sent, throwsA(unavailable()));
    await started.future;
    port.close();
    port.close();
    result.complete({'status': 'SUBMITTED'});
    await expected;
    await expectLater(port.submit(proof), throwsA(unavailable()));
    expect(pauses, 1);
  });
}
