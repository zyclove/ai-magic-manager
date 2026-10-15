import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/contracts.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/commercial_entitlements.dart';
import 'package:parent/core/parent_durable_storage.dart';

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

class _LostReply extends http.BaseClient {
  final delegate = http.Client();
  bool lost = false;
  int writes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'POST') writes++;
    final response = await delegate.send(request);
    if (!lost &&
        request.method == 'POST' &&
        request.url.path.endsWith('/accept') &&
        response.statusCode == 200) {
      lost = true;
      await response.stream.drain<void>();
      throw http.ClientException('Synthetic acknowledgement loss');
    }
    return response;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test(
      'production contract controller recovers current state without another acceptance',
      () async {
    final encoded = Platform.environment['PARENT_CONTRACT_HTTP_FIXTURE'];
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
      throw StateError('Only loopback fixture permitted');
    }
    final client = _LostReply();
    addTearDown(client.close);
    final api = ParentApi(() => Future.value(fixture['token']),
        baseUrl: root.toString(), client: client);
    final tenant = fixture['tenantId'] as String,
        reviewId = fixture['reviewId'] as String;
    final repository = ParentContractsRepository(
        api: api, tenant: tenant, current: () => true);
    final list = await api.page(repository.path);
    expect(list.items.single['id'], reviewId);
    final review = await repository.get(reviewId),
        comparison =
            await repository.comparison(await repository.get(reviewId));
    expect(review.state, 'AWAITING_CUSTOMER');
    expect(comparison.factsMatch, true);
    final before = await repository.history(reviewId);
    expect(before.items.first.action, 'APPROVED');
    expect(before.items.every((e) => e.actorId == null), true);
    final storage = _Storage(),
        durable = ContractAcceptanceStore(storage: storage);
    ContractAcceptance make() => ContractAcceptance(
        repository: repository,
        store: durable,
        actor: fixture['actorId'],
        isCurrent: () => true);
    var operation = make();
    await operation.load();
    await operation.submit(review, comparison);
    expect(operation.error, isA<ParentApiException>());
    expect(operation.queried, false);
    expect(client.lost, true);
    expect(storage.values.values.single,
        isNot(contains(review.contractReference)));
    operation.dispose();
    operation = make();
    await operation.load();
    expect(client.writes, 1);
    await operation.recover();
    expect(operation.error, isNull);
    expect(operation.latest!.state, 'APPLIED');
    expect(client.writes, 1);
    final rights = ParentCommercialEntitlements.parse(
        await api.object('/tenants/$tenant/commercial-entitlements'), tenant);
    expect(rights.paidDeviceCapacity, 25);
    expect(rights.features, contains('ORG_BULK'));
    final history = await repository.history(reviewId);
    expect(history.items.where((e) => e.action == 'CUSTOMER_ACCEPTED'),
        hasLength(1));
    expect(await operation.clear(), true);
    expect(storage.values, isEmpty);
    // APPLIED is not eligible for a new confirmation, even if a caller still has an old comparison.
    await operation.submit(await repository.get(reviewId), comparison);
    expect(client.writes, 1);
    expect(operation.pending, isNull);
    operation.dispose();
  });
}
