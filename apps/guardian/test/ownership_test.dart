import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/access.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/labels.dart';

void main() {
  test('ownership audit and invalidation labels describe the action', () {
    expect(label('OWNERSHIP_CHANGED'), '所有者已变更，请重新申请');
    expect(label('OWNERSHIP_TRANSFER_ACCEPTED'), '完成所有者交接');
    expect(label('ENROLLMENT_OWNERSHIP_CANCELLED'), '交接后取消待确认配对');
  });
  test('ownership recipient navigation includes unscoped adults', () {
    for (final role in ['OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR']) {
      expect(canOpenSection(role, 'ownership'), isTrue, reason: role);
    }
    for (final role in ['CHILD', 'TEACHER', '']) {
      expect(canOpenSection(role, 'ownership'), isFalse, reason: role);
    }
  });
  test('ownership failures describe recovery instead of raw codes', () {
    expect(const ApiFailure(409, 'OWNERSHIP_TRANSFER_PENDING').message,
        contains('已有'));
    expect(const ApiFailure(400, 'OWNERSHIP_TARGET_INELIGIBLE').message,
        contains('成人'));
  });
}
