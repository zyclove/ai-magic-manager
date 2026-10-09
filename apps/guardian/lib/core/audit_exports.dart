import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'api.dart';
import 'audit.dart';

Never _invalid() => throw const ApiFailure(502, 'INVALID_EXPORT_RESPONSE');
const exportByteLimit = 8388608;

class AuditExportJob {
  final String id, state;
  final int createdAt, updatedAt, expiresAt, requestedTo, attempts;
  final AuditQuery selection;
  final int? recordCount, byteCount;
  final String? failureCode;
  const AuditExportJob(
      this.id,
      this.state,
      this.createdAt,
      this.updatedAt,
      this.expiresAt,
      this.requestedTo,
      this.attempts,
      this.selection,
      this.recordCount,
      this.byteCount,
      this.failureCode);
  bool get pending => state == 'QUEUED' || state == 'RUNNING';
  bool get cancellable => pending || state == 'READY';
  String get title => const {
        'QUEUED': '等待生成',
        'RUNNING': '正在生成',
        'READY': '可下载',
        'FAILED': '生成失败',
        'CANCELLED': '已取消',
        'EXPIRED': '已到期',
        'REVOKED': '权限已失效'
      }[state]!;
  String get description => switch (state) {
        'QUEUED' => attempts == 0 ? '任务已提交，将在后台生成。' : '服务正在重试，请稍候。',
        'RUNNING' => '正在整理审计记录，可以离开此页面。',
        'READY' => '下载前会再次核对权限并要求近期安全验证。',
        'FAILED' => failureCode == 'EXPORT_ROW_LIMIT_EXCEEDED' ||
                failureCode == 'EXPORT_BYTE_LIMIT_EXCEEDED'
            ? '记录超出导出上限，请缩小日期范围或增加筛选条件后重新生成。'
            : '任务未能完成。请返回审计日志重新生成。',
        'CANCELLED' => '已停止生成并清除在线文件。',
        'EXPIRED' => '下载期限已结束，请按需要重新生成。',
        _ => '成员权限发生变化，此导出已无法访问。'
      };
  static AuditExportJob parse(dynamic v) {
    const keys = {
      'id',
      'state',
      'createdAt',
      'updatedAt',
      'expiresAt',
      'from',
      'to',
      'requestedTo',
      'action',
      'resourceId',
      'correlationId',
      'recordCount',
      'byteCount',
      'failureCode',
      'attempts'
    };
    if (v is! Json ||
        v.length != keys.length ||
        !v.keys.every(keys.contains) ||
        v['id'] is! String ||
        !auditUuid.hasMatch(v['id']) ||
        !const [
          'QUEUED',
          'RUNNING',
          'READY',
          'FAILED',
          'CANCELLED',
          'EXPIRED',
          'REVOKED'
        ].contains(v['state'])) _invalid();
    for (final k in [
      'createdAt',
      'updatedAt',
      'expiresAt',
      'from',
      'to',
      'requestedTo',
      'attempts'
    ]) {
      if (v[k] is! int || v[k] < 0 || v[k] > 8640000000000000) _invalid();
    }
    if (v['from'] >= v['to'] ||
        v['to'] > v['createdAt'] ||
        v['to'] > v['requestedTo'] ||
        v['requestedTo'] - v['from'] > 366 * 86400000 ||
        v['updatedAt'] < v['createdAt'] ||
        v['expiresAt'] <= v['createdAt'] ||
        v['attempts'] > 3) _invalid();
    final action = v['action'],
        resource = v['resourceId'],
        trace = v['correlationId'];
    if (action != null &&
        (action is! String ||
            !RegExp(r'^[A-Z][A-Z0-9_]{0,99}$').hasMatch(action))) _invalid();
    if (resource != null &&
        (resource is! String || !auditResourceId(resource))) {
      _invalid();
    }
    if (trace != null && (trace is! String || !auditUuid.hasMatch(trace))) {
      _invalid();
    }
    if (v['recordCount'] != null &&
        (v['recordCount'] is! int ||
            v['recordCount'] < 0 ||
            v['recordCount'] > 10000)) _invalid();
    if (v['byteCount'] != null &&
        (v['byteCount'] is! int ||
            v['byteCount'] <= 0 ||
            v['byteCount'] > exportByteLimit)) _invalid();
    if (v['state'] == 'READY' &&
        (v['recordCount'] == null || v['byteCount'] == null)) _invalid();
    if (v['failureCode'] != null &&
        (v['failureCode'] is! String ||
            !RegExp(r'^[A-Z][A-Z0-9_]{0,99}$').hasMatch(v['failureCode']))) {
      _invalid();
    }
    return AuditExportJob(
        v['id'],
        v['state'],
        v['createdAt'],
        v['updatedAt'],
        v['expiresAt'],
        v['requestedTo'],
        v['attempts'],
        AuditQuery(
            from: v['from'],
            to: v['to'],
            action: action,
            resourceId: resource,
            correlationId: trace),
        v['recordCount'],
        v['byteCount'],
        v['failureCode']);
  }
}

