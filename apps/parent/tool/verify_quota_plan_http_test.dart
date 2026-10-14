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

/// Failure injection occurs after real Spring commits; the original body and key are retained.
class _LostReplies extends http.BaseClient {
  final delegate = http.Client();
  bool createLost = false, updateLost = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final result = await delegate.send(request);
    if (result.statusCode < 300 &&
        ((!createLost &&
                request.method == 'POST' &&
                request.url.path.endsWith('/quota-plans')) ||
            (!updateLost &&
                request.method == 'PUT' &&
                request.url.path.contains('/quota-plans/')))) {
      if (request.method == 'POST') {
        createLost = true;
      } else {
        updateLost = true;
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
      'real HTTP plan creation, loss recovery, pause retry, resume and version reads',
      () async {
    final encoded = Platform.environment['PARENT_QUOTA_PLAN_HTTP_FIXTURE'];
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
        body: {'nickname': 'Plan HTTP child', 'ageBand': 'AGE_7_12'}) as Json;
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
    final weekly = {for (final d in quotaWeekDays) d: 1815};
    await first.submit('PLAN_CREATE', {
      'name': 'Weekly HTTP plan',
      'subjectId': child['id'],
      'scope': 'TOTAL',
      'timeZone': calendar['timeZone'],
      'effectiveFrom': calendar['currentDate'],
      'weeklyLimits': weekly,
      'dateOverrides': <String, int>{}
    });
    expect(first.error, isA<ParentApiException>());
    expect(first.committed, isNull);
    first.dispose();
    final recovered = make();
    await recovered.load();
    await recovered.query();
    expect(recovered.error, isNull);
    expect(recovered.latest!['version'], 0);
    final before = recovered.latest!;
    expect(await recovered.acknowledge(), isTrue);
    await recovered.submit(
        'PLAN_UPDATE',
        {
          'name': 'Weekly HTTP plan',
          'state': 'PAUSED',
          'weeklyLimits': weekly,
          'dateOverrides': <String, int>{}
        },
        before: before);
    expect(recovered.error, isA<ParentApiException>());
    recovered.dispose();
    final retry = make();
    await retry.load();
    await retry.retry();
    expect(retry.error, isNull);
    expect(retry.committed!['state'], 'PAUSED');
    expect(retry.latest!['version'], 1);
    await api.send('PUT', '$path/quota-plans/${before['id']}',
        body: {
          'name': 'Weekly HTTP plan',
          'state': 'ACTIVE',
          'weeklyLimits': weekly,
          'dateOverrides': <String, int>{}
        },
        version: 1,
        idempotencyKey: '00000000-0000-4000-8000-000000009998');
    await retry.query();
    expect(retry.committed!['state'], 'PAUSED');
    expect(retry.latest!['state'], 'ACTIVE');
    expect(retry.latest!['version'], 2);
    expect(await retry.acknowledge(), isTrue);
    retry.dispose();
    final revisions = QuotaRevisionController(
        api, '$path/quota-plans/${before['id']}/revisions', () => true);
    await revisions.load();
    expect(revisions.error, isNull);
    expect(revisions.items.map((r) => r['version']), [2, 1, 0]);
    revisions.dispose();
    final pools = await api.page('$path/quota-pools');
    expect(pools.items, hasLength(1));
    expect(readQuota(pools.items.single)['limitSeconds'], 1815);
    expect(transport.createLost && transport.updateLost, isTrue);
  });
}
