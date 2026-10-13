import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/parent_api.dart';
import '../core/parent_durable_storage.dart';
import '../core/parent_session.dart';

/// Adult side of the existing two-device BYOD registration protocol. The
/// one-time claim secret stays in memory and is never written to local storage.
class EnrollmentFlow extends StatefulWidget {
  final ParentSession session;
  const EnrollmentFlow({super.key, required this.session});

  @override
  State<EnrollmentFlow> createState() => _EnrollmentFlowState();
}

class _EnrollmentFlowState extends State<EnrollmentFlow> {
  static final _storage = ParentDurableStorage();
  final pairingCode = TextEditingController();
  final subjects = <Json>[];
  String? selectedSubject, nextCursor, enrollmentId, pendingCreateId;
  String platform = 'ANDROID';
  Json? ticket, progress;
  Object? error;
  bool loading = true,
      loadingMore = false,
      busy = false,
      createUncertain = false;
  late final String tenantId, actorId;

  String get root => '/tenants/$tenantId';
  String get pendingKey => 'parent.pending.enrollment.$tenantId.$actorId';
  bool get current =>
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.profile?['subject'] == actorId &&
      widget.session.canDecide;

  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'] as String;
    actorId = widget.session.profile!['subject'] as String;
    widget.session.addListener(_accessChanged);
    _load();
  }

  @override
  void dispose() {
    widget.session.removeListener(_accessChanged);
    pairingCode.dispose();
    super.dispose();
  }

  void _accessChanged() {
    if (current || !mounted) return;
    ticket = null;
    progress = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(false);
    });
  }

  Future<void> _load() async {
    try {
      final saved = await _storage.read(key: pendingKey);
      if (saved != null) {
        dynamic parsed;
        try {
          parsed = jsonDecode(saved);
        } on FormatException {
          await _storage.delete(key: pendingKey);
        }
        if (parsed is Map<String, dynamic> &&
            parsed['actor'] == actorId &&
            parsed['id'] is String) {
          final id = parsed['id'] as String;
          final creating = parsed['createPending'] == true;
          if (creating) {
            pendingCreateId = id;
            createUncertain = true;
          }
          try {
            final found = await widget.session.api.object(creating
                ? '$root/enrollment-creation-results/$id'
                : '$root/enrollments/$id');
            if (!mounted || !current) return;
            if (found['id'] != id || found['state'] is! String) {
              throw const ParentApiException(502, 'INVALID_RESPONSE');
            }
            if (found['state'] == 'PENDING_CLAIM' ||
                found['state'] == 'AWAITING_CONFIRMATION') {
              enrollmentId = id;
              progress = found;
              createUncertain = false;
              pendingCreateId = null;
              if (creating) {
                await _storage.write(
                    key: pendingKey,
                    value: jsonEncode({'actor': actorId, 'id': id}));
              }
            } else {
              await _storage.delete(key: pendingKey);
              createUncertain = false;
              pendingCreateId = null;
            }
          } on ParentApiException catch (failure) {
            if (failure.status == 404 && creating) {
              // A timed-out POST may still be committing; retain the exact ID.
              createUncertain = true;
            } else if (creating) {
              // A temporary authorization loss must not destroy the recovery ID.
              rethrow;
            } else if (failure.status == 403 || failure.status == 404) {
              // Only a non-secret ID was saved. A lost scope cannot recover it.
              await _storage.delete(key: pendingKey);
              createUncertain = false;
              pendingCreateId = null;
            } else {
              rethrow;
            }
          }
        } else {
          if (parsed is! Map<String, dynamic> || parsed['actor'] != actorId) {
            await _storage.delete(key: pendingKey);
          }
        }
      }
      if (enrollmentId == null) await _loadSubjects();
    } catch (failure) {
      if (mounted && current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _loadSubjects({bool more = false}) async {
    if (!current || loadingMore) return;
    if (more) setState(() => loadingMore = true);
    try {
      final page = await widget.session.api
          .page('$root/subjects', cursor: more ? nextCursor : null);
      if (!mounted || !current) return;
      setState(() {
        if (!more) subjects.clear();
        subjects.addAll(page.items);
        nextCursor = page.nextCursor;
        selectedSubject ??=
            subjects.isNotEmpty ? subjects.first['id'] as String : null;
        error = null;
      });
    } catch (failure) {
      if (mounted && current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => loadingMore = false);
    }
  }

  Future<bool> _authorize() async {
    final authenticated = await widget.session.reauthenticate();
    if (!mounted || !current) return false;
    if (!authenticated && widget.session.error != null) {
      setState(() => error = widget.session.error);
    }
    return authenticated;
  }

  Future<void> _create() async {
    if (!current || busy || selectedSubject == null) return;
    var submitted = false;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!await _authorize()) return;
      final requestId = const Uuid().v4();
      // A response may disappear after the server commits. Persist this
      // non-secret identifier before sending, or do not start the request.
      await _storage.write(
          key: pendingKey,
          value: jsonEncode(
              {'actor': actorId, 'id': requestId, 'createPending': true}));
      if (!mounted || !current) return;
      pendingCreateId = requestId;
      submitted = true;
      final result = await widget.session.api
          .send('POST', '$root/enrollments', clientRequestId: requestId, body: {
        'subjectId': selectedSubject,
        'requestedMode': 'BYOD',
        'platform': platform,
      });
      if (result is! Json ||
          result['id'] != requestId ||
          result['token'] is! String ||
          result['expiresAt'] is! int) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (!mounted || !current) return;
      setState(() {
        enrollmentId = requestId;
        pendingCreateId = null;
        createUncertain = false;
        ticket = result;
        progress = result;
      });
      try {
        await _storage.write(
            key: pendingKey,
            value: jsonEncode({'actor': actorId, 'id': requestId}));
      } catch (_) {
        if (mounted && current) {
          setState(() => error = '注册已创建，但设备无法保存进度。请立即记录注册编号并在本次页面完成配对。');
        }
      }
    } catch (failure) {
      if (mounted && current) {
        var uncertain = submitted &&
            (failure is! ParentApiException ||
                failure.status == 0 ||
                failure.status >= 500 ||
                failure.code == 'ENROLLMENT_REQUEST_ALREADY_USED');
        if (submitted && !uncertain) {
          try {
            await _storage.delete(key: pendingKey);
            pendingCreateId = null;
          } catch (_) {
            uncertain = true;
          }
        }
        if (!mounted || !current) return;
        setState(() {
          error = failure;
          createUncertain = uncertain;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _recoverPendingCreate() async {
    final id = pendingCreateId;
    if (!current || busy || id == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final found = await widget.session.api
          .object('$root/enrollment-creation-results/$id');
      if (!mounted || !current) return;
      if (found['id'] != id || found['state'] is! String) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (found['state'] == 'PENDING_CLAIM' ||
          found['state'] == 'AWAITING_CONFIRMATION') {
        setState(() {
          enrollmentId = id;
          progress = found;
          ticket = null;
          pendingCreateId = null;
          createUncertain = false;
        });
        try {
          await _storage.write(
              key: pendingKey, value: jsonEncode({'actor': actorId, 'id': id}));
        } catch (_) {
          if (mounted && current) {
            setState(() => error = '已找到注册记录，但设备无法保存进度。请在本次页面处理，重启后可按请求编号再次查询。');
          }
        }
      } else {
        await _storage.delete(key: pendingKey);
        if (!mounted || !current) return;
        if (found['state'] == 'CONFIRMED') {
          Navigator.of(context).pop(true);
          return;
        }
        setState(() {
          pendingCreateId = null;
          createUncertain = false;
          error = '原注册已结束，可按需要重新发起配对。';
        });
      }
    } on ParentApiException catch (failure) {
      if (!mounted || !current) return;
      setState(() => error =
          failure.status == 404 ? '暂未查到这个请求。服务端可能仍在处理；请稍后再查询，勿重复创建。' : failure);
    } catch (failure) {
      if (mounted && current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _refreshProgress() async {
    if (!current || enrollmentId == null || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final found =
          await widget.session.api.object('$root/enrollments/$enrollmentId');
      if (!mounted || !current) return;
      setState(() => progress = found);
      if (found['state'] == 'CONFIRMED') {
        await _storage.delete(key: pendingKey);
        if (mounted) Navigator.of(context).pop(true);
      } else if (found['state'] != 'PENDING_CLAIM' &&
          found['state'] != 'AWAITING_CONFIRMATION') {
        await _storage.delete(key: pendingKey);
        if (mounted) Navigator.of(context).pop(false);
      }
    } catch (failure) {
      if (mounted && current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _confirm() async {
    final code = pairingCode.text.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9]{8}$').hasMatch(code) ||
        !current ||
        enrollmentId == null ||
        busy) {
      setState(() => error = '请输入设备屏幕显示的 8 位配对码。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!await _authorize()) return;
      final response = await widget.session.api.send(
          'POST', '$root/enrollments/$enrollmentId/confirm',
          body: {'pairingCode': code});
      if (response is! Json || response['state'] != 'ACTIVE') {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      await _storage.delete(key: pendingKey);
      if (mounted && current) Navigator.of(context).pop(true);
    } catch (failure) {
      if (mounted && current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _cancel() async {
    if (!current || enrollmentId == null || busy) return;
    final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('取消这次设备注册？'),
              content: const Text('一次性凭据立即失效；若设备已经认领，待确认凭证也会撤销。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('返回')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('取消注册')),
              ],
            ));
    if (approved != true || !mounted) return;
    setState(() => busy = true);
    try {
      if (!await _authorize()) return;
      await widget.session.api
          .send('DELETE', '$root/enrollments/$enrollmentId');
      await _storage.delete(key: pendingKey);
      if (mounted && current) Navigator.pop(context, false);
    } catch (failure) {
      if (mounted && current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _copyTicket() async {
    if (!current || ticket == null) return;
    final payload = jsonEncode({
      'tenantId': tenantId,
      'id': ticket!['id'],
      'token': ticket!['token'],
      'expiresAt': ticket!['expiresAt'],
    });
    try {
      await Clipboard.setData(ClipboardData(text: payload));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制一次性凭据。请只传给正在配对的设备，用后清空剪贴板。')));
      }
    } catch (_) {
      if (mounted) setState(() => error = '复制失败，请在管理工作台重新查看本次注册流程。');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(enrollmentId == null ? '连接儿童设备' : '完成设备配对'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                    '当前仅支持 Android 手机/平板和 Android TV 的 BYOD 有限控制。注册成功不代表系统级策略已执行。'),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text('$error', style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 16),
                if (loading) const LinearProgressIndicator(),
                if (!loading && enrollmentId == null) ...[
                  if (createUncertain) ...[
                    const Text('创建结果不明。请按原请求编号查询服务端记录，勿重复生成凭据。'),
                    if (pendingCreateId != null)
                      SelectableText('请求编号：$pendingCreateId'),
                    OutlinedButton.icon(
                        onPressed: busy || pendingCreateId == null
                            ? null
                            : _recoverPendingCreate,
                        icon: const Icon(Icons.sync),
                        label: const Text('查询创建结果')),
                  ],
                  if (subjects.isEmpty) const Text('暂无儿童档案。请先在管理工作台添加。'),
                  if (subjects.isNotEmpty)
                    DropdownButtonFormField<String>(
                      value: selectedSubject,
                      decoration: const InputDecoration(labelText: '所属儿童'),
                      items: [
                        for (final child in subjects)
                          DropdownMenuItem(
                              value: child['id'] as String,
                              child: Text(
                                  child['nickname'] as String? ?? '未命名档案')),
                      ],
                      onChanged: busy
                          ? null
                          : (value) => setState(() => selectedSubject = value),
                    ),
                  if (nextCursor != null)
                    TextButton(
                        onPressed: loadingMore
                            ? null
                            : () => _loadSubjects(more: true),
                        child: Text(loadingMore ? '正在加载…' : '加载更多儿童')),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: platform,
                    decoration: const InputDecoration(labelText: '设备平台'),
                    items: const [
                      DropdownMenuItem(
                          value: 'ANDROID', child: Text('Android 手机/平板')),
                      DropdownMenuItem(
                          value: 'ANDROID_TV', child: Text('Android TV')),
                    ],
                    onChanged: busy
                        ? null
                        : (value) =>
                            setState(() => platform = value ?? platform),
                  ),
                ],
                if (!loading && enrollmentId != null) ...[
                  SelectableText('注册编号：$enrollmentId'),
                  Text('状态：${progress?['state'] ?? '待查询'}'),
                  if (progress?['state'] == 'PENDING_CLAIM')
                    const Text('请先在儿童设备输入完整凭据，看到 8 位配对码后点“检查状态”。'),
                  const SizedBox(height: 10),
                  if (ticket != null) ...[
                    const Text('一次性凭据只在本次打开时显示。请在儿童设备填写完整凭据，勿发到公开群聊。'),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                        onPressed: _copyTicket,
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('复制完整注册凭据')),
                    const SizedBox(height: 8),
                    Text(
                        '有效期：${DateTime.fromMillisecondsSinceEpoch(ticket!['expiresAt'] as int).toLocal()}'),
                  ] else
                    const Text('上次凭据已不再显示。若设备尚未认领，请取消本次注册并重新生成。'),
                  const SizedBox(height: 16),
                  TextField(
                      controller: pairingCode,
                      maxLength: 8,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                          labelText: '设备上显示的 8 位配对码', counterText: '')),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: busy ? null : () => Navigator.pop(context, false),
              child: const Text('稍后处理')),
          if (enrollmentId == null && !loading)
            FilledButton(
                onPressed: busy || selectedSubject == null || createUncertain
                    ? null
                    : _create,
                child: const Text('创建一次性凭据')),
          if (enrollmentId != null) ...[
            if (progress?['state'] == 'PENDING_CLAIM' ||
                progress?['state'] == 'AWAITING_CONFIRMATION')
              TextButton(
                  onPressed: busy ? null : _cancel, child: const Text('取消注册')),
            TextButton(
                onPressed: busy ? null : _refreshProgress,
                child: const Text('检查状态')),
            FilledButton(
                onPressed: busy || progress?['state'] != 'AWAITING_CONFIRMATION'
                    ? null
                    : _confirm,
                child: const Text('确认配对')),
          ],
        ],
      );
}
