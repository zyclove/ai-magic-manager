import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_draft_branch.dart';

const _request = '11111111-1111-4111-8111-111111111111';
List<Json> _rules({String domain = 'original.example.test'}) => [
      {
        'id': 'launch',
        'kind': 'APP_LAUNCH',
        'effect': 'ALLOW',
        'required': true,
        'applicationId': 'application-opaque'
      },
      {
        'id': 'install',
        'kind': 'APP_INSTALL',
        'effect': 'DENY',
        'required': true,
        'applicationId': 'application-opaque'
      },
      {
        'id': 'uninstall',
        'kind': 'APP_UNINSTALL',
        'effect': 'PROTECT',
        'required': true,
        'applicationId': 'application-opaque'
      },
      {
        'id': 'permission',
        'kind': 'RUNTIME_PERMISSION',
        'effect': 'DEFAULT',
        'required': false,
        'applicationId': 'application-opaque',
        'permission': 'CAMERA'
      },
      {
        'id': 'special',
        'kind': 'SPECIAL_ACCESS',
        'effect': 'GRANT',
        'required': false,
        'applicationId': 'application-opaque',
        'permission': 'USAGE_ACCESS'
      },
      {
        'id': 'quota',
        'kind': 'DAILY_QUOTA',
        'effect': 'LIMIT',
        'required': true,
        'seconds': 3599
      },
      {
        'id': 'window',
        'kind': 'TIME_WINDOW',
        'effect': 'ALLOW',
        'required': true,
        'scheduleId': 'schedule-opaque'
      },
      {
        'id': 'domain',
        'kind': 'DOMAIN_ACCESS',
        'effect': 'DENY',
        'required': true,
        'domain': domain
      },
      {
        'id': 'reminder',
        'kind': 'USAGE_REMINDER',
        'effect': 'REMIND',
        'required': false,
        'seconds': 59
      },
    ];
Json _draft({bool template = false, int revision = 4}) => {
      'id': template ? 'template-opaque' : 'policy-opaque',
      'name': '原草稿',
      'kind': template ? 'TEMPLATE' : 'POLICY',
      'revision': revision,
      'rules': _rules(),
      'sourceVersionId': 'old-source-opaque',
    };
Json _version() => {
      'id': 'version-opaque',
      'policyId': 'policy-opaque',
      'snapshot': {
        'schemaVersion': 1,
        'sourceRules': _rules(domain: 'source.example.test')
      },
    };
Json _receipt(bool copying) => {
      ..._draft(revision: copying ? 0 : 5),
      'id': copying ? 'new-policy-opaque' : 'policy-opaque',
      'name': '分支草稿',
      'sourceVersionId': copying ? null : 'version-opaque',
      'rules': _rules(
          domain: copying ? 'original.example.test' : 'source.example.test'),
    };
PolicyDraftBranch _branch(bool copying) => copying
    ? PolicyDraftBranch.copy(_draft(template: true), {'name': '  分支草稿  '})
    : PolicyDraftBranch.rollback(_draft(), _version(), {'name': '  分支草稿  '});
