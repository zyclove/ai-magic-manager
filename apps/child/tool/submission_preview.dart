// Explicit public UI acceptance entrypoint. Never used by lib/main.dart.
// All service calls are controlled in-memory fixtures; no native or remote I/O.
import 'package:child/core/session.dart';
import 'package:child/ui/design.dart';
import 'package:child/ui/submission_section.dart';
import 'package:device_access/device_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../test/support/identity_fixture.dart';
import '../test/support/submission_fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final identity = IdentityFixture();
  await identity.activate();
  final receiver = SubmissionFixture();
  await receiver.open();
  final session = ChildSession(
      identity: identity.identity,
      submissionFactory: (_) async => receiver,
      nowMillis: () => IdentityFixture.now);
  await session.initialize();
  for (var i = 0; session.busy && i < 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  final state = Uri.base.queryParameters['state'];
  if (state == 'unknown') {
    receiver.loseResponse = true;
    await session.createSubmission(SubmissionFixture.input(),
        applicationName: '阅读空间');
  } else if (state == 'offline') {
    await session.submissionDetail(SubmissionFixture.request);
    receiver.failure =
        const AccessTransportFailure('CONNECTION_FAILED', retryable: true);
    await session.refreshSubmissions();
  }
  runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: childTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent()
          },
          child: Scaffold(
              appBar: AppBar(title: const Text('我的规则 · 访问申请')),
              body: SingleChildScrollView(
                  child: Center(
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const ChildNotice('公开合成界面样例',
                                        detail:
                                            '仅用于交互验收，不连接真实服务或设备，不输入真实私人资料。'),
                                    const SizedBox(height: 24),
                                    SubmissionSection(
                                        session: session, available: true)
                                  ])))))))));
}
