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
        'PREVIEW_STALE' => '预览已过期或设备已变化，请重新预览。',
        'POLICY_GROUP_CHANGED' => '设备组或成员状态已变化，请重新选择设备组并预览。',
        'POLICY_GROUP_TOO_LARGE' => '该组超过 50 台有效设备，请在管理台拆分后重试。不会截取部分设备。',
        'POLICY_GROUP_EMPTY' => '该组没有当前有效设备，请检查成员注册及启用状态。',
        'DEVICE_GROUP_NAME_EXISTS' => '此机构已有同名设备组，请核对目录或更换名称。',
        'DEVICE_GROUP_ARCHIVED' => '设备组已归档，请刷新后查看历史。',
        'DEVICE_GROUP_STALE_MEMBERSHIP' => '成员注册周期已改变，请核对并移出旧关联后再加入。',
        'DEVICE_GROUP_DEVICE_UNAVAILABLE' => '所选设备或儿童档案已不可用，请刷新后重新选择。',
        'DEVICE_GROUP_MEMBER_UNAVAILABLE' => '所选成员已被移出，请刷新设备组。',
        'DEVICE_GROUP_CAPACITY_REACHED' => '设备组已达 5000 台容量，请拆分设备组。',
        'INVALID_DEVICE_GROUP_NAME' => '设备组名称无效，请去除控制或不可见格式字符。',
        'APPLICATION_IDENTITY_EXISTS' => '相同应用身份已登记，请返回目录核对；不要重复创建。',
        'DUPLICATE_SIGNING_DIGEST' => '签名摘要不能重复，请检查后重新登记。',
        'INVALID_CLASSIFICATION_RESPONSE' => '返回的应用分类与所选身份不一致，请重新读取。',
        'INVALID_OBSERVATION_RESPONSE' => '观察授权响应未通过校验，请重新核对原操作和当前状态。',
        'INVALID_PERMISSION_OBSERVATION_RESPONSE' => '权限状态数据未通过校验，请刷新后重新核对。',
        'INVALID_PERMISSION_SELECTION' => '应用清单已变化，请刷新后重新选择。',
        'PERMISSION_PROFILE_MISMATCH' => '这份快照属于另一个设备用户，请在儿童设备选择对应用户的应用后上报。',
        'PERMISSION_VIEW_CHANGED' => '观察授权刚刚发生变化，请刷新后查看。',
        'PERMISSION_BACKEND_UNAVAILABLE' => '当前服务尚未提供权限观察，请联系管理员启用并完成设备兼容验证。',
        'OBSERVATION_RESULT_UNAVAILABLE' => '未找到原操作结果，不代表从未提交。请核对当前授权和审计。',
        'IDEMPOTENCY_RESPONSE_ERASED' => '原操作结果已按删除流程清理。不会重放或自动重新创建授权。',
        'REGISTRATION_CHANGED' => '设备注册或所属档案已变化。请返回设备列表重新选择。',
        'DEVICE_NOT_ACTIVE' => '设备已不处于启用状态，不能继续修改授权。',
        'INVALID_TIME_ZONE' => '时区未被服务端识别，请检查拼写，例如 Asia/Shanghai。',
        'DUPLICATE_SCHEDULE_DATE' => '同一日期只能设置一份例外安排，请合并时段。',
        'AMBIGUOUS_SCHEDULE_WINDOW' => '开始和结束时间不能相同。全天不可用请使用空时段。',
        'SAFETY_BASELINE_PROTECTED' => '此规则会影响紧急联系或恢复管理，请调整目标应用或限制方式。',
        'DOMAIN_NOT_CANONICAL' => '域名格式不正确，请使用小写域名，不含协议或路径。',
        'NOT_RUNTIME_PERMISSION' => '该权限已不在支持目录中，请重新选择权限项目。',
        'ACCESS_REQUEST_NOT_PENDING' => '申请状态已变化，请刷新列表。',
        'HELP_REQUEST_VERSION_CHANGED' => '求助状态已变化，请刷新列表。',
        'INVALID_HELP_RESPONSE' => '求助记录未通过校验，请重新查询。',
        'HELP_REQUEST_UNAVAILABLE' => '这条求助当前已不可查看，请核对权限或联系管理员。',
        'HELP_PENDING_CHANGED' => '待核对求助已变化，请返回列表打开原记录。',
        'SCOPE_DENIED' => '当前账号没有此操作权限。',
        'INVALID_SUBJECT_CHANGE' => '档案参数已失效或不完整，请重新核对昵称、年龄段和版本。',
        'SUBJECT_RESULT_UNAVAILABLE' => '未找到原档案操作结果，不代表没有提交。请另行核对目录与审计。',
        'UNAUTHENTICATED' => '登录已过期，请重新登录。',
        'NETWORK_ERROR' => '连接服务失败，请检查网络后重试。',
        'INVALID_RESPONSE' => '服务返回的数据无法识别，请稍后刷新。',
        'INVALID_NOTIFICATION_RESPONSE' => '消息响应不完整，请重新读取后核对。',
        'INVALID_NOTIFICATION_SELECTION' => '所选消息已失效，请重新读取列表。',
        'WORKSPACE_CHANGED' => '当前身份或工作空间已变化，请重新打开消息中心。',
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
      bool Function()? isCurrent,
      int maxResponseBytes = 1024 * 1024}) async {
    if (maxResponseBytes < 1 || maxResponseBytes > 4 * 1024 * 1024) {
      throw const ParentApiException(400, 'INVALID_RESPONSE');
    }
    try {
      final token = await accessToken();
      // A screen can lose its account or workspace while token refresh waits.
      // Check again immediately before constructing and dispatching the request.
      if (isCurrent != null && !isCurrent()) {
        throw const ParentApiException(409, 'SCOPE_DENIED');
      }
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

  Future<Json> object(String path, {bool Function()? isCurrent}) async {
    final result = await send('GET', path, isCurrent: isCurrent);
    if (result is! Map<String, dynamic>) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return result;
  }

  Future<ParentPage> page(String path,
      {String? cursor, int limit = 50, bool Function()? isCurrent}) async {
    if (limit < 1 || limit > 50) {
      throw const ParentApiException(400, 'INVALID_RESPONSE');
    }
    final separator = path.contains('?') ? '&' : '?';
    final result = await send('GET',
        '$path${separator}limit=$limit${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}',
        isCurrent: isCurrent);
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
