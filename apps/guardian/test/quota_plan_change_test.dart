import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/quota_plan_change.dart';

const _request = '11111111-1111-4111-8111-111111111111';
const _days = ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY',
  'FRIDAY', 'SATURDAY', 'SUNDAY'];
Json _weekly() => Map<String, dynamic>.fromIterables(
    _days, [0, 1, 59, 60, 61, 86399, 86400]);
Json _create({bool application = false}) => {
  'name': '每天额度', 'subjectId': 'subject-opaque',
  'scope': application ? 'APPLICATION' : 'TOTAL',
  if (application) 'applicationId': 'application-opaque',
  'timeZone': 'Asia/Shanghai', 'effectiveFrom': '2026-10-27',
  'weeklyLimits': _weekly(),
  'dateOverrides': {'2024-02-29': 1, '2026-10-28': 0, '2026-10-29': 86400},
};
Json _update() => {
  'name': '修改后的额度', 'state': 'PAUSED', 'weeklyLimits': _weekly(),
  'dateOverrides': {'2026-10-29': 61},
};
Json _snapshot({bool application = false, int version = 0}) => {
  ..._create(application: application), 'applicationId': application
      ? 'application-opaque' : null,
  'id': 'plan-opaque', 'state': 'ACTIVE', 'version': version,
  'createdAt': 1793059200000,
};
Json _clone(Json value) => jsonDecode(jsonEncode(value)) as Json;
Json _week(Json value) => value['weeklyLimits'] as Json;
Json _dates(Json value) => value['dateOverrides'] as Json;
Object? _reverseKeys(Object? value) => value is Json
    ? <String, dynamic>{for (final key in value.keys.toList().reversed)
        key: _reverseKeys(value[key])} : value;
Matcher _failure(int status, String code) => throwsA(isA<ApiFailure>()
    .having((failure) => failure.status, 'status', status)
    .having((failure) => failure.code, 'code', code));
Matcher get _invalidInput => _failure(400, 'VALIDATION_FAILED');
Matcher get _invalidResponse => _failure(502, 'INVALID_QUOTA_PLAN_RESPONSE');

