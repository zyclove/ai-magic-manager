@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
// This browser-only fixture restores the page's real session selection storage.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/contracts.dart' show isContractId;
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/commercial_catalog_page.dart';
import 'package:guardian/pages/contracts_page.dart';
import 'package:guardian/pages/device_groups_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'access_request_dialog_test.dart' as access_fixture;
import 'commercial_catalog_test.dart' as catalog_fixture;
import 'contracts_test.dart' as contract_fixture;
import 'quota_plan_editor_test.dart' as quota_fixture;

// Local submission fixtures exercise real public pages, repositories and API
// parsers. They grant no account permission or proof of backend/device execution.
const _actor = 'submit-direct-variant-admin';
const _tenant = contract_fixture.tenant;
const _root = '/tenants/$_tenant';
const _groupId = '44444444-4444-4444-4444-444444444444';

class _SubmitSession extends Session {
  final Api testApi;
  _SubmitSession(this.testApi) {
    profile = {
      'subject': _actor,
      'canManageContracts': true,
      'canApproveContracts': true,
      'canManageCatalog': true,
      'canApproveCatalog': true,
    };
    tenant = {'id': _tenant, 'kind': 'ORGANIZATION'};
    role = 'OWNER';
  }

  @override
  Api get api => testApi;
  @override
  bool get authenticated => true;
}

