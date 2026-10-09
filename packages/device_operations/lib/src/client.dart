import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

class ExitFailure implements Exception {
  final String code, message;
  final int? status;
  final String? correlationId;
  final bool outcomeUnknown;
  const ExitFailure(this.code, this.message,
      {this.status, this.correlationId, this.outcomeUnknown = false});
  @override
  String toString() => message;
}

abstract interface class ExitGateway {
  Future<DeviceSnapshot> device(ExitScope scope);
  Future<ExitPreview> preview(ExitScope scope, int deviceVersion);
  Future<ExitOperation> confirm(ExitScope scope,
      {required String previewId,
      required String previewHash,
      required int deviceVersion,
      required String key});
  Future<ExitOperation> operation(ExitScope scope, String operationId);
  Future<List<ExitOperation>> operations(ExitScope scope);
  Future<ExitOperation> cancel(ExitScope scope,
      {required String operationId, required int version, required String key});
}

/// Caller owns the authenticated HTTP client and token refresh lifecycle.
class DeviceOperationsClient implements ExitGateway {
  final Uri apiRoot;
  final Future<http.Client> Function() clientFactory;
  final Duration timeout;
  DeviceOperationsClient(
      {required Uri apiRoot,
      required this.clientFactory,
      this.timeout = const Duration(seconds: 25),
      bool allowLoopbackHttp = false})
      : apiRoot = apiRoot.replace(
            path: apiRoot.path.replaceFirst(RegExp(r'/$'), '')) {
    final loopback =
        const {'localhost', '127.0.0.1', '::1'}.contains(apiRoot.host);
    if (apiRoot.host.isEmpty ||
        apiRoot.userInfo.isNotEmpty ||
        apiRoot.hasQuery ||
        apiRoot.hasFragment ||
        !apiRoot.path.endsWith('/api/v1') ||
        timeout <= Duration.zero ||
        !(apiRoot.scheme == 'https' ||
            (apiRoot.scheme == 'http' && allowLoopbackHttp && loopback))) {
      throw ArgumentError('An explicit HTTPS API root is required');
    }
  }

  String _path(ExitScope scope) =>
      '/tenants/${scope.tenantId}/devices/${scope.deviceId}';

  /// Timeout includes credential refresh, headers and the bounded body stream.
  /// A timed-out HTTP request can still commit; no mutation is retried here.
  Future<T> _request<T>(
      String method, String path, T Function(Map<String, dynamic>) parse,
      {Map<String, dynamic>? body,
      Map<String, String>? query,
      int? version,
      String? key,
      bool mutation = false}) async {
    if (version != null && (version < 0 || version > 9007199254740991)) {
      throw ArgumentError('Invalid version');
    }
    if (key != null) canonicalId(key);
    Future<T> execute() async {
      final transport = await clientFactory();
      final request = http.Request(method,
          apiRoot.replace(path: '${apiRoot.path}$path', queryParameters: query))
        ..headers['Accept'] = 'application/json';
      if (version != null) request.headers['If-Match'] = '"$version"';
      if (key != null) request.headers['Idempotency-Key'] = key;
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final result = await transport.send(request);
      final bytes = <int>[];
      await for (final chunk in result.stream) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          throw const FormatException('Response too large');
        }
        bytes.addAll(chunk);
      }
      Map<String, dynamic>? json;
      try {
        final value = jsonDecode(utf8.decode(bytes));
        if (value is Map<String, dynamic>) json = value;
      } on FormatException {
        /* Keep failure handling independent from server copy. */
      }
      if (result.statusCode < 200 || result.statusCode >= 300) {
        final rawCode = json?['errorCode'] ?? json?['code'];
        final code =
            rawCode is String && RegExp(r'^[A-Z_]{1,80}$').hasMatch(rawCode)
                ? rawCode
                : 'HTTP_FAILURE';
        final rawId =
            json?['correlationId'] ?? result.headers['x-correlation-id'];
        final correlation =
            rawId is String && RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(rawId)
                ? rawId
                : null;
        final knownRejection = result.statusCode >= 400 &&
            result.statusCode < 500 &&
            _rejections.contains(code);
        throw ExitFailure(code, _failureCopy[code] ?? '请求未完成，请核对状态或联系管理员。',
            status: result.statusCode,
            correlationId: correlation,
            outcomeUnknown: mutation && !knownRejection);
      }
      if (json == null) throw const FormatException('Expected an object');
      return parse(json);
    }

    try {
      return await execute().timeout(timeout);
    } on ExitFailure {
      rethrow;
    } on TimeoutException {
      throw ExitFailure('NETWORK_TIMEOUT', '连接超时。提交结果可能尚未确认。',
          outcomeUnknown: mutation);
    } on FormatException {
      throw ExitFailure('RESPONSE_INVALID', '响应无法验证，请核对当前状态。',
          outcomeUnknown: mutation);
    } catch (_) {
      // Never echo transport errors, authentication exceptions or response bodies.
      throw ExitFailure('CONNECTION_FAILED', '连接未完成，请检查网络或重新登录。',
          outcomeUnknown: mutation);
    }
  }

  ExitOperation _boundOperation(ExitScope scope, Map<String, dynamic> json,
      {String? id}) {
    final value = ExitOperation.fromJson(json);
    if (!value.matches(scope) || (id != null && value.id != id)) {
      throw const FormatException('Scope mismatch');
    }
    return value;
  }

  @override
  Future<DeviceSnapshot> device(ExitScope scope) =>
      _request('GET', _path(scope), (json) {
        final value = DeviceSnapshot.fromJson(json);
        if (value.id != scope.deviceId ||
            value.registrationId != scope.registrationId) {
          throw const FormatException('Scope mismatch');
        }
        return value;
      });
  @override
  Future<ExitPreview> preview(ExitScope scope, int deviceVersion) =>
      _request('POST', '${_path(scope)}/deprovision/previews', (json) {
        final value = ExitPreview.fromJson(json);
        if (!value.matches(scope) || value.deviceVersion != deviceVersion) {
          throw const FormatException('Scope mismatch');
        }
        return value;
      }, body: {'action': 'AGENT_UNENROLL'}, version: deviceVersion);
  @override
  Future<ExitOperation> confirm(ExitScope scope,
      {required String previewId,
      required String previewHash,
      required int deviceVersion,
      required String key}) {
    canonicalId(previewId);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(previewHash)) {
      throw ArgumentError('Invalid preview hash');
    }
    return _request('POST', '${_path(scope)}/deprovision/operations',
        (json) => _boundOperation(scope, json),
        body: {'previewId': previewId, 'previewHash': previewHash},
        version: deviceVersion,
        key: key,
        mutation: true);
  }

  @override
  Future<ExitOperation> operation(ExitScope scope, String operationId) =>
      _request(
          'GET',
          '${_path(scope)}/deprovision/operations/${canonicalId(operationId)}',
          (json) => _boundOperation(scope, json, id: operationId));
  @override
  Future<List<ExitOperation>> operations(ExitScope scope) async {
    final values = <ExitOperation>[];
    final seenIds = <String>{}, seenCursors = <String>{};
    String? cursor;
    // Bounded traversal: do not silently present partial history as current.
    for (var page = 0; page < 20; page++) {
      final result = await _request<(List<ExitOperation>, String?)>(
          'GET', '${_path(scope)}/deprovision/operations', (json) {
        final items = json['items'];
        if (items is! List || items.length > 100) {
          throw const FormatException('Invalid operation page');
        }
        final next = json['nextCursor'];
        if (next != null && next is! String) {
          throw const FormatException('Invalid cursor');
        }
        if (next != null) canonicalId(next);
        final parsed = items.map((item) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException('Invalid operation');
          }
          return _boundOperation(scope, item);
        }).toList();
        return (parsed, next as String?);
      }, query: {'limit': '100', if (cursor != null) 'cursor': cursor});
      for (final value in result.$1) {
        if (!seenIds.add(value.id)) {
          throw const ExitFailure('RESPONSE_INVALID', '操作记录重复，请稍后刷新。');
        }
        values.add(value);
      }
      cursor = result.$2;
      if (cursor == null) return List.unmodifiable(values);
      if (!seenCursors.add(cursor)) {
        throw const ExitFailure('RESPONSE_INVALID', '操作分页异常，请联系管理员。');
      }
    }
    throw const ExitFailure(
        'HISTORY_LIMIT_REACHED', '操作历史超过本页处理范围，请联系管理员核对当前任务。');
  }

  @override
  Future<ExitOperation> cancel(ExitScope scope,
          {required String operationId,
          required int version,
          required String key}) =>
      _request(
          'POST',
          '${_path(scope)}/deprovision/operations/${canonicalId(operationId)}/cancel',
          (json) => _boundOperation(scope, json, id: operationId),
          version: version,
          key: key,
          mutation: true);
}

