import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/access.dart';
import 'package:guardian/core/audit.dart';
import 'package:guardian/core/audit_exports.dart';
import 'package:guardian/ui/audit_exports_view.dart';
import 'package:guardian/ui/export_create_dialog.dart';
import 'package:guardian/ui/design.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const id = '11111111-1111-1111-1111-111111111111';
const other = '22222222-2222-2222-2222-222222222222';
const now = 1791590400000;
Json job({String state = 'QUEUED', String key = id, int? bytes}) => {
      'id': key,
      'state': state,
      'createdAt': now,
      'updatedAt': now,
      'expiresAt': now + 86400000,
      'from': now - 60000,
      'to': now,
      'requestedTo': now,
      'action': null,
      'resourceId': null,
      'correlationId': null,
      'recordCount': state == 'READY' ? 0 : null,
      'byteCount': state == 'READY' ? (bytes ?? 100) : null,
      'failureCode': state == 'FAILED' ? 'EXPORT_ROW_LIMIT_EXCEEDED' : null,
      'attempts': state == 'QUEUED' ? 0 : 1
    };
Json payload({String key = id}) => {
      'schemaVersion': 1,
      'type': 'AUDIT_JSON',
      'tenantId': id,
      'jobId': key,
      'selection': {
        'from': now - 60000,
        'to': now,
        'action': null,
        'resourceId': null,
        'correlationId': null
      },
      'requestedTo': now,
      'generatedAt': now,
      'recordCount': 0,
      'events': []
    };
http.Response response(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
AuditExportRepository repository(
        FutureOr<http.Response> Function(http.Request) fn,
        {bool Function()? current}) =>
    AuditExportRepository(
        api: Api(() async => MockClient((r) async => fn(r))),
        root: '/tenants/$id',
        current: current ?? () => true);
Widget host(Widget child) => MaterialApp(
    theme: consoleTheme(),
    home: Scaffold(body: SingleChildScrollView(child: child)));
void main() {
  test(
      'exports follow audit roles and login return paths are internal allowlisted routes',
      () {
    expect(canOpenSection('AUDITOR', 'exports'), isTrue);
    expect(canOpenSection('CHILD', 'exports'), isFalse);
    expect(canOpenSection('TEACHER', 'exports'), isFalse);
    expect(trustedReturnPath('/exports'), '/exports');
    expect(trustedReturnPath('/audit'), '/audit');
    for (final value in [
      'https://example.com',
      '//example.com',
      '/auth/callback',
      '/exports?token=x',
      '/unknown'
    ]) {
      expect(trustedReturnPath(value), '/');
    }
  });
  test(
      'strict job model rejects missing ready artifact metadata and invalid intervals',
      () {
    expect(
        () => AuditExportJob.parse({...job(state: 'READY'), 'byteCount': null}),
        throwsA(isA<ApiFailure>()));
    expect(() => AuditExportJob.parse({...job(), 'to': now + 1}),
        throwsA(isA<ApiFailure>()));
    expect(() => AuditExportJob.parse({...job(), 'state': 'UNVERIFIED'}),
        throwsA(isA<ApiFailure>()));
  });
  test(
      'authenticated download preserves bytes and rejects a different job payload',
      () async {
    final data = payload(), bytes = utf8.encode(jsonEncode(payload()));
    final value =
        AuditExportJob.parse(job(state: 'READY', bytes: bytes.length));
    final repo = repository((r) {
      expect(r.followRedirects, isFalse);
      return response(data);
    });
    expect(await repo.download(value), bytes);
    final bad = repository((_) => response(payload(key: other)));
    await expectLater(bad.download(value), throwsA(isA<ApiFailure>()));
  });
  test('workspace change discards a completed download', () async {
    final pending = Completer<http.Response>();
    var current = true;
    final data = payload(), bytes = utf8.encode(jsonEncode(payload()));
    final repo = repository((_) => pending.future, current: () => current);
    final result = repo.download(
        AuditExportJob.parse(job(state: 'READY', bytes: bytes.length)));
    current = false;
    pending.complete(response(data));
    await expectLater(result, throwsA(isA<ApiFailure>()));
  });
  testWidgets('unknown creation retries the original key and exact selection',
      (t) async {
    final requests = <http.Request>[];
    var done = 0;
    final repo = repository((r) {
      requests.add(r);
      return requests.length == 1
          ? response({'errorCode': 'TEMPORARY_FAILURE'}, 503)
          : response(job(), 202);
    });
    await t.pumpWidget(host(ExportCreateDialog(
        repository: repo,
        query: const AuditQuery(from: now - 60000, to: now),
        onCreated: (_) => done++,
        onReauth: () {})));
    await t.tap(find.text('生成导出'));
    await t.pumpAndSettle();
    await t.tap(find.text('重试生成'));
    await t.pumpAndSettle();
    expect(done, 1);
    expect(requests.length, 2);
    expect(requests[0].headers['Idempotency-Key'],
        requests[1].headers['Idempotency-Key']);
    expect(requests[0].body, requests[1].body);
    expect(jsonDecode(requests[0].body).containsKey('limit'), isFalse);
  });
  testWidgets('MFA failure offers reauthentication without saving a file',
      (t) async {
    var saved = 0, reauth = 0;
    final repo = repository((r) => r.url.path.endsWith('/content')
        ? response({'errorCode': 'REAUTH_REQUIRED'}, 401)
        : response({
            'items': [job(state: 'READY')],
            'nextCursor': null
          }));
    await t.pumpWidget(host(AuditExportsView(
        repository: repo,
        saveFile: (_, __) async {
          saved++;
        },
        onReauth: () => reauth++,
        onAudit: () {})));
    await t.pumpAndSettle();
    expect(t.getSize(find.byType(Panel)).width,
        t.view.physicalSize.width / t.view.devicePixelRatio);
    await t.tap(find.text('下载 JSON'));
    await t.pumpAndSettle();
    expect(saved, 0);
    await t.tap(find.text('重新安全验证'));
    expect(reauth, 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('mobile cancel requires confirmation and shows terminal state',
      (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    var cancelled = false;
    final repo = repository((r) {
      if (r.method == 'POST') {
        cancelled = true;
        return response(job(state: 'CANCELLED'));
      }
      return response({
        'items': [job(state: cancelled ? 'CANCELLED' : 'QUEUED')],
        'nextCursor': null
      });
    });
    await t.pumpWidget(host(AuditExportsView(
        repository: repo,
        saveFile: (Uint8List _, String __) async {},
        onReauth: () {},
        onAudit: () {})));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('取消导出'));
    await t.tap(find.text('取消导出'));
    await t.pumpAndSettle();
    expect(cancelled, isFalse);
    await t.tap(find.text('确认取消'));
    await t.pumpAndSettle();
    expect(cancelled, isTrue);
    expect(find.text('已取消'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
