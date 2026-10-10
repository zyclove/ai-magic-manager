import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/access.dart';

void main() {
  test('notification navigation includes requesters and excludes auditors', () {
    for (final role in ['OWNER', 'GUARDIAN', 'ORG_ADMIN', 'TEACHER', 'CHILD']) {
      expect(canOpenSection(role, 'notifications'), isTrue, reason: role);
    }
    expect(canOpenSection('AUDITOR', 'notifications'), isFalse);
    expect(canOpenSection('', 'notifications'), isFalse);
  });
  test('role navigation mirrors restricted resources', () {
    expect(canOpenSection('AUDITOR', 'subjects'), isFalse);
    expect(canOpenSection('AUDITOR', 'devices'), isFalse);
    expect(canOpenSection('AUDITOR', 'audit'), isTrue);
    expect(canOpenSection('CHILD', 'policies'), isFalse);
    expect(canOpenSection('CHILD', 'audit'), isFalse);
    expect(canOpenSection('CHILD', 'devices'), isTrue);
    expect(canOpenSection('GUARDIAN', 'members'), isFalse);
    expect(canOpenSection('OWNER', 'members'), isTrue);
  });
  test('commercial account is read only for adult administrators and auditors',
      () {
    for (final role in ['OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR']) {
      expect(canOpenSection(role, 'commercial'), isTrue, reason: role);
    }
    for (final role in ['CHILD', 'TEACHER', '']) {
      expect(canOpenSection(role, 'commercial'), isFalse, reason: role);
    }
    expect(trustedReturnPath('/commercial'), '/commercial');
  });
  test('late workspace responses and logout cannot restore stale selection',
      () {
    final selections = SelectionGeneration();
    final b = selections.begin();
    final c = selections.begin();
    expect(selections.current(b), isFalse);
    expect(selections.current(c), isTrue);
    selections.invalidate();
    expect(selections.current(c), isFalse);
  });
}
