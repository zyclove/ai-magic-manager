import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/quota_pool_change.dart';

const _request = '11111111-1111-4111-8111-111111111111';
Json _form({int minutes = 60, bool application = false}) => {
  'name': '  每日额度  ', 'subjectId': 'subject-opaque',
  'applicationId': application ? 'application-opaque' : '',
  'periodId': '2026-11-01', 'timeZone': 'America/New_York', 'minutes': minutes,
};
Json _pool({int limit = 3600, int used = 0, int reserved = 0, int version = 0,
    bool application = false, bool planned = false}) => {
  'id': 'pool-opaque', 'subjectId': 'subject-opaque', 'name': '每日额度',
  'scope': application ? 'APPLICATION' : 'TOTAL',
  'applicationId': application ? 'application-opaque' : null,
  'periodId': '2026-11-01', 'timeZone': 'America/New_York',
  'periodStart': 1793505600000, 'periodEnd': 1793595600000,
  'limitSeconds': limit, 'usedSeconds': used, 'reservedSeconds': reserved,
  'availableSeconds': limit - used - reserved, 'status': 'CONFIGURED',
  'evidenceStatus': 'LEDGER_ONLY', 'version': version,
  'planId': planned ? 'plan-opaque' : null, 'planVersion': planned ? 3 : null,
};
Json _clone(Json value) => jsonDecode(jsonEncode(value)) as Json;
Json _reverseKeys(Json value) => {
  for (final key in value.keys.toList().reversed) key: value[key],
};
Matcher _failure(int status, String code) => throwsA(isA<ApiFailure>()
    .having((failure) => failure.status, 'status', status)
    .having((failure) => failure.code, 'code', code));
Matcher get _invalidInput => _failure(400, 'VALIDATION_FAILED');
Matcher get _invalidDuration => _failure(400, 'INVALID_QUOTA_DURATION');
Matcher get _balanceConflict => _failure(400, 'QUOTA_BALANCE_CONFLICT');
Matcher get _invalidResponse => _failure(502, 'INVALID_QUOTA_POOL_RESPONSE');