class AuditExportPage {
  final List<AuditExportJob> items;
  final String? nextCursor;
  const AuditExportPage(this.items, this.nextCursor);
}

class AuditExportRepository {
  final Api api;
  final String root;
  final bool Function() current;
  AuditExportRepository(
      {required this.api, required this.root, required this.current});
  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<dynamic> _send(String method, String suffix,
      {Json? body, String? key}) async {
    ensureCurrent();
    try {
      final v = await api.send(method, '$root/audit-exports$suffix',
          body: body, key: key);
      ensureCurrent();
      return v;
    } catch (_) {
      ensureCurrent();
      rethrow;
    }
  }

  Future<AuditExportJob> create(AuditQuery query, String key) async {
    final job = AuditExportJob.parse(await _send('POST', '', key: key, body: {
      'from': query.from,
      'to': query.to,
      if (query.action != null) 'action': query.action,
      if (query.resourceId != null) 'resourceId': query.resourceId,
      if (query.correlationId != null) 'correlationId': query.correlationId,
    }));
    if (job.selection.from != query.from ||
        job.requestedTo != query.to ||
        job.selection.action != query.action ||
        job.selection.resourceId != query.resourceId ||
        job.selection.correlationId != query.correlationId) _invalid();
    return job;
  }

  Future<AuditExportPage> load({String? cursor}) async {
    final v = await _send(
        'GET',
        '?${Uri(queryParameters: {
              'limit': '20',
              if (cursor != null) 'cursor': cursor
            }).query}');
    if (v is! Json ||
        v.length != 2 ||
        !v.containsKey('nextCursor') ||
        v['items'] is! List ||
        (v['items'] as List).length > 20) _invalid();
    final next = v['nextCursor'];
    if (next != null &&
        (next is! String ||
            next.isEmpty ||
            next.length > 512 ||
            next == cursor)) _invalid();
    final items =
        (v['items'] as List).map(AuditExportJob.parse).toList(growable: false);
    if (next != null && items.length != 20) _invalid();
    final ids = <String>{};
    AuditExportJob? previous;
    for (final job in items) {
      if (!ids.add(job.id) ||
          (previous != null &&
              (previous.createdAt < job.createdAt ||
                  (previous.createdAt == job.createdAt &&
                      previous.id.compareTo(job.id) <= 0)))) _invalid();
      previous = job;
    }
    return AuditExportPage(items, next as String?);
  }

  Future<AuditExportJob> cancel(String id) async {
    if (!auditUuid.hasMatch(id)) _invalid();
    final job = AuditExportJob.parse(await _send('POST', '/$id/cancel'));
    if (job.id != id || job.cancellable) _invalid();
    return job;
  }

  Future<Uint8List> download(AuditExportJob job) async {
    ensureCurrent();
    if (job.state != 'READY') throw const ApiFailure(409, 'EXPORT_NOT_READY');
    StreamSubscription<List<int>>? subscription;
    bool ended = false, aborted = false;
    try {
      final bytes = await (() async {
        final request = http.Request('GET',
            Uri.parse('${api.baseUrl}$root/audit-exports/${job.id}/content'))
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
        final client = await api.client();
        if (aborted) throw const ApiFailure(0, 'NETWORK_ERROR');
        ensureCurrent();
        final response = await client.send(request);
        if (aborted || !current()) {
          unawaited(
              response.stream.listen(null).cancel().catchError((Object _) {}));
          ensureCurrent();
          throw const ApiFailure(0, 'NETWORK_ERROR');
        }
        ensureCurrent();
        final maximum = response.statusCode == 200 ? exportByteLimit : 65536;
        if (response.contentLength != null &&
            response.contentLength! > maximum) {
          unawaited(
              response.stream.listen(null).cancel().catchError((Object _) {}));
          _invalid();
        }
        final received = Completer<Uint8List>(),
            builder = BytesBuilder(copy: false);
        subscription = response.stream.listen((chunk) {
          if (received.isCompleted) return;
          if (builder.length + chunk.length > maximum) {
            received.completeError(
                const ApiFailure(502, 'INVALID_EXPORT_RESPONSE'));
            subscription?.cancel();
            return;
          }
          builder.add(chunk);
        }, onError: (Object error, StackTrace stack) {
          ended = true;
          if (!received.isCompleted) received.completeError(error, stack);
        }, onDone: () {
          ended = true;
          if (!received.isCompleted) received.complete(builder.takeBytes());
        }, cancelOnError: true);
        final bytes = await received.future;
        ensureCurrent();
        dynamic v;
        try {
          v = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          v = null;
        }
        if (response.statusCode != 200) {
          throw ApiFailure(
              response.statusCode,
              v is Json && v['errorCode'] is String
                  ? v['errorCode']
                  : 'REQUEST_FAILED',
              v is Json && v['correlationId'] is String
                  ? v['correlationId']
                  : null);
        }
        if (response.headers['content-type']
                    ?.split(';')
                    .first
                    .trim()
                    .toLowerCase() !=
                'application/json' ||
            bytes.length != job.byteCount ||
            (response.contentLength != null &&
                response.contentLength != bytes.length)) _invalid();
        _validateContent(v, job);
        return bytes;
      })()
          .timeout(const Duration(seconds: 25));
      ensureCurrent();
      return bytes;
    } on TimeoutException {
      ensureCurrent();
      throw const ApiFailure(0, 'NETWORK_ERROR');
    } on http.ClientException {
      ensureCurrent();
      throw const ApiFailure(0, 'NETWORK_ERROR');
    } finally {
      aborted = true;
      if (!ended && subscription != null) {
        unawaited(subscription!.cancel().catchError((Object _) {}));
      }
    }
  }

  void _validateContent(dynamic v, AuditExportJob job) {
    final q = job.selection;
    if (v is! Json ||
        v['schemaVersion'] != 1 ||
        v['type'] != 'AUDIT_JSON' ||
        v['tenantId'] != root.split('/').last ||
        v['jobId'] != job.id ||
        v['requestedTo'] != job.requestedTo ||
        v['recordCount'] != job.recordCount ||
        v['generatedAt'] is! int ||
        v['generatedAt'] < job.createdAt ||
        v['generatedAt'] >= job.expiresAt ||
        v['selection'] is! Json ||
        v['events'] is! List ||
        (v['events'] as List).length != job.recordCount) _invalid();
    final selection = v['selection'] as Json;
    if (selection.length != 5 ||
        selection['from'] != q.from ||
        selection['to'] != q.to ||
        selection['action'] != q.action ||
        selection['resourceId'] != q.resourceId ||
        selection['correlationId'] != q.correlationId) _invalid();
    final ids = <String>{};
    AuditEvent? previous;
    for (final raw in v['events']) {
      final event = AuditEvent.parse(raw);
      if (!ids.add(event.id) ||
          event.occurredAt < q.from ||
          event.occurredAt >= q.to ||
          (q.action != null && q.action != event.action) ||
          (q.resourceId != null && q.resourceId != event.resourceId) ||
          (q.correlationId != null && q.correlationId != event.correlationId) ||
          (previous != null &&
              (previous.occurredAt < event.occurredAt ||
                  (previous.occurredAt == event.occurredAt &&
                      previous.id.compareTo(event.id) <= 0)))) _invalid();
      previous = event;
    }
  }
}
