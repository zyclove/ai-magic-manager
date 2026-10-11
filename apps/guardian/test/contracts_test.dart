import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/contracts.dart';
import 'package:guardian/core/contracts_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const tenant = '11111111-1111-1111-1111-111111111111';
const reviewId = '22222222-2222-2222-2222-222222222222';
const offerId = '33333333-3333-3333-3333-333333333333';

Json review(
        {bool platform = true,
        String state = 'PENDING_REVIEW',
        int version = 1,
        String sourceState = 'ACTIVE'}) =>
    {
      'id': reviewId,
      'tenantId': tenant,
      'offerId': offerId,
      'offerRevision': 3,
      'contractReference': 'CN-2026-01',
      'sourceRevision': 1,
      'state': state,
      'version': version,
      'buyerReference': 'buyer-1',
      'capacityKind': 'BASE',
      'deviceCapacity': 25,
      'features': ['ORG_BULK'],
      'activeFrom': 1791619200000,
      'expiresAt': 1823155200000,
      'sourceState': sourceState,
      'executedAt': 1791619200000,
      'evidenceHash': 'a' * 64,
      'createdAt': 100,
      'updatedAt': 200,
      'entitlementApplied': state == 'APPLIED',
      if (platform) ...{
        'submittedBy': 'contract-author',
        'approvedBy': state == 'PENDING_REVIEW' ? null : 'contract-approver',
        'acceptedBy':
            state == 'APPLIED' && sourceState == 'ACTIVE' ? 'org-owner' : null
      }
    };

Json comparison({int version = 1, bool match = true}) => {
      'reviewId': reviewId,
      'reviewVersion': version,
      'offerId': offerId,
      'contractOfferRevision': 3,
      'currentOfferRevision': match ? 3 : 4,
      'offerState': 'APPROVED',
      'factsMatch': match,
      'issues': match ? <String>[] : ['REVISION_CHANGED'],
      'offer': {
        'sku': 'ORG_STANDARD',
        'platform': 'ANDROID',
        'deviceMode': 'FULLY_MANAGED',
        'billingPeriod': 'YEAR',
        'capacityKind': 'BASE',
        'deviceCapacity': 25,
        'features': ['ORG_BULK'],
        'availableFrom': 100,
        'availableUntil': 500
      }
    };

