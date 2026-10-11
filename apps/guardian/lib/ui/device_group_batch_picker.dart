import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/labels.dart';
import 'design.dart';

/// Explicit device registration selection for one atomic group-membership request.
class DeviceGroupBatchPicker extends StatefulWidget {
  final Api api;
  final String root;
  final String? groupId;
  final bool Function() current;

  const DeviceGroupBatchPicker(
      {super.key,
      required this.api,
      required this.root,
      this.groupId,
      required this.current});

  @override
  State<DeviceGroupBatchPicker> createState() => _DeviceGroupBatchPickerState();
}

class _DeviceGroupBatchPickerState extends State<DeviceGroupBatchPicker> {
  final selected = <String, Json>{};
  List<Json> devices = const [];
  String? cursor;
  Object? error;
  bool loading = false;
  bool get removing => widget.groupId != null;
  String idOf(Json row) => row[removing ? 'deviceId' : 'id'] as String;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  Future<void> load({bool more = false}) async {
    if (!mounted || !widget.current() || loading || (more && cursor == null)) {
      return;
    }
    final requestedCursor = more ? cursor : null;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final path = removing
          ? '${widget.root}/device-groups/${widget.groupId}/devices'
          : '${widget.root}/devices';
      final page = await widget.api.page(path, cursor: requestedCursor);
      if (!mounted || !widget.current()) return;
      final seen = more ? devices.map(idOf).toSet() : <String>{};
      for (final row in page.items) {
        if (row[removing ? 'deviceId' : 'id'] is! String ||
            row['registrationId'] is! String ||
            row['displayName'] is! String ||
            row['state'] is! String ||
            row['platform'] is! String ||
            (removing && row['membershipStatus'] is! String) ||
            !seen.add(idOf(row))) {
          throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
        }
      }
      setState(() {
        devices =
            List.unmodifiable(more ? [...devices, ...page.items] : page.items);
        cursor = page.nextCursor;
      });
    } catch (failure) {
      if (mounted && widget.current()) setState(() => error = failure);
    } finally {
      if (mounted && widget.current()) setState(() => loading = false);
    }
  }

  void toggle(Json row) {
    final id = idOf(row);
    setState(() {
      if (selected.containsKey(id)) {
        selected.remove(id);
      } else if (selected.length < 50) {
        selected[id] = row;
      }
    });
  }

  @override
  Widget build(BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(removing ? '批量移出设备组' : '批量加入设备组',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(removing
                    ? '可清理停用、旧注册周期及其他成员；单次最多 50 台。移出不撤销设备注册或已有独立策略。'
                    : '仅可选择已激活的本机构设备；单次最多 50 台。确认时会重新核对每台设备的注册周期。'),
                const SizedBox(height: 12),
                Text('已选择 ${selected.length} / 50 台',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (loading) const LinearProgressIndicator(),
                if (error != null)
                  FailureView(error!, retry: () => load(more: cursor != null)),
                Expanded(
                  child: devices.isEmpty && !loading && error == null
                      ? EmptyView(removing ? '组内没有设备' : '没有可选设备',
                          removing ? '当前设备组已没有需要清理的成员。' : '请先注册并激活机构设备。')
                      : ListView.builder(
                          itemCount: devices.length + (cursor == null ? 0 : 1),
                          itemBuilder: (context, index) {
                            if (index == devices.length) {
                              return TextButton.icon(
                                onPressed:
                                    loading ? null : () => load(more: true),
                                icon: const Icon(Icons.expand_more),
                                label: const Text('加载更多设备'),
                              );
                            }
                            final row = devices[index];
                            final id = idOf(row);
                            final active = row['state'] == 'ACTIVE';
                            final checked = selected.containsKey(id);
                            return CheckboxListTile(
                              value: checked,
                              onChanged: (removing || active) &&
                                      (checked || selected.length < 50)
                                  ? (_) => toggle(row)
                                  : null,
                              title: Text(row['displayName'] as String),
                              subtitle: Text(
                                  '${label(row['platform'])} · ${label(row['state'])}'
                                  '${removing ? ' · ${label(row['membershipStatus'])}' : ''}\n$id'),
                              isThreeLine: true,
                              controlAffinity: ListTileControlAffinity.leading,
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: selected.isEmpty || !widget.current()
                            ? null
                            : () => Navigator.of(context)
                                .pop(List<Json>.unmodifiable(selected.values)),
                        child: Text(
                            '核对并${removing ? '移出' : '加入'} ${selected.length} 台')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}
