import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

typedef Json = Map<String, dynamic>;
String requestId() {
  final random = Random.secure();
  return List.generate(
      24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class ApiFailure implements Exception {
  final int status;
  final String code;
  final String? correlationId;
  const ApiFailure(this.status, this.code, [this.correlationId]);
  String get message => switch (code) {
        'REAUTH_REQUIRED' => '此操作需要近期多因素认证。请完成安全验证后重试。',
        'UNAUTHENTICATED' => '登录已过期，请重新登录。',
        'SCOPE_DENIED' => '当前账号没有此操作权限。',
        'RESOURCE_VERSION_CONFLICT' => '记录已被其他操作更新。请刷新后再修改。',
        'VALIDATION_FAILED' || 'MALFORMED_REQUEST' => '提交内容不符合要求，请检查各项输入。',
        'NETWORK_ERROR' => '无法连接服务，请检查网络后重试。',
        'PENDING_OPERATION_UNCHANGED' => '上次提交的结果尚未确认。请使用原内容重试，或刷新列表确认结果后重新操作。',
        'ADD_TIME_WINDOW' => '请先添加至少一个每周时段。',
        'INVALID_TIME_WINDOW' => '请选择日期，并设置不同的开始和结束时间。',
        'LOGIN_STATE_EXPIRED' => '登录请求已过期，请重新发起安全登录。',
        'INVALID_TIME_ZONE' => '请输入有效时区，例如 Asia/Shanghai。',
        'SAFETY_BASELINE_PROTECTED' => '此规则涉及紧急恢复保护，不能限制。',
        'INVITATION_INVALID' => '邀请已失效、过期或已使用。',
        'UNSUPPORTED_MANAGEMENT_MODE' => '该设备管理模式尚未配置执行适配器。',
        'PAIRING_VERIFICATION_FAILED' => '配对码不正确，请核对设备上显示的 8 位配对码。',
        'CONFIGURATION_SIGNING_UNAVAILABLE' => '配置签名服务尚未配置，请联系管理员。',
        _ => status == 403
            ? '没有访问权限，请切换工作空间或联系管理员。'
            : status == 404
                ? '该记录不存在或已不可访问。'
                : status >= 500
                    ? '服务暂时不可用，请稍后重试。'
                    : '操作未完成，请检查输入和当前记录状态。',
      };
  @override
  String toString() => message;
}

class PageResult {
  final List<Json> items;
  final String? nextCursor;
  PageResult(this.items, this.nextCursor);
}

class Api {
  final _pendingWrites = <String, String>{};
  final Future<http.Client> Function() client;
  final String baseUrl;
  Api(this.client,
      {this.baseUrl = const String.fromEnvironment('API_URL',
          defaultValue: 'http://localhost:8082/api/v1')});
  Future<dynamic> send(String method, String path,
      {Json? body, int? version, String? key}) async {
    try {
      final signature = jsonEncode([method, path, version, body]);
      if (key != null &&
          _pendingWrites.containsKey(key) &&
          _pendingWrites[key] != signature) {
        throw const ApiFailure(409, 'PENDING_OPERATION_UNCHANGED');
      }
      final req = http.Request(method, Uri.parse('$baseUrl$path'));
      req.headers['Accept'] = 'application/json';
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      if (version != null) req.headers['If-Match'] = '"$version"';
      if (key != null) req.headers['Idempotency-Key'] = key;
      if (key != null) _pendingWrites[key] = signature;
      final response = await (() async =>
              http.Response.fromStream(await (await client()).send(req)))()
          .timeout(const Duration(seconds: 25));
      if (key != null && response.statusCode < 500) _pendingWrites.remove(key);
      dynamic decoded;
      if (response.body.isNotEmpty) {
        try {
          decoded = jsonDecode(utf8.decode(response.bodyBytes));
        } on FormatException {
          decoded = null;
        }
      }
      if (response.statusCode >= 400) {
        throw ApiFailure(
            response.statusCode,
            decoded is Map
                ? decoded['errorCode'] ?? 'REQUEST_FAILED'
                : 'REQUEST_FAILED',
            decoded is Map ? decoded['correlationId'] : null);
      }
      return decoded;
    } on ApiFailure {
      rethrow;
    } on TimeoutException {
      throw const ApiFailure(0, 'NETWORK_ERROR');
    } on http.ClientException {
      throw const ApiFailure(0, 'NETWORK_ERROR');
    }
  }

  Future<PageResult> page(String path, {String? cursor}) async {
    final separator = path.contains('?') ? '&' : '?';
    final result = await send('GET',
        '$path${separator}limit=50${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}');
    if (result is! Map || result['items'] is! List) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    return PageResult(
        (result['items'] as List)
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
        result['nextCursor']);
  }

  Future<List<Json>> all(String path) async {
    final items = <Json>[];
    String? cursor;
    final seen = <String>{};
    do {
      final next = await page(path, cursor: cursor);
      items.addAll(next.items);
      cursor = next.nextCursor;
      if (cursor != null && !seen.add(cursor)) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      if (items.length > 10000) throw const ApiFailure(400, 'TOO_MANY_RESULTS');
    } while (cursor != null);
    return items;
  }
}
