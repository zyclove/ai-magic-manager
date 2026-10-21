import 'dart:async';
import 'package:child/core/assisted_runtime.dart';
import 'package:device_policy/device_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../packages/device_policy/test/fixtures.dart' as signed;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/family_assistance');
  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'health': 'ACTIVE',
        'limitStatus': 'ALLOW',
        'observedAt': signed.now,
        'remainingSeconds': 42,
        'optedIn': true,
        'usageGranted': true,
        'accessibilityConnected': true,
        'systemEnforced': false,
      };
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('a forged typed configuration never reaches native acceptance',
      () async {
    final key = signed.newKey();
    final runtime =
        AndroidAssistedRuntime(channel: channel, nowMillis: () => signed.now);
    final verifier = ConfigurationVerifier(
        scope: signed.scope,
        trustedKeys: signed.publicRing(key),
        nowMillis: () => signed.now);
    final forged = VerifiedConfiguration.internal(
        signed.sign(signed.newKey('attacker'), signed.envelope()),
        signed.envelope());
    await expectLater(runtime.acceptVerified([forged], verifier),
        throwsA(isA<ConfigurationFailure>()));
    expect(calls, isEmpty);
    expect(runtime.snapshot.health, 'UNAVAILABLE');
  });

  test('only compact JWS reverified for enrolled scope crosses the bridge',
      () async {
    final key = signed.newKey();
    final runtime =
        AndroidAssistedRuntime(channel: channel, nowMillis: () => signed.now);
    final verifier = ConfigurationVerifier(
        scope: signed.scope,
        trustedKeys: signed.publicRing(key),
        nowMillis: () => signed.now);
    final compact = signed.sign(key, signed.envelope());
    final value = await verifier.verify(compact);
    await runtime.acceptVerified([value], verifier);
    expect(calls.single.method, 'acceptSignedConfigurations');
    expect(calls.single.arguments, {
      'tenantId': signed.tenant,
      'deviceId': signed.device,
      'registrationId': signed.registration,
      'configurations': [compact],
    });
    expect(runtime.snapshot.remainingSeconds, 42);
    expect(runtime.snapshot.systemEnforced, isFalse);
  });

  test('a missing native observation cannot manufacture active state',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (_) async => {
                  'health': 'ACTIVE',
                  'limitStatus': 'RESTRICT',
                  'systemEnforced': false,
                });
    final runtime =
        AndroidAssistedRuntime(channel: channel, nowMillis: () => signed.now);
    await runtime.refresh();
    expect(runtime.snapshot.health, 'UNAVAILABLE');
    expect(runtime.snapshot.remainingSeconds, isNull);
  });

  test('revoking local consent disables assistance without accepting rules',
      () async {
    final runtime =
        AndroidAssistedRuntime(channel: channel, nowMillis: () => signed.now);
    await runtime.setConsent(false);
    expect(calls.single.method, 'setConsent');
    expect(calls.single.arguments, {'enabled': false});
  });

  test('stale active snapshot cannot keep displaying an old allowance',
      () async {
    final runtime = AndroidAssistedRuntime(
        channel: channel, nowMillis: () => signed.now + 15001);
    await runtime.refresh();
    expect(runtime.snapshot.health, 'UNAVAILABLE');
    expect(runtime.snapshot.remainingSeconds, isNull);
  });

  test('active snapshot requires actual consent and both native permissions',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (_) async => {
                  'health': 'ACTIVE',
                  'limitStatus': 'ALLOW',
                  'observedAt': signed.now,
                  'remainingSeconds': 42,
                  'optedIn': false,
                  'usageGranted': true,
                  'accessibilityConnected': true,
                  'systemEnforced': false,
                });
    final runtime =
        AndroidAssistedRuntime(channel: channel, nowMillis: () => signed.now);
    await runtime.refresh();
    expect(runtime.snapshot.health, 'UNAVAILABLE');
  });

  test('an older native failure cannot overwrite a newer permission result',
      () async {
    final entered = Completer<void>();
    final pending = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
      if (call.method == 'inspect') {
        entered.complete();
        return pending.future;
      }
      return Future.value({
        'health': 'PERMISSION_MISSING',
        'limitStatus': 'UNKNOWN',
        'observedAt': signed.now,
        'optedIn': true,
        'usageGranted': false,
        'accessibilityConnected': false,
        'systemEnforced': false,
      });
    });
    final runtime =
        AndroidAssistedRuntime(channel: channel, nowMillis: () => signed.now);
    var changes = 0;
    runtime.addListener(() => changes++);
    final original = runtime.refresh();
    await entered.future;
    await runtime.setConsent(true);
    pending.completeError(PlatformException(code: 'NATIVE_UNAVAILABLE'));
    await original;
    expect(runtime.snapshot.health, 'PERMISSION_MISSING');
    expect(runtime.snapshot.usageGranted, isFalse);
    expect(changes, 1);
    runtime.dispose();
  });

  testWidgets('a stalled native check cannot retain an old active allowance',
      (tester) async {
    final runtime =
        AndroidAssistedRuntime(channel: channel, nowMillis: () => signed.now);
    await runtime.refresh();
    expect(runtime.snapshot.health, 'ACTIVE');
    final entered = Completer<void>();
    final pending = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) {
      entered.complete();
      return pending.future;
    });
    final operation = runtime.refresh();
    await tester.pump();
    expect(entered.isCompleted, isTrue);
    try {
      await tester.pump(const Duration(seconds: 6));
      expect(runtime.snapshot.health, 'UNAVAILABLE');
      expect(runtime.snapshot.remainingSeconds, isNull);
    } finally {
      pending.complete({
        'health': 'ACTIVE',
        'limitStatus': 'ALLOW',
        'observedAt': signed.now,
        'remainingSeconds': 42,
        'optedIn': true,
        'usageGranted': true,
        'accessibilityConnected': true,
        'systemEnforced': false,
      });
      await tester.pump();
      await operation;
      runtime.dispose();
    }
  });

  test('a native response after disposal is discarded without reporting',
      () async {
    final entered = Completer<void>();
    final pending = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) {
      entered.complete();
      return pending.future;
    });
    var reports = 0;
    final runtime = AndroidAssistedRuntime(
        channel: channel,
        nowMillis: () => signed.now,
        report: (_) async {
          reports++;
        });
    final operation = runtime.refresh();
    await entered.future;
    runtime.dispose();
    pending.complete({
      'health': 'ACTIVE',
      'limitStatus': 'ALLOW',
      'observedAt': signed.now,
      'remainingSeconds': 42,
      'optedIn': true,
      'usageGranted': true,
      'accessibilityConnected': true,
      'systemEnforced': false,
    });
    await expectLater(operation, completes);
    expect(runtime.snapshot.health, 'UNAVAILABLE');
    expect(reports, 0);
  });
}
