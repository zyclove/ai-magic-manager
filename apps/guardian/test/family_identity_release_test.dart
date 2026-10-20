import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/family_identity_controller.dart';
import 'package:guardian/core/family_identity_repository.dart';
import 'family_identity_configuration_test.dart';
import 'family_identity_controller_test.dart' show IdentityTestStorage;
import 'family_identity_repository_test.dart' show identityReply;
import 'family_identity_release_fixtures.dart';
export 'family_identity_release_fixtures.dart';

FamilyIdentityController releaseController(
        Future<http.Response> Function(http.Request) handler,
        {bool publish = true,
        bool rollback = true,
        bool manage = true,
        bool prepared = true,
        bool Function()? current,
        IdentityTestStorage? storage}) =>
    FamilyIdentityController(
        repository: FamilyIdentityRepository(
            api: Api(
                () async => MockClient((request) async {
                      if (request.method == 'GET' &&
                          request.url.path.endsWith('/release-preparations')) {
                        return identityReply({
                          'items': prepared
                              ? [
                                  {
                                    'id': preparationId,
                                    'versionId': identityVersionId,
                                    'status': 'PREPARED',
                                    'reasonCode': 'READY',
                                    'runtimeStatus': 'APPLY_REQUIRED',
                                    'salesAllowed': false
                                  }
                                ]
                              : []
                        });
                      }
                      return handler(request);
                    }),
                baseUrl: 'https://fixture.invalid'),
            current: current ?? () => true),
        actor: 'release-operator',
        current: current ?? () => true,
        canManage: () => manage,
        canTest: () => true,
        canPublish: () => publish,
        canRollback: () => rollback,
        clearSensitiveInput: () {},
        storage: storage);

void readyPreparation(FamilyIdentityController controller) {
  controller.preparation = const IdentityProviderReleasePreparation(
      preparationId, identityVersionId, 'PREPARED', 'READY');
}

