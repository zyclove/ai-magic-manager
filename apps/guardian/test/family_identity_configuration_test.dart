import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/family_identity_configuration.dart';

const identityVersionId = '11111111-1111-4111-8111-111111111111';
const identityOperationId = '22222222-2222-4222-8222-222222222222';

Json identityVersionFixture() => {
      'id': identityVersionId,
      'version': 1,
      'baseVersion': 0,
      'createdAt': 1792200000000,
      'settings': {
        'smsSignName': '家庭服务',
        'smsTemplateCode': 'SMS_123456',
        'wechatAppId': 'wx0123456789abcdef',
        'parentPackageName': 'com.aimanager.parent',
        'parentCertificateSha256': 'a' * 64
      },
      'credentials': {
        'otpHmacKey': true,
        'smsAccessKeyId': true,
        'smsAccessKeySecret': true,
        'smsSecurityToken': false,
        'wechatAppSecret': true
      },
      'readinessStatus': 'READY',
    };
Json identityStatusFixture({bool manage = true, bool test = true}) => {
      'environmentId': 'family-cn-pilot',
      'capabilities': {
        'canRead': true,
        'canManage': manage,
        'canTest': test,
        'secretStorageReady': true,
        'releasePreparationReady': true
      },
      'latestVersion': 1,
      'version': identityVersionFixture(),
      'readinessChecks': <Object>[],
      'runtimeStatus': 'APPLY_REQUIRED',
      'salesAllowed': false,
    };
Json identityAcceptanceFixture() => {
      'id': identityOperationId,
      'versionId': identityVersionId,
      'environmentId': 'family-cn-pilot',
      'providerJarSha256': 'a' * 64,
      'parentApkSha256': 'b' * 64,
      'createdAt': 1792200000000,
      'status': 'BLOCKED',
      'runtimeStatus': 'APPLY_REQUIRED',
      'salesAllowed': false,
      'providerRequestsPerformed': false,
      'checks': identityRequiredAcceptanceCases
          .map((id) => <String, dynamic>{
                'id': id,
                'label': '待联调项目',
                'stage': '真实联调',
                'status': 'BLOCKED',
                'reasonCode': 'REAL_EXECUTION_NOT_OBSERVED',
                'action': '请完成正式真机联调',
              })
          .toList(),
    };

void main() {
  test(
      'loaded configuration with closed login remains distinct from acceptance',
      () {
    final status = IdentityProviderStatus.parse(
        identityStatusFixture()..['runtimeStatus'] = 'APPLIED_CLOSED');
    expect(status.runtimeStatus, 'APPLIED_CLOSED');
  });
  test(
      'status accepts presence flags and distinguishes configuration from runtime',
      () {
    final status = IdentityProviderStatus.parse(identityStatusFixture());
    expect(status.version!.credentials.wechatAppSecret, isTrue);
    expect(status.version!.version, 1);
    expect(status.runtimeStatus, 'APPLY_REQUIRED');
  });
  test('secret contents and extra response fields are rejected', () {
    final version = identityVersionFixture();
    version['credentials'] = <String, dynamic>{
      ...version['credentials'] as Json,
      'wechatAppSecret': 'must-never-read-back'
    };
    expect(() => IdentityProviderVersion.parse(version),
        throwsA(isA<ApiFailure>()));
    final status = identityStatusFixture()
      ..['smsAccessKeySecret'] = 'must-never-read-back';
    expect(
        () => IdentityProviderStatus.parse(status), throwsA(isA<ApiFailure>()));
  });
  test('fake runtime success or enabled sales are rejected', () {
    for (final change in [
      <String, dynamic>{'runtimeStatus': 'ACTIVE'},
      <String, dynamic>{'salesAllowed': true},
      <String, dynamic>{'latestVersion': 2}
    ]) {
      expect(
          () => IdentityProviderStatus.parse(
              identityStatusFixture()..addAll(change)),
          throwsA(isA<ApiFailure>()));
    }
  });
  test('acceptance requires all fixed cases and never accepts a supplier pass',
      () {
    expect(
        IdentityProviderAcceptanceRun.parse(identityAcceptanceFixture()).checks,
        hasLength(12));
    final missing = identityAcceptanceFixture();
    (missing['checks'] as List).removeLast();
    expect(() => IdentityProviderAcceptanceRun.parse(missing),
        throwsA(isA<ApiFailure>()));
    final fake = identityAcceptanceFixture();
    ((fake['checks'] as List).first as Json)['status'] = 'READY';
    expect(() => IdentityProviderAcceptanceRun.parse(fake),
        throwsA(isA<ApiFailure>()));
    for (final change in [
      <String, dynamic>{'status': 'PASS'},
      <String, dynamic>{'providerRequestsPerformed': true}
    ]) {
      expect(
          () => IdentityProviderAcceptanceRun.parse(
              identityAcceptanceFixture()..addAll(change)),
          throwsA(isA<ApiFailure>()));
    }
  });
}
