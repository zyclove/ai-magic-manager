import 'package:flutter/material.dart';
import 'package:usage_report_ui/usage_report_ui.dart';
import '../core/report_loader.dart';
import '../core/session.dart';
import 'design.dart';

class ChildReportSection extends StatefulWidget {
  final ChildSession session;
  final ChildReportFactory? factory;
  final bool nativeAvailable;
  final VoidCallback reconnect;
  const ChildReportSection(
      {super.key,
      required this.session,
      required this.factory,
      required this.nativeAvailable,
      required this.reconnect});
  @override
  State<ChildReportSection> createState() => _ChildReportSectionState();
}

class _ChildReportSectionState extends State<ChildReportSection> {
  ChildReports? _reports;
  @override
  void initState() {
    super.initState();
    _reports =
        widget.nativeAvailable ? widget.factory?.call(widget.session) : null;
  }

  @override
  void didUpdateWidget(covariant ChildReportSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nativeAvailable != widget.nativeAvailable ||
        oldWidget.session != widget.session ||
        oldWidget.factory != widget.factory) {
      _reports?.close();
      _reports =
          widget.nativeAvailable ? widget.factory?.call(widget.session) : null;
    }
  }

  @override
  void dispose() {
    _reports?.close();
    super.dispose();
  }

  bool get available =>
      widget.nativeAvailable &&
      widget.session.foreground &&
      widget.session.identityReadSucceeded &&
      widget.session.credentialReady &&
      widget.session.identityView?.cloudAuthenticationBlocked == false;
  @override
  Widget build(BuildContext context) {
    final reports = _reports;
    if (!widget.nativeAvailable || reports == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('我的使用情况', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        const ChildNotice('本设备报表尚不可用',
            detail: '请在已配置并连接的 Android 设备端查看。浏览器预览不会读取设备私有报表。'),
        TextButton(onPressed: widget.reconnect, child: const Text('检查设备连接'))
      ]);
    }
    return DeviceUsageReportView(
        key: ObjectKey(reports),
        load: reports.load,
        cancel: reports.cancel,
        accessChanges: widget.session,
        available: () => available,
        reconnect: widget.reconnect);
  }
}
