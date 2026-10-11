import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/labels.dart';
import 'design.dart';

/// Explicit device registration selection for one atomic group-membership request.
class DeviceGroupBatchPicker extends StatefulWidget {
  final Api api;
  final String root;
  final bool Function() current;

  const DeviceGroupBatchPicker(
      {super.key,
      required this.api,
      required this.root,
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
      final page = await widget.api
          .page('${widget.root}/devices', cursor: requestedCursor);
      if (!mounted || !widget.current()) return;
      final seen = more ? devices.map((d) => d['id']).toSet() : <Object?>{};
      for (final row in page.items) {
        if (row['id'] is! String ||
            row['registrationId'] is! String ||
            row['displayName'] is! String ||
            row['state'] is! String ||
            row['platform'] is! String ||
            !seen.add(row['id'])) {
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
    final id = row['id'] as String;
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
                Text('批量加入设备组', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('仅可选择已激活的本机构设备；单次最多 50 台。确认时会重新核对每台设备的注册周期。'),
                const SizedBox(height: 12),
                Text('已选择 ${selected.length} / 50 台',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (loading) const LinearProgressIndicator(),
                if (error != null)
                  FailureView(error!, retry: () => load(more: cursor != null)),
                Expanded(
                  child: devices.isEmpty && !loading && error == null
                      ? const EmptyView('没有可选设备', '请先注册并激活机构设备。')
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
                            final id = row['id'] as String;
                            final active = row['state'] == 'ACTIVE';
                            final checked = selected.containsKey(id);
                            return CheckboxListTile(
                              value: checked,
                              onChanged:
                                  active && (checked || selected.length < 50)
                                      ? (_) => toggle(row)
                                      : null,
                              title: Text(row['displayName'] as String),
                              subtitle: Text(
                                  '${label(row['platform'])} · ${label(row['state'])}\n$id'),
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
                        child: Text('核对并加入 ${selected.length} 台')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}
