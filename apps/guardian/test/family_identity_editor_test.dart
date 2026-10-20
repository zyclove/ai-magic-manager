import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/family_identity_editor.dart';
import 'package:guardian/core/family_identity_configuration.dart';
import 'family_identity_configuration_test.dart';

void main() {
  testWidgets(
      'existing secret presence never prefills a value and replacements clear after save',
      (tester) async {
    final done = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: IdentityProvidersEditor(
                currentVersion:
                    IdentityProviderVersion.parse(identityVersionFixture()),
                isCurrent: () => true,
                onSave: (settings, replacements, clear) {
                  calls++;
                  expect(replacements, {'wechatAppSecret': 'b' * 32});
                  return done.future;
                }))));
    expect(find.byKey(const Key('identity-wechat-secret')), findsNothing);
    await tester.ensureVisible(find.text('更换微信密钥'));
    await tester.tap(find.text('更换微信密钥'));
    await tester.pump();
    await tester.enterText(
        find.byKey(const Key('identity-wechat-secret')), 'b' * 32);
    final button = find.widgetWithText(FilledButton, '保存配置版本');
    await tester.ensureVisible(button);
    final callback = tester.widget<FilledButton>(button).onPressed!;
    callback();
    callback();
    await tester.pump();
    expect(calls, 1);
    expect(
        tester
            .widget<TextFormField>(
                find.byKey(const Key('identity-wechat-secret')))
            .controller!
            .text,
        isEmpty);
    done.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('scope changes clear replacement fields and disable submission',
      (tester) async {
    var current = true, calls = 0;
    final key = GlobalKey<IdentityProvidersEditorState>();
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: IdentityProvidersEditor(
                key: key,
                currentVersion:
                    IdentityProviderVersion.parse(identityVersionFixture()),
                isCurrent: () => current,
                onSave: (_, __, ___) async {
                  calls++;
                }))));
    await tester.ensureVisible(find.text('更换微信密钥'));
    await tester.tap(find.text('更换微信密钥'));
    await tester.pump();
    await tester.enterText(
        find.byKey(const Key('identity-wechat-secret')), 'b' * 32);
    current = false;
    key.currentState!.clearSensitiveInput();
    await tester.pump();
    expect(
        tester
            .widget<TextFormField>(
                find.byKey(const Key('identity-wechat-secret')))
            .controller!
            .text,
        isEmpty);
    final button = find.widgetWithText(FilledButton, '保存配置版本');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
