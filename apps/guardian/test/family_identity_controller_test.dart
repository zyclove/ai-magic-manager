import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/family_identity_controller.dart';
import 'package:guardian/core/family_identity_repository.dart';
import 'family_identity_configuration_test.dart';
import 'family_identity_repository_test.dart' show identityReply;
import 'family_identity_release_fixtures.dart' show releaseStatusFixture;

class IdentityTestStorage implements IdentityProviderOperationStorage {
  final values = <String, String>{};
  bool failWrite = false;
  @override
  String? read(String key) => values[key];
  @override
  void write(String key, String value) {
    values[key] = value;
    if (failWrite) throw StateError('private-storage-details');
  }

  @override
  void remove(String key) => values.remove(key);
}

void main() {
  test('MFA rejection locks every write until a successful status refresh',
      () async {
    var rejectReads = false;
    final api = Api(
        () async => MockClient((request) async {
              if (request.method == 'POST') {
                return identityReply({'errorCode': 'REAUTH_REQUIRED'},
                    status: 401);
              }
              if (rejectReads) {
                throw http.ClientException('synthetic unknown status');
              }
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(releaseStatusFixture());
              }
              return identityReply(identityStatusFixture());
            }),
        baseUrl: 'https://fixture.invalid');
    final controller = FamilyIdentityController(
        repository: FamilyIdentityRepository(api: api, current: () => true),
        actor: 'operator',
        current: () => true,
        canManage: () => true,
        canTest: () => true,
        clearSensitiveInput: () {});
    await controller.load();
    expect(controller.canSave, isTrue);
    await controller
        .save(IdentityProviderVersion.parse(identityVersionFixture()).settings);
    expect(controller.needsReauthentication, isTrue);
    expect(controller.canSave, isFalse);
    expect(controller.canValidate, isFalse);
    expect(controller.canPrepare, isFalse);
    rejectReads = true;
    await controller.load();
    expect(controller.canSave, isFalse);
    rejectReads = false;
    await controller.load();
    expect(controller.needsReauthentication, isFalse);
    expect(controller.canSave, isTrue);
    controller.dispose();
  });
  test(
      'recovering an older operation cannot replace the latest displayed configuration',
      () async {
    final storage = IdentityTestStorage();
    final api = Api(
        () async => MockClient((request) async {
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(releaseStatusFixture());
              }
              if (request.url.path.endsWith('/status')) {
                final status = identityStatusFixture();
                status['latestVersion'] = 2;
                status['version'] = identityVersionFixture()
                  ..addAll({
                    'id': identityOperationId,
                    'version': 2,
                    'baseVersion': 1
                  });
                return identityReply(status);
              }
              return identityReply(identityVersionFixture());
            }),
        baseUrl: 'https://fixture.invalid');
    final controller = FamilyIdentityController(
        repository: FamilyIdentityRepository(api: api, current: () => true),
        actor: 'operator',
        current: () => true,
        canManage: () => true,
        canTest: () => true,
        storage: storage,
        clearSensitiveInput: () {});
    storage.values[controller.storageKey] =
        jsonEncode({'id': identityVersionId, 'type': 'VERSION'});
    await controller.load();
    await controller.recover();
    expect(controller.version!.id, identityOperationId);
    expect(controller.version!.version, 2);
    expect(controller.pending, isNull);
    controller.dispose();
  });
  test(
      'unknown save retains only operation identity and recovers by GET without resending secrets',
      () async {
    final storage = IdentityTestStorage(), sent = <http.Request>[];
    String? operation;
    final api = Api(
        () async => MockClient((request) async {
              sent.add(request);
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(releaseStatusFixture());
              }
              if (request.method == 'POST') {
                operation = jsonDecode(request.body)['id'];
                throw http.ClientException('private-secret-or-provider-url');
              }
              if (request.url.path.contains('/versions/')) {
                return identityReply(
                    identityVersionFixture()..['id'] = operation);
              }
              return identityReply(identityStatusFixture());
            }),
        baseUrl: 'https://fixture.invalid');
    var cleared = 0;
    final controller = FamilyIdentityController(
        repository: FamilyIdentityRepository(api: api, current: () => true),
        actor: 'synthetic-operator',
        current: () => true,
        canManage: () => true,
        canTest: () => true,
        storage: storage,
        clearSensitiveInput: () => cleared++);
    await controller.load();
    await controller.save(
        IdentityProviderVersion.parse(identityVersionFixture()).settings,
        replacements: {'wechatAppSecret': 'b' * 32});
    expect(controller.pending, isNotNull);
    final saved = jsonDecode(storage.values.values.single) as Map;
    expect(saved.keys.toSet(), {'id', 'type'});
    expect(jsonEncode(saved), isNot(contains('b' * 32)));
    expect(controller.errorMessage, isNot(contains('private-')));
    await controller.recover();
    expect(controller.pending, isNull);
    expect(storage.values, isEmpty);
    expect(sent.where((request) => request.method == 'POST'), hasLength(1));
    expect(cleared, greaterThanOrEqualTo(1));
    controller.dispose();
  });
  test(
      'same-frame double save dispatches once and storage failure prevents dispatch',
      () async {
    final done = Completer<http.Response>(), storage = IdentityTestStorage();
    var posts = 0;
    String? operation;
    final api = Api(
        () async => MockClient((request) async {
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(releaseStatusFixture());
              }
              if (request.method == 'GET') {
                return identityReply(identityStatusFixture());
              }
              posts++;
              operation = jsonDecode(request.body)['id'];
              return done.future;
            }),
        baseUrl: 'https://fixture.invalid');
    final controller = FamilyIdentityController(
        repository: FamilyIdentityRepository(api: api, current: () => true),
        actor: 'operator',
        current: () => true,
        canManage: () => true,
        canTest: () => true,
        storage: storage,
        clearSensitiveInput: () {});
    await controller.load();
    final first = controller
        .save(IdentityProviderVersion.parse(identityVersionFixture()).settings);
    final second = controller
        .save(IdentityProviderVersion.parse(identityVersionFixture()).settings);
    await Future<void>.delayed(Duration.zero);
    expect(posts, 1);
    done.complete(identityReply(identityVersionFixture()
      ..addAll({'id': operation, 'version': 2, 'baseVersion': 1})));
    await Future.wait([first, second]);
    storage.failWrite = true;
    await controller
        .save(IdentityProviderVersion.parse(identityVersionFixture()).settings);
    expect(posts, 1);
    expect(controller.errorMessage, contains('本次未提交'));
    controller.dispose();
  });
  test('reauthentication clears inputs and never preserves secret payloads',
      () async {
    var cleared = 0;
    final storage = IdentityTestStorage();
    final api = Api(
        () async => MockClient((request) async =>
            identityReply({'errorCode': 'REAUTH_REQUIRED'}, status: 401)),
        baseUrl: 'https://fixture.invalid');
    final controller = FamilyIdentityController(
        repository: FamilyIdentityRepository(api: api, current: () => true),
        actor: 'operator',
        current: () => true,
        canManage: () => true,
        canTest: () => true,
        storage: storage,
        clearSensitiveInput: () => cleared++);
    await controller.load();
    expect(controller.needsReauthentication, isTrue);
    controller.prepareReauthentication();
    expect(cleared, greaterThanOrEqualTo(2));
    expect(storage.values, isEmpty);
    controller.dispose();
  });
  test('scope revocation hides late data and clears all sensitive input',
      () async {
    final done = Completer<http.Response>();
    var active = true, cleared = 0;
    final api = Api(() async => MockClient((_) => done.future),
        baseUrl: 'https://fixture.invalid');
    final controller = FamilyIdentityController(
        repository: FamilyIdentityRepository(api: api, current: () => active),
        actor: 'operator',
        current: () => active,
        canManage: () => true,
        canTest: () => true,
        clearSensitiveInput: () => cleared++);
    final loading = controller.load();
    active = false;
    controller.invalidate();
    done.complete(identityReply(identityStatusFixture()));
    await loading;
    expect(controller.status, isNull);
    expect(controller.version, isNull);
    expect(cleared, greaterThanOrEqualTo(1));
    controller.dispose();
  });
}
