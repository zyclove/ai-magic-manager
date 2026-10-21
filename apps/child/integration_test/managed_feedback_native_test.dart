import 'dart:convert';
import 'dart:math';
import 'package:child/platform/device_keys.dart';
import 'package:child/platform/managed_feedback.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';

/// Dedicated unmanaged emulator only. Uses fresh test aliases and synthetic challenges;
/// never reads the installation's identity store or contacts a backend/EMM.
/// AndroidX success on this fixture means local completion, not identity verification.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final completed = <String>[];
  binding.reportData = {
    'schemaVersion': 1,
    'scope': 'LOCAL_NATIVE_ONLY',
    'checks': completed,
  };
  const enabled = bool.fromEnvironment('MANAGED_FEEDBACK_NATIVE_CHECK');
  const channel = MethodChannel('com.aimanager.child/managed_feedback');
  final keys = AndroidDeviceKeys();
  String? ownedHandle;

  Future<ManagedAgentBindingProof> freshProof() async {
    final handle = ownedHandle ??= await keys.generateHandle();
    final random = Random.secure();
    final now = DateTime.now().millisecondsSinceEpoch;
    final challenge = ManagedAgentChallenge.fromJson({
      'challengeId': const Uuid().v4(),
      'nonce': base64Url
          .encode(List<int>.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', ''),
      'audience': managedAgentAudience,
      'createdAt': now,
      'expiresAt': now + 120000,
    });
    return keys.managedBindingProof(handle, challenge, now);
  }

  setUp(() {
    expect(enabled, isTrue,
        reason: 'Use an explicitly reserved unmanaged emulator installation.');
  });
  tearDown(() async {
    if (!enabled) return;
    try {
      await channel.invokeMethod<void>('pause');
    } finally {
      final handle = ownedHandle;
      ownedHandle = null;
      if (handle != null) await keys.deleteOriginalHandle(handle);
    }
  });

  testWidgets(
      'original Android key signs binding proofs and is explicitly deleted',
      (tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('受管反馈 · 本地原生验收'))));
    final first = await freshProof();
    final alias = ownedHandle!;
    final second = await freshProof();
    // Compare booleans so a failing assertion cannot print handles or compact proofs.
    expect(alias.startsWith('aimanager.device.'), isTrue);
    expect(ownedHandle == alias, isTrue);
    expect(first.compact.isNotEmpty && second.compact.isNotEmpty, isTrue);
    expect(first.compact != second.compact, isTrue);
    expect(first.challengeId != second.challengeId, isTrue);
    await keys.deleteOriginalHandle(alias);
    await expectLater(
        freshProof(),
        throwsA(isA<DeviceIdentityFailure>()
            .having((error) => error.code, 'code', 'DEVICE_KEY_UNAVAILABLE')));
    // Deletion was confirmed above; do not leave an owned alias for another test.
    ownedHandle = null;
    completed.add('KEYSTORE_PROOF_AND_DELETE');
  });

  testWidgets('real AndroidX submission returns only local completion',
      (tester) async {
    final proof = await freshProof();
    final port = AndroidManagedFeedback();
    try {
      await port.submit(proof);
      // No provider/device state is inferred from the void local acknowledgement.
      debugPrint('MANAGED_FEEDBACK_NATIVE_LOCAL_SUBMISSION_COMPLETED');
      completed.add('LOCAL_SDK_COMPLETION');
    } finally {
      port.close();
    }
  });

  testWidgets(
      'pause invalidates the pending Dart result and allows later submission',
      (tester) async {
    final proof = await freshProof();
    final port = AndroidManagedFeedback();
    try {
      final pending = port.submit(proof);
      final rejected = expectLater(
          pending,
          throwsA(isA<DeviceIdentityFailure>().having(
              (error) => error.code, 'code', 'MANAGED_FEEDBACK_UNAVAILABLE')));
      port.pause();
      await rejected;
      // The native pause is asynchronous. Drain this FIFO channel before resubmitting.
      await channel.invokeMethod<void>('pause');
      await port.submit(await freshProof());
      completed.add('PAUSE_AND_RESUBMIT');
    } finally {
      port.close();
    }
  });

  testWidgets('closed adapter rejects further submissions', (tester) async {
    final proof = await freshProof();
    final port = AndroidManagedFeedback();
    port.close();
    port.close();
    await expectLater(
        port.submit(proof),
        throwsA(isA<DeviceIdentityFailure>().having(
            (error) => error.code, 'code', 'MANAGED_FEEDBACK_UNAVAILABLE')));
    completed.add('CLOSED_ADAPTER_REJECTS');
  });

  testWidgets('native host rejects malformed and caller-extended envelopes',
      (tester) async {
    final proof = await freshProof();
    for (final input in <Object?>[
      null,
      {'proof': 'not-a-proof'},
      {'proof': proof.compact, 'key': 'caller-selected'},
      {'proof': proof.compact, 'severity': 'ERROR'},
    ]) {
      await expectLater(
          channel.invokeMethod<Object?>('submit', input),
          throwsA(isA<PlatformException>()
              .having(
                  (error) => error.code, 'code', 'MANAGED_FEEDBACK_UNAVAILABLE')
              .having(
                  (error) => error.message, 'message', 'Feedback unavailable')
              .having((error) => error.details == null, 'no details', isTrue)));
    }
    completed.add('INVALID_ENVELOPES_REJECTED');
  });
}
