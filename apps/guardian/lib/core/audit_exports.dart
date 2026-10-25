import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'api.dart';
import 'audit.dart';
import 'scoped_http_client.dart';

import 'package:audit_client/exports.dart';
export 'package:audit_client/exports.dart';

Never _invalid() => throw const ApiFailure(502, 'INVALID_EXPORT_RESPONSE');
AuditExportJob _parseJob(dynamic value) {
  try {
    return AuditExportJob.parse(value);
  } on AuditProtocolException {
    _invalid();
  }
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
    final job = _parseJob(await _send('POST', '', key: key, body: {
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
    try {
      return AuditExportPage.parse(v, cursor: cursor);
    } on AuditProtocolException {
      _invalid();
    }
  }

  Future<AuditExportJob> cancel(String id) async {
    if (!auditUuid.hasMatch(id)) _invalid();
    final job = _parseJob(await _send('POST', '/$id/cancel'));
    if (job.id != id || job.cancellable) _invalid();
    return job;
  }

  Future<Uint8List> download(AuditExportJob job) async {
    ensureCurrent();
    if (job.state != 'READY') throw const ApiFailure(409, 'EXPORT_NOT_READY');
    StreamSubscription<List<int>>? subscription;
    bool ended = false, aborted = false;
    final abort = Completer<void>();
    void abortRequest() {
      if (!abort.isCompleted) abort.complete();
    }

    try {
      final bytes = await (() async {
        final request = ScopeGuardedRequest('GET',
            Uri.parse('${api.baseUrl}$root/audit-exports/${job.id}/content'),
            isCurrent: current,
            abortTrigger: abort.future,
            isAborted: () => aborted)
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
        final client = await api.client();
        if (aborted) throw const ApiFailure(0, 'NETWORK_ERROR');
        ensureCurrent();
        final response = await client.send(request);
        if (aborted || !current()) {
          _discardResponse(response);
          ensureCurrent();
          throw const ApiFailure(0, 'NETWORK_ERROR');
        }
        ensureCurrent();
        final maximum = response.statusCode == 200 ? exportByteLimit : 65536;
        if (response.contentLength != null &&
            response.contentLength! > maximum) {
          abortRequest();
          _discardResponse(response);
          _invalid();
        }
        final received = Completer<Uint8List>(),
            builder = BytesBuilder(copy: false);
        subscription = response.stream.listen((chunk) {
          if (received.isCompleted) return;
          if (builder.length + chunk.length > maximum) {
            abortRequest();
            received.completeError(
                const ApiFailure(502, 'INVALID_EXPORT_RESPONSE'));
            unawaited(subscription?.cancel().catchError((Object _) {}));
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
          .timeout(const Duration(seconds: 25), onTimeout: () {
        aborted = true;
        abortRequest();
        throw TimeoutException('Download deadline elapsed');
      });
      ensureCurrent();
      return bytes;
    } on ScopeChangedException {
      abortRequest();
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
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

  void _discardResponse(http.StreamedResponse response) {
    unawaited(Future<void>.sync(() async {
      try {
        await response.stream
            .listen(null, onError: (Object _, StackTrace __) {})
            .cancel();
      } catch (_) {
        // Cleanup must not replace the original deadline or protocol error.
      }
    }));
  }

  void _validateContent(dynamic v, AuditExportJob job) {
    try {
      validateAuditExportContent(v, job, root.split('/').last);
    } on AuditProtocolException {
      _invalid();
    }
  }
}
