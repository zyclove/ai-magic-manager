import 'dart:convert';
import 'dart:io' show pid;
import 'package:child/platform/secret_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Removes only this journey's completed synthetic observation record. Never
/// clear application data, identity credentials, key preferences or other files.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('remove only the verified synthetic observation fixture',
      (tester) async {
    final store = AndroidObservationStore();
    final identity = AndroidIdentityStore();
    final identityBefore = await identity.read();
    final value = await store.read();
    expect(value != null, isTrue);
    final record = jsonDecode(value!) as Map;
    expect(
        record['scope'] ==
            '11111111-1111-1111-1111-111111111111.'
                '22222222-2222-2222-2222-222222222222.'
                '33333333-3333-3333-3333-333333333333',
        isTrue);
    expect(record['pendingInventory'] == null && record['pendingUsage'] == null,
        isTrue);
    expect(record['inventoryCount'] == 1 && record['usageCount'] == 1, isTrue);
    // The production adapter intentionally has no deletion surface; test-only
    // cleanup uses the mature SDK for this exact key, then its read barrier.
    await store.backend.storage.delete(key: 'observation_record');
    expect(await store.read() == null, isTrue);
    expect(await identity.read() == identityBefore, isTrue);
    debugPrint('OBSERVATION_STORAGE_CLEANUP ${jsonEncode({
          'phase': 'cleanup',
          'pid': pid,
          'fixtureRemoved': true,
          'identityPresentBeforeCleanup': identityBefore != null,
          'identityUnchanged': true
        })}');
  });
}