http.Response _reply(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

class _PageHttp {
  final Object Function(http.Request) read;
  final mutations = <http.Request>[];
  final pending = Completer<http.Response>();
  Completer<http.Client>? clientGate;
  _PageHttp(this.read);

  late final transport = MockClient((request) async {
    if (request.method == 'GET') return _reply(read(request));
    mutations.add(request);
    return pending.future;
  });
  late final api = Api(
      () => clientGate?.future ?? Future<http.Client>.value(transport),
      baseUrl: 'https://fixture.invalid/api/v1');

  void blockClient() => clientGate = Completer<http.Client>();
  void releaseClient() {
    final gate = clientGate;
    if (gate != null && !gate.isCompleted) gate.complete(transport);
    clientGate = null;
  }

  void releaseResponse() {
    if (!pending.isCompleted) {
      pending.complete(_reply({'errorCode': 'TEST_CLEANUP'}, 503));
    }
  }
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Future<void> _settle(WidgetTester tester) async {
  await _flush(tester);
  await tester.pumpAndSettle(const Duration(milliseconds: 30),
      EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
}

void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
}

void _resetViewport(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Future<void> _mountPage(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(MaterialApp(
    theme: consoleTheme(),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: page,
      ),
    ),
  ));
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder control) async {
  expect(control, findsOneWidget);
  await tester.ensureVisible(control);
  await tester.tap(control);
  await _settle(tester);
}

Finder _pageButton(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    );

VoidCallback _capture(WidgetTester tester, String text) {
  final finder = find.widgetWithText(FilledButton, text);
  expect(finder, findsOneWidget);
  final callback = tester.widget<FilledButton>(finder).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

Future<void> _disposePage(
    WidgetTester tester, _PageHttp fixture, _SubmitSession session) async {
  // Finish pending writes inside the test body, after all widgets are disposed.
  // Re-awaiting a cached fake-zone Future from addTearDown can hang the runner.
  await tester.pumpWidget(const SizedBox.shrink());
  fixture.releaseClient();
  fixture.releaseResponse();
  await _flush(tester);
  fixture.transport.close();
  session.dispose();
  _resetViewport(tester);
}

Json _group() => {
      'id': _groupId,
      'name': '七年级设备组',
      'state': 'ACTIVE',
      'version': 3,
      'deviceCount': 0,
      'createdAt': 1000,
      'updatedAt': 1003,
    };

Object _groupRead(http.Request request) {
  final path = request.url.path;
  if (path == '/api/v1$_root/device-groups') {
    return {
      'items': [_group()],
      'nextCursor': null
    };
  }
  if (path == '/api/v1$_root/device-groups/$_groupId') return _group();
  if (path == '/api/v1$_root/device-groups/$_groupId/devices') {
    return {'items': <Json>[], 'nextCursor': null};
  }
  if (path == '/api/v1$_root/device-groups/$_groupId/summary') {
    return {
      'groupId': _groupId,
      'version': 3,
      'total': 0,
      'current': 0,
      'staleRegistration': 0,
      'deviceInactive': 0,
      'profileArchived': 0,
    };
  }
  throw StateError('Unexpected group read: $path');
}

Object _contractRead(http.Request request) {
  final path = request.url.path;
  if (path == '/api/v1/platform/contracts/capabilities') {
    return {
      'submissionEnabled': true,
      'revocationSubmissionEnabled': true,
      'region': 'CN',
      'channel': 'CONTRACT',
      'recentAuthenticationRequired': true,
      'independentApprovalRequired': true,
      'customerAcceptanceRequired': true,
    };
  }
  if (path == '/api/v1/platform/contracts') {
    return {
      'items': [contract_fixture.review()],
      'nextCursor': null
    };
  }
  if (path == '/api/v1/platform/contracts/${contract_fixture.reviewId}') {
    return contract_fixture.review();
  }
  if (path ==
      '/api/v1/platform/contracts/${contract_fixture.reviewId}/comparison') {
    return contract_fixture.comparison();
  }
  if (path ==
      '/api/v1/platform/contracts/${contract_fixture.reviewId}/history') {
    return {'items': <Json>[], 'nextBeforeVersion': null};
  }
  throw StateError('Unexpected contract read: $path');
}

Object _catalogRead(http.Request request) {
  final path = request.url.path;
  if (path == '/api/v1/platform/catalog/offers') {
    return {
      'items': [catalog_fixture.snapshot()],
      'nextCursor': null
    };
  }
  if (path == '/api/v1/platform/catalog/offers/${catalog_fixture.offerId}') {
    return catalog_fixture.snapshot();
  }
  if (path ==
      '/api/v1/platform/catalog/offers/${catalog_fixture.offerId}/history') {
    return {
      'items': [catalog_fixture.history()],
      'nextBeforeRevision': null,
    };
  }
  throw StateError('Unexpected catalog read: $path');
}

void main() {
  testWidgets('V06 group confirmation submits one version-bound archive',
      (tester) async {
    _viewport(tester);
    final fixture = _PageHttp(_groupRead);
    final session = _SubmitSession(fixture.api);
    try {
      await _mountPage(tester, DeviceGroupsPage(session: session));
      await _tap(tester, find.text('七年级设备组'));
      await _tap(tester, _pageButton('归档设备组'));
      expect(find.text('归档设备组'), findsWidgets);
      fixture.blockClient();
      final submit = _capture(tester, '确认归档');
      submit();
      submit();
      expect(fixture.mutations, isEmpty);
      fixture.releaseClient();
      await _flush(tester);

      expect(fixture.mutations, hasLength(1),
          reason: 'Group confirmation must lock before its first await.');
      final request = fixture.mutations.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1$_root/device-groups/$_groupId/archive');
      expect(request.headers['If-Match'], '"3"');
      expect(request.headers['Idempotency-Key'], isNotEmpty);
      expect(request.body, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await _disposePage(tester, fixture, session);
    }
  });

  testWidgets('V07 quota plan saves one complete calendar-bound body',
      (tester) async {
    _viewport(tester);
    final pending = Completer<void>();
    final bodies = <Json>[];
    try {
      await quota_fixture.open(tester, (body) {
        bodies.add(Map<String, dynamic>.from(body));
        return pending.future;
      });
      final submit = _capture(tester, '保存计划');
      submit();
      submit();

      expect(pending.isCompleted, isFalse);
      expect(bodies, hasLength(1),
          reason:
              'Quota save must lock while the first submission is pending.');
      expect(bodies.single, {
        'name': '每周使用额度',
        'subjectId': 'child',
        'scope': 'TOTAL',
        'timeZone': 'America/Los_Angeles',
        'effectiveFrom': '2026-10-08',
        'weeklyLimits': {
          'MONDAY': 3600,
          'TUESDAY': 3600,
          'WEDNESDAY': 3600,
          'THURSDAY': 3600,
          'FRIDAY': 3600,
          'SATURDAY': 3600,
          'SUNDAY': 3600,
        },
        'dateOverrides': <String, int>{},
      });
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!pending.isCompleted) pending.complete();
      await _flush(tester);
      _resetViewport(tester);
    }
  });

  testWidgets('V08 contract evidence submits one original token and review id',
      (tester) async {
    _viewport(tester);
    final fixture = _PageHttp(_contractRead);
    final session = _SubmitSession(fixture.api);
    try {
      await _mountPage(tester, ContractsPage(session: session, platform: true));
      await _tap(tester, _pageButton('提交签约或撤销事实'));
      await tester.enterText(find.widgetWithText(TextField, '签名断言'),
          '  header.payload.signature  ');
      fixture.blockClient();
      final submit = _capture(tester, '提交待审');
      submit();
      submit();
      expect(fixture.mutations, isEmpty);
      fixture.releaseClient();
      await _flush(tester);

      expect(fixture.mutations, hasLength(1),
          reason: 'Evidence submission must lock before its first await.');
      final request = fixture.mutations.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/platform/contracts');
      final body = jsonDecode(request.body) as Json;
      expect(body.keys, unorderedEquals(['id', 'evidence']));
      expect(isContractId(body['id'] as String), isTrue);
      expect(body['evidence'], 'header.payload.signature');
      expect(tester.takeException(), isNull);
    } finally {
      await _disposePage(tester, fixture, session);
    }
  });

  testWidgets('V09 contract action submits one reviewed version and reason',
      (tester) async {
    _viewport(tester);
    final fixture = _PageHttp(_contractRead);
    final session = _SubmitSession(fixture.api);
    try {
      await _mountPage(tester, ContractsPage(session: session, platform: true));
      await _tap(
          tester,
          find.byKey(
              const ValueKey('contract-review-${contract_fixture.reviewId}')));
      await _tap(tester, _pageButton('批准，待机构确认'));
      await tester.enterText(
          find.widgetWithText(TextField, '审核原因'), '  已独立核对签约事实  ');
      fixture.blockClient();
      final submit = _capture(tester, '确认操作');
      submit();
      submit();
      expect(fixture.mutations, isEmpty);
      fixture.releaseClient();
      await _flush(tester);

      expect(fixture.mutations, hasLength(1),
          reason: 'Contract action must lock before its first await.');
      final request = fixture.mutations.single;
      expect(request.method, 'POST');
      expect(request.url.path,
          '/api/v1/platform/contracts/${contract_fixture.reviewId}/approve');
      expect(request.headers['If-Match'], '"1"');
      expect(jsonDecode(request.body), {'reason': '已独立核对签约事实'});
      expect(tester.takeException(), isNull);
    } finally {
      await _disposePage(tester, fixture, session);
    }
  });

  testWidgets('V10 catalog action submits one offer revision and reason',
      (tester) async {
    _viewport(tester);
    final fixture = _PageHttp(_catalogRead);
    final session = _SubmitSession(fixture.api);
    const storageKey = 'ai-manager.catalog.selected.$_actor';
    final previousSelection = html.window.sessionStorage.remove(storageKey);
    try {
      await _mountPage(tester, CommercialCatalogPage(session: session));
      await _tap(
          tester,
          find.byKey(
              const ValueKey('catalog-offer-${catalog_fixture.offerId}')));
      await _tap(tester, _pageButton('提交审核'));
      await tester.enterText(
          find.widgetWithText(TextField, '操作原因'), '  已核对地区渠道与报价内容  ');
      fixture.blockClient();
      final submit = _capture(tester, '确认操作');
      submit();
      submit();
      expect(fixture.mutations, isEmpty);
      fixture.releaseClient();
      await _flush(tester);

      expect(fixture.mutations, hasLength(1),
          reason: 'Catalog action must lock before its first await.');
      final request = fixture.mutations.single;
      expect(request.method, 'POST');
      expect(request.url.path,
          '/api/v1/platform/catalog/offers/${catalog_fixture.offerId}/submit');
      expect(request.headers['If-Match'], '"1"');
      expect(jsonDecode(request.body), {'reason': '已核对地区渠道与报价内容'});
      expect(tester.takeException(), isNull);
    } finally {
      await _disposePage(tester, fixture, session);
      if (previousSelection == null) {
        html.window.sessionStorage.remove(storageKey);
      } else {
        html.window.sessionStorage[storageKey] = previousSelection;
      }
    }
  });

  testWidgets(
      'V11 access request sends one exact device and baseline selection',
      (tester) async {
    _viewport(tester);
    final pending = Completer<Json>();
    final bodies = <Json>[];
    try {
      await access_fixture.open(tester, (body) {
        bodies.add(Map<String, dynamic>.from(body));
        return pending.future;
      });
      await access_fixture.selectDevice(tester);
      await access_fixture.selectApp(tester);
      await tester.enterText(find.byKey(const Key('request-minutes')), '5');
      await tester.enterText(
          find.byKey(const Key('request-reason')), '  课堂活动  ');
      final submit = _capture(tester, '提交申请');
      submit();
      submit();

      expect(pending.isCompleted, isFalse);
      expect(bodies, hasLength(1),
          reason:
              'Access request must lock while the first submit is pending.');
      expect(bodies.single, {
        'deviceId': access_fixture.deviceId,
        'policyId': 'policy-1',
        'baseVersionId': 'version-1',
        'applicationId': 'app-1',
        'ruleIds': ['lesson_0', 'window'],
        'requestedWindowSeconds': 300,
        'reason': '课堂活动',
      });
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!pending.isCompleted) pending.complete(<String, dynamic>{});
      await _flush(tester);
      _resetViewport(tester);
    }
  });
}
