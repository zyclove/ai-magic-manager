import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/contract_action_resume.dart';

const reviewId = '22222222-2222-2222-2222-222222222222';

void main() {
  test('step-up resume restores only a scoped pointer and never the operation',
      () {
    const pointer = ContractActionResume(reviewId, 'approve');
    final encoded = pointer.encode(
        actor: 'operator-1',
        scope: 'platform',
        tenantId: '',
        role: '',
        now: 1000);
    expect(encoded, isNot(contains('reason')));
    expect(encoded, isNot(contains('evidence')));
    expect(
        ContractActionResume.decode(encoded,
                actor: 'operator-1',
                scope: 'platform',
                tenantId: '',
                role: '',
                now: 1200)
            ?.reviewId,
        reviewId);
    expect(
        ContractActionResume.decode(encoded,
            actor: 'another-operator',
            scope: 'platform',
            tenantId: '',
            role: '',
            now: 1200),
        isNull);
    expect(
        ContractActionResume.decode(encoded,
            actor: 'operator-1',
            scope: 'tenant',
            tenantId: '',
            role: '',
            now: 1200),
        isNull);
    expect(
        ContractActionResume.decode(encoded,
            actor: 'operator-1',
            scope: 'platform',
            tenantId: '',
            role: '',
            now: 601001),
        isNull);
  });

  test('institution resume stays bound to role and tenant', () {
    const pointer = ContractActionResume(reviewId, 'accept');
    final encoded = pointer.encode(
        actor: 'owner-1',
        scope: 'tenant',
        tenantId: '11111111-1111-1111-1111-111111111111',
        role: 'ORG_ADMIN',
        now: 1000);
    expect(
        ContractActionResume.decode(encoded,
                actor: 'owner-1',
                scope: 'tenant',
                tenantId: '11111111-1111-1111-1111-111111111111',
                role: 'ORG_ADMIN',
                now: 1200)
            ?.action,
        'accept');
    expect(
        ContractActionResume.decode(encoded,
            actor: 'owner-1',
            scope: 'tenant',
            tenantId: '33333333-3333-3333-3333-333333333333',
            role: 'ORG_ADMIN',
            now: 1200),
        isNull);
    expect(
        ContractActionResume.decode(encoded,
            actor: 'owner-1',
            scope: 'tenant',
            tenantId: '11111111-1111-1111-1111-111111111111',
            role: 'AUDITOR',
            now: 1200),
        isNull);
  });
}
