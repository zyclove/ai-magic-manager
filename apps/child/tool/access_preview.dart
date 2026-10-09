// Public UI fixture only. This entrypoint never opens storage or a connection.
import 'package:child/core/access.dart';
import 'package:child/ui/access_section.dart';
import 'package:child/ui/design.dart';
import 'package:device_access/device_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

void main() => runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: childTheme(),
    locale: const Locale('zh', 'CN'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('zh', 'CN')],
    home: const _Preview()));

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  int state = 0, syncs = 0;
  static const labels = ['离线记录', '已到期', '已撤回', '需要核对'];
  ChildAccessSnapshot get view => ChildAccessSnapshot(
          contextReady: true,
          onlineConfirmed: state != 0,
          pendingReceipts: state == 0 ? 1 : 0,
          entries: [
            ChildAccessEntry(
                AccessJournalEntry(
                    VerifiedAccessWindow.internal('public-ui-fixture-only', {
                      'grantIssuedAt': 1791504000000,
                      'absoluteNotAfter': 1791505800000,
                      'approvalState': state == 2 ? 'REVOKED' : 'APPROVED'
                    }),
                    state == 1
                        ? AccessEntryState.expired
                        : state == 2
                            ? AccessEntryState.removed
                            : AccessEntryState.stored,
                    pendingAcknowledgement: state == 0),
                '阅读练习',
                requiresReview: state == 3)
          ]);
  @override
  Widget build(BuildContext context) => Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent()
          },
          child: Scaffold(
              appBar: AppBar(title: const Text('我的规则 · 临时访问')),
              body: SingleChildScrollView(
                  child: Center(
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 680),
                          child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const ChildNotice('界面验收样例，不连接真实设备',
                                        detail: '公开合成状态，不读取身份、授权或使用记录。'),
                                    const SizedBox(height: 20),
                                    Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: List.generate(
                                            labels.length,
                                            (index) => ChoiceChip(
                                                label: Text(labels[index]),
                                                selected: state == index,
                                                onSelected: (_) => setState(
                                                    () => state = index)))),
                                    const Divider(),
                                    AccessSection(
                                        view: view,
                                        synchronize: () =>
                                            setState(() => syncs++)),
                                    const Divider(),
                                    Text('样例同步次数：$syncs')
                                  ])))))));
}
