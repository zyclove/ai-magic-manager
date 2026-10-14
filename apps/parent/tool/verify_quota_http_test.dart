import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/quotas.dart';

class _Storage extends ParentDurableStorage {
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

/// Drop a reply only after the real Spring service has returned a successful commit.
class _LostReplies extends http.BaseClient {
  final delegate = http.Client();
  bool createLost = false, adjustmentLost = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final result = await delegate.send(request);
    if (request.method == 'POST' &&
        result.statusCode < 300 &&
        ((!createLost && request.url.path.endsWith('/quota-pools')) ||
            (!adjustmentLost && request.url.path.endsWith('/adjustments')))) {
      if (request.url.path.endsWith('/quota-pools')) {
        createLost = true;
      } else {
        adjustmentLost = true;
      }
      await result.stream.drain<void>();
      throw http.ClientException('Synthetic lost acknowledgement');
    }
    return result;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test(
      'real HTTP creates recovers adjusts retries and reads ledger without double granting',
      () async {
    final encoded = Platform.environment['PARENT_QUOTA_HTTP_FIXTURE'];
    if (encoded == null || encoded.length > 16000) {
      throw StateError('Explicit fixture required');
    }
    final fixture = jsonDecode(encoded) as Json,
        root = Uri.parse(jsonDecode(encoded)['apiRoot']);
    if (fixture['testOnly'] != true ||
        root.scheme != 'http' ||
        root.host != '127.0.0.1' ||
        !root.hasPort ||
        root.path != '/api/v1' ||
        root.hasQuery ||
        root.hasFragment ||
        root.userInfo.isNotEmpty) {
      throw StateError('Only loopback fixtures are permitted');
    }
    final transport = _LostReplies();
    addTearDown(transport.close);
    final api = ParentApi(() async => fixture['token'],
        baseUrl: root.toString(), client: transport);
    final tenant = fixture['tenantId'] as String,
        actor = fixture['actorId'] as String;
    final path = '/tenants/$tenant';
    final child = await api.send('POST', '$path/subjects',
        body: {'nickname': 'HTTP quota child', 'ageBand': 'AGE_7_12'}) as Json;
    final calendar = await api.object(
        '$path/quota-plans/calendar?subjectId=${child['id']}&defaultTimeZone=UTC');
    final store = QuotaOperationStore(storage: _Storage());
    QuotaOperationController make() => QuotaOperationController(
        api: api,
        store: store,
        tenant: tenant,
        actor: actor,
        isCurrent: () => true);
    final first = make();
    await first.load();
    await first.submit('CREATE', {
      'name': 'HTTP daily quota',
      'subjectId': child['id'],
      'scope': 'TOTAL',
      'periodId': calendar['currentDate'],
      'timeZone': calendar['timeZone'],
      'limitSeconds': 3600
    });
    expect(first.error, isA<ParentApiException>());
    expect(first.committed, isNull);
    first.dispose();
    final recovered = make();
    await recovered.load();
    await recovered.query();
    expect(recovered.error, isNull);
    expect(recovered.latest!['limitSeconds'], 3600);
    final before = recovered.latest!;
    expect(await recovered.acknowledge(), isTrue);
    await recovered.submit(
        'ADJUST', {'deltaSeconds': 900, 'reason': 'EXTRA_TIME'},
        before: before);
    expect(recovered.error, isA<ParentApiException>());
    recovered.dispose();
    final retry = make();
    await retry.load();
    await retry.retry();
    expect(retry.error, isNull);
    expect(retry.committed!['limitSeconds'], 4500);
    expect(retry.latest!['version'], 1);
    await api.send('POST', '$path/quota-pools/${before['id']}/adjustments',
        body: {'deltaSeconds': 300, 'reason': 'EXTRA_TIME'},
        version: 1,
        idempotencyKey: '00000000-0000-4000-8000-000000009999');
    await retry.query();
    expect(retry.committed!['limitSeconds'], 4500);
    expect(retry.latest!['limitSeconds'], 4800);
    expect(await retry.acknowledge(), isTrue);
    retry.dispose();
    var ledger =
        await api.page('$path/quota-pools/${before['id']}/ledger', limit: 1);
    final records = [...ledger.items];
    while (ledger.nextCursor != null) {
      ledger = await api.page('$path/quota-pools/${before['id']}/ledger',
          limit: 1, cursor: ledger.nextCursor);
      records.addAll(ledger.items);
    }
    for (final row in records) {
      validateQuotaLedger(row);
    }
    expect(records, hasLength(3));
    expect(records.where((r) => r['kind'] == 'ADJUSTED'), hasLength(2));
    expect(transport.createLost && transport.adjustmentLost, isTrue);
  });
}
