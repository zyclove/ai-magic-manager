import 'package:device_observation/device_observation.dart';
import 'package:flutter/material.dart';
import 'design.dart';

class ObservationSection extends StatelessWidget {
  final ObservationView view;
  final bool busy, available;
  final String? errorCode;
  final VoidCallback? refresh, synchronize, openSettings;
  const ObservationSection(
      {super.key,
      required this.view,
      this.busy = false,
      this.available = true,
      this.errorCode,
      this.refresh,
      this.synchronize,
      this.openSettings});
  String _authorization(bool? enabled) {
    if (enabled == null) return '等待在线核对';
    if (!view.onlineConfirmed) return enabled ? '上次允许，需在线核对' : '上次关闭，需在线核对';
    return enabled ? '监护人已允许' : '监护人未允许';
  }

  String _error(String code) => switch (code) {
        'CONNECTION_FAILED' || 'NETWORK_TIMEOUT' => '暂时无法在线核对，已暂停新采集。请检查网络后刷新。',
        'OBSERVATION_STORAGE_FAILED' ||
        'OBSERVATION_STORAGE_UNAVAILABLE' =>
          '加密存储暂不可用，已停止采集与上传。请联系监护人。',
        'USAGE_ACCESS_NOT_GRANTED' ||
        'OBSERVATION_ACCESS_DENIED' =>
          '系统尚未允许访问使用情况，未继续采集。',
        'OBSERVATION_NOT_AUTHORIZED' ||
        'OBSERVATION_AUTHORIZATION_CHANGED' =>
          '管理员授权已变化，旧的待发数据已停止使用。请刷新授权状态。',
        'OBSERVATION_AUTHORIZATION_ROLLBACK' ||
        'OBSERVATION_AUTHORIZATION_INVALID' =>
          '在线授权未通过校验，已停止采集。请监护人检查服务。',
        'OBSERVATION_ACK_INVALID' => '服务器回执未通过校验，待发请求会保留。请重试或联系监护人。',
        'OBSERVATION_REPORT_RATE_LIMITED' => '同步过于频繁，请稍后再试。',
        'OBSERVATION_SAMPLE_INVALID' ||
        'OBSERVATION_LIMIT_EXCEEDED' =>
          '系统数据暂时无法安全报告，未上传不完整或异常数据。请联系监护人。',
        'OBSERVATION_DEVICE_LOCKED' => '设备尚未解锁，暂不读取使用情况。',
        _ => '此次同步未完成。请刷新授权状态或联系监护人。'
      };
  Widget _status(IconData icon, String title, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: childNavy),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: childNavy)),
          Text(value)
        ]))
      ]));
  String _time(int? millis) {
    if (millis == null) return '尚无确认记录';
    try {
      return DateTime.fromMillisecondsSinceEpoch(millis)
          .toLocal()
          .toString()
          .split('.')
          .first;
    } catch (_) {
      return '时间不可用';
    }
  }

  Future<void> _settings(BuildContext context) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('允许查看系统使用摘要'),
                content: const SingleChildScrollView(
                    child: Text('监护人已允许使用摘要。接下来由系统设置决定本应用能否访问系统聚合数据。\n\n'
                        '只报告当前用户可见启动应用的聚合区间与时长，不读取原始操作事件、网页内容或摄像头。该访问不会阻止其他应用。\n\n'
                        '你可以在系统中撤回访问。返回后会重新核对，未满足两项授权前不会读取使用记录。')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('暂不打开')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('前往系统设置'))
                ]));
    if (confirmed == true) openSettings?.call();
  }

  @override
  Widget build(BuildContext context) {
    final authorization = view.authorization, platform = view.platform;
    final usable = available && !busy;
    final canCollect = usable &&
        view.onlineConfirmed &&
        platform?.unlocked == true &&
        (authorization?.inventoryEnabled == true ||
            authorization?.usageEnabled == true &&
                platform?.usageGranted == true);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
          header: true,
          child:
              Text('使用情况与隐私', style: Theme.of(context).textTheme.titleLarge)),
      const SizedBox(height: 12),
      const Text('由监护人分别授权。只报告可见应用与系统聚合，不采集原始行为或摄像头。'),
      if (!view.onlineConfirmed) ...[
        const SizedBox(height: 12),
        const ChildNotice('尚未在线核对当前授权', detail: '下方可能是上次缓存设置。核对完成前不会新增采集。')
      ],
      _status(Icons.apps_outlined, '应用清单',
          _authorization(authorization?.inventoryEnabled)),
      _status(Icons.timer_outlined, '使用摘要',
          _authorization(authorization?.usageEnabled)),
      _status(
          Icons.privacy_tip_outlined,
          '系统特殊访问',
          platform == null
              ? '等待检查系统许可'
              : !platform.unlocked
                  ? '设备尚未解锁'
                  : !platform.usageSupported
                      ? '系统不支持使用摘要'
                      : platform.usageGranted
                          ? '系统访问已允许'
                          : '系统访问未授予'),
      if (platform?.television == true) const Text('已检测到电视特征；实际设备兼容性仍需核对。'),
      const SizedBox(height: 12),
      Text('清单最近确认：${_time(view.lastInventoryAt)}'),
      if (view.lastInventoryAt != null)
        Text('已确认可见应用：${view.inventoryCount}；不代表完整安装清单。'),
      const SizedBox(height: 8),
      Text('摘要最近确认：${_time(view.lastUsageAt)}'),
      if (view.lastUsageAt != null)
        Text('最近报告 ${view.usageCount} 条系统聚合记录；区间可能超出查询范围，不作为精确计费。'),
      if (view.pendingReports > 0)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('等待确认的请求：${view.pendingReports}，重试会先核对当前授权。')),
      if (errorCode != null) ...[
        const SizedBox(height: 16),
        Semantics(
            liveRegion: true,
            child: ChildNotice(_error(errorCode!), warning: true))
      ],
      const SizedBox(height: 20),
      SizedBox(
          width: double.infinity,
          child: OutlinedButton(
              onPressed: usable ? refresh : null, child: const Text('刷新授权状态'))),
      const SizedBox(height: 12),
      SizedBox(
          width: double.infinity,
          child: FilledButton(
              onPressed: canCollect ? synchronize : null,
              child: const Text('同步已授权数据'))),
      if (authorization?.usageEnabled == true &&
          view.onlineConfirmed &&
          platform?.usageGranted == false &&
          platform?.usageSupported == true) ...[
        const SizedBox(height: 12),
        SizedBox(
            width: double.infinity,
            child: OutlinedButton(
                onPressed: usable && openSettings != null
                    ? () => _settings(context)
                    : null,
                child: const Text('打开系统使用情况访问')))
      ],
      const SizedBox(height: 12),
      const Text('撤回云端授权后，服务器阻止后续报告并清理对应观察数据。设备下次联网核对时清理待发数据。')
    ]);
  }
}
