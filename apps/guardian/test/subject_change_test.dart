import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/subject_change.dart';

const _id = 'a1111111-1111-4111-8111-111111111111';
const _otherId = 'b2222222-2222-4222-8222-222222222222';
const _maxVersion = 9007199254740991;
Json _before() => {'id': _id, 'nickname': '小星', 'ageBand': 'AGE_7_12',
  'version': 7, 'state': 'ACTIVE'};
Json _values() => {'nickname': '  新昵称  ', 'ageBand': 'AGE_13_17'};
Json _receipt(SubjectChangeDraft draft) => {
  'id': draft.before?['id'] ?? _otherId,
  'nickname': draft.operation == 'ARCHIVE' ? draft.before!['nickname'] : draft.body['nickname'],
  'ageBand': draft.operation == 'ARCHIVE' ? draft.before!['ageBand'] : draft.body['ageBand'],
  'version': draft.before == null ? 0 : (draft.before!['version'] as int) + 1,
  'state': draft.operation == 'ARCHIVE' ? 'ARCHIVED' : 'ACTIVE',
};
List<SubjectChangeDraft> _drafts() => [SubjectChangeDraft.create(_values()),
  SubjectChangeDraft.update(_before(), _values()), SubjectChangeDraft.archive(_before())];
Matcher _failure(int status, String code) => throwsA(isA<ApiFailure>()
    .having((failure) => failure.status, 'status', status)
    .having((failure) => failure.code, 'code', code));

