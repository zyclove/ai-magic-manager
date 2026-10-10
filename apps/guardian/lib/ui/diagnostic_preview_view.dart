import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../core/device_diagnostic.dart';

class DiagnosticPreviewView extends StatefulWidget {
  final Future<DeviceDiagnostic> Function() load;
  final bool Function() current;
  final Listenable? accessChanges;
  final VoidCallback? onReauth;
  final VoidCallback onClose;
  const DiagnosticPreviewView(
      {super.key,
      required this.load,
      required this.current,
      this.accessChanges,
      this.onReauth,
      required this.onClose});
  @override
  State<DiagnosticPreviewView> createState() => _DiagnosticPreviewViewState();
}

class _DiagnosticPreviewViewState extends State<DiagnosticPreviewView>
    with WidgetsBindingObserver {
  DeviceDiagnostic? report;
  ApiFailure? error;
  bool loading = false, foreground = true, invalidated = false, cleared = false;
  int generation = 0;
  bool get current => mounted && foreground && !invalidated && widget.current();

  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    invalidated = !widget.current();
    WidgetsBinding.instance.addObserver(this);
    widget.accessChanges?.addListener(accessChanged);
  }

  @override
  void didUpdateWidget(covariant DiagnosticPreviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accessChanges != widget.accessChanges) {
      oldWidget.accessChanges?.removeListener(accessChanged);
      widget.accessChanges?.addListener(accessChanged);
    }
    if (!widget.current()) {
      invalidated = true;
      clear();
    }
  }

  void clear() {
    generation++;
    report = null;
    error = null;
    loading = false;
    cleared = true;
  }

  void accessChanged() {
    if (!mounted || widget.current()) return;
    setState(() {
      invalidated = true;
      clear();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() {
      foreground = state == AppLifecycleState.resumed;
      clear();
    });
  }

  @override
  void dispose() {
    generation++;
    widget.accessChanges?.removeListener(accessChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    if (!current || loading) return;
    final expected = ++generation;
    setState(() {
      loading = true;
      report = null;
      error = null;
    });
    try {
      final result = await widget.load();
      if (current && generation == expected) setState(() => report = result);
    } catch (failure) {
      if (current && generation == expected) {
        setState(() => error = failure is ApiFailure
            ? failure
            : const ApiFailure(0, 'NETWORK_ERROR'));
      }
    } finally {
      if (current && generation == expected) setState(() => loading = false);
    }
  }

  String time(int? value) {
    if (value == null) return '尚无记录';
    try {
      return DateFormat('yyyy-MM-dd HH:mm:ss')
          .format(DateTime.fromMillisecondsSinceEpoch(value));
    } on ArgumentError {
      return '时间未知';
    }
  }

  String version(DiagnosticVersion value) => value.status == 'REPORTED'
      ? value.value!
      : value.status == 'REDACTED'
          ? '已脱敏'
          : '尚未报告';
  String errorMessage(ApiFailure failure) => switch (failure.code) {
        'DIAGNOSTIC_TOO_LARGE' => '诊断数据超过单次读取上限，请联系管理员排查设备上报和当前配置数量。',
        'DIAGNOSTIC_SCOPE_CHANGED' ||
        'WORKSPACE_CHANGED' =>
          '设备绑定或工作空间已变化，请关闭后重新打开。',
        'DIAGNOSTIC_SOURCE_INVALID' ||
        'INVALID_DIAGNOSTIC_RESPONSE' =>
          '诊断数据不完整，本次未展示结果。请稍后重新读取。',
        'DIAGNOSTIC_SERIALIZATION_FAILED' => '暂时无法生成诊断，请稍后重试。',
        _ => failure.message,
      };
  Widget fact(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        SelectionArea(child: Text(value))
      ]));
  Widget heading(String title) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 10),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium));
  Widget facts(List<(String, String)> values) =>
      LayoutBuilder(builder: (context, size) {
        final width =
            size.maxWidth < 520 ? size.maxWidth : (size.maxWidth - 24) / 2;
        return Wrap(spacing: 24, children: [
          for (final value in values)
            SizedBox(width: width, child: fact(value.$1, value.$2))
        ]);
      });

  Widget result(DeviceDiagnostic value) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('设备自报与下发记录，不代表策略已执行。'),
        const SizedBox(height: 10),
        Text('读取时间：${time(value.generatedAt)} · 本机时间',
            style: Theme.of(context).textTheme.bodySmall),
        heading('设备与版本'),
        facts([
          ('设备状态', label(value.state)),
          ('平台', value.platform == 'ANDROID_TV' ? 'Android TV' : 'Android'),
          ('系统版本', version(value.os)),
          ('设备应用版本', version(value.agent)),
          ('服务端版本', version(value.server)),
          ('管理模式', label(value.managementMode)),
          ('控制能力', label(value.controlLevel)),
          ('心跳观察', label(value.observationStatus)),
          ('最后心跳', time(value.lastHeartbeatAt)),
        ]),
        heading('设备能力'),
        if (value.capabilities.isEmpty) const Text('尚无可识别的能力记录。'),
        for (final capability in value.capabilities)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(capabilityName(capability.key),
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                        '${label(capability.status)} · 授权${label(capability.grantStatus)}'),
                    Text(
                        '设备自报${capability.reportedSupported ? '支持' : '不支持'} · ${label(capability.evidenceSource)}',
                        style: Theme.of(context).textTheme.bodySmall),
                    Text('检查时间：${time(capability.checkedAt)}',
                        style: Theme.of(context).textTheme.bodySmall),
                    Text(label(capability.limitationCode),
                        style: Theme.of(context).textTheme.bodySmall),
                  ])),
        if (value.omittedCapabilityCount > 0)
          Text('另有 ${value.omittedCapabilityCount} 项未识别能力已省略原文。'),
        heading('当前配置下发'),
        if (value.configurations.isEmpty) const Text('当前注册周期暂无配置下发记录。'),
        for (var i = 0; i < value.configurations.length; i++)
          configuration(value.configurations[i], i + 1),
        heading('本次诊断标识'),
        SelectionArea(child: Text(value.correlationId)),
        const SizedBox(height: 6),
        const Text('联系管理员排查时可提供此标识。预览不包含令牌、密钥、配置正文或儿童自由文本。'),
      ]);
  Widget configuration(DiagnosticConfiguration value, int index) =>
      ExpansionTile(
          key: ValueKey('${generation}/${value.id}'),
          tilePadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: Text('配置 $index'),
          subtitle: Text(label(value.deliveryState)),
          children: [
            facts([
              ('操作', label(value.action)),
              ('版本序号', '${value.sourceSequence}'),
              ('下发时间', time(value.issuedAt)),
              ('下发到期', time(value.deliveryExpiresAt)),
              ('设备报告收到', time(value.receivedReportedAt)),
              ('设备报告保存', time(value.storedReportedAt)),
              if (value.rejectionCode != null)
                ('拒绝原因', label(value.rejectionCode!)),
            ]),
            fact('策略指纹', value.policyHash ?? '尚无有效指纹'),
            fact('配置指纹', value.configurationHash ?? '尚无有效指纹')
          ]);

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('设备诊断', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('仅供管理员读取脱敏状态。此预览不授予远程支持访问。'),
        const SizedBox(height: 12),
        if (loading) const LinearProgressIndicator(),
        const Divider(),
        Expanded(
            child: SingleChildScrollView(
                child: invalidated || !widget.current()
                    ? const Text('账号或设备范围已变化，请关闭后重新打开。')
                    : !foreground
                        ? const Text('已进入后台，诊断信息已清除。')
                        : report != null
                            ? result(report!)
                            : error != null
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                        Text(errorMessage(error!)),
                                        if (error!.correlationId != null &&
                                            RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
                                                .hasMatch(
                                                    error!.correlationId!))
                                          Padding(
                                              padding: const EdgeInsets.only(
                                                  top: 12),
                                              child: SelectionArea(
                                                  child: Text(
                                                      '请求标识：${error!.correlationId}'))),
                                        if (error!.code == 'REAUTH_REQUIRED' &&
                                            widget.onReauth != null)
                                          TextButton.icon(
                                              onPressed: widget.onReauth,
                                              icon: const Icon(
                                                  Icons.verified_user_outlined),
                                              label: const Text('重新认证')),
                                      ])
                                : Text(loading
                                    ? '正在读取当前设备状态…'
                                    : cleared
                                        ? '诊断信息已清除，请重新读取。'
                                        : '诊断信息尚未读取'))),
        const Divider(),
        Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              TextButton(onPressed: widget.onClose, child: const Text('关闭')),
              FilledButton.icon(
                  onPressed: current && !loading ? load : null,
                  icon: const Icon(Icons.refresh),
                  label: Text(report == null ? '读取诊断' : '刷新诊断')),
            ]),
      ]));
}

