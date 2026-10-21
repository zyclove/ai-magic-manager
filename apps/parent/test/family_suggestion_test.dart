import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family.dart';
import 'package:parent/core/family_suggestion.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';

class _Store extends ParentDurableStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'unknown AI result restores exact original prompt and rejects grafting new text',
      () async {
    final store = _Store(), sent = <http.Request>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      sent.add(r);
      expect(store.values, isNotEmpty);
      if (sent.length == 1) {
        return http.Response('{"errorCode":"UNAVAILABLE"}', 503);
      }
      return http.Response(
          jsonEncode({
            'id': 'suggestion',
            'task': 'RULE_DRAFT',
            'status': 'FALLBACK',
            'summary': 'manual',
            'evidence': [],
            'limitations': [],
            'ruleDraft': null
          }),
          200);
    }));
    addTearDown(api.close);
    final service =
        FamilyService(api: api, tenantId: 'family', available: () => true);
    final first = FamilySuggestionCoordinator(
        service: service,
        actor: 'adult',
        subjectId: 'child',
        task: 'RULE_DRAFT',
        storage: store);
    await first.restore();
    await expectLater(
        first.submit(prompt: 'original prompt', cloudConsent: true),
        throwsA(isA<ParentApiException>()));
    final second = FamilySuggestionCoordinator(
        service: service,
        actor: 'adult',
        subjectId: 'child',
        task: 'RULE_DRAFT',
        storage: store);
    await second.restore();
    await expectLater(
        second.submit(prompt: 'different prompt', cloudConsent: true),
        throwsStateError);
    expect(sent.length, 1);
    final result =
        await second.submit(prompt: 'original prompt', cloudConsent: true);
    expect(result['id'], 'suggestion');
    expect(sent[1].body, sent[0].body);
    expect(
        sent[1].headers['Idempotency-Key'], sent[0].headers['Idempotency-Key']);
    expect(store.values, isEmpty);
  });
}
