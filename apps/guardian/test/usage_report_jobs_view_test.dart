import 'dart:async';
import 'dart:convert';
import 'dart:ui' show SemanticsFlag;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/usage_report_job_dialog.dart';
import 'package:guardian/ui/usage_report_jobs_view.dart';
import 'package:guardian/core/usage_reports.dart';
import 'usage_report_jobs_test.dart'
    show draft, jobFixture, repository, response;
import 'usage_reports_test.dart' show now, target, reportFixture;

Widget host(Widget child) => MaterialApp(
    theme: consoleTheme(),
    home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  for (final change in ['expiry', 'background']) {
    testWidgets('late download cannot save after $change', (t) async {
      final payload = reportFixture(), job = jobFixture();
      final bytes = utf8.encode(jsonEncode(payload)).length;
      job['byteCount'] = bytes;
      job['parts'][0]['byteCount'] = bytes;
      int reads = 0, saved = 0, clock = now + 2000;
      final waiting = Completer<void>();
      final repo = repository((r) async {
        if (r.url.path.endsWith('/parts/0')) {
          reads++;
          if (reads == 2) await waiting.future;
          return response(payload);
        }
        if (r.url.queryParameters.containsKey('limit')) {
          return response({
            'items': [job],
            'nextCursor': null
          });
        }
        return response(job);
      });
      await t.pumpWidget(host(UsageReportJobsView(
          repository: repo,
          resolveTarget: (_) async => target,
          clock: () => clock,
          saveFile: (bytes, name) async {
            saved++;
          })));
      await t.pumpAndSettle();
      await t.tap(find.text('查看结果'));
      await t.pumpAndSettle();
      await t.tap(find.text('设备 1 · 11111111'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('下载本设备 JSON'));
      await t.tap(find.text('下载本设备 JSON'));
      await t.pump();
      expect(reads, 2);
      if (change == 'expiry') {
        clock = now + 86400001;
      } else {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      }
      waiting.complete();
      await t.pump();
      if (change == 'background') {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      await t.pumpAndSettle();
      expect(saved, 0);
      expect(find.text('已保存的设备报表'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  }
  for (final revoked in [false, true]) {
    testWidgets(
        'download rechecks authorization before browser save: revoked=$revoked',
        (t) async {
      final payload = reportFixture(), job = jobFixture();
      final bytes = utf8.encode(jsonEncode(payload)).length;
      job['byteCount'] = bytes;
      job['parts'][0]['byteCount'] = bytes;
      int reads = 0, saved = 0;
      String? filename;
      final repo = repository((r) {
        if (r.url.path.endsWith('/parts/0')) {
          reads++;
          return response(payload);
        }
        if (r.url.queryParameters.containsKey('limit')) {
          return response({
            'items': [job],
            'nextCursor': null
          });
        }
        return response(
            revoked && reads > 0 ? jobFixture(state: 'REVOKED') : job);
      });
      await t.pumpWidget(host(UsageReportJobsView(
          repository: repo,
          resolveTarget: (_) async => target,
          clock: () => now + 2000,
          saveFile: (bytes, name) async {
            saved++;
            filename = name;
            expect(jsonDecode(utf8.decode(bytes)), payload);
          })));
      await t.pumpAndSettle();
      await t.tap(find.text('查看结果'));
      await t.pumpAndSettle();
      await t.tap(find.text('设备 1 · 11111111'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('下载本设备 JSON'));
      await t.tap(find.text('下载本设备 JSON'));
      await t.pumpAndSettle();
      expect(saved, revoked ? 0 : 1);
      expect(reads, revoked ? 1 : 2);
      if (!revoked) {
        expect(filename, endsWith('11111111-1111-1111-1111-111111111111.json'));
      } else {
        expect(find.text('已保存的设备报表'), findsNothing);
      }
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'result selection shows current device names and button semantics',
      (t) async {
    final semantics = t.ensureSemantics();
    final repo = repository((r) => response({
          'items': [jobFixture()],
          'nextCursor': null
        }));
    await t.pumpWidget(host(UsageReportJobsView(
        repository: repo,
        loadTargets: () async => [target],
        resolveTarget: (_) async => target,
        clock: () => now + 2000)));
    await t.pumpAndSettle();
    await t.tap(find.text('查看结果'));
    await t.pumpAndSettle();
    final label = find.text('${target.displayName} · 11111111');
    expect(label, findsOneWidget);
    expect(t.getSemantics(label).hasFlag(SemanticsFlag.isButton), true);
    await t.pumpWidget(const SizedBox());
    semantics.dispose();
  });
  testWidgets('changed current registration blocks result selection',
      (t) async {
    final repo = repository((r) => response({
          'items': [jobFixture()],
          'nextCursor': null
        }));
    await t.pumpWidget(host(UsageReportJobsView(
        repository: repo,
        loadTargets: () async => [
              UsageReportTarget(target.deviceId, target.subjectId,
                  target.subjectId, 'Changed')
            ],
        resolveTarget: (_) async => target,
        clock: () => now + 2000)));
    await t.pumpAndSettle();
    await t.tap(find.text('查看结果'));
    await t.pumpAndSettle();
    expect(find.text('选择结果设备'), findsNothing);
    expect(find.textContaining('班级名册或设备所属档案已变化'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  for (final change in ['background', 'revoked', 'expired']) {
    testWidgets('saved result is cleared on $change', (t) async {
      String state = 'READY';
      int clock = now + 2000;
      final payload = reportFixture();
      final job = jobFixture();
      final bytes = utf8.encode(jsonEncode(payload)).length;
      job['byteCount'] = bytes;
      job['parts'][0]['byteCount'] = bytes;
      final repo = repository((r) {
        if (r.url.path.endsWith('/parts/0')) return response(payload);
        final value = state == 'READY' ? job : jobFixture(state: state);
        if (r.url.queryParameters.containsKey('limit')) {
          return response({
            'items': [value],
            'nextCursor': null
          });
        }
        return response(value);
      });
      await t.pumpWidget(host(UsageReportJobsView(
          repository: repo,
          resolveTarget: (_) async => target,
          clock: () => clock)));
      await t.pumpAndSettle();
      await t.tap(find.text('查看结果'));
      await t.pumpAndSettle();
      await t.tap(find.text('设备 1 · 11111111'));
      await t.pumpAndSettle();
      expect(find.text('已保存的设备报表'), findsOneWidget);
      if (change == 'background') {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        t.binding.scheduleForcedFrame();
        await t.pump();
        expect(find.text('已保存的设备报表'), findsNothing);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pumpAndSettle();
        expect(find.text('已保存的设备报表'), findsNothing);
      } else {
        if (change == 'revoked') {
          state = 'REVOKED';
        } else {
          clock = now + 86400001;
        }
        await t.pump(const Duration(seconds: 5));
        await t.pumpAndSettle();
        expect(find.text('已保存的设备报表'), findsNothing);
      }
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('reauthentication failure remains visible until explicit retry',
      (t) async {
    final repo = repository((r) {
      if (r.url.path.endsWith('/parts/0')) {
        return response({'errorCode': 'REAUTH_REQUIRED'}, status: 401);
      }
      if (r.url.queryParameters.containsKey('limit')) {
        return response({
          'items': [jobFixture()],
          'nextCursor': null
        });
      }
      return response(jobFixture());
    });
    await t.pumpWidget(host(UsageReportJobsView(
        repository: repo,
        resolveTarget: (_) async => target,
        reauth: () {},
        clock: () => now + 2000)));
    await t.pumpAndSettle();
    await t.tap(find.text('查看结果'));
    await t.pumpAndSettle();
    await t.tap(find.text('设备 1 · 11111111'));
    await t.pumpAndSettle();
    expect(find.textContaining('此操作需要近期多因素认证'), findsOneWidget);
    await t.pump(const Duration(seconds: 6));
    await t.pumpAndSettle();
    expect(find.textContaining('此操作需要近期多因素认证'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('unknown create retry preserves the exact request and key',
      (t) async {
    final bodies = <String>[], keys = <String?>[];
    int created = 0;
    final repo = repository((r) {
      bodies.add(r.body);
      keys.add(r.headers['idempotency-key']);
      return bodies.length == 1
          ? response({'code': 'SERVICE_UNAVAILABLE'}, status: 503)
          : response(jobFixture(state: 'QUEUED'), status: 202);
    });
    await t.pumpWidget(host(UsageReportJobDialog(
        repository: repo, draft: draft(), onCreated: (_) => created++)));
    await t.tap(find.text('确认生成'));
    await t.pumpAndSettle();
    await t.tap(find.text('按原条件重试'));
    await t.pumpAndSettle();
    expect(bodies.length, 2);
    expect(bodies.toSet().length, 1);
    expect(keys.toSet().length, 1);
    expect(keys.first, isNotEmpty);
    expect(created, 1);
  });

  testWidgets('late create after workspace change does not navigate',
      (t) async {
    bool current = true;
    int created = 0;
    final changes = ChangeNotifier();
    final wait = Completer<void>();
    final repo = repository((r) async {
      await wait.future;
      return response(jobFixture(state: 'QUEUED'), status: 202);
    }, current: () => current);
    await t.pumpWidget(host(UsageReportJobDialog(
        repository: repo,
        draft: draft(),
        accessChanges: changes,
        onCreated: (_) => created++)));
    await t.tap(find.text('确认生成'));
    await t.pump();
    current = false;
    changes.notifyListeners();
    await t.pump();
    wait.complete();
    await t.pumpAndSettle();
    expect(created, 0);
    expect(find.text('确认生成'), findsNothing);
    await t.pumpWidget(const SizedBox());
    changes.dispose();
  });

  testWidgets('pending tasks poll only while foreground and stop on disposal',
      (t) async {
    int reads = 0;
    final repo = repository((r) {
      reads++;
      return response({
        'items': [jobFixture(state: 'RUNNING')],
        'nextCursor': null
      });
    });
    await t.pumpWidget(host(UsageReportJobsView(
        repository: repo,
        resolveTarget: (_) async => target,
        clock: () => now + 2000)));
    await t.pumpAndSettle();
    expect(reads, 1);
    expect(find.text('0 / 1 台'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
    expect(reads, 2);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await t.pump(const Duration(seconds: 12));
    expect(reads, 2);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(reads, 3);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 12));
    expect(reads, 3);
  });

  testWidgets('expired ready task cannot open saved private report', (t) async {
    final repo = repository((r) => response({
          'items': [jobFixture()],
          'nextCursor': null
        }));
    await t.pumpWidget(host(UsageReportJobsView(
        repository: repo,
        resolveTarget: (_) async => target,
        clock: () => now + 86400001)));
    await t.pumpAndSettle();
    expect(find.text('已到期'), findsOneWidget);
    expect(find.text('查看结果'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('workspace change closes owned result selection dialog',
      (t) async {
    bool current = true;
    final changes = ChangeNotifier();
    final repo = repository(
        (r) => response({
              'items': [jobFixture()],
              'nextCursor': null
            }),
        current: () => current);
    await t.pumpWidget(host(UsageReportJobsView(
        repository: repo,
        resolveTarget: (_) async => target,
        accessChanges: changes,
        clock: () => now + 2000)));
    await t.pumpAndSettle();
    await t.tap(find.text('查看结果'));
    await t.pumpAndSettle();
    expect(find.text('选择结果设备'), findsOneWidget);
    current = false;
    changes.notifyListeners();
    await t.pumpAndSettle();
    expect(find.text('选择结果设备'), findsNothing);
    expect(find.text('已生成'), findsNothing);
    await t.pumpWidget(const SizedBox());
    changes.dispose();
  });

  testWidgets('cancel requires confirmation and replaces ready state',
      (t) async {
    bool cancelled = false;
    final repo = repository((r) {
      if (r.method == 'POST') {
        cancelled = true;
        return response(jobFixture(state: 'CANCELLED'));
      }
      return response({
        'items': [jobFixture(state: cancelled ? 'CANCELLED' : 'READY')],
        'nextCursor': null
      });
    });
    await t.pumpWidget(host(UsageReportJobsView(
        repository: repo,
        resolveTarget: (_) async => target,
        clock: () => now + 2000)));
    await t.pumpAndSettle();
    await t.tap(find.text('取消任务'));
    await t.pumpAndSettle();
    expect(cancelled, false);
    await t.tap(find.text('确认取消'));
    await t.pumpAndSettle();
    expect(cancelled, true);
    expect(find.text('已取消'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