void main() {
  test('inputs and snapshots preserve seconds, calendar dates and deeply frozen maps', () {
    for (final application in [false, true]) {
      final body = _create(application: application);
      final change = QuotaPlanChange.create(body);
      final expected = _clone(body);
      expect(change.body, expected);
      expect(_week(change.body).values.toList(), [0, 1, 59, 60, 61, 86399, 86400]);
      expect(_dates(change.body)['2024-02-29'], 1);
      expect(() => change.body.clear(), throwsUnsupportedError);
      expect(() => _week(change.body)['MONDAY'] = 60, throwsUnsupportedError);
      expect(() => _dates(change.body).clear(), throwsUnsupportedError);
      _week(body).clear();
      _dates(body).clear();
      body.clear();
      expect(change.body, expected);
      final raw = _snapshot(application: application);
      final snapshot = readQuotaPlanSnapshot(raw, expectedId: 'plan-opaque');
      expect(() => snapshot.clear(), throwsUnsupportedError);
      expect(() => _week(snapshot).clear(), throwsUnsupportedError);
      expect(() => _dates(snapshot).clear(), throwsUnsupportedError);
      raw.clear();
      expect(snapshot['subjectId'], 'subject-opaque');
      expect(_week(snapshot)['SUNDAY'], 86400);
    }
    expect(QuotaPlanChange.create({..._create(), 'applicationId': null}).body,
        {..._create(), 'applicationId': null});
    final before = _snapshot(version: 4);
    final update = QuotaPlanChange.update(before, _update());
    before['subjectId'] = 'other-subject';
    before['createdAt'] = 0;
    before['version'] = 99;
    expect(update.body.keys.toSet(), {'name', 'state', 'weeklyLimits', 'dateOverrides'});
    expect(update.committed({..._snapshot(version: 5), ..._update(),
      'effectiveFrom': '2026-11-01'})['createdAt'], 1793059200000);
    expect(() => update.body.clear(), throwsUnsupportedError);
    expect(() => _week(update.body).clear(), throwsUnsupportedError);
    final rawCalendar = <String, dynamic>{
      'timeZone': 'America/New_York', 'currentDate': '2024-02-29',
    };
    final calendar = readQuotaPlanCalendar(rawCalendar);
    rawCalendar.clear();
    expect(calendar, {'timeZone': 'America/New_York', 'currentDate': '2024-02-29'});
    expect(() => calendar.clear(), throwsUnsupportedError);
    expect(() => readQuotaPlanCalendar({'currentDate': '2026-10-27'}),
        _invalidResponse);
    expect(() => readQuotaPlanCalendar({'timeZone': ' ',
      'currentDate': '2026-10-27'}), _invalidResponse);

    for (final date in ['2026-02-29', '1900-02-29', '2024-02-30', '2026-04-31',
      '2026-00-01', '2026-13-01', '2026-01-00', '2026-1-01', '2026-01-01\n']) {
      expect(() => QuotaPlanChange.create({..._create(), 'effectiveFrom': date}),
          _invalidInput);
      expect(() => readQuotaPlanSnapshot({..._snapshot(), 'effectiveFrom': date}),
          _invalidResponse);
      expect(() => readQuotaPlanCalendar({'timeZone': 'Asia/Shanghai',
        'currentDate': date}), _invalidResponse);
    }
    expect(QuotaPlanChange.create({..._create(), 'effectiveFrom': '2000-02-29'})
        .body['effectiveFrom'], '2000-02-29');
    final sixtyDates = <String, dynamic>{
      for (var day = 1; day <= 60; day++)
        '2027-${day <= 31 ? '03' : '04'}-'
        '${(day <= 31 ? day : day - 31).toString().padLeft(2, '0')}': day,
    };
    expect(_dates(QuotaPlanChange.create({..._create(),
      'dateOverrides': sixtyDates}).body), hasLength(60));
    for (final invalid in <Json>[
      {}, {..._create(), 'unexpected': true}, {..._create(), 'name': ' '},
      {..._create(), 'name': List.filled(101, 'a').join()},
      {..._create(), 'subjectId': ''}, {..._create(), 'scope': 'UNKNOWN'},
      {..._create(), 'applicationId': 'wrong-for-total'},
      {..._create(application: true), 'applicationId': null},
      {..._create(), 'timeZone': List.filled(101, 'a').join()},
      {..._create(), 'weeklyLimits': null},
      {..._create(), 'weeklyLimits': {..._weekly()}..remove('MONDAY')},
      {..._create(), 'weeklyLimits': {..._weekly(), 'EXTRA': 0}},
      {..._create(), 'weeklyLimits': {..._weekly(), 'MONDAY': -1}},
      {..._create(), 'weeklyLimits': {..._weekly(), 'MONDAY': 86401}},
      {..._create(), 'weeklyLimits': {..._weekly(), 'MONDAY': 1.5}},
      {..._create(), 'weeklyLimits': {..._weekly(), 'MONDAY': '60'}},
      {..._create(), 'dateOverrides': {'2026-02-30': 60}},
      {..._create(), 'dateOverrides': {'2026-10-27': -1}},
      {..._create(), 'dateOverrides': {'2026-10-27': 86401}},
      {..._create(), 'dateOverrides': {'2026-10-27': true}},
      {..._create(), 'dateOverrides': {...sixtyDates, '2027-05-01': 0}},
    ]) {
      expect(() => QuotaPlanChange.create(invalid), _invalidInput);
    }
    expect(() => QuotaPlanChange.update(_snapshot(version: 9007199254740991),
        _update()), _invalidInput);
    expect(() => QuotaPlanChange.update(_snapshot(), {..._update(),
        'effectiveFrom': '2026-10-28'}), _invalidInput);
  });

  test('committed receipts require complete original configuration and exact next version', () {
    for (final creating in [true, false]) {
      for (final application in [false, true]) {
        final change = creating
            ? QuotaPlanChange.create(_create(application: application))
            : QuotaPlanChange.update(_snapshot(application: application, version: 4), _update());
        final receipt = creating ? _snapshot(application: application) : {
          ..._snapshot(application: application, version: 5), ..._update(),
          'effectiveFrom': '2026-11-01',
        };
        final result = change.committed(_reverseKeys(receipt));
        final expected = _clone(result);
        expect(result['version'], creating ? 0 : 5);
        expect(result['effectiveFrom'], creating ? '2026-10-27' : '2026-11-01');
        expect(() => result.clear(), throwsUnsupportedError);
        expect(() => _week(result).clear(), throwsUnsupportedError);
        expect(() => _dates(result).clear(), throwsUnsupportedError);
        _week(receipt).clear();
        receipt.clear();
        expect(result, expected);
        Json changed(void Function(Json) mutate) {
          final value = _clone(expected);
          mutate(value);
          return value;
        }
        for (final invalid in <Object?>[
          null, [], {},
          changed((plan) => plan['id'] = ''),
          if (!creating) changed((plan) => plan['id'] = 'other-plan'),
          changed((plan) => plan['subjectId'] = 'other-subject'),
          changed((plan) => plan['scope'] = 'UNKNOWN'),
          changed((plan) => plan['applicationId'] = 'other-application'),
          changed((plan) => plan['timeZone'] = 'UTC'),
          changed((plan) => plan['name'] = 'other-name'),
          changed((plan) => plan['state'] = creating ? 'PAUSED' : 'ACTIVE'),
          changed((plan) => plan['version'] = creating ? 1 : 4),
          changed((plan) => plan['version'] = creating ? 2 : 6),
          changed((plan) => plan['version'] = 5.5),
          changed((plan) => plan['createdAt'] = -1),
          changed((plan) => plan['createdAt'] = 9007199254740992),
          if (!creating) changed((plan) => plan['createdAt'] = 0),
          changed((plan) => plan['effectiveFrom'] = '2026-02-30'),
          if (creating) changed((plan) => plan['effectiveFrom'] = '2026-10-28'),
          changed((plan) => _week(plan)['TUESDAY'] = 60),
          changed((plan) => _dates(plan)['2026-10-29'] = 30),
          changed((plan) => plan.remove('weeklyLimits')),
        ]) {
          expect(() => change.committed(invalid), _invalidResponse);
        }
      }
    }
  });

  test('queries bind request and original receipt while later configurations remain current facts', () {
    for (final creating in [true, false]) {
      final change = creating ? QuotaPlanChange.create(_create(application: true))
          : QuotaPlanChange.update(_snapshot(application: true, version: 4), _update());
      final committed = creating ? _snapshot(application: true) : {
        ..._snapshot(application: true, version: 5), ..._update(),
        'effectiveFrom': '2026-11-01',
      };
      final current = _clone(committed)
        ..['version'] = (committed['version'] as int) + 3
        ..['name'] = '后续保存的配置'
        ..['state'] = creating ? 'PAUSED' : 'ACTIVE'
        ..['effectiveFrom'] = '2026-12-01'
        ..['weeklyLimits'] = {for (final day in _days) day: 3600}
        ..['dateOverrides'] = <String, dynamic>{};
      Json query({Json? original, Json? latest}) => {
        'requestId': _request, 'operation': creating ? 'PLAN_CREATE' : 'PLAN_UPDATE',
        'committed': original ?? committed, 'current': latest ?? current,
      };
      final result = change.queryResult(_reverseKeys(query()), requestId: _request);
      expect(result.committed['name'], creating ? '每天额度' : '修改后的额度');
      expect(result.current['name'], '后续保存的配置');
      expect(result.current['effectiveFrom'], '2026-12-01');
      expect(change.queryResult(query(latest: _clone(committed)), requestId: _request)
          .current, result.committed);
      expect(() => result.committed.clear(), throwsUnsupportedError);
      expect(() => _week(result.committed).clear(), throwsUnsupportedError);
      expect(() => result.current.clear(), throwsUnsupportedError);
      expect(() => _dates(result.current).clear(), throwsUnsupportedError);
      Json changedCurrent(void Function(Json) mutate) {
        final value = _clone(current);
        mutate(value);
        return value;
      }
      for (final invalid in <Object?>[
        null, {}, {...query(), 'extra': true},
        {...query(), 'requestId': 'other-request'},
        {...query(), 'operation': creating ? 'PLAN_UPDATE' : 'PLAN_CREATE'},
        {...query(), 'committed': null}, {...query(), 'committed': current},
        query(latest: changedCurrent((plan) => plan['id'] = 'other-plan')),
        query(latest: changedCurrent((plan) => plan['subjectId'] = 'other-subject')),
        query(latest: changedCurrent((plan) => plan['applicationId'] = 'other-app')),
        query(latest: changedCurrent((plan) => plan['timeZone'] = 'UTC')),
        query(latest: changedCurrent((plan) => plan['createdAt'] = 0)),
        query(latest: changedCurrent((plan) {
          plan['scope'] = 'TOTAL';
          plan['applicationId'] = null;
        })),
        query(latest: changedCurrent((plan) =>
            plan['version'] = (committed['version'] as int) - 1)),
        query(latest: {...committed, 'name': '同版本内容被改变'}),
        query(latest: {...committed, 'effectiveFrom': '2026-12-01'}),
        query(latest: {...committed, 'weeklyLimits': _week(current)}),
      ]) {
        expect(() => change.queryResult(invalid, requestId: _request), _invalidResponse);
      }
      final expectedCommitted = _clone(result.committed);
      final expectedCurrent = _clone(result.current);
      _week(committed).clear();
      committed.clear();
      current.clear();
      expect(result.committed, expectedCommitted);
      expect(result.current, expectedCurrent);
    }
  });
}
