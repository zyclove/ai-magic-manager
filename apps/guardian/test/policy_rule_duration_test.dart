import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_rule_duration.dart';

Matcher get _invalid => throwsA(isA<ApiFailure>()
    .having((failure) => failure.status, 'status', 400)
    .having((failure) => failure.code, 'code', 'INVALID_DURATION'));

void main() {
  test('whole-second boundaries round trip exactly with immutable fields and labels', () {
    for (final sample in const [
      (1, 0, 1, '1 秒'),
      (59, 0, 59, '59 秒'),
      (60, 1, 0, '1 分钟'),
      (61, 1, 1, '1 分钟 1 秒'),
      (3599, 59, 59, '59 分钟 59 秒'),
      (3600, 60, 0, '1 小时'),
      (3661, 61, 1, '1 小时 1 分钟 1 秒'),
      (86399, 1439, 59, '23 小时 59 分钟 59 秒'),
      (86400, 1440, 0, '24 小时'),
    ]) {
      final initial = policyRuleDurationInitial(sample.$1);
      expect(initial, {'minutes': sample.$2, 'seconds': sample.$3});
      expect(policyRuleDurationSeconds(initial), sample.$1);
      expect(policyRuleDurationLabel(sample.$1), sample.$4);
      expect(() => initial['seconds'] = 0, throwsUnsupportedError);
      expect(() => initial.clear(), throwsUnsupportedError);
    }
    expect(policyRuleDurationSeconds({'minutes': 1}), 60);
    expect(policyRuleDurationSeconds({'minutes': 1, 'seconds': null}), 60);
    expect(policyRuleDurationSeconds({'minutes': 1440, 'seconds': null}), 86400);
  });

  test('invalid types and durations fail without rounding or clamping', () {
    for (final value in <Object?>[
      null, true, '60', 1.5, 59.9, double.nan, double.infinity,
      <int>[], <String, dynamic>{}, -1, 0, 86401,
    ]) {
      expect(() => policyRuleDurationInitial(value), _invalid);
      expect(() => policyRuleDurationLabel(value), _invalid);
    }
    for (final values in <Json>[
      {}, {'seconds': 1}, {'minutes': null, 'seconds': 1},
      {'minutes': true, 'seconds': 1}, {'minutes': '1', 'seconds': 1},
      {'minutes': 0.5, 'seconds': 1}, {'minutes': double.infinity},
      {'minutes': -1, 'seconds': 59}, {'minutes': 1441},
      {'minutes': 0}, {'minutes': 0, 'seconds': null},
      {'minutes': 0, 'seconds': 0}, {'minutes': 1440, 'seconds': 1},
      {'minutes': 0, 'seconds': -1}, {'minutes': 0, 'seconds': 60},
      {'minutes': 0, 'seconds': 1.5}, {'minutes': 0, 'seconds': '1'},
      {'minutes': 0, 'seconds': true}, {'minutes': 0, 'seconds': double.nan},
    ]) {
      expect(() => policyRuleDurationSeconds(values), _invalid);
    }
  });
}
