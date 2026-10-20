import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:audit_client/audit_client.dart';
import 'package:audit_client/exports.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';
import 'operation_journal.dart';
import 'operation_result_terminal.dart';
export 'package:audit_client/exports.dart';

Json exportSelection(AuditQuery q) => {
      'from': q.from,
      'to': q.to,
      if (q.action != null) 'action': q.action,
      if (q.resourceId != null) 'resourceId': q.resourceId,
      if (q.correlationId != null) 'correlationId': q.correlationId
    };
AuditQuery exportQuery(Json v) => AuditQuery(
    from: v['from'],
    to: v['to'],
    action: v['action'],
    resourceId: v['resourceId'],
    correlationId: v['correlationId']);

/// Metadata and content use fresh credentials, exact scope checks and no redirects.
class ParentAuditExports {
  final ParentApi api;
  final String tenant;
  final bool Function() current;
  final Future<String> Function() token;
  final http.Client client;
  ParentAuditExports(
      {required this.api,
      required this.tenant,
      required this.current,
      required this.token,
      http.Client? client})
      : client = client ?? http.Client();
  String get path => '/tenants/$tenant/audit-exports';
  void close() => client.close();
  void ensure() {
    if (!current()) throw const ParentApiException(409, 'SCOPE_DENIED');
  }

  AuditExportJob parse(dynamic raw) {
    try {
      return AuditExportJob.parse(raw);
    } on AuditProtocolException {
      throw const ParentApiException(502, 'INVALID_EXPORT_RESPONSE');
    }
  }

  Future<dynamic> send(String method, String suffix,
      {Json? body, String? key, bool Function()? operation,
      Future<bool> Function()? beforeDispatch}) async {
    bool valid() => current() && (operation?.call() ?? true);
    ensure();
    if (!valid()) throw const ParentApiException(409, 'SCOPE_DENIED');
    final value = await api.send(method, '$path$suffix',
        body: body, idempotencyKey: key, isCurrent: valid,
        beforeDispatch: beforeDispatch);
    if (!valid()) throw const ParentApiException(409, 'SCOPE_DENIED');
    return value;
  }

  AuditExportJob selected(dynamic raw, AuditQuery q) {
    final job = parse(raw);
    if (job.selection.from != q.from ||
        job.requestedTo != q.to ||
        job.selection.action != q.action ||
        job.selection.resourceId != q.resourceId ||
        job.selection.correlationId != q.correlationId) {
      throw const ParentApiException(502, 'INVALID_EXPORT_RESPONSE');
    }
    return job;
  }

  Future<AuditExportJob> create(AuditQuery q, String key,
      {required bool Function() operation, Future<bool> Function()? beforeDispatch}) async {
    q.validate();
    return selected(
        await send('POST', '',
            body: exportSelection(q), key: key, operation: operation,
            beforeDispatch: beforeDispatch),
        q);
  }

  Future<AuditExportJob> recover(AuditQuery q, String key,
      {bool Function()? operation, Future<bool> Function()? beforeDispatch}) async {
    q.validate();
    if (!auditUuid.hasMatch(key)) {
      throw const ParentApiException(400, 'INVALID_EXPORT_REQUEST');
    }
    return selected(
        await send('POST', '/creation-results/$key/query',
            body: exportSelection(q), operation: operation,
            beforeDispatch: beforeDispatch),
        q);
  }

