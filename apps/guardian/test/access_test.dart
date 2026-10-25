import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/access.dart';

void main() {
  test('unknown sections are unavailable even to workspace administrators', () {
    for (final role in [
      'OWNER', 'ORG_ADMIN', 'GUARDIAN', 'AUDITOR', 'TEACHER', 'CHILD', ''
    ]) {
      for (final section in [
        '', 'unknown-feature', 'overview/', 'devices?tab=all', 'Devices',
        '../devices', '/devices', 'catalog/new'
      ]) {
        expect(canOpenSection(role, section), isFalse,
            reason: '$role / $section');
      }
    }
  });
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
    expect(trustedReturnPath('/catalog'), '/catalog');
  });
  for (final path in [
    '/managed-android',
    '/managed-android-review',
    '/device-groups',
  ]) {
    test('authentication returns to the requested $path page', () {
      expect(trustedReturnPath(path), path);
    });
  }
  test('authentication rejects external, altered and unknown return paths', () {
    for (final path in <String?>[
      null,
      '',
      'managed-android',
      '//managed-android',
      'https://example.invalid/managed-android',
      'javascript:alert(1)',
      '/managed-android?next=/devices',
      '/managed-android#devices',
      '/managed-android/',
      '/managed-android/details',
      '/managed-android-review?next=/devices',
      '/managed-android-review/',
      '/device-groups?group=1',
      '/device-groups/',
      '/Device-groups',
      '/managed%2Dandroid',
      '/%2fmanaged-android',
      r'\managed-android',
      ' /managed-android',
      '/managed-android ',
      '/devices/../managed-android',
      '/unknown',
      '/login',
      '/auth/callback',
    ]) {
      expect(trustedReturnPath(path), '/', reason: 'return path: $path');
    }
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
