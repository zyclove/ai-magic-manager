import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/application_registration.dart';

String _digest(String byte) => List.filled(32, byte).join();
String _colon(String hex) => [
  for (var index = 0; index < hex.length; index += 2) hex.substring(index, index + 2),
].join(':');
Json _form({Object? digests = ''}) => {
  'displayName': '  阅读工具  ', 'packageName': '  Com.Example_App.Reader  ',
  'platform': 'ANDROID', 'profile': 'PRIMARY', 'digests': digests,
};
Matcher _failure(int status, String code) => throwsA(isA<ApiFailure>()
    .having((failure) => failure.status, 'status', status)
    .having((failure) => failure.code, 'code', code));

void main() {
  test('declaration preserves package case, normalizes fingerprints and freezes only contract fields', () {
    final a = _digest('a1'), b = _digest('b2'), c = _digest('c3'), d = _digest('d4');
    final source = {..._form(digests:
        '  ${_colon(d.toUpperCase())}, ${b.toUpperCase()}，$c\r\n$a\n  '),
      'unrelated': {'private': 'discarded'}};
    final payload = applicationRegistrationPayload(source);
    source.clear();
    expect(payload, {'displayName': '阅读工具', 'platform': 'ANDROID',
      'packageName': 'Com.Example_App.Reader', 'profile': 'PRIMARY',
      'signingDigests': [a, b, c, d]});
    expect(() => payload['platform'] = 'ANDROID_TV', throwsUnsupportedError);
    expect(() => (payload['signingDigests'] as List).add(_digest('e5')),
        throwsUnsupportedError);
    for (final platform in ['ANDROID', 'ANDROID_TV']) {
      for (final profile in ['PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN']) {
        final body = applicationRegistrationPayload({..._form(),
          'platform': platform, 'profile': profile});
        expect(body['platform'], platform);
        expect(body['profile'], profile);
      }
    }
    for (final packageName in ['Com.Example_123.App', ' a.b ',
      'a.${List.filled(253, 'b').join()}']) {
      expect(validateAndroidPackageName(packageName), isNull);
    }
    for (final packageName in <String?>[null, '', 'one', '_com.reader',
      'com.1reader', 'https://com.reader', 'com.reader/app', 'com.reader-app',
      'a.${List.filled(254, 'b').join()}']) {
      expect(validateAndroidPackageName(packageName), isNotNull);
    }
  });

  test('signature errors identify empty, repeated, invalid or excessive entries without dropping input', () {
    final a = _digest('a1'), b = _digest('b2');
    for (final text in <String?>[null, '', ' \r\n\t', a, a.toUpperCase(),
      _colon(a.toUpperCase()), '$a,$b', '$a，$b', '$a\n$b', '$a\r\n$b', '$a\n']) {
      expect(validateApplicationSigningDigests(text), isNull);
    }
    for (final blank in <String?>[null, '', ' \r\n\t']) {
      expect(applicationRegistrationPayload(_form(digests: blank))['signingDigests'], isEmpty);
    }
    final nine = [for (var index = 0; index < 9; index++)
      _digest(index.toRadixString(16).padLeft(2, '0'))].join(',');
    final invalidDigests = [
      '$a,,$b', '$a\n\n$b', '$a,\n$b', '$a,', ',$a',
      '$a,${_colon(a.toUpperCase())}', a.substring(1), '${a}0',
      _colon(a).substring(1), '${a.substring(0, 32)} ${a.substring(32)}',
      '$a;$b', nine,
    ];
    for (final text in invalidDigests) {
      expect(validateApplicationSigningDigests(text), isNotNull);
      expect(() => applicationRegistrationPayload(_form(digests: text)),
          _failure(400, 'VALIDATION_FAILED'));
    }
    expect(validateApplicationSigningDigests('$a,,$b'), contains('为空'));
    expect(validateApplicationSigningDigests('$a,${_colon(a.toUpperCase())}'), contains('重复'));
    expect(validateApplicationSigningDigests(nine), contains('最多'));
    for (final invalid in <Json>[
      {..._form(), 'displayName': ''},
      {..._form(), 'displayName': List.filled(101, '名').join()},
      {..._form(), 'displayName': 1}, {..._form(), 'packageName': 'bad'},
      {..._form(), 'packageName': null}, {..._form(), 'platform': 'IOS'},
      {..._form(), 'profile': 'OTHER'}, {..._form(), 'digests': [a]},
    ]) {
      expect(() => applicationRegistrationPayload(invalid),
          _failure(400, 'VALIDATION_FAILED'));
    }
    final eight = [for (var index = 0; index < 8; index++)
      _digest(index.toRadixString(16).padLeft(2, '0'))];
    expect(applicationRegistrationPayload(_form(digests: eight.join('\r\n')))
        ['signingDigests'], eight);
  });

  test('creation results must match the complete original declaration and remain immutable', () {
    final a = _digest('a1'), b = _digest('b2'), c = _digest('c3');
    final body = applicationRegistrationPayload(_form(digests: '$b,$a'));
    Json response() => {'id': 'd1111111-1111-4111-8111-111111111111',
      ...body, 'signingDigests': [b, a], 'evidenceStatus': 'ADMIN_DECLARED',
      'unrelated': {'private': 'discarded'}};
    final source = response();
    final result = requireApplicationRegistrationResult(source, body);
    source.clear();
    expect(result.keys, unorderedEquals(['id', 'displayName', 'platform',
      'packageName', 'profile', 'signingDigests', 'evidenceStatus']));
    expect(result['packageName'], 'Com.Example_App.Reader');
    expect(result['signingDigests'], [a, b]);
    expect(() => result['displayName'] = '变更', throwsUnsupportedError);
    expect(() => (result['signingDigests'] as List).clear(), throwsUnsupportedError);
    for (final invalid in <Object?>[
      null, [], body, {...response(), 'id': 'bad'},
      {...response(), 'id': 'D1111111-1111-4111-8111-111111111111'},
      {...response(), 'evidenceStatus': 'OBSERVED'},
      {...response(), 'displayName': '其他名称'},
      {...response(), 'packageName': 'com.example_app.reader'},
      {...response(), 'platform': 'ANDROID_TV'}, {...response(), 'profile': 'WORK'},
      {...response(), 'signingDigests': [a]},
      {...response(), 'signingDigests': [a, b, c]},
      {...response(), 'signingDigests': [a, a]},
      {...response(), 'signingDigests': [a.toUpperCase(), b]},
      {...response(), 'signingDigests': [null]},
      {...response(), 'signingDigests': '$a,$b'},
    ]) {
      expect(() => requireApplicationRegistrationResult(invalid, body),
          _failure(502, 'INVALID_RESPONSE'));
    }
    final empty = applicationRegistrationPayload(_form());
    expect(requireApplicationRegistrationResult({'id': response()['id'], ...empty,
      'evidenceStatus': 'ADMIN_DECLARED'}, empty)['signingDigests'], isEmpty);
  });
}
