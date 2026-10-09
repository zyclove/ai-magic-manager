import 'dart:convert';
import 'package:device_operations/device_operations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'client_test.dart' show scope;
import 'fixtures.dart';

void main() {
  late PreferencesExitJournal journal;
  late SharedPreferencesAsync preferences;
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    preferences = SharedPreferencesAsync();
    journal = PreferencesExitJournal(preferences: preferences);
  });
  PendingExit pending() => PendingExit(
      kind: PendingKind.confirm,
      key: requestKey,
      registrationId: registrationId,
      version: 7,
      createdAt: now,
      previewId: previewId,
      previewHash: previewHash);
  test('persists only scoped recovery metadata and restores exact payload',
      () async {
    await journal.write(scope(), pending());
    final restored = await journal.read(scope());
    expect(restored?.key, requestKey);
    expect(restored?.previewHash, previewHash);
    expect(restored?.version, 7);
    final stored = await preferences.getString(journal.keyFor(scope()));
    expect(stored, isNot(contains('verified-subject')));
    expect(stored, isNot(contains('access_token')));
    await journal.clear(scope());
    expect(await journal.read(scope()), null);
  });
  test('different authenticated actor cannot recover another actor request',
      () async {
    await journal.write(scope(), pending());
    final other = ExitScope(
        actorId: 'another-subject',
        tenantId: tenantId,
        deviceId: deviceId,
        registrationId: registrationId,
        role: 'OWNER');
    expect(await journal.read(other), null);
    expect(journal.keyFor(other), isNot(journal.keyFor(scope())));
  });
  test('corrupt record is not silently discarded or replaced', () async {
    await preferences.setString(journal.keyFor(scope()), '{invalid');
    await expectLater(journal.read(scope()), throwsFormatException);
    await expectLater(journal.write(scope(), pending()), throwsFormatException);
    expect(await preferences.getString(journal.keyFor(scope())), '{invalid');
  });
  test('another request cannot replace a still pending operation', () async {
    await journal.write(scope(), pending());
    final other = PendingExit(
        kind: PendingKind.cancel,
        key: commandId,
        registrationId: registrationId,
        version: 1,
        createdAt: now,
        operationId: operationId);
    await expectLater(journal.write(scope(), other), throwsStateError);
    expect((await journal.read(scope()))?.key, requestKey);
  });
  test('stored schema and registration mismatch fail closed', () async {
    await journal.write(scope(), pending());
    final value =
        jsonDecode((await preferences.getString(journal.keyFor(scope())))!)
            as Map<String, dynamic>;
    value['registrationId'] = tenantId;
    await preferences.setString(journal.keyFor(scope()), jsonEncode(value));
    await expectLater(journal.read(scope()), throwsFormatException);
  });
}