void main() {
  test('creation and ledger snapshots keep zero, 24 hours, DST and immutable facts', () {
    for (final minutes in [0, 1440]) {
      for (final application in [false, true]) {
        final form = _form(minutes: minutes, application: application);
        final change = QuotaPoolChange.create(form);
        final expected = {
          'name': '每日额度', 'subjectId': 'subject-opaque',
          'scope': application ? 'APPLICATION' : 'TOTAL',
          if (application) 'applicationId': 'application-opaque',
          'periodId': '2026-11-01', 'timeZone': 'America/New_York',
          'limitSeconds': minutes * 60,
        };
        expect(change.body, expected);
        expect(() => change.body.clear(), throwsUnsupportedError);
        form.clear();
        expect(change.body, expected);
        final result = change.committed(_pool(limit: minutes * 60,
            application: application));
        expect(result['availableSeconds'], minutes * 60);
        expect(result['status'], 'CONFIGURED');
        expect(result['evidenceStatus'], 'LEDGER_ONLY');
        expect(result, hasLength(18));
        expect(() => result['limitSeconds'] = 1, throwsUnsupportedError);
      }
    }
    expect(QuotaPoolChange.create({..._form(), 'applicationId': null}).body['scope'],
        'TOTAL');
    final noApplication = _form()..remove('applicationId');
    expect(QuotaPoolChange.create(noApplication).body.containsKey('applicationId'), isFalse);
    for (final seconds in [1, 59]) {
      final change = QuotaPoolChange.create({..._form(minutes: 0), 'seconds': seconds});
      expect(change.body['limitSeconds'], seconds);
      expect(change.body.containsKey('seconds'), isFalse);
      expect(change.committed(_pool(limit: seconds))['availableSeconds'], seconds);
    }
    expect(QuotaPoolChange.create({..._form(), 'seconds': null}).body['limitSeconds'], 3600);
    expect(() => QuotaPoolChange.create({..._form(minutes: 1440), 'seconds': 1}),
        _invalidDuration);
    expect(quotaPoolPeriodError('2000-02-29'), isNull);
    for (final date in [null, '', '1900-02-29', '2026-02-30', '2026-13-01', '2026-01-01\n']) {
      expect(quotaPoolPeriodError(date), contains('yyyy-MM-dd'));
    }
    for (final day in const [
      ('2026-03-08', 1772946000000, 1773028800000, 23),
      ('2026-11-01', 1793505600000, 1793595600000, 25),
    ]) {
      final raw = {..._pool(), 'periodId': day.$1,
        'periodStart': day.$2, 'periodEnd': day.$3};
      final result = readQuotaPoolSnapshot(raw, expectedId: 'pool-opaque');
      raw.clear();
      expect(result['periodEnd'] - result['periodStart'], day.$4 * 3600000);
      expect(() => result.clear(), throwsUnsupportedError);
    }
    for (final invalid in <Json>[
      {}, {..._form(), 'name': ' '}, {..._form(), 'subjectId': null},
      {..._form(), 'applicationId': true}, {..._form(), 'applicationId': ' '},
      {..._form(), 'timeZone': ''}, {..._form(), 'periodId': '2026-02-29'},
      {..._form(), 'periodId': '1900-02-29'}, {..._form(), 'periodId': '2026-04-31'},
      {..._form(), 'periodId': '2026-1-01'}, {..._form(), 'minutes': null},
      {..._form(), 'minutes': -1}, {..._form(), 'minutes': 1441},
      {..._form(), 'minutes': 1.5}, {..._form(), 'minutes': '60'},
      {..._form(), 'seconds': -1}, {..._form(), 'seconds': 60},
      {..._form(), 'seconds': 1.5}, {..._form(), 'seconds': '1'},
      {..._form(), 'scope': 'TOTAL'},
    ]) {
      expect(() => QuotaPoolChange.create(invalid), _invalidInput);
    }
    Json changed(void Function(Json) mutate) {
      final value = _pool();
      mutate(value);
      return value;
    }
    for (final invalid in <Object?>[
      null, [], {},
      changed((pool) => pool.remove('applicationId')),
      changed((pool) => pool.remove('planId')),
      changed((pool) => pool.remove('planVersion')),
      changed((pool) => pool['scope'] = 'APPLICATION'),
      changed((pool) => pool['applicationId'] = 'wrong-for-total'),
      changed((pool) => pool['periodId'] = '2026-02-30'),
      changed((pool) => pool['limitSeconds'] = 86401),
      changed((pool) => pool['usedSeconds'] = -1),
      changed((pool) => pool['reservedSeconds'] = true),
      changed((pool) => pool['availableSeconds'] = 3599),
      changed((pool) => pool['availableSeconds'] = 3600.5),
      changed((pool) => pool['periodStart'] = -1),
      changed((pool) => pool['periodEnd'] = pool['periodStart']),
      changed((pool) => pool['periodEnd'] = 9007199254740992),
      changed((pool) => pool['periodEnd'] = 8640000000000001),
      changed((pool) {
        pool['periodStart'] = 8640000000000001;
        pool['periodEnd'] = 8640000000000002;
      }),
      changed((pool) => pool['version'] = 1.5),
      changed((pool) => pool['version'] = 9007199254740992),
      changed((pool) => pool['status'] = 'ENFORCED'),
      changed((pool) => pool['evidenceStatus'] = 'EXECUTED'),
      changed((pool) => pool['planId'] = 'unpaired-plan'),
      changed((pool) => pool['planVersion'] = 0),
      changed((pool) { pool['planId'] = 'plan'; pool['planVersion'] = -1; }),
    ]) {
      expect(() => readQuotaPoolSnapshot(invalid), _invalidResponse);
    }
    final ledger = <String, dynamic>{
      'id': 'entry-opaque', 'leaseId': 'lease-opaque', 'kind': 'SETTLED',
      'limitDelta': 0, 'usedDelta': 59, 'reservedDelta': -59,
      'sequence': 1, 'reason': null, 'occurredAt': 1793505600000,
    };
    final entry = readQuotaLedgerEntry(ledger);
    expect(entry, ledger);
    expect(entry, hasLength(9));
    expect(() => entry.clear(), throwsUnsupportedError);
    for (final kind in ['CREATED', 'ADJUSTED', 'RESERVED', 'SETTLED', 'RELEASED']) {
      expect(readQuotaLedgerEntry({...ledger, 'kind': kind})['kind'], kind);
    }
    for (final invalid in <Object?>[
      null, {}, {...ledger, 'id': ''}, {...ledger, 'leaseId': ' '},
      {...ledger, 'kind': 'EXECUTED'}, {...ledger, 'limitDelta': -86401},
      {...ledger, 'limitDelta': 86401}, {...ledger, 'usedDelta': -1},
      {...ledger, 'reservedDelta': 1.5}, {...ledger, 'sequence': -1},
      {...ledger, 'sequence': '1'}, {...ledger, 'reason': false},
      {...ledger, 'occurredAt': 9007199254740992},
      {...ledger, 'occurredAt': 8640000000000001},
    ]) {
      expect(() => readQuotaLedgerEntry(invalid), _invalidResponse);
    }
    ledger.clear();
    expect(entry['usedDelta'], 59);
  });

  test('adjustments honor reserved seconds and receipts require the exact original mutation', () {
    final before = _pool(used: 59, reserved: 1, version: 4, planned: true);
    final adjust = QuotaPoolChange.adjust(before, {'direction': 'SUBTRACT', 'minutes': 59});
    expect(adjust.body, {'deltaSeconds': -3540, 'reason': 'CORRECTION'});
    expect(() => adjust.body.clear(), throwsUnsupportedError);
    expect(QuotaPoolChange.adjust(before, {'direction': 'ADD', 'minutes': 1380}).body,
        {'deltaSeconds': 82800, 'reason': 'EXTRA_TIME'});
    expect(() => QuotaPoolChange.adjust(before,
        {'direction': 'SUBTRACT', 'minutes': 60}), _balanceConflict);
    expect(() => QuotaPoolChange.adjust(before,
        {'direction': 'ADD', 'minutes': 1381}), _balanceConflict);
    expect(QuotaPoolChange.adjust(_pool(limit: 0),
        {'direction': 'ADD', 'minutes': 1440}).body['deltaSeconds'], 86400);
    expect(QuotaPoolChange.adjust(_pool(limit: 86400),
        {'direction': 'SUBTRACT', 'minutes': 1440}).body['deltaSeconds'], -86400);
    for (final seconds in [1, 59]) {
      expect(QuotaPoolChange.adjust(before, {
        'direction': 'ADD', 'minutes': 0, 'seconds': seconds,
      }).body, {'deltaSeconds': seconds, 'reason': 'EXTRA_TIME'});
      expect(QuotaPoolChange.adjust(before, {
        'direction': 'SUBTRACT', 'minutes': 0, 'seconds': seconds,
      }).body, {'deltaSeconds': -seconds, 'reason': 'CORRECTION'});
    }
    expect(QuotaPoolChange.adjust(before, {'direction': 'ADD',
      'minutes': 1, 'seconds': null}).body['deltaSeconds'], 60);
    expect(() => QuotaPoolChange.adjust(before,
        {'direction': 'ADD', 'minutes': 0}), _invalidDuration);
    expect(() => QuotaPoolChange.adjust(before,
        {'direction': 'SUBTRACT', 'minutes': 0, 'seconds': null}), _invalidDuration);
    expect(() => QuotaPoolChange.adjust(before,
        {'direction': 'ADD', 'minutes': 1440, 'seconds': 1}), _invalidDuration);
    for (final values in <Json>[
      {}, {'direction': 'ADD', 'minutes': 1441},
      {'direction': 'OTHER', 'minutes': 1}, {'direction': 'SUBTRACT', 'minutes': 1.5},
      {'direction': 'ADD', 'minutes': '1'},
      {'direction': 'ADD', 'minutes': 0, 'seconds': 60},
    ]) {
      expect(() => QuotaPoolChange.adjust(before, values), _invalidInput);
    }
    expect(() => QuotaPoolChange.adjust({...before, 'version': 9007199254740991},
        {'direction': 'ADD', 'minutes': 1}), _invalidInput);
    before.clear();
    final originalAdjustment = _pool(limit: 60, used: 59, reserved: 1,
        version: 5, planned: true);
    final changes = [QuotaPoolChange.create(_form()), adjust];
    for (var index = 0; index < changes.length; index++) {
      final change = changes[index];
      final raw = index == 0 ? _pool() : _clone(originalAdjustment);
      final result = change.committed(_reverseKeys(raw));
      final expected = _clone(result);
      raw.clear();
      expect(result, expected);
      expect(() => result.clear(), throwsUnsupportedError);
      Json changed(void Function(Json) mutate) {
        final value = _clone(expected);
        mutate(value);
        return value;
      }
      for (final invalid in <Object?>[
        null, {},
        changed((pool) => pool['name'] = '另一个额度'),
        changed((pool) => pool['subjectId'] = 'other-subject'),
        changed((pool) { pool['scope'] = 'APPLICATION'; pool['applicationId'] = 'other-app'; }),
        changed((pool) => pool['periodId'] = '2026-11-02'),
        changed((pool) => pool['timeZone'] = 'UTC'),
        if (index == 1) changed((pool) => pool['periodStart'] += 1),
        if (index == 1) changed((pool) => pool['periodEnd'] += 1),
        changed((pool) => pool['version'] = index == 0 ? 1 : 6),
        changed((pool) { pool['planId'] = 'other-plan'; pool['planVersion'] = 0; }),
        changed((pool) { pool['limitSeconds'] += 1; pool['availableSeconds'] += 1; }),
        changed((pool) {
          if (index == 0) {
            pool['usedSeconds'] = 1;
            pool['availableSeconds'] -= 1;
          } else {
            pool['usedSeconds'] = 58;
            pool['reservedSeconds'] = 2;
          }
        }),
      ]) {
        expect(() => change.committed(invalid), _invalidResponse);
      }
    }
  });

  test('queries prove the original operation independently of later valid ledger balances', () {
    for (final creating in [true, false]) {
      final before = _pool(used: 59, reserved: 1, version: 4, planned: true);
      final change = creating ? QuotaPoolChange.create(_form())
          : QuotaPoolChange.adjust(before, {'direction': 'ADD', 'minutes': 1});
      final committed = creating ? _pool()
          : _pool(limit: 3660, used: 59, reserved: 1, version: 5, planned: true);
      final current = _clone(committed)
        ..['version'] = (committed['version'] as int) + 3
        ..['limitSeconds'] = 4000
        ..['usedSeconds'] = 300
        ..['reservedSeconds'] = 100
        ..['availableSeconds'] = 3600;
      Json query({Json? original, Json? latest}) => {
        'requestId': _request, 'operation': creating ? 'CREATE' : 'ADJUST',
        'committed': original ?? committed, 'current': latest ?? current,
      };
      final result = change.queryResult(query(), requestId: _request);
      expect(result.committed['limitSeconds'], creating ? 3600 : 3660);
      expect(result.current['limitSeconds'], 4000);
      expect(result.current['usedSeconds'], 300);
      expect(change.queryResult(query(latest: _clone(committed)), requestId: _request)
          .current, result.committed);
      expect(() => result.committed.clear(), throwsUnsupportedError);
      expect(() => result.current.clear(), throwsUnsupportedError);
      Json changedCurrent(void Function(Json) mutate) {
        final value = _clone(current);
        mutate(value);
        return value;
      }
      for (final invalid in <Object?>[
        null, {}, {...query(), 'extra': true},
        {...query(), 'requestId': 'other-request'},
        {...query(), 'operation': creating ? 'ADJUST' : 'CREATE'},
        {...query(), 'committed': null}, {...query(), 'committed': current},
        query(latest: changedCurrent((pool) => pool['id'] = 'other-pool')),
        query(latest: changedCurrent((pool) => pool['name'] = 'other-name')),
        query(latest: changedCurrent((pool) => pool['subjectId'] = 'other-subject')),
        query(latest: changedCurrent((pool) => pool['timeZone'] = 'UTC')),
        query(latest: changedCurrent((pool) => pool['periodEnd'] += 1)),
        query(latest: changedCurrent((pool) {
          pool['planId'] = 'other-plan'; pool['planVersion'] = 1;
        })),
        query(latest: changedCurrent((pool) =>
            pool['version'] = (committed['version'] as int) - 1)),
        query(latest: {...current, 'version': committed['version']}),
      ]) {
        expect(() => change.queryResult(invalid, requestId: _request), _invalidResponse);
      }
      final expectedCommitted = _clone(result.committed);
      final expectedCurrent = _clone(result.current);
      committed.clear();
      current.clear();
      expect(result.committed, expectedCommitted);
      expect(result.current, expectedCurrent);
    }
  });
}
