import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_draft_change.dart';

const _policyId = 'policy-opaque-id';
const _sourceId = 'published-version-opaque-id';

List<Json> _rules() => [
  {'id': 'launch', 'kind': 'APP_LAUNCH', 'effect': 'ALLOW',
    'required': true, 'applicationId': 'application-id'},
  {'id': 'install', 'kind': 'APP_INSTALL', 'effect': 'DENY',
    'required': true, 'applicationId': 'application-id'},
  {'id': 'protect', 'kind': 'APP_UNINSTALL', 'effect': 'PROTECT',
    'required': true, 'applicationId': 'application-id'},
  {'id': 'permission', 'kind': 'RUNTIME_PERMISSION', 'effect': 'DEFAULT',
    'required': false, 'applicationId': 'application-id',
    'permission': 'android.permission.CAMERA'},
  {'id': 'special', 'kind': 'SPECIAL_ACCESS', 'effect': 'GRANT',
    'required': false, 'applicationId': 'application-id', 'permission': 'usage'},
  {'id': 'quota', 'kind': 'DAILY_QUOTA', 'effect': 'LIMIT',
    'required': true, 'seconds': 3600},
  {'id': 'window', 'kind': 'TIME_WINDOW', 'effect': 'ALLOW',
    'required': true, 'scheduleId': 'schedule-id'},
  {'id': 'domain', 'kind': 'DOMAIN_ACCESS', 'effect': 'DENY',
    'required': true, 'domain': 'example.test'},
  {'id': 'reminder', 'kind': 'USAGE_REMINDER', 'effect': 'REMIND',
    'required': false, 'applicationId': 'application-id', 'seconds': 600},
];

Json _values({bool creating = false}) => {
  'name': '本次草稿',
  if (creating) 'kind': 'POLICY',
  'rules': _rules(),
};

Json _snapshot({String id = _policyId, String name = '原草稿',
    String kind = 'POLICY', int revision = 4,
    String? sourceVersionId = _sourceId}) => {
  'id': id, 'name': name, 'kind': kind, 'revision': revision,
  'rules': _rules(), 'sourceVersionId': sourceVersionId,
};

Json _clone(Json value) => jsonDecode(jsonEncode(value)) as Json;
List _ruleList(Json value) => value['rules'] as List;

Object? _reverseKeys(Object? value) {
  if (value is Json) {
    return <String, dynamic>{
      for (final key in value.keys.toList().reversed) key: _reverseKeys(value[key])
    };
  }
  if (value is List) return value.map(_reverseKeys).toList();
  return value;
}

Matcher _failure(int status, String code) => throwsA(isA<ApiFailure>()
    .having((failure) => failure.status, 'status', status)
    .having((failure) => failure.code, 'code', code));
Matcher get _invalidInput => _failure(400, 'VALIDATION_FAILED');
Matcher get _invalidResponse => _failure(502, 'INVALID_RESPONSE');

