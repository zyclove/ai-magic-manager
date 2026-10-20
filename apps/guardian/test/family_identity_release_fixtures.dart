import 'package:guardian/core/api.dart';
import 'family_identity_configuration_test.dart' show identityVersionId;

const releaseId = '33333333-3333-4333-8333-333333333333';
const preparationId = '44444444-4444-4444-8444-444444444444';
const historicalId = '55555555-5555-4555-8555-555555555555';
Json releaseOperationFixture(
        {String id = releaseId,
        String state = 'WAITING_EXECUTOR',
        String kind = 'PUBLISH',
        String versionId = identityVersionId}) =>
    {
      'id': id,
      'kind': kind,
      'versionId': versionId,
      'preparationId': preparationId,
      'providerJarSha256': 'a' * 64,
      'parentApkSha256': 'b' * 64,
      'baseRuntimeRevision': 0,
      'state': state,
      'reasonCode': 'TEST_STATE',
      'createdAt': 1792200000000,
      'confirmedAt': state == 'APPLIED_CLOSED' ? 1792200000001 : null,
      'canCheckRuntime': state != 'APPLIED_CLOSED' && state != 'CANCELLED',
      'canCancel': state == 'WAITING_EXECUTOR',
      'runtimeStatus':
          state == 'APPLIED_CLOSED' ? 'APPLIED_CLOSED' : 'APPLY_REQUIRED',
      'salesAllowed': false,
    };
Json rollbackTargetFixture() => {
      'versionId': historicalId,
      'preparationId': preparationId,
      'providerJarSha256': 'a' * 64,
      'parentApkSha256': 'b' * 64,
      'confirmedAt': 1792200000000,
    };
Json releaseStatusFixture(
        {Json? active, Json? confirmed, bool rollback = false}) =>
    {
      'environmentId': 'family-cn-pilot',
      'runtimeRevision': 0,
      'observationReady': true,
      'executorReady': true,
      'activeOperation': active,
      'confirmedOperation': confirmed,
      'rollbackTargets': rollback ? [rollbackTargetFixture()] : [],
      'runtimeStatus': confirmed == null ? 'APPLY_REQUIRED' : 'APPLIED_CLOSED',
      'salesAllowed': false,
    };
Json runtimeCheckFixture(
        {required String id,
        String operationId = releaseId,
        String versionId = identityVersionId,
        String state = 'MISMATCH'}) =>
    {
      'id': id,
      'operationId': operationId,
      'versionId': versionId,
      'state': state,
      'reasonCode': 'TEST_CHECK',
      'createdAt': 1792200000000,
      'completedAt': state == 'CHECKING' ? null : 1792200000001,
      'instances': [
        {
          'instanceId': 'identity-1',
          'state': state == 'CONFIRMED' ? 'CONFIRMED' : 'MISMATCH',
          'reasonCode': 'TEST_INSTANCE',
          'observedAt': 1792200000000
        }
      ],
      'runtimeStatus':
          state == 'CONFIRMED' ? 'APPLIED_CLOSED' : 'APPLY_REQUIRED',
      'salesAllowed': false,
    };