  Future<AuditExportPage> list({String? cursor}) async {
    final raw = await send(
        'GET',
        '?${Uri(queryParameters: {
              'limit': '20',
              if (cursor != null) 'cursor': cursor
            }).query}');
    try {
      return AuditExportPage.parse(raw, cursor: cursor);
    } on AuditProtocolException {
      throw const ParentApiException(502, 'INVALID_EXPORT_RESPONSE');
    }
  }

  Future<AuditExportJob> get(String id,
      {bool Function()? operation, Future<bool> Function()? beforeDispatch}) async {
    if (!auditUuid.hasMatch(id)) {
      throw const ParentApiException(400, 'INVALID_EXPORT_REQUEST');
    }
    final job = parse(await send('GET', '/$id', operation: operation,
        beforeDispatch: beforeDispatch));
    if (job.id != id) {
      throw const ParentApiException(502, 'INVALID_EXPORT_RESPONSE');
    }
    return job;
  }

  Future<AuditExportJob> cancel(String id,
      {required bool Function() operation, Future<bool> Function()? beforeDispatch}) async {
    if (!auditUuid.hasMatch(id)) {
      throw const ParentApiException(400, 'INVALID_EXPORT_REQUEST');
    }
    final job = parse(await send('POST', '/$id/cancel', operation: operation,
        beforeDispatch: beforeDispatch));
    if (job.id != id || job.cancellable) {
      throw const ParentApiException(502, 'INVALID_EXPORT_RESPONSE');
    }
    return job;
  }

  /// A bounded authenticated stream. Plaintext lives only in memory until the
  /// administrator chooses a destination; HTTP metadata and payload are checked.
  Future<Uint8List> download(AuditExportJob job,
      {required bool Function() operation}) async {
    void valid() {
      ensure();
      if (!operation()) throw const ParentApiException(409, 'SCOPE_DENIED');
    }

    valid();
    if (job.state != 'READY' ||
        job.expiresAt <= DateTime.now().millisecondsSinceEpoch) {
      throw const ParentApiException(409, 'EXPORT_NOT_READY');
    }
    StreamSubscription<List<int>>? sub;
    bool aborted = false, ended = false;
    try {
      return await (() async {
        final credential = await token();
        valid();
        if (aborted) throw const ParentApiException(0, 'NETWORK_ERROR');
        final request = http.Request(
            'GET', Uri.parse('${api.baseUrl}$path/${job.id}/content'))
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $credential',
            'Cache-Control': 'no-store',
            'Accept': 'application/json'
          });
        final reply = await client.send(request);
        if (aborted || !current() || !operation()) {
          unawaited(
              reply.stream.listen(null).cancel().catchError((Object _) {}));
          valid();
          throw const ParentApiException(0, 'NETWORK_ERROR');
        }
        final max = reply.statusCode == 200 ? exportByteLimit : 65536;
        if (reply.contentLength != null && reply.contentLength! > max) {
          unawaited(
              reply.stream.listen(null).cancel().catchError((Object _) {}));
          throw const ParentApiException(502, 'INVALID_EXPORT_RESPONSE');
        }
        final bytes = BytesBuilder(copy: false), ready = Completer<Uint8List>();
        sub = reply.stream.listen((chunk) {
          if (ready.isCompleted) return;
          if (!current() || !operation() || bytes.length + chunk.length > max) {
            ready.completeError(
                const ParentApiException(502, 'INVALID_EXPORT_RESPONSE'));
            unawaited(sub?.cancel());
            return;
          }
          bytes.add(chunk);
        }, onDone: () {
          ended = true;
          if (!ready.isCompleted) ready.complete(bytes.takeBytes());
        }, onError: (Object e, StackTrace s) {
          ended = true;
          if (!ready.isCompleted) ready.completeError(e, s);
        }, cancelOnError: true);
        final body = await ready.future;
        valid();
        dynamic decoded;
        try {
          decoded = jsonDecode(utf8.decode(body));
        } on FormatException {
          decoded = null;
        }
        if (reply.statusCode != 200) {
          throw ParentApiException(
              reply.statusCode,
              decoded is Json && decoded['errorCode'] is String
                  ? decoded['errorCode']
                  : 'REQUEST_FAILED',
              decoded is Json && decoded['correlationId'] is String
                  ? decoded['correlationId']
                  : null);
        }
        if (reply.headers['content-type']
                    ?.split(';')
                    .first
                    .trim()
                    .toLowerCase() !=
                'application/json' ||
            body.length != job.byteCount ||
            (reply.contentLength != null &&
                body.length != reply.contentLength)) {
          throw const ParentApiException(502, 'INVALID_EXPORT_RESPONSE');
        }
        try {
          validateAuditExportContent(decoded, job, tenant);
        } on AuditProtocolException {
          throw const ParentApiException(502, 'INVALID_EXPORT_RESPONSE');
        }
        valid();
        return body;
      })()
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw const ParentApiException(0, 'NETWORK_ERROR');
    } on http.ClientException {
      throw const ParentApiException(0, 'NETWORK_ERROR');
    } finally {
      aborted = true;
      if (!ended && sub != null) {
        unawaited(sub!.cancel().catchError((Object _) {}));
      }
    }
  }
}

