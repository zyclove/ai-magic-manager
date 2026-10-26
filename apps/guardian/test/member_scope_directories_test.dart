import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/member_scope_directories.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const root = '/tenants/workspace';

http.Response page(List<Json> items, {String? cursor}) => http.Response(
    jsonEncode({'items': items, 'nextCursor': cursor}), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Api api(FutureOr<http.Response> Function(http.Request) handle) {
  final client = MockClient((request) async {
    expect(request.method, 'GET');
    return handle(request);
  });
  addTearDown(client.close);
  return Api(() async => client);
}

Matcher get lost => isA<ApiFailure>()
    .having((failure) => failure.code, 'code', 'WORKSPACE_CHANGED');

void main() {
  test('lazy caches coalesce paged reads and retain immutable active options only', () async {
    final firstSubjects = Completer<http.Response>();
    addTearDown(() {
      if (!firstSubjects.isCompleted) firstSubjects.complete(page([]));
    });
    final requests = <http.Request>[];
    var subjectReads = 0;
    final directories = MemberScopeDirectories(api: api((request) {
      requests.add(request);
      if (request.url.path.endsWith('/classes')) {
        return page([
          {'id': 'c1', 'name': '七年级一班', 'state': 'ACTIVE', 'private': 'discard'},
          {'id': 'archived-class', 'name': '旧班级', 'state': 'ARCHIVED'},
        ]);
      }
      subjectReads++;
      if (subjectReads == 1) return firstSubjects.future;
      if (request.url.queryParameters['cursor'] == 'subjects-next') {
        return page([
          {'id': 's2', 'nickname': '小雨', 'version': 9},
          {'id': 'archived-at', 'nickname': '旧档案乙', 'archivedAt': 1},
        ]);
      }
      return page([]);
    }), root: root, current: () => true);
    expect(directories.subjects, isNull);
    expect(directories.classes, isNull);
    expect(requests, isEmpty);
    final first = directories.load(MemberScopeDirectory.subjects);
    final duplicate = directories.load(MemberScopeDirectory.subjects);
    final classes = directories.load(MemberScopeDirectory.classes);
    await Future<void>.delayed(Duration.zero);
    expect(requests.where((r) => r.url.path.endsWith('/subjects')), hasLength(1));
    firstSubjects.complete(page([
      {'id': 's1', 'nickname': '小明', 'private': 'discard'},
      {'id': 'archived-flag', 'nickname': '旧档案甲', 'archived': true},
    ], cursor: 'subjects-next'));
    await Future.wait([first, duplicate, classes]);
    expect(directories.subjects, {'s1': '小明', 's2': '小雨'});
    expect(directories.classes, {'c1': '七年级一班'});
    expect(() => directories.subjects!['new'] = '改名', throwsUnsupportedError);
    expect(() => directories.classes!.clear(), throwsUnsupportedError);
    expect(requests.map((r) => r.url.queryParameters['limit']), everyElement('50'));
    expect(requests.where((r) => r.url.path.endsWith('/subjects'))
        .map((r) => r.url.queryParameters['cursor']), [null, 'subjects-next']);
    await directories.load(MemberScopeDirectory.subjects);
    await directories.load(MemberScopeDirectory.classes);
    expect(requests, hasLength(3));
    final retainedClasses = directories.classes;
    await directories.load(MemberScopeDirectory.subjects, refresh: true);
    expect(directories.subjects, isNotNull);
    expect(directories.subjects, isEmpty);
    expect(identical(directories.classes, retainedClasses), isTrue);
    await directories.load(MemberScopeDirectory.subjects);
    expect(requests, hasLength(4));
  });

  test('failures retry without false empty success and lost scopes reject late pagination', () async {
    for (final failure in [(503, 'UNAVAILABLE'), (401, 'REAUTH_REQUIRED')]) {
      var reads = 0;
      final directories = MemberScopeDirectories(api: api((_) => ++reads == 1
          ? http.Response(jsonEncode({'errorCode': failure.$2}), failure.$1)
          : page([{'id': 's', 'nickname': '恢复档案'}])),
          root: root, current: () => true);
      await expectLater(directories.load(MemberScopeDirectory.subjects),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', failure.$1)));
      expect(directories.subjects, isNull);
      expect(directories.current, isTrue);
      await directories.load(MemberScopeDirectory.subjects);
      expect(directories.subjects, {'s': '恢复档案'});
      expect(reads, 2);
    }
    for (final invalid in <(MemberScopeDirectory, List<Json>)>[
      (MemberScopeDirectory.subjects, [{'id': 7, 'nickname': '档案'}]),
      (MemberScopeDirectory.classes, [
        {'id': 'c', 'name': '甲班'}, {'id': 'c', 'name': '乙班'}]),
      (MemberScopeDirectory.subjects, [{'id': 's' * 101, 'nickname': '档案'}]),
      (MemberScopeDirectory.subjects, [{'id': 's', 'nickname': '名' * 61}]),
      (MemberScopeDirectory.classes, [{'id': 'c', 'name': '名' * 101}]),
    ]) {
      var reads = 0;
      final directories = MemberScopeDirectories(api: api((_) => page(++reads == 1
          ? invalid.$2 : invalid.$1 == MemberScopeDirectory.subjects
              ? [{'id': 'ok', 'nickname': '有效'}] : [{'id': 'ok', 'name': '有效'}])),
          root: root, current: () => true);
      await expectLater(directories.load(invalid.$1), throwsA(isA<ApiFailure>()
          .having((e) => e.code, 'code', 'INVALID_MEMBER_SCOPE_OPTIONS')));
      expect(directories.subjects, isNull);
      expect(directories.classes, isNull);
      await directories.load(invalid.$1);
      expect(invalid.$1 == MemberScopeDirectory.subjects
          ? directories.subjects : directories.classes, {'ok': '有效'});
    }
    for (final failure in [
      (403, 'SCOPE_DENIED'), (401, 'UNAUTHENTICATED'), (409, 'WORKSPACE_CHANGED'),
    ]) {
      var reads = 0;
      final directories = MemberScopeDirectories(api: api((_) => ++reads == 1
          ? page([{'id': 'c', 'name': '原私有班级'}])
          : http.Response(jsonEncode({'errorCode': failure.$2}), failure.$1)),
          root: root, current: () => true);
      await directories.load(MemberScopeDirectory.classes);
      await expectLater(directories.load(MemberScopeDirectory.subjects),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', failure.$1)));
      expect(directories.current, isFalse);
      expect(directories.classes, isNull);
      expect(directories.subjects, isNull);
      await expectLater(directories.load(MemberScopeDirectory.classes), throwsA(lost));
      expect(reads, 2);
    }
    final latePage = Completer<http.Response>();
    addTearDown(() {
      if (!latePage.isCompleted) latePage.complete(page([]));
    });
    var allowed = true;
    var reads = 0;
    final directories = MemberScopeDirectories(api: api((_) {
      reads++;
      return reads == 1 ? page([{'id': 'c', 'name': '原班级'}]) : latePage.future;
    }), root: root, current: () => allowed);
    await directories.load(MemberScopeDirectory.classes);
    final loading = directories.load(MemberScopeDirectory.subjects);
    final rejected = expectLater(loading, throwsA(lost));
    await Future<void>.delayed(Duration.zero);
    allowed = false;
    expect(directories.current, isFalse);
    allowed = true;
    latePage.complete(page([{'id': 's', 'nickname': '晚到私有档案'}], cursor: 'do-not-fetch'));
    await rejected;
    expect(directories.classes, isNull);
    expect(directories.subjects, isNull);
    expect(reads, 2);
    var unavailableReads = 0;
    final unavailable = MemberScopeDirectories(api: api((_) {
      unavailableReads++;
      return page([]);
    }), root: root, current: () => throw StateError('Owner no longer available'));
    expect(unavailable.current, isFalse);
    await expectLater(unavailable.load(MemberScopeDirectory.subjects), throwsA(lost));
    expect(unavailableReads, 0);
  });
}