void main() {
  test(
      'tenant contract projection rejects platform actor data and false claims',
      () {
    expect(ContractReview.parse(review(platform: false), platform: false).id,
        reviewId);
    expect(() => ContractReview.parse(review(), platform: false),
        throwsA(isA<ApiFailure>()));
    expect(
        () => ContractReview.parse(
            {...review(platform: false), 'entitlementApplied': true},
            platform: false),
        throwsA(isA<ApiFailure>()));
    expect(
        () => ContractReviewPage.parse({
              'items': [review(platform: false), review(platform: false)],
              'nextCursor': null
            }, platform: false),
        throwsA(isA<ApiFailure>()));
    expect(contractStateLabel('APPLIED'), '已处理');
    expect(
        () => ContractReview.parse(
            {...review(platform: false), 'evidenceHash': 'bad'},
            platform: false),
        throwsA(isA<ApiFailure>()));
    expect(
        contractReviewLabel(ContractReview.parse(
            review(state: 'APPLIED', sourceState: 'REVOKED'),
            platform: true)),
        '撤销已执行');
  });

  test('platform capabilities and review writes carry version and reason',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response(
            jsonEncode({
              'submissionEnabled': false,
              'revocationSubmissionEnabled': false,
              'region': 'CN',
              'channel': 'CONTRACT',
              'recentAuthenticationRequired': true,
              'independentApprovalRequired': true,
              'customerAcceptanceRequired': true
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response(
          jsonEncode(request.url.path.endsWith('/approve')
              ? review(state: 'AWAITING_CUSTOMER', version: 2)
              : review()),
          request.method == 'POST' ? 201 : 200,
          headers: {'content-type': 'application/json'});
    });
    var active = true;
    final repository = ContractsRepository.platform(
        api: Api(() async => client, baseUrl: 'https://example.test/api/v1'),
        current: () => active);
    expect((await repository.capabilities()).submissionEnabled, isFalse);
    expect(
        ContractCapabilities.parse({
          'submissionEnabled': false,
          'revocationSubmissionEnabled': true,
          'region': 'CN',
          'channel': 'CONTRACT',
          'recentAuthenticationRequired': true,
          'independentApprovalRequired': true,
          'customerAcceptanceRequired': true
        }).canSubmit,
        isTrue);
    final id = repository.newId();
    expect(isContractId(id), isTrue);
    final created = await repository.create(reviewId, 'a.b.c');
    expect(jsonDecode(requests.last.body)['id'], reviewId);
    await repository.approve(created, 'Independently reviewed');
    expect(requests.last.headers['If-Match'], '"1"');
    expect(jsonDecode(requests.last.body)['reason'], 'Independently reviewed');
    active = false;
    await expectLater(repository.list(), throwsA(isA<ApiFailure>()));
  });

  test('institution acceptance remains tenant-bound and hides platform actors',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final result = request.url.path.endsWith('/accept')
          ? review(platform: false, state: 'APPLIED', version: 3)
          : review(platform: false, state: 'AWAITING_CUSTOMER', version: 2);
      return http.Response(jsonEncode(result), 200,
          headers: {'content-type': 'application/json'});
    });
    final repository = ContractsRepository.tenant(
        api: Api(() async => client, baseUrl: 'https://example.test/api/v1'),
        current: () => true,
        tenantId: tenant);
    final pending = await repository.get(reviewId);
    expect(pending.submittedBy, isNull);
    final applied = await repository.accept(pending);
    expect(applied.state, 'APPLIED');
    expect(requests.last.url.path,
        '/api/v1/tenants/$tenant/contracts/$reviewId/accept');
    expect(requests.last.headers['If-Match'], '"2"');
    await expectLater(repository.capabilities(), throwsA(isA<ApiFailure>()));
  });

  test('rejects malformed or cross-tenant read responses', () async {
    Future<void> invalid(http.Response response) async {
      final repository = ContractsRepository.tenant(
          api: Api(() async => MockClient((_) async => response),
              baseUrl: 'https://example.test/api/v1'),
          current: () => true,
          tenantId: tenant);
      await expectLater(
          repository.get(reviewId),
          throwsA(isA<ApiFailure>()
              .having((e) => e.code, 'code', 'INVALID_CONTRACT_RESPONSE')));
    }

    await invalid(http.Response('<html>bad</html>', 200,
        headers: {'content-type': 'text/html'}));
    await invalid(http.Response(
        jsonEncode({
          ...review(platform: false),
          'tenantId': '44444444-4444-4444-4444-444444444444'
        }),
        200,
        headers: {'content-type': 'application/json'}));
  });

  test('current offer comparison is bound to the reviewed contract', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode(comparison()), 200,
          headers: {'content-type': 'application/json'});
    });
    final repository = ContractsRepository.tenant(
        api: Api(() async => client, baseUrl: 'https://example.test/api/v1'),
        current: () => true,
        tenantId: tenant);
    final contract =
        ContractReview.parse(review(platform: false), platform: false);
    final result = await repository.comparison(contract);
    expect(result.factsMatch, isTrue);
    expect(result.offer?.deviceMode, 'FULLY_MANAGED');
    expect(requests.single.url.path,
        '/api/v1/tenants/$tenant/contracts/$reviewId/comparison');
    expect(ContractComparison.parse(comparison(match: false)).issues,
        ['REVISION_CHANGED']);
    expect(
        () => ContractComparison.parse({...comparison(), 'factsMatch': false}),
        throwsA(isA<ApiFailure>()));
    expect(
        () => ContractComparison.parse({...comparison(), 'reviewId': offerId}),
        returnsNormally);
    final bad = ContractsRepository.tenant(
        api: Api(
            () async => MockClient((_) async => http.Response(
                jsonEncode({...comparison(), 'reviewId': offerId}), 200,
                headers: {'content-type': 'application/json'})),
            baseUrl: 'https://example.test/api/v1'),
        current: () => true,
        tenantId: tenant);
    await expectLater(bad.comparison(contract), throwsA(isA<ApiFailure>()));
  });

  test(
      'history pages are ordered and tenant events exclude operator identities',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final second = request.url.queryParameters['beforeVersion'] == '2';
      return http.Response(
          jsonEncode({
            'items': second
                ? [
                    {'version': 1, 'action': 'SUBMITTED', 'occurredAt': 100}
                  ]
                : [
                    {
                      'version': 3,
                      'action': 'CUSTOMER_ACCEPTED',
                      'occurredAt': 300
                    },
                    {'version': 2, 'action': 'APPROVED', 'occurredAt': 200}
                  ],
            'nextBeforeVersion': second ? null : 2
          }),
          200,
          headers: {'content-type': 'application/json'});
    });
    final repository = ContractsRepository.tenant(
        api: Api(() async => client, baseUrl: 'https://example.test/api/v1'),
        current: () => true,
        tenantId: tenant);
    final first = await repository.history(reviewId);
    expect(first.items.first.actorId, isNull);
    expect(first.nextBeforeVersion, 2);
    final second = await repository.history(reviewId, beforeVersion: 2);
    expect(second.items.single.version, 1);
    expect(requests.last.url.queryParameters['beforeVersion'], '2');
    expect(
        () => ContractHistoryPage.parse({
              'items': [
                {
                  'version': 2,
                  'action': 'APPROVED',
                  'reason': 'Internal-only details',
                  'occurredAt': 200,
                }
              ],
              'nextBeforeVersion': null
            }, platform: false),
        throwsA(isA<ApiFailure>()));
  });
}