class AuditExportStore {
  late final ParentOperationJournal journal = ParentOperationJournal(storage);
  final ParentDurableStorage storage;
  AuditExportStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String key(String tenant, String actor) =>
      'parent.pending.audit-export.$tenant.$actor';
  void validate(Json row) {
    if (row['kind'] == 'create' &&
        row.length == 3 &&
        row['requestId'] is String &&
        auditUuid.hasMatch(row['requestId']) &&
        row['query'] is Json) {
      final q = row['query'] as Json;
      if (q.keys.any((k) => !const [
                'from',
                'to',
                'action',
                'resourceId',
                'correlationId'
              ].contains(k)) ||
          q['from'] is! int ||
          q['to'] is! int ||
          ['action', 'resourceId', 'correlationId']
              .any((k) => q[k] != null && q[k] is! String)) {
        throw const FormatException('导出恢复记录无效。');
      }
      exportQuery(q).validate();
      return;
    }
    if (row['kind'] == 'cancel' &&
        row.length == 2 &&
        row['jobId'] is String &&
        auditUuid.hasMatch(row['jobId'])) return;
    throw const FormatException('导出恢复记录无效。');
  }

  Future<Json?> load(String tenant, String actor) async {
    final raw = await journal.read(key: key(tenant, actor));
    if (raw == null) return null;
    if (raw.length > 2048) throw const FormatException('导出恢复记录无效。');
    final v = jsonDecode(raw);
    if (v is! Json) throw const FormatException('导出恢复记录无效。');
    validate(v);
    return v;
  }

  Future<void> save(String tenant, String actor, Json row) async {
    validate(row);
    if (await load(tenant, actor) != null) throw StateError('请先核对上一次导出操作。');
    await journal.write(key: key(tenant, actor), value: jsonEncode(row));
  }

  Future<void> clear(String tenant, String actor, Json expected) async {
    final old = await load(tenant, actor);
    if (old != null && jsonEncode(old) != jsonEncode(expected)) {
      throw StateError('恢复记录已变化。');
    }
    await journal.delete(key: key(tenant, actor));
  }
}

/// One durable write at a time. Unknown outcomes are queried, never auto-replayed.
class AuditExportOperation extends ChangeNotifier with ParentTerminalOperation {
  @override
  ParentOperationJournal get operationJournal => store.journal;
  @override
  String get operationSlot => store.key(repository.tenant, actor);
  @override
  Json? get operationPayload => pending;
  @override
  bool get operationCurrent => active;
  @override
  bool get operationHasSuccessfulResult => pending?['kind'] == 'create' && result != null;
  @override
  void forgetOperationPayload() {
    pending = null;
    result = null;
    queried = false;
    loaded = false;
  }
  final ParentAuditExports repository;
  final AuditExportStore store;
  final String actor;
  final bool Function() current;
  Json? pending;
  AuditExportJob? result;
  Object? error;
  bool loaded = false, busy = false, queried = false, disposed = false;
  int epoch = 0;
  AuditExportOperation(
      {required this.repository,
      required this.store,
      required this.actor,
      required this.current});
  bool get active => !disposed && current();
  void signal() {
    if (!disposed) notifyListeners();
  }

  void suspend() {
    epoch++;
  }

  @override
  void dispose() {
    disposed = true;
    epoch++;
    super.dispose();
  }

  Future<void> load() async {
    if (!active || busy) return;
    busy = true;
    loaded = false;
    error = null;
    signal();
    try {
      final v = await store.load(repository.tenant, actor);
      if (active) {
        pending = v;
        result = null;
        queried = false;
        loaded = true;
      }
    } catch (e) {
      await captureResultTerminal(e);
      if (active) error = e;
    } finally {
      busy = false;
      signal();
    }
  }

