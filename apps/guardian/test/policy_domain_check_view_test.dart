import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_domain_check.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/policy_domain_check_view.dart';

const _input = Key('policy-domain-input');
const _submit = Key('policy-domain-submit');
const _result = Key('policy-domain-result');
bool _allowed() => true;

PolicyDomainEvaluation _evaluation(String domain, String effect,
        [List<String> rules = const []]) =>
    PolicyDomainEvaluation(
        canonicalDomain: domain,
        predictedEffect: effect,
        matchingRuleIds: rules);

Widget _host(Future<PolicyDomainEvaluation> Function(String) evaluate,
        ChangeNotifier changes,
        {bool Function() hasAccess = _allowed,
        int revision = 7,
        Key? viewKey}) =>
    MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: PolicyDomainCheckView(
                    key: viewKey,
                    evaluate: evaluate,
                    draftRevision: revision,
                    hasAccess: hasAccess,
                    accessChanges: changes))));

void main() {
  testWidgets(
      'checks one trimmed domain and clears a result when input changes',
      (tester) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    final domains = <String>[];
    await tester.pumpWidget(_host((domain) async {
      domains.add(domain);
      return domains.length == 1
          ? _evaluation('xn--fsqu00a.xn--0zwm56d', 'DENY', ['rule-a'])
          : _evaluation(domain, 'NO_MATCH');
    }, changes));
    expect(domains, isEmpty);
    await tester.enterText(find.byKey(_input), '  例子.测试  ');
    await tester.tap(find.byKey(_submit));
    await tester.pumpAndSettle();
    expect(domains, ['例子.测试']);
    expect(find.text('规则预测：拒绝'), findsOneWidget);
    await tester.tap(find.text('查看匹配规则（1）'));
    await tester.pumpAndSettle();
    expect(find.text('rule-a'), findsOneWidget);
    await tester.enterText(find.byKey(_input), 'other.example');
    await tester.pump();
    expect(find.byKey(_result), findsNothing);
    await tester.tap(find.byKey(_submit));
    await tester.pumpAndSettle();
    expect(find.text('规则预测：未匹配'), findsOneWidget);
    expect(find.textContaining('不代表已允许或已拦截'), findsOneWidget);
  });

  testWidgets('allows one request and discards its result after an input edit',
      (tester) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    final pending = Completer<PolicyDomainEvaluation>();
    var calls = 0;
    await tester.pumpWidget(_host((_) {
      calls++;
      return pending.future;
    }, changes));
    await tester.enterText(find.byKey(_input), 'private.example');
    final callback =
        tester.widget<FilledButton>(find.byKey(_submit)).onPressed!;
    callback();
    callback();
    await tester.pump();
    expect(calls, 1);
    await tester.enterText(find.byKey(_input), 'replacement.example');
    pending.complete(_evaluation('private.example', 'ALLOW', ['old-rule']));
    await tester.pumpAndSettle();
    expect(find.byKey(_result), findsNothing);
    expect(tester.widget<TextField>(find.byKey(_input)).controller!.text,
        'replacement.example');
    expect(
        tester.widget<FilledButton>(find.byKey(_submit)).onPressed, isNotNull);
  });

  testWidgets(
      'permission ABA permanently clears input and ignores late replies',
      (tester) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    final pending = Completer<PolicyDomainEvaluation>();
    var allowed = true;
    var calls = 0;
    await tester.pumpWidget(_host((_) {
      calls++;
      return pending.future;
    }, changes, hasAccess: () => allowed));
    await tester.enterText(find.byKey(_input), 'private.example');
    final field = tester.widget<TextField>(find.byKey(_input)).controller!;
    final callback =
        tester.widget<FilledButton>(find.byKey(_submit)).onPressed!;
    callback();
    allowed = false;
    changes.notifyListeners();
    allowed = true;
    changes.notifyListeners();
    pending.complete(_evaluation('private.example', 'DENY', ['private-rule']));
    await tester.pumpAndSettle();
    callback();
    expect(calls, 1);
    expect(field.text, isEmpty);
    expect(find.byKey(_input), findsNothing);
    expect(find.byKey(_result), findsNothing);
    expect(find.textContaining('检查已失效'), findsOneWidget);
  });

  testWidgets(
      'narrow layout supports keyboard and rejects a URL without sending',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    var calls = 0;
    await tester.pumpWidget(_host((domain) async {
      calls++;
      return _evaluation(domain, 'ALLOW', ['rule-a']);
    }, changes));
    await tester.enterText(find.byKey(_input), 'https://example.com/path');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.textContaining('不含协议、端口或路径'), findsOneWidget);
    await tester.enterText(find.byKey(_input), '例子.测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('规则预测：允许'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failure keeps input and a stale revision requires reopening',
      (tester) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    var calls = 0;
    await tester.pumpWidget(_host((domain) async {
      calls++;
      if (calls == 1) return _evaluation(domain, 'ALLOW', ['rule-a']);
      throw calls == 2
          ? const ApiFailure(0, 'NETWORK_ERROR')
          : const ApiFailure(412, 'PRECONDITION_FAILED');
    }, changes));
    await tester.enterText(find.byKey(_input), 'example.com');
    final originalSubmit =
        tester.widget<FilledButton>(find.byKey(_submit)).onPressed!;
    for (var call = 1; call <= 3; call++) {
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(_input)).controller!.text,
          'example.com');
      if (call == 2) {
        expect(find.byType(FailureView), findsOneWidget);
        expect(find.byKey(_result), findsNothing);
      }
    }
    expect(find.textContaining('关闭后重新打开当前详情'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(_submit)).onPressed, isNull);
    originalSubmit();
    await tester.pump();
    expect(calls, 3);
  });

  testWidgets('a covered callback cannot dispatch and forbidden results redact',
      (tester) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    var calls = 0;
    Future<PolicyDomainEvaluation> evaluate(String _) async {
      calls++;
      throw const ApiFailure(403, 'FORBIDDEN');
    }

    await tester.pumpWidget(_host(evaluate, changes));
    await tester.enterText(find.byKey(_input), 'private.example');
    final callback =
        tester.widget<FilledButton>(find.byKey(_submit)).onPressed!;
    final context = tester.element(find.byType(PolicyDomainCheckView));
    unawaited(showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('覆盖弹窗'))));
    await tester.pumpAndSettle();
    callback();
    await tester.pump();
    expect(calls, 0);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_submit));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byKey(_input), findsNothing);
    expect(find.byKey(_result), findsNothing);
    callback();
    expect(calls, 1);
  });

  testWidgets('a replaced context and disposal cannot display an old response',
      (tester) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    final pending = Completer<PolicyDomainEvaluation>();
    Future<PolicyDomainEvaluation> evaluate(String _) => pending.future;
    await tester.pumpWidget(_host(evaluate, changes));
    await tester.enterText(find.byKey(_input), 'private.example');
    await tester.tap(find.byKey(_submit));
    await tester.pump();
    await tester.pumpWidget(_host(evaluate, changes, revision: 8));
    await tester.pumpAndSettle();
    expect(find.byKey(_input), findsNothing);
    expect(find.textContaining('检查已失效'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    pending.complete(_evaluation('private.example', 'DENY', ['private-rule']));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
