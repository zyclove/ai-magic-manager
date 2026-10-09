import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/observation.dart';
import 'design.dart';

class ObservationView extends StatelessWidget {
  final ObservationSnapshot? snapshot;
  final bool busy, canEdit;
  final String deviceName;
  final Object? error;
  final VoidCallback? refresh, edit, previous, next, reauth;
  const ObservationView(
      {super.key,
      this.snapshot,
      this.busy = false,
      this.canEdit = false,
      required this.deviceName,
      this.error,
      this.refresh,
      this.edit,
      this.previous,
      this.next,
      this.reauth});
  @override
  Widget build(BuildContext context) {
    final loaded = error == null ? snapshot : null;
    final settings = loaded?.settings;
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          PageHeading('使用情况与隐私', deviceName,
              action: Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                    onPressed: busy ? null : refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新状态')),
                if (canEdit && settings != null)
                  FilledButton.icon(
                      onPressed: busy ? null : edit,
                      icon: const Icon(Icons.privacy_tip_outlined),
                      label: const Text('修改观察授权')),
              ])),
          const Notice('观察与系统控制分开：清单仅含可见启动应用；使用摘要是设备自报系统聚合。'
              '不读取摄像头、原始行为或网页内容，不将重叠区间相加为今日总量，也不用于精确计费。'),
          const SizedBox(height: 16),
          if (busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 16)
          ],
          if (error != null) ...[
            Semantics(
                liveRegion: true,
                child: Notice(observationError(error!), warning: true)),
            if (error is ApiFailure &&
                (error as ApiFailure).status == 401 &&
                reauth != null)
              TextButton.icon(
                  onPressed: reauth,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('重新安全验证')),
          ] else if (settings != null) ...[
            Panel(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('当前管理员授权',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    Chip(
                        avatar: Icon(
                            settings.inventoryEnabled
                                ? Icons.check_circle_outline
                                : Icons.block_outlined,
                            size: 18),
                        label: Text(
                            '应用清单 · ${settings.inventoryEnabled ? '允许' : '关闭'}')),
                    Chip(
                        avatar: Icon(
                            settings.usageEnabled
                                ? Icons.check_circle_outline
                                : Icons.block_outlined,
                            size: 18),
                        label: Text(
                            '使用摘要 · ${settings.usageEnabled ? '允许' : '关闭'}')),
                  ]),
                  const SizedBox(height: 12),
                  Text(
                      '授权版本 ${settings.version} · ${settings.updatedAt == null ? '尚未设置，默认关闭' : observationMoment(settings.updatedAt!)}'),
                  const SizedBox(height: 8),
                  const Text('系统特殊访问仍须设备侧允许。云端授权不证明设备已采集或已执行管控。',
                      style: TextStyle(color: muted)),
                  if (!canEdit)
                    const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('当前为只读查看；修改授权须由监护人或机构管理员完成近期多因素认证。')),
                ])),
            const SizedBox(height: 20),
            if (!settings.usageEnabled)
              const Panel(
                  child: EmptyView('使用摘要未授权',
                      '当前没有开放使用摘要，不能据此判断没有使用应用。授权关闭后服务器清理摘要，设备须下次联网核对本地待发数据。'))
            else if (loaded!.batches.isEmpty)
              const Panel(
                  child: EmptyView('尚无可查看摘要',
                      '请在设备侧核对系统许可并同步。也可能没有可见应用记录或历史已经清理，不能据此判断没有使用应用。'))
            else ...[
              Text('最近报告 · 每页最多 5 批',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                  '下方时间统一为 UTC；系统实际区间可能超出请求区间，批次间可能重叠。保留上限和批次数限制会裁剪历史，不能作为完整趋势。',
                  style: TextStyle(color: muted)),
              const SizedBox(height: 12),
              for (final batch in loaded.batches)
                Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _BatchCard(batch)),
            ],
            if (settings.usageEnabled)
              Wrap(spacing: 12, runSpacing: 8, children: [
                OutlinedButton(
                    onPressed: busy ? null : previous,
                    child: const Text('上一页')),
                OutlinedButton(
                    onPressed: busy || loaded!.nextCursor == null ? null : next,
                    child: const Text('下一页')),
              ]),
          ] else if (!busy)
            const EmptyView('等待读取授权', '请刷新当前设备的观察设置。'),
        ]);
  }
}

String observationMoment(int value) =>
    '${DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toIso8601String().split('.').first.replaceFirst('T', ' ')} UTC';

class _BatchCard extends StatelessWidget {
  final ObservedUsageBatch batch;
  const _BatchCard(this.batch);
  @override
  Widget build(BuildContext context) => Panel(
      padding: const EdgeInsets.all(8),
      child: ExpansionTile(
        title: Text('报告 #${batch.sequence} · ${batch.applications.length} 条聚合'),
        subtitle:
            Text('系统聚合 · 设备自报，尚未验证\n接收：${observationMoment(batch.receivedAt)}'),
        childrenPadding: const EdgeInsets.all(12),
        children: [
          Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  '资料：${observationProfile(batch.profile)} · 授权版本 ${batch.authorizationVersion}\n'
                  '设备报告时区：${batch.timeZone}\n'
                  '请求区间：${observationMoment(batch.queryStart)} 至 ${observationMoment(batch.queryEnd)}\n'
                  '设备观测：${observationMoment(batch.observedAt)}')),
          const SizedBox(height: 16),
          if (batch.applications.isEmpty)
            const Notice('此批没有可见应用聚合记录，不代表整台设备没有使用。')
          else
            SizedBox(
                height: (batch.applications.length * 156.0).clamp(120.0, 360.0),
                child: ListView.separated(
                    itemCount: batch.applications.length,
                    separatorBuilder: (_, __) => const Divider(height: 24),
                    itemBuilder: (_, index) {
                      final app = batch.applications[index];
                      return Semantics(
                          container: true,
                          label:
                              '${app.displayName}，${app.packageName}，前台 ${observationDuration(app.foregroundMillis)}，实际系统区间 ${observationMoment(app.firstTimeStamp)} 至 ${observationMoment(app.lastTimeStamp)}',
                          child: ExcludeSemantics(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(app.displayName,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                SelectableText(app.packageName,
                                    style: const TextStyle(
                                        color: muted, fontSize: 12)),
                                const SizedBox(height: 6),
                                Text(
                                    '前台 ${observationDuration(app.foregroundMillis)}'),
                                Text(
                                    '实际系统区间：${observationMoment(app.firstTimeStamp)} 至 ${observationMoment(app.lastTimeStamp)}',
                                    style: const TextStyle(
                                        color: muted, fontSize: 12)),
                              ])));
                    })),
        ],
      ));
}