String capabilityName(String key) =>
    const {
      'managed.app_policy': '受管应用策略',
      'app.install_policy': '应用安装管理',
      'app.launch_block': '应用启动限制',
      'permission.runtime': '运行时权限管理',
      'device.lock_task': '专用设备模式',
      'usage.shared_quota_enforced': '共享额度执行',
      'usage.report': '使用情况报告',
      'network.domain_filter': '网络域名过滤',
    }[key] ??
    '未知能力';

String label(String value) =>
    const {
      'ACTIVE': '已激活',
      'AWAITING_CONFIRMATION': '待确认',
      'REVOKED': '已撤销',
      'BYOD': '个人设备',
      'WORK_PROFILE': '工作资料',
      'FULLY_MANAGED': '完全受管',
      'DEDICATED': '专用设备',
      'UNVERIFIED': '尚未验证',
      'LIMITED': '有限',
      'NONE': '无',
      'RECENT': '最近有心跳',
      'STALE': '记录已过期',
      'UNKNOWN': '未知',
      'UNSUPPORTED': '不支持',
      'GRANTED': '已授予',
      'DENIED': '已拒绝',
      'NOT_REQUESTED': '尚未申请',
      'NOT_APPLICABLE': '不适用',
      'AGENT_REPORT': '设备上报',
      'REGISTRATION_MODE': '注册模式',
      'MANAGED_REGISTRATION_REQUIRED': '需要受管设备注册。',
      'EVIDENCE_NOT_CERTIFIED': '此证据尚未经过执行能力认证。',
      'PENDING_SIGNATURE': '等待签名',
      'READY': '等待设备拉取',
      'SERVED': '已提供给设备',
      'DEVICE_REPORTED_RECEIVED': '设备报告已收到',
      'DEVICE_REPORTED_STORED': '设备报告已保存',
      'DEVICE_REPORTED_REJECTED': '设备报告已拒绝',
      'EXPIRED_AWAITING_PULL': '已过期，未取得保存确认',
      'UPSERT_CONFIGURATION': '设置配置',
      'REMOVE_CONFIGURATION': '撤销配置',
      'UNSUPPORTED_SCHEMA': '不支持的格式版本',
      'SIGNATURE_INVALID': '签名无效',
      'IDENTITY_MISMATCH': '身份不匹配',
      'UNSUPPORTED_RULES': '规则不受支持',
      'STORAGE_FAILURE': '保存失败',
      'EXPIRED': '已过期',
      'OLDER_VERSION': '版本过旧',
      'UNKNOWN_REJECTION': '未知拒绝原因',
    }[value] ??
    '未知';