void main() {
  test('three subject changes capture only immutable contract fields and validate input boundaries', () {
    final previous = {..._before(), 'extra': {'private': 'discarded'}};
    final values = {..._values(), 'id': _otherId, 'version': 99, 'state': 'ARCHIVED'};
    final create = SubjectChangeDraft.create(values);
    final update = SubjectChangeDraft.update(previous, values);
    final archive = SubjectChangeDraft.archive(previous);
    previous.clear();
    values.clear();
    expect(create.operation, 'CREATE');
    expect(create.before, isNull);
    expect(create.body, {'operation': 'CREATE', 'nickname': '新昵称', 'ageBand': 'AGE_13_17'});
    expect(update.operation, 'UPDATE');
    expect(update.body, {'operation': 'UPDATE', 'subjectId': _id, 'version': 7,
      'nickname': '新昵称', 'ageBand': 'AGE_13_17'});
    expect(archive.operation, 'ARCHIVE');
    expect(archive.body, {'operation': 'ARCHIVE', 'subjectId': _id, 'version': 7});
    for (final draft in [create, update, archive]) {
      expect(() => draft.body['operation'] = 'OTHER', throwsUnsupportedError);
      if (draft.before != null) {
        expect(draft.before, _before());
        expect(() => draft.before!['nickname'] = '改变', throwsUnsupportedError);
      }
    }
    expect(validateSubjectNickname('  名称  '), isNull);
    expect(validateSubjectNickname(List.filled(30, '🙂').join()), isNull);
    expect(validateSubjectNickname(List.filled(31, '🙂').join()), isNotNull,
        reason: 'The nickname limit follows Java UTF-16 length.');
    expect(validateSubjectNickname(null), isNotNull);
    for (final invalid in <Json>[
      {'nickname': ' ', 'ageBand': 'AGE_7_12'},
      {'nickname': List.filled(61, '字').join(), 'ageBand': 'AGE_7_12'},
      {'nickname': 1, 'ageBand': 'AGE_7_12'},
      {'nickname': '小星', 'ageBand': 'OTHER'},
    ]) {
      expect(() => SubjectChangeDraft.create(invalid), _failure(400, 'VALIDATION_FAILED'));
      expect(() => SubjectChangeDraft.update(_before(), invalid), _failure(400, 'VALIDATION_FAILED'));
    }
    for (final before in [
      {..._before(), 'state': 'ARCHIVED'}, {..._before(), 'version': _maxVersion},
      {..._before(), 'version': 7.0},
    ]) {
      expect(() => SubjectChangeDraft.update(before, _values()), _failure(502, 'INVALID_RESPONSE'));
      expect(() => SubjectChangeDraft.archive(before), _failure(502, 'INVALID_RESPONSE'));
    }
    final boundary = SubjectChangeDraft.archive({..._before(), 'version': _maxVersion - 1});
    expect(boundary.committed({..._before(), 'version': _maxVersion,
      'state': 'ARCHIVED'})['version'], _maxVersion);
  });

  test('original receipts must match operation identity, exact next version and captured name and age', () {
    for (final draft in _drafts()) {
      final source = {..._receipt(draft), 'extra': {'private': 'discarded'}};
      final snapshot = draft.committed(source);
      source.clear();
      expect(snapshot, _receipt(draft));
      expect(snapshot.keys, unorderedEquals(['id', 'nickname', 'ageBand', 'version', 'state']));
      expect(() => snapshot['nickname'] = '改变', throwsUnsupportedError);
      final expected = _receipt(draft);
      for (final invalid in <Object?>[
        null, [], {...expected, 'id': 'BAD'},
        {...expected, 'state': draft.operation == 'ARCHIVE' ? 'ACTIVE' : 'ARCHIVED'},
        {...expected, 'version': (expected['version'] as int) + 1},
        {...expected, 'nickname': '其他昵称'},
        {...expected, 'ageBand': expected['ageBand'] == 'UNDER_7' ? 'AGE_7_12' : 'UNDER_7'},
      ]) {
        expect(() => draft.committed(invalid), _failure(502, 'INVALID_RESPONSE'));
      }
      if (draft.before != null) {
        expect(() => draft.committed({...expected, 'id': _otherId}),
            _failure(502, 'INVALID_RESPONSE'));
      }
    }
    for (final invalid in <Object?>[
      null, [], {..._before(), 'id': _id.toUpperCase()},
      {..._before(), 'nickname': ''}, {..._before(), 'nickname': {'private': 'raw'}},
      {..._before(), 'nickname': List.filled(61, '字').join()},
      {..._before(), 'ageBand': 'OTHER'}, {..._before(), 'version': -1},
      {..._before(), 'version': _maxVersion + 1}, {..._before(), 'version': 7.0},
      {..._before(), 'state': 'OTHER'},
    ]) {
      expect(() => readSubjectSnapshot(invalid), _failure(502, 'INVALID_RESPONSE'));
    }
    expect(() => readSubjectSnapshot(_before(), expectedId: _otherId),
        _failure(502, 'INVALID_RESPONSE'));
  });

  test('queries separate original receipts from later edits or archives and reject same-version changes', () {
    for (final draft in _drafts()) {
      final committed = _receipt(draft);
      for (final state in draft.operation == 'ARCHIVE' ? ['ARCHIVED'] : ['ACTIVE', 'ARCHIVED']) {
        final latest = {...committed, 'nickname': '当前昵称', 'ageBand': 'UNDER_7',
          'version': (committed['version'] as int) + 2, 'state': state};
        final source = {'operation': draft.operation, 'committed': committed, 'current': latest};
        final result = draft.queryResult(source);
        expect(result.committed, committed);
        expect(result.current, latest);
        latest.clear();
        expect(result.current['nickname'], '当前昵称');
        expect(result.committed['nickname'], isNot('当前昵称'));
        expect(() => result.current['version'] = 99, throwsUnsupportedError);
        expect(() => result.committed['version'] = 99, throwsUnsupportedError);
      }
      final unchanged = draft.queryResult({'operation': draft.operation,
        'committed': committed, 'current': {...committed}});
      expect(unchanged.current, unchanged.committed);
      for (final invalid in <Object?>[
        null, [], {'operation': 'OTHER', 'committed': committed, 'current': committed},
        {'operation': draft.operation, 'committed': {...committed, 'nickname': '其他'}, 'current': committed},
        {'operation': draft.operation, 'committed': committed,
          'current': {...committed, 'id': committed['id'] == _id ? _otherId : _id}},
        {'operation': draft.operation, 'committed': committed,
          'current': {...committed, 'version': (committed['version'] as int) - 1}},
        {'operation': draft.operation, 'committed': committed,
          'current': {...committed, 'nickname': '同版本改变'}},
        {'operation': draft.operation, 'committed': committed,
          'current': {...committed, 'ageBand': 'UNDER_7'}},
        {'operation': draft.operation, 'committed': committed,
          'current': {...committed, 'state': draft.operation == 'ARCHIVE' ? 'ACTIVE' : 'ARCHIVED'}},
      ]) {
        expect(() => draft.queryResult(invalid), _failure(502, 'INVALID_RESPONSE'));
      }
      if (draft.operation == 'ARCHIVE') {
        expect(() => draft.queryResult({'operation': 'ARCHIVE', 'committed': committed,
          'current': {...committed, 'version': (committed['version'] as int) + 1, 'state': 'ACTIVE'}}),
            _failure(502, 'INVALID_RESPONSE'));
      }
    }
  });
}