void main() {
  test(
      'publisher can load a prepared version without configuration editing permission',
      () async {
    final controller = releaseController(
        (request) async => identityReply(
            request.url.path.endsWith('/release-status')
                ? releaseStatusFixture()
                : identityStatusFixture(manage: false)),
        manage: false);
    await controller.load();
    expect(controller.canSave, isFalse);
    expect(controller.canPrepare, isFalse);
    expect(controller.preparation?.id, preparationId);
    expect(controller.canPublishRelease, isTrue);
    controller.dispose();
  });
  test(
      'a missing preparation keeps the publisher waiting for the configuration administrator',
      () async {
    final controller = releaseController(
        (request) async => identityReply(
            request.url.path.endsWith('/release-status')
                ? releaseStatusFixture()
                : identityStatusFixture(manage: false)),
        manage: false,
        prepared: false);
    await controller.load();
    expect(controller.preparation, isNull);
    expect(controller.canPublishRelease, isFalse);
    controller.dispose();
  });
  test('a running original runtime check remains query-only until it finishes',
      () async {
    final storage = IdentityTestStorage();
    var finished = false, posts = 0;
    final controller = releaseController((request) async {
      if (request.method == 'POST') posts++;
      if (request.url.path.contains('/runtime-checks/')) {
        return identityReply(runtimeCheckFixture(
            id: identityOperationId,
            state: finished ? 'MISMATCH' : 'CHECKING'));
      }
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture(
              active: releaseOperationFixture(state: 'EXECUTION_UNKNOWN'))
          : identityStatusFixture());
    }, storage: storage);
    storage.values[controller.storageKey] =
        jsonEncode({'id': identityOperationId, 'type': 'CHECK'});
    await controller.load();
    await controller.recover();
    expect(controller.pending?.id, identityOperationId);
    expect(controller.canCheckRuntime, isFalse);
    finished = true;
    await controller.recover();
    expect(controller.pending, isNull);
    expect(posts, 0);
    controller.dispose();
  });
  test(
      'failed refresh cannot leave previously cached publication authority enabled',
      () async {
    var failRead = false;
    final controller = releaseController((request) async {
      if (failRead) throw http.ClientException('synthetic offline');
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture(rollback: true)
          : identityStatusFixture());
    });
    await controller.load();
    readyPreparation(controller);
    expect(controller.canPublishRelease, isTrue);
    failRead = true;
    await controller.load();
    expect(controller.canPublishRelease, isFalse);
    expect(controller.canRollbackRelease, isFalse);
    controller.dispose();
  });
  test(
      'release status accepts closed loading and rejects secrets or opened sales',
      () {
    expect(
        IdentityProviderReleaseStatus.parse(releaseStatusFixture())
            .confirmedOperation,
        isNull);
    final loaded = releaseOperationFixture(state: 'APPLIED_CLOSED');
    expect(
        IdentityProviderReleaseStatus.parse(
                releaseStatusFixture(confirmed: loaded))
            .runtimeStatus,
        'APPLIED_CLOSED');
    for (final invalid in [
      releaseStatusFixture()..['salesAllowed'] = true,
      releaseStatusFixture()..['wechatAppSecret'] = 'must-not-read-back',
      releaseStatusFixture(active: loaded),
      releaseStatusFixture(confirmed: releaseOperationFixture()),
      releaseStatusFixture()
        ..['rollbackTargets'] = [
          rollbackTargetFixture(),
          rollbackTargetFixture()
        ]
    ]) {
      expect(() => IdentityProviderReleaseStatus.parse(invalid),
          throwsA(isA<ApiFailure>()));
    }
  });
  test(
      'runtime confirmation requires all returned instances and cannot accept fake success',
      () {
    expect(
        IdentityProviderRuntimeCheck.parse(runtimeCheckFixture(
                id: identityOperationId, state: 'CONFIRMED'))
            .state,
        'CONFIRMED');
    for (final invalid in [
      runtimeCheckFixture(id: identityOperationId, state: 'CONFIRMED')
        ..['instances'] = [],
      runtimeCheckFixture(id: identityOperationId, state: 'CONFIRMED')
        ..['instances'] =
            runtimeCheckFixture(id: identityOperationId)['instances'],
      runtimeCheckFixture(id: identityOperationId, state: 'CONFIRMED')
        ..['runtimeStatus'] = 'ACTIVE',
      runtimeCheckFixture(id: identityOperationId)..['providerProof'] = 'hidden'
    ]) {
      expect(() => IdentityProviderRuntimeCheck.parse(invalid),
          throwsA(isA<ApiFailure>()));
    }
  });
  test(
      'publish binds frozen artifacts and runtime revision and rejects substituted response',
      () async {
    final sent = <http.Request>[];
    var substitute = false;
    final repo = FamilyIdentityRepository(
        api: Api(
            () async => MockClient((request) async {
                  sent.add(request);
                  return identityReply(releaseOperationFixture()
                    ..['versionId'] =
                        substitute ? historicalId : identityVersionId);
                }),
            baseUrl: 'https://fixture.invalid/api/v1'),
        current: () => true);
    await repo.requestRelease(releaseId, 'PUBLISH', identityVersionId,
        preparationId, 0, 'a' * 64, 'b' * 64);
    expect(sent.single.url.path,
        '/api/v1/platform/identity-providers/release-operations');
    expect(jsonDecode(sent.single.body), {
      'id': releaseId,
      'kind': 'PUBLISH',
      'versionId': identityVersionId,
      'preparationId': preparationId,
      'expectedRuntimeRevision': 0,
      'providerJarSha256': 'a' * 64,
      'parentApkSha256': 'b' * 64
    });
    expect(sent.single.followRedirects, isFalse);
    substitute = true;
    await expectLater(
        repo.requestRelease(releaseId, 'PUBLISH', identityVersionId,
            preparationId, 0, 'a' * 64, 'b' * 64),
        throwsA(isA<ApiFailure>()));
  });
  test('config editor and tester do not gain publish or rollback authority',
      () async {
    var posts = 0;
    final controller = releaseController((request) async {
      if (request.method == 'POST') posts++;
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture(rollback: true)
          : identityStatusFixture());
    }, publish: false, rollback: false);
    await controller.load();
    readyPreparation(controller);
    expect(controller.canSave, isTrue);
    expect(controller.canPublishRelease, isFalse);
    expect(controller.canRollbackRelease, isFalse);
    await controller.publish('a' * 64, 'b' * 64);
    await controller
        .rollback(IdentityProviderReleaseTarget.parse(rollbackTargetFixture()));
    expect(posts, 0);
    controller.dispose();
  });
  test('unknown publish is query-only and never resends a release', () async {
    final storage = IdentityTestStorage(), sent = <http.Request>[];
    String? id;
    final controller = releaseController((request) async {
      sent.add(request);
      if (request.method == 'POST') {
        id = jsonDecode(request.body)['id'];
        throw http.ClientException('private-executor-details');
      }
      if (request.url.path.contains('/release-operations/')) {
        return identityReply(releaseOperationFixture(id: id!));
      }
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture(
              active: id == null ? null : releaseOperationFixture(id: id!))
          : identityStatusFixture());
    }, storage: storage);
    await controller.load();
    readyPreparation(controller);
    await controller.publish('a' * 64, 'b' * 64);
    expect(controller.pending!.type, 'PUBLISH');
    expect(
        jsonDecode(storage.values.values.single).keys.toSet(), {'id', 'type'});
    expect(controller.canPublishRelease, isFalse);
    await controller.publish('a' * 64, 'b' * 64);
    await controller.recover();
    expect(controller.pending, isNull);
    expect(controller.releaseStatus!.activeOperation!.id, id);
    expect(sent.where((request) => request.method == 'POST'), hasLength(1));
    expect(controller.errorMessage, isNull);
    controller.dispose();
  });
  test(
      'unknown runtime check recovers original observation without a second probe',
      () async {
    final sent = <http.Request>[], storage = IdentityTestStorage();
    String? checkId;
    final controller = releaseController((request) async {
      sent.add(request);
      if (request.method == 'POST') {
        checkId = jsonDecode(request.body)['id'];
        throw http.ClientException('probe unknown');
      }
      if (request.url.path.contains('/runtime-checks/')) {
        return identityReply(runtimeCheckFixture(id: checkId!));
      }
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture(
              active: releaseOperationFixture(state: 'EXECUTION_UNKNOWN'))
          : identityStatusFixture());
    }, storage: storage);
    await controller.load();
    await controller.checkReleaseRuntime();
    expect(controller.pending!.type, 'CHECK');
    await controller.recover();
    expect(controller.runtimeCheck!.state, 'MISMATCH');
    expect(sent.where((request) => request.method == 'POST'), hasLength(1));
    expect(controller.canPublishRelease, isFalse);
    expect(controller.canRollbackRelease, isFalse);
    controller.dispose();
  });
  test('rollback only accepts unmodified server historical candidates',
      () async {
    var posts = 0;
    final controller = releaseController((request) async {
      if (request.method == 'POST') posts++;
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture(rollback: true)
          : identityStatusFixture());
    });
    await controller.load();
    final forged = rollbackTargetFixture()..['parentApkSha256'] = 'c' * 64;
    await controller.rollback(IdentityProviderReleaseTarget.parse(forged));
    expect(posts, 0);
    expect(controller.errorMessage, contains('不在可回退清单'));
    controller.dispose();
  });
  test('late release status after account change cannot populate current state',
      () async {
    final release = Completer<http.Response>();
    var current = true;
    final controller = releaseController(
        (request) async => request.url.path.endsWith('/release-status')
            ? release.future
            : identityReply(identityStatusFixture()),
        current: () => current);
    final loading = controller.load();
    await Future<void>.delayed(Duration.zero);
    current = false;
    controller.invalidate();
    release.complete(identityReply(releaseStatusFixture()));
    await loading;
    expect(controller.releaseStatus, isNull);
    controller.dispose();
  });
  test('claimed and unknown releases cannot be cancelled even with authority',
      () async {
    var state = 'CLAIMED', posts = 0;
    final controller = releaseController((request) async {
      if (request.method == 'POST') posts++;
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture(active: releaseOperationFixture(state: state))
          : identityStatusFixture());
    });
    await controller.load();
    await controller.cancelRelease();
    state = 'EXECUTION_UNKNOWN';
    await controller.load();
    await controller.cancelRelease();
    expect(controller.canCancelRelease, isFalse);
    expect(posts, 0);
    controller.dispose();
  });
  test(
      'unknown cancellation recovers by cancellation UUID without repeating it',
      () async {
    final storage = IdentityTestStorage();
    var cancelled = false, posts = 0;
    String? cancellationId;
    final controller = releaseController((request) async {
      if (request.method == 'POST') {
        posts++;
        cancellationId = jsonDecode(request.body)['id'];
        cancelled = true;
        throw http.ClientException('lost cancellation');
      }
      if (request.url.path.contains('/cancellations/')) {
        expect(request.url.path.endsWith('/$cancellationId'), isTrue);
        return identityReply(releaseOperationFixture(state: 'CANCELLED'));
      }
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture(
              active: cancelled ? null : releaseOperationFixture())
          : identityStatusFixture());
    }, storage: storage);
    await controller.load();
    await controller.cancelRelease();
    expect(controller.pending!.type, 'CANCELLATION');
    await controller.recover();
    expect(controller.pending, isNull);
    expect(controller.releaseStatus!.activeOperation, isNull);
    expect(posts, 1);
    controller.dispose();
  });
}