  Future<void> create(AuditQuery q) async => _submit({
        'kind': 'create',
        'requestId': const Uuid().v4(),
        'query': exportSelection(q)
      });
  Future<void> cancel(String id) async =>
      _submit({'kind': 'cancel', 'jobId': id});
  Future<void> _submit(Json row) async {
    if (operationBlocked) return;
    if (!active || busy || !loaded || pending != null) return;
    final ticket = epoch;
    bool valid() => active && ticket == epoch;
    busy = true;
    error = null;
    result = null;
    queried = false;
    signal();
    try {
      await store.save(repository.tenant, actor, row);
      if (!valid()) {
        loaded = false;
        return;
      }
      pending = row;
      final value = row['kind'] == 'create'
          ? await repository.create(exportQuery(row['query']), row['requestId'],
              operation: valid, beforeDispatch: operationBeforeWrite)
          : await repository.cancel(row['jobId'], operation: valid,
              beforeDispatch: operationBeforeWrite);
      if (valid()) {
        result = value;
        queried = true;
        if (operationHasSuccessfulResult ||
            row['kind'] == 'cancel' && value.state == 'CANCELLED') await recordSuccessfulOperation();
        // A verified reply resolves the operation. Only uncertain outcomes or
        // a local cleanup failure need the administrator's recovery workflow.
        await store.clear(repository.tenant, actor, row);
        if (valid()) pending = null;
      }
    } catch (e) {
      await captureResultTerminal(e);
      if (active) {
        error = e;
        if (pending == null) loaded = false;
      }
    } finally {
      busy = false;
      signal();
    }
  }

  Future<void> recover() async {
    if (operationBlocked) return;
    if (!active || busy || pending == null) return;
    final ticket = epoch;
    busy = true;
    error = null;
    result = null;
    queried = false;
    signal();
    try {
      final row = pending!;
      final value = row['kind'] == 'create'
          ? await repository.recover(
              exportQuery(row['query']), row['requestId'],
              operation: () => active && ticket == epoch,
              beforeDispatch: operationBeforeDispatch)
          : await repository.get(row['jobId'],
              operation: () => active && ticket == epoch,
              beforeDispatch: operationBeforeDispatch);
      if (active && ticket == epoch) {
        result = value;
        queried = true;
        if (operationHasSuccessfulResult) await recordSuccessfulOperation();
      }
    } catch (e) {
      await captureResultTerminal(e);
      if (active && ticket == epoch) {
        error = e;
        queried = e is ParentApiException &&
            e.code == 'EXPORT_CREATION_RESULT_UNAVAILABLE';
      }
    } finally {
      busy = false;
      signal();
    }
  }

  Future<bool> clear() async {
    if (operationBlocked) return false;
    if (!active || busy || pending == null || !queried) return false;
    busy = true;
    error = null;
    signal();
    try {
      await store.clear(repository.tenant, actor, pending!);
      if (!active) return false;
      pending = null;
      result = null;
      queried = false;
      return true;
    } catch (e) {
      await captureResultTerminal(e);
      if (active) error = e;
      return false;
    } finally {
      busy = false;
      signal();
    }
  }
}

String auditExportError(Object e) => e is ParentApiException
    ? switch (e.code) {
        'INVALID_EXPORT_RESPONSE' => '导出数据未通过核对，请重新读取。',
        'EXPORT_NOT_READY' => '导出尚未准备好或已过期，请刷新任务状态。',
        'EXPORT_CAPACITY_REACHED' => '当前生成任务较多，请稍后重试或取消不再需要的任务。',
        'EXPORT_CREATION_RESULT_UNAVAILABLE' =>
          '未找到原生成结果，不代表没有提交。请核对本人的导出列表后再处理。',
        'EXPORT_ENCRYPTION_UNAVAILABLE' => '服务尚未配置导出加密能力，请联系管理员。',
        _ => e.toString(),
      }
    : e is FormatException || e is StateError
        ? '本机恢复记录无法安全读取或保存，请重试；不会自动提交。'
        : '操作未完成，请重新核对。';