Json _clone(Json value) => jsonDecode(jsonEncode(value)) as Json;
List _ruleList(Json value) => value['rules'] as List;
Object? _reverseKeys(Object? value) {
  if (value is Json) {
    return <String, dynamic>{
      for (final key in value.keys.toList().reversed)
        key: _reverseKeys(value[key]),
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
  test(
      'branches capture detached full rules and validate only their required source facts',
      () {
    final template = _draft(template: true);
    final current = _draft();
    final source = _version();
    final values = <String, dynamic>{'name': '  分支草稿  '};
    final copy = PolicyDraftBranch.copy(template, values);
    final rollback = PolicyDraftBranch.rollback(current, source, values);
    values.clear();
    (_ruleList(template)[7] as Json)['domain'] = 'changed.example.test';
    _ruleList(template).clear();
    template.clear();
    current.clear();
    (source['snapshot']['sourceRules'] as List).clear();
    source.clear();
    for (final branch in [copy, rollback]) {
      expect(branch.body, {'name': '分支草稿'});
      expect(() => branch.body.clear(), throwsUnsupportedError);
    }
    final copied = copy.committed(_receipt(true));
    final restored = rollback.committed(_receipt(false));
    expect(_ruleList(copied), hasLength(9));
    expect((_ruleList(copied)[7] as Json)['domain'], 'original.example.test');
    expect((_ruleList(restored)[7] as Json)['domain'], 'source.example.test');
    expect((_ruleList(restored)[5] as Json)['seconds'], 3599);
    expect((_ruleList(restored)[8] as Json)['seconds'], 59);
    expect(() => restored.clear(), throwsUnsupportedError);
    expect(() => _ruleList(restored).clear(), throwsUnsupportedError);
    expect(() => (_ruleList(restored).first as Json).clear(),
        throwsUnsupportedError);

    for (final values in <Json>[
      {},
      {'name': ' '},
      {'name': List.filled(101, 'a').join()},
      {'name': '分支草稿', 'extra': true},
    ]) {
      expect(() => PolicyDraftBranch.copy(_draft(template: true), values),
          _invalidInput);
      expect(() => PolicyDraftBranch.rollback(_draft(), _version(), values),
          _invalidInput);
    }
    expect(() => PolicyDraftBranch.copy(_draft(), {'name': '分支草稿'}),
        _invalidInput);
    expect(
        () => PolicyDraftBranch.rollback(
            _draft(template: true), _version(), {'name': '分支草稿'}),
        _invalidInput);
    expect(
        () => PolicyDraftBranch.rollback(
            _draft(revision: 9007199254740991), _version(), {'name': '分支草稿'}),
        _invalidInput);
    for (final source in <Json>[
      {},
      {..._version(), 'id': ''},
      {..._version(), 'policyId': 'other-policy'},
      {..._version(), 'snapshot': null},
      {
        ..._version(),
        'snapshot': {'schemaVersion': 2, 'sourceRules': _rules()}
      },
      {
        ..._version(),
        'snapshot': {'schemaVersion': 1.5, 'sourceRules': _rules()}
      },
      {
        ..._version(),
        'snapshot': {
          'schemaVersion': 1,
          'sourceRules': [{}]
        }
      },
      {
        ..._version(),
        'snapshot': {
          'schemaVersion': 1,
          'sourceRules': [_rules().first, _rules().first]
        }
      },
    ]) {
      expect(
          () => PolicyDraftBranch.rollback(_draft(), source, {'name': '分支草稿'}),
          _invalidInput);
    }
  });

  test(
      'committed branches require distinct copy identity or exact rollback revision and source',
      () {
    for (final copying in [true, false]) {
      final branch = _branch(copying);
      final raw = _receipt(copying);
      final result = branch.committed(_reverseKeys(raw));
      final expected = _clone(result);
      expect(result['kind'], 'POLICY');
      expect(result['revision'], copying ? 0 : 5);
      expect(result['sourceVersionId'], copying ? null : 'version-opaque');
      raw.clear();
      expect(result, expected);
      final omittedNulls = _clone(expected);
      for (final rule in _ruleList(omittedNulls).cast<Json>()) {
        rule.removeWhere((key, value) => value == null);
      }
      expect(branch.committed(omittedNulls), expected);
      Json changed(void Function(Json) mutate) {
        final value = _clone(expected);
        mutate(value);
        return value;
      }

      for (final invalid in <Object?>[
        null,
        [],
        {},
        changed((draft) =>
            draft['id'] = copying ? 'template-opaque' : 'other-policy'),
        changed((draft) => draft['name'] = '其他名称'),
        changed((draft) => draft['kind'] = 'TEMPLATE'),
        changed((draft) => draft['revision'] = copying ? 1 : 4),
        changed((draft) => draft['revision'] = copying ? 2 : 6),
        changed((draft) => draft['sourceVersionId'] = 'wrong-source'),
        changed((draft) => draft['rules'] = _ruleList(draft).reversed.toList()),
        changed((draft) =>
            (_ruleList(draft)[7] as Json)['domain'] = 'other.example.test'),
        changed((draft) => (_ruleList(draft)[5] as Json)['seconds'] = 3600),
      ]) {
        expect(() => branch.committed(invalid), _invalidResponse);
      }
    }
  });

  test(
      'queries preserve the original branch while later draft and source changes remain current facts',
      () {
    for (final copying in [true, false]) {
      final branch = _branch(copying);
      final committed = _receipt(copying);
      final current = _clone(committed)
        ..['revision'] = (committed['revision'] as int) + 3
        ..['name'] = '后来修改的草稿'
        ..['rules'] = <Json>[]
        ..['sourceVersionId'] = 'later-rollback-version';
      Json query({Json? original, Json? latest}) => {
            'requestId': _request,
            'operation': copying ? 'TEMPLATE_COPY' : 'ROLLBACK_DRAFT',
            'committed': original ?? committed,
            'current': latest ?? current,
          };
      final result =
          branch.queryResult(_reverseKeys(query()), requestId: _request);
      expect(result.committed['name'], '分支草稿');
      expect(_ruleList(result.committed), hasLength(9));
      expect(result.current['name'], '后来修改的草稿');
      expect(result.current['sourceVersionId'], 'later-rollback-version');
      expect(_ruleList(result.current), isEmpty);
      expect(
          branch
              .queryResult(query(latest: _clone(committed)),
                  requestId: _request)
              .current,
          result.committed);
      expect(() => result.committed.clear(), throwsUnsupportedError);
      expect(() => result.current.clear(), throwsUnsupportedError);
      expect(() => _ruleList(result.current).add({}), throwsUnsupportedError);
      for (final invalid in <Object?>[
        null,
        {},
        {...query(), 'extra': true},
        {...query(), 'requestId': 'other-request'},
        {...query(), 'operation': copying ? 'ROLLBACK_DRAFT' : 'TEMPLATE_COPY'},
        {...query(), 'committed': null},
        {...query(), 'committed': current},
        query(latest: {...current, 'id': 'other-policy'}),
        query(latest: {...current, 'kind': 'TEMPLATE'}),
        query(latest: {
          ...current,
          'revision': (committed['revision'] as int) - 1
        }),
        query(latest: {...committed, 'name': '同版本篡改'}),
        query(latest: {
          ...committed,
          'sourceVersionId': 'same-version-source-change'
        }),
        query(latest: {
          ...committed,
          'rules': _rules(domain: 'same-version-change.test')
        }),
      ]) {
        expect(() => branch.queryResult(invalid, requestId: _request),
            _invalidResponse);
      }
      final expectedCommitted = _clone(result.committed);
      final expectedCurrent = _clone(result.current);
      _ruleList(committed).clear();
      committed.clear();
      current.clear();
      expect(result.committed, expectedCommitted);
      expect(result.current, expectedCurrent);
    }
  });
}
