import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/family_identity_controller.dart';
import 'package:guardian/core/family_identity_repository.dart';
import 'family_identity_configuration_test.dart';
import 'family_identity_repository_test.dart' show identityReply;
import 'family_identity_release_fixtures.dart';

void main() {
  test(
      'refresh reads current real acceptance instead of displaying a fixed checklist',
      () async {
    final requests = <http.Request>[];
    final api = Api(
        () async => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/release-status')) {
                return identityReply(releaseStatusFixture());
              }
              if (request.url.path.endsWith('/acceptance-status')) {
                return identityReply(
                    {'errorCode': 'IDENTITY_PROVIDER_NOT_FOUND'},
                    status: 404);
              }
              return identityReply(identityStatusFixture());
            }),
        baseUrl: 'https://fixture.invalid');
    final controller = FamilyIdentityController(
        repository: FamilyIdentityRepository(api: api, current: () => true),
        actor: 'synthetic-refresh-operator',
        current: () => true,
        canManage: () => false,
        canTest: () => false,
        clearSensitiveInput: () {});
    await controller.load();
    expect(
        requests.where(
            (request) => request.url.path.endsWith('/acceptance-status')),
        hasLength(1));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    controller.dispose();
  });
}