void main() {
  test('draft changes preserve every rule kind and detach immutable inputs', () {
    final values = _values(creating: true);
    final create = PolicyDraftChange.create(values);
    expect(create.body.keys.toSet(), {'operation', 'name', 'kind', 'rules'});
    expect(create.body['operation'], 'CREATE');
    expect(create.body['kind'], 'POLICY');
    expect(_ruleList(create.body).map((rule) => rule['kind']).toList(), [
      'APP_LAUNCH', 'APP_INSTALL', 'APP_UNINSTALL', 'RUNTIME_PERMISSION',
      'SPECIAL_ACCESS', 'DAILY_QUOTA', 'TIME_WINDOW', 'DOMAIN_ACCESS',
      'USAGE_REMINDER',
    ]);
    expect((_ruleList(create.body)[3] as Json)['permission'],
        'android.permission.CAMERA');
    expect((_ruleList(create.body)[5] as Json)['seconds'], 3600);
    expect((_ruleList(create.body)[6] as Json)['scheduleId'], 'schedule-id');
    expect((_ruleList(create.body)[7] as Json)['domain'], 'example.test');
    expect((_ruleList(create.body)[8] as Json)['required'], isFalse);
    final expected = _clone(create.body);
    expect(() => create.body['name'] = '改名', throwsUnsupportedError);
    expect(() => _ruleList(create.body).clear(), throwsUnsupportedError);
    expect(() => (_ruleList(create.body).first as Json)['effect'] = 'DENY',
        throwsUnsupportedError);
    values['name'] = '改变原输入';
    (_ruleList(values).first as Json)['effect'] = 'DENY';
    _ruleList(values).clear();
    expect(create.body, expected);

    final before = _snapshot();
    final update = PolicyDraftChange.update(before, _values());
    before['revision'] = 99;
    before['kind'] = 'TEMPLATE';
    before['sourceVersionId'] = 'another-version';
    _ruleList(before).clear();
    expect(update.body.keys.toSet(),
        {'operation', 'policyId', 'revision', 'name', 'rules'});
    expect(update.body['operation'], 'UPDATE');
    expect(update.body['policyId'], _policyId);
    expect(update.body['revision'], 4);
    expect(update.committed(_snapshot(name: '本次草稿', revision: 5))
        ['sourceVersionId'], _sourceId);
    expect(() => update.body.clear(), throwsUnsupportedError);
    expect(() => _ruleList(update.body).clear(), throwsUnsupportedError);
    final snapshot = readPolicyDraftSnapshot(_snapshot(), expectedId: _policyId);
    expect(snapshot['sourceVersionId'], _sourceId);
    expect(() => snapshot['revision'] = 5, throwsUnsupportedError);
    expect(() => _ruleList(snapshot).clear(), throwsUnsupportedError);
    expect(() => (_ruleList(snapshot).first as Json).clear(),
        throwsUnsupportedError);
    expect(PolicyDraftChange.create({..._values(creating: true),
      'kind': 'TEMPLATE'}).body['kind'], 'TEMPLATE');

    final invalidRules = <Object?>[
      null, {}, [{'id': 'missing-fields'}],
      [_rules().first, _rules().first],
      [{..._rules().first, 'effect': 'REMIND'}],
      [{..._rules().first, 'scheduleId': 'unused-schedule'}],
      [{..._rules()[5], 'seconds': 0}],
      [{..._rules()[5], 'seconds': 86401}],
      [{..._rules()[3], 'required': 'false'}],
      [for (var index = 0; index < 101; index++)
        {..._rules().first, 'id': 'rule_$index'}],
    ];
    for (final rules in invalidRules) {
      expect(() => PolicyDraftChange.create({
        ..._values(creating: true), 'rules': rules
      }), _invalidInput);
    }
    for (final values in <Json>[
      {}, {..._values(creating: true), 'name': ' '},
      {..._values(creating: true), 'kind': 'UNKNOWN'},
      {..._values(creating: true), 'unexpected': true},
    ]) {
      expect(() => PolicyDraftChange.create(values), _invalidInput);
    }
    for (final before in <Json>[
      _snapshot(revision: 9007199254740991),
      {..._snapshot(), 'revision': 1.5},
      {..._snapshot(), 'sourceVersionId': ''},
    ]) {
      expect(() => PolicyDraftChange.update(before, _values()), _invalidInput);
    }
    expect(() => PolicyDraftChange.update(_snapshot(), _values(creating: true)),
        _invalidInput);
  });

  test('committed receipts match exact content and the one committed revision', () {
    for (final creating in [true, false]) {
      final values = _values(creating: creating);
      final change = creating ? PolicyDraftChange.create(values)
          : PolicyDraftChange.update(_snapshot(), values);
      final receipt = _snapshot(id: creating ? 'created-policy-id' : _policyId,
          name: '本次草稿', revision: creating ? 0 : 5,
          sourceVersionId: creating ? null : _sourceId);
      final result = change.committed(_reverseKeys(receipt));
      final expected = _clone(result);
      expect(result['id'], receipt['id']);
      expect(result['revision'], creating ? 0 : 5);
      expect(() => result['name'] = '改写回执', throwsUnsupportedError);
      expect(() => _ruleList(result).clear(), throwsUnsupportedError);
      expect(() => (_ruleList(result).first as Json).clear(),
          throwsUnsupportedError);
      (_ruleList(receipt).first as Json)['effect'] = 'DENY';
      receipt.clear();
      expect(result, expected);

      Json changed(void Function(Json) mutate) {
        final value = _clone(expected);
        mutate(value);
        return value;
      }
      for (final invalid in <Object?>[
        null, [], {},
        changed((draft) => draft['id'] = ''),
        if (!creating) changed((draft) => draft['id'] = 'different-policy'),
        changed((draft) => draft['name'] = '其他内容'),
        changed((draft) => draft['kind'] = 'TEMPLATE'),
        changed((draft) => draft['revision'] = creating ? 1 : 4),
        changed((draft) => draft['revision'] = creating ? 2 : 6),
        changed((draft) => draft['revision'] = 5.5),
        changed((draft) => draft['revision'] = 9007199254740992),
        changed((draft) => draft['sourceVersionId'] = 'other-source'),
        changed((draft) => draft['rules'] = _ruleList(draft).reversed.toList()),
        changed((draft) => (_ruleList(draft).first as Json)['effect'] = 'DENY'),
        changed((draft) => (_ruleList(draft)[5] as Json)['seconds'] = 600),
      ]) {
        expect(() => change.committed(invalid), _invalidResponse);
      }
      final explicitNull = _clone(expected);
      for (final rule in _ruleList(explicitNull).cast<Json>()) {
        rule.removeWhere((key, value) => value == null);
      }
      expect(change.committed(explicitNull), expected,
          reason: 'Absent optional fields and explicit nulls have one meaning.');
    }
  });

  test('queries keep the original receipt separate from later current edits', () {
    for (final creating in [true, false]) {
      final change = creating ? PolicyDraftChange.create(_values(creating: true))
          : PolicyDraftChange.update(_snapshot(), _values());
      final committed = _snapshot(name: '本次草稿', revision: creating ? 0 : 5,
          sourceVersionId: creating ? null : _sourceId);
      final current = _clone(committed)
        ..['revision'] = (committed['revision'] as int) + 3
        ..['name'] = '后来修改的草稿'
        ..['sourceVersionId'] = 'later-rollback-version'
        ..['rules'] = <Json>[];
      Json query({Json? original, Json? latest}) => {
        'operation': creating ? 'CREATE' : 'UPDATE',
        'committed': original ?? committed,
        'current': latest ?? current,
      };
      final result = change.queryResult(_reverseKeys(query()));
      expect(result.committed['name'], '本次草稿');
      expect(_ruleList(result.committed), hasLength(9));
      expect(result.current['name'], '后来修改的草稿');
      expect(result.current['sourceVersionId'], 'later-rollback-version');
      expect(_ruleList(result.current), isEmpty);
      expect(result.committed['id'], result.current['id']);
      expect(change.queryResult(query(latest: _clone(committed))).current,
          result.committed);
      expect(() => result.committed.clear(), throwsUnsupportedError);
      expect(() => result.current.clear(), throwsUnsupportedError);
      expect(() => (_ruleList(result.committed).first as Json).clear(),
          throwsUnsupportedError);
      expect(() => _ruleList(result.current).add({}), throwsUnsupportedError);
      Json changedCurrent(void Function(Json) mutate) {
        final value = _clone(current);
        mutate(value);
        return value;
      }
      final changedSameRevision = _clone(committed)..['name'] = '同版本篡改';
      final reorderedSameRevision = _clone(committed)
        ..['rules'] = _ruleList(committed).reversed.toList();
      for (final invalid in <Object?>[
        null, {},
        {...query(), 'operation': creating ? 'UPDATE' : 'CREATE'},
        {...query(), 'current': null},
        {...query(), 'committed': current},
        query(latest: changedCurrent((draft) => draft['id'] = 'other-policy')),
        query(latest: changedCurrent((draft) => draft['kind'] = 'TEMPLATE')),
        query(latest: {...committed, 'sourceVersionId': 'same-version-tamper'}),
        query(latest: changedCurrent((draft) => draft['sourceVersionId'] = 12)),
        query(latest: changedCurrent((draft) =>
            draft['revision'] = (committed['revision'] as int) - 1)),
        query(latest: changedSameRevision),
        query(latest: reorderedSameRevision),
      ]) {
        expect(() => change.queryResult(invalid), _invalidResponse);
      }
      final frozenOriginal = _clone(result.committed);
      final frozenCurrent = _clone(result.current);
      _ruleList(committed).clear();
      committed.clear();
      current.clear();
      expect(result.committed, frozenOriginal);
      expect(result.current, frozenCurrent);
    }
  });
}
