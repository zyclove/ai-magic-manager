import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

typedef Json = Map<String, dynamic>;

class ParentPage {
  final List<Json> items;
  final String? nextCursor;
  const ParentPage(this.items, this.nextCursor);
}

/// API errors keep the server's correlation ID for support without logging tokens.
class ParentApiException implements Exception {
  final int status;
  final String code;
  final String? correlationId;

  const ParentApiException(this.status, this.code, [this.correlationId]);

  String get message => switch (code) {
        'REAUTH_REQUIRED' => '请完成近期安全验证后重试。',
        'RESOURCE_VERSION_CONFLICT' => '记录已发生变化，请刷新后重新处理。',
        'ACCESS_REQUEST_NOT_PENDING' => '申请状态已变化，请刷新列表。',
        'HELP_REQUEST_VERSION_CHANGED' => '求助状态已变化，请刷新列表。',
        'SCOPE_DENIED' => '当前账号没有此操作权限。',
        'UNAUTHENTICATED' => '登录已过期，请重新登录。',
        'NETWORK_ERROR' => '连接服务失败，请检查网络后重试。',
        'INVALID_RESPONSE' => '服务返回的数据无法识别，请稍后刷新。',
        'CONFIGURATION_REQUIRED' => '请先配置可从手机访问的 HTTPS 身份服务和 API。',
        'LOGIN_FAILED' => '安全登录未完成，请检查身份服务或稍后重试。',
        _ => status == 403
            ? '当前账号没有此操作权限。'
            : status >= 500
                ? '服务暂时不可用，请稍后重试。'
                : '操作未完成，请刷新后重试。',
      };

  @override
  String toString() =>
      correlationId == null ? message : '$message\n问题编号：$correlationId';
}

class ParentApi {
  final Future<String> Function() accessToken;
  final http.Client _http;
  final String baseUrl;

  ParentApi(this.accessToken, {http.Client? client, required this.baseUrl})
      : _http = client ?? http.Client();

  /// All sensitive reads are no-store. Writes use an explicit version and
  /// idempotency key when the endpoint supports one.
  Future<dynamic> send(String method, String path,
      {Json? body,
      int? version,
      String? idempotencyKey,
      String? clientRequestId,
      int maxResponseBytes = 1024 * 1024}) async {
    if (maxResponseBytes < 1 || maxResponseBytes > 4 * 1024 * 1024) {
      throw const ParentApiException(400, 'INVALID_RESPONSE');
    }
    try {
      final token = await accessToken();
      final request = http.Request(method, Uri.parse('$baseUrl$path'));
      // An API redirect must not forward the bearer token to another origin.
      request.followRedirects = false;
      request.headers.addAll({
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
        'Cache-Control': 'no-store',
        if (version != null) 'If-Match': '"$version"',
        if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
        if (clientRequestId != null) 'Client-Request-Id': clientRequestId,
      });
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final (status, bytes) = await (() async {
        final streamed = await _http.send(request);
        final bytes = <int>[];
        await for (final chunk in streamed.stream) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const ParentApiException(502, 'INVALID_RESPONSE');
          }
          bytes.addAll(chunk);
        }
        return (streamed.statusCode, bytes);
      })()
          .timeout(const Duration(seconds: 25));
      if (status >= 300 && status < 400) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      dynamic decoded;
      if (bytes.isNotEmpty) {
        try {
          decoded = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          throw const ParentApiException(502, 'INVALID_RESPONSE');
        }
      }
      if (status >= 400) {
        throw ParentApiException(
            status,
            decoded is Map && decoded['errorCode'] is String
                ? decoded['errorCode'] as String
                : 'REQUEST_FAILED',
            decoded is Map && decoded['correlationId'] is String
                ? decoded['correlationId'] as String
                : null);
      }
      return decoded;
    } on ParentApiException {
      rethrow;
    } on TimeoutException {
      throw const ParentApiException(0, 'NETWORK_ERROR');
    } on http.ClientException {
      throw const ParentApiException(0, 'NETWORK_ERROR');
    }
  }

  Future<Json> object(String path) async {
    final result = await send('GET', path);
    if (result is! Map<String, dynamic>) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return result;
  }

  Future<ParentPage> page(String path, {String? cursor, int limit = 50}) async {
    if (limit < 1 || limit > 50) {
      throw const ParentApiException(400, 'INVALID_RESPONSE');
    }
    final separator = path.contains('?') ? '&' : '?';
    final result = await send('GET',
        '$path${separator}limit=$limit${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}');
    if (result is! Map || result['items'] is! List) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    final items = <Json>[];
    for (final item in result['items'] as List) {
      if (item is! Map<String, dynamic>) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      items.add(item);
    }
    final next = result['nextCursor'];
    if (next != null && (next is! String || next.isEmpty)) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return ParentPage(items, next as String?);
  }

  Future<List<Json>> all(String path) async {
    final items = <Json>[];
    final cursors = <String>{};
    String? cursor;
    do {
      final page = await this.page(path, cursor: cursor);
      items.addAll(page.items);
      cursor = page.nextCursor;
      if (cursor != null && !cursors.add(cursor)) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (items.length > 10000) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
    } while (cursor != null);
    return items;
  }

  void close() => _http.close();
}