const _failureCopy = <String, String>{
  'REAUTH_REQUIRED': '请重新完成管理员安全验证，再核对此操作。',
  'SCOPE_DENIED': '当前账号无权管理此设备，请联系家庭或机构管理员。',
  'RESOURCE_VERSION_CONFLICT': '设备或操作已变化，请刷新后重新确认。',
  'VERSION_REQUIRED': '缺少资源版本，请刷新后重试。',
  'DEPROVISION_PREVIEW_UNAVAILABLE': '预览已失效或已使用，请核对操作记录。',
  'DEPROVISION_ACTION_UNSUPPORTED': '此设备当前不支持该退出操作。',
  'REGISTRATION_KEY_UNAVAILABLE': '原注册密钥不可用，请联系管理员。',
  'SIGNING_KEY_NOT_CONFIGURED': '清理签名服务未配置，请联系运维。',
  'SIGNING_TEMPORARILY_UNAVAILABLE': '清理签名服务暂时不可用，请稍后核对。',
  'IDEMPOTENCY_KEY_CONFLICT': '请求标识发生冲突，请核对已有操作。',
  'IDEMPOTENCY_KEY_EXPIRED': '原请求的保留期限已到，请核对历史记录后联系管理员。',
  'CLEANUP_OPERATION_EXISTS': '当前注册已有清理任务，请先查看操作状态。',
  'CLEANUP_NOT_CANCELLABLE': '此操作已不能取消，请刷新当前状态。',
};
const _rejections = <String>{
  'REAUTH_REQUIRED',
  'SCOPE_DENIED',
  'RESOURCE_VERSION_CONFLICT',
  'VERSION_REQUIRED',
  'DEPROVISION_PREVIEW_UNAVAILABLE',
  'DEPROVISION_ACTION_UNSUPPORTED',
  'REGISTRATION_KEY_UNAVAILABLE',
  'IDEMPOTENCY_KEY_REQUIRED',
  'IDEMPOTENCY_KEY_INVALID',
  'IDEMPOTENCY_KEY_CONFLICT',
  'IDEMPOTENCY_KEY_EXPIRED',
  'CLEANUP_OPERATION_EXISTS',
  'CLEANUP_NOT_CANCELLABLE',
  'VALIDATION_FAILED',
  'INVALID_REQUEST',
};
