import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/commercial_catalog.dart';
import 'package:guardian/core/commercial_catalog_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const offerId = '1f535a7b-691d-49c5-84bf-2d279fbd35bb';
const eventId = '26f1123d-a79b-4d6e-9f64-6c048a05098b';

Map<String, dynamic> draft() => {
      'sku': 'FAMILY_BASIC',
      'skuVersion': 1,
      'region': 'CN',
      'channel': 'CONTRACT',
      'buyerKind': 'FAMILY',
      'platform': 'ANDROID',
      'deviceMode': 'BYOD',
      'billingPeriod': 'YEAR',
      'priceType': 'FIXED',
      'currency': 'CNY',
      'priceMinor': 100,
      'taxBasis': 'INCLUSIVE',
      'capacityKind': 'BASE',
      'deviceCapacity': 3,
      'features': ['ADVANCED_SCHEDULES'],
      'availableFrom': 1800000000000,
      'availableUntil': 1810000000000
    };

Map<String, dynamic> snapshot({String state = 'DRAFT', int revision = 1}) => {
      'id': offerId,
      'revision': revision,
      'state': state,
      'offer': draft(),
      'createdBy': 'operator',
      'lastEditor': 'operator',
      'approvedBy': state == 'APPROVED' ? 'approver' : null,
      'createdAt': 100,
      'updatedAt': 200,
      'purchaseAvailable': false
    };

Map<String, dynamic> history() => {
      'revision': 1,
      'eventId': eventId,
      'action': 'CREATED',
      'actorId': 'operator',
      'reason': null,
      'correlationId': eventId,
      'payloadHash': 'a' * 64,
      'offer': draft(),
      'occurredAt': 100
    };

void main() {
  test('catalog models reject sales claims and invalid version pages', () {
    expect(CatalogOffer.parse(snapshot()).offer['sku'], 'FAMILY_BASIC');
    expect(() => CatalogOffer.parse({...snapshot(), 'purchaseAvailable': true}),
        throwsA(isA<ApiFailure>()));
    expect(
        () => CatalogOfferPage.parse({
              'items': [snapshot(), snapshot()],
              'nextCursor': null
            }),
        throwsA(isA<ApiFailure>()));
    expect(
        () => CatalogHistoryPage.parse({
              'items': [history(), history()],
              'nextBeforeRevision': null
            }),
        throwsA(isA<ApiFailure>()));
  });

  test('operator repository sends UUID replay body, version and reason',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST' && request.url.path.endsWith('/approve')) {
        return http.Response(
            jsonEncode(snapshot(state: 'APPROVED', revision: 2)), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response(
          jsonEncode(snapshot()), request.method == 'POST' ? 201 : 200,
          headers: {'content-type': 'application/json'});
    });
    var active = true;
    final repository = CommercialCatalogRepository(
        api: Api(() async => client, baseUrl: 'https://example.test/api/v1'),
        current: () => active);
    final id = repository.newId();
    expect(isCatalogId(id), isTrue);
    // The fixture uses a fixed ID to verify the request and response are bound.
    final created = await repository.create(offerId, CatalogDraft(draft()));
    expect(created.state, 'DRAFT');
    expect(jsonDecode(requests.first.body)['id'], offerId);
    await repository.approve(created, 'Reviewed by finance');
    expect(requests.last.headers['If-Match'], '"1"');
    expect(jsonDecode(requests.last.body)['reason'], 'Reviewed by finance');
    active = false;
    await expectLater(repository.list(), throwsA(isA<ApiFailure>()));
  });

  test('bounded list and history validate cursor and event payload', () async {
    final client = MockClient((request) async {
      final body = request.url.path.endsWith('/history')
          ? {
              'items': [history()],
              'nextBeforeRevision': null
            }
          : {
              'items': [snapshot()],
              'nextCursor': null
            };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    });
    final repository = CommercialCatalogRepository(
        api: Api(() async => client, baseUrl: 'https://example.test/api/v1'),
        current: () => true);
    expect((await repository.list()).items.single.id, offerId);
    expect((await repository.history(offerId)).items.single.action, 'CREATED');
    await expectLater(
        repository.list(cursor: 'bad'), throwsA(isA<ApiFailure>()));
  });
}
