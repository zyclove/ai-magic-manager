import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/access.dart';

void main() {
  test('family finance is a trusted return path after real MFA', () {
    expect(trustedReturnPath('/family-finance'), '/family-finance');
    expect(trustedReturnPath('https://attacker.invalid/family-finance'), '/');
  });
  test('family ownership does not substitute independent platform capability',
      () {
    expect(
        canOpenFamilyFinance(
            authenticated: true,
            canReviewRefunds: false,
            canManageFinance: false),
        isFalse);
    expect(
        canOpenFamilyFinance(
            authenticated: false,
            canReviewRefunds: true,
            canManageFinance: true),
        isFalse);
    expect(
        canOpenFamilyFinance(
            authenticated: true,
            canReviewRefunds: true,
            canManageFinance: false),
        isTrue);
    expect(
        canOpenFamilyFinance(
            authenticated: true,
            canReviewRefunds: false,
            canManageFinance: true),
        isTrue);
  });
}
