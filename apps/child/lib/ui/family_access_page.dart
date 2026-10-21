import 'dart:async';
import 'package:flutter/material.dart';
import '../core/family_access.dart';
import '../core/session.dart';
import '../core/assisted_runtime.dart';
import 'design.dart';

class FamilyAccessPage extends StatefulWidget {
  final ChildSession session;
  final FamilyAccessFactory factory;
  final AndroidAssistedRuntime? runtime;
  const FamilyAccessPage(
      {super.key, required this.session, required this.factory, this.runtime});
  @override
  State<FamilyAccessPage> createState() => _FamilyAccessPageState();
}

class _FamilyAccessPageState extends State<FamilyAccessPage>
    with WidgetsBindingObserver {
  final _reason = TextEditingController();
  FamilyAccessCoordinator? _owner;
  FamilyAccessRecord? _record;
  String? _error;
  bool _busy = false,
      _loading = true,
      _storageBlocked = false,
      _resumePending = false;
  int _seconds = 300, _generation = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_sessionChanged);
    widget.runtime?.addListener(_nativeChanged);
    try {
      _owner = widget.factory(widget.session);
      unawaited(_restore());
    } catch (_) {
      _error = 'DEVICE_CREDENTIAL_UNAVAILABLE';
      _loading = false;
    }
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_busy && _owner?.current == true && _record?.state == 'PENDING') {
        unawaited(_run(() => _owner!.refresh()));
      }
    });
  }

  void _nativeChanged() {
    if (mounted) setState(() {});
  }

  void _sessionChanged() {
    if (_owner?.current != true) {
      _owner?.pause();
      _generation++;
      _reason.clear();
      if (mounted) {
        setState(() {
          _record = null;
          _busy = false;
        });
      }
    } else if (_resumePending) {
      _resumePending = false;
      unawaited(_restore());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumePending = true;
      _sessionChanged();
    } else {
      _owner?.pause();
      _generation++;
      _reason.clear();
      if (mounted) {
        setState(() {
          _record = null;
          _busy = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _restore() async {
    final owner = _owner;
    if (owner == null || !owner.current) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = await owner.restore();
      if (mounted && generation == _generation && owner.current) {
        setState(() {
          _record = next;
          _storageBlocked = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = 'FAMILY_ACCESS_STORAGE_UNAVAILABLE';
          _storageBlocked = true;
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _run(Future<FamilyAccessRecord?> Function() action) async {
    final owner = _owner;
    if (_busy || _storageBlocked || owner?.current != true) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await action();
      if (mounted && generation == _generation && owner!.current) {
        setState(() => _record = next);
      }
    } on FamilyAccessFailure catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.code);
      }
      try {
        final restored = await owner!.restore();
        if (mounted && generation == _generation && owner.current) {
          setState(() => _record = restored);
        }
      } catch (_) {
        if (mounted && generation == _generation) {
          setState(() => _storageBlocked = true);
        }
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final generation = _generation;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
                title: const Text('发送临时放行申请'),
                content:
                    Text('申请 ${_seconds ~/ 60} 分钟。家长批准后，还需要同步已验证的签名安排并核对本机状态。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: const Text('返回')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialog, true),
                      child: const Text('确认发送'))
                ]));
    if (confirmed == true &&
        mounted &&
        generation == _generation &&
        _owner?.current == true) {
      await _run(() => _owner!.submit(_seconds, reason: _reason.text));
      if (_record != null) _reason.clear();
    }
  }

  String _status(FamilyAccessRecord record) {
    if (!record.confirmed) return '提交结果尚未确认';
    return switch (record.state) {
      'PENDING' => '云端已收到，等待家长处理',
      'APPROVED' => '云端已批准，等待本机核对',
      'DENIED' => '家长未同意这次申请',
      'EXPIRED' => '这次申请已到期',
      _ => '申请状态需要核对',
    };
  }

  String _errorText(String code) => switch (code) {
        'FAMILY_ACCESS_RULE_SYNC_PENDING' => '批准已保存，但签名安排同步尚未完成。请重试核对。',
        'FAMILY_ACCESS_NETWORK_UNKNOWN' ||
        'FAMILY_ACCESS_SERVER_UNAVAILABLE' =>
          '暂时无法确认云端结果。原申请已保留，请核对并重试原申请。',
        'DEVICE_CREDENTIAL_UNAVAILABLE' ||
        'FAMILY_ACCESS_CONTEXT_CHANGED' =>
          '设备连接需要核对，请返回检查连接状态。',
        'FAMILY_ACCESS_RATE_LIMITED' => '申请较频繁，请稍后核对原申请。',
        'FAMILY_ACCESS_UNAVAILABLE' => '此设备暂不能使用家庭申请，请监护人核对家庭安排。',
        _ => '本次操作尚未完成。请保留原申请并重试核对。',
      };
  @override
  void dispose() {
    _poll?.cancel();
    _generation++;
    _owner?.close();
    _reason.dispose();
    widget.session.removeListener(_sessionChanged);
    widget.runtime?.removeListener(_nativeChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final record = _record;
    final canAct =
        !_busy && !_loading && !_storageBlocked && _owner?.current == true;
    final canCreate = record == null ||
        (record.confirmed && {'DENIED', 'EXPIRED'}.contains(record.state));
    final native = widget.runtime?.snapshot;
    return Scaffold(
        appBar: AppBar(title: const Text('申请临时放行')),
        body: SafeArea(
            child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('申请提交到家长端。云端批准不代表本机已经解除限制。'),
                      const SizedBox(height: 20),
                      if (_loading) const LinearProgressIndicator(),
                      if (_error != null) ...[
                        ChildNotice(_errorText(_error!)),
                        const SizedBox(height: 16)
                      ],
                      if (_storageBlocked)
                        OutlinedButton(
                            onPressed: _busy ? null : _restore,
                            child: const Text('重新读取原申请')),
                      if (record != null) ...[
                        ChildNotice(_status(record),
                            detail:
                                '${record.requestedSeconds ~/ 60} 分钟的原申请已保留。'),
                        if (record.notAfter != null) ...[
                          const SizedBox(height: 12),
                          Text(
                              '批准到期：${DateTime.fromMillisecondsSinceEpoch(record.notAfter!).toLocal()}'),
                        ],
                        if (record.state == 'APPROVED' &&
                            native?.health == 'ACTIVE' &&
                            native?.reason == 'exception_active') ...[
                          const SizedBox(height: 12),
                          const Text('本机已核对：当前签名安排中的临时放行有效。'),
                        ],
                        const SizedBox(height: 12),
                        FilledButton(
                            onPressed: canAct
                                ? () => _run(record.confirmed
                                    ? _owner!.refresh
                                    : _owner!.retry)
                                : null,
                            child: Text(
                                record.confirmed ? '刷新审批并核对本机' : '核对并重试原申请')),
                        const SizedBox(height: 24),
                      ],
                      if (canCreate) ...[
                        DropdownButtonFormField<int>(
                            value: _seconds,
                            decoration:
                                const InputDecoration(labelText: '申请时长'),
                            items: [60, 300, 600, 900, 1800, 3600]
                                .map((value) => DropdownMenuItem(
                                    value: value,
                                    child: Text('${value ~/ 60} 分钟')))
                                .toList(),
                            onChanged: canAct
                                ? (value) => setState(() => _seconds = value!)
                                : null),
                        const SizedBox(height: 16),
                        TextField(
                            controller: _reason,
                            maxLength: 300,
                            maxLines: 3,
                            enabled: canAct,
                            decoration: const InputDecoration(
                                labelText: '想告诉家长的话（可不填）')),
                        const SizedBox(height: 16),
                        FilledButton(
                            onPressed: canAct ? _submit : null,
                            child: const Text('提交申请')),
                      ],
                    ]))));
  }
}
