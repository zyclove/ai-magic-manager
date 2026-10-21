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
        'ACCOUNT_SECURITY_UNAVAILABLE' => '账号安全服务暂未开放或暂时无法连接，请稍后重试。',
        'ACCOUNT_SESSION_STALE' => '账号登录方式已更新，请用当前手机号或已绑定微信重新登录。',
        'ACCOUNT_OPERATION_CHANGED' => '账号状态已变化，请重新核对后操作。',
        'ACCOUNT_OPERATION_UNCONFIRMED' => '暂未确认修改结果。请先核对当前账号状态，再继续操作。',
        'ACCOUNT_OPERATION_NOT_STARTED' => '账号修改尚未开始，可重新选择验证方式。',
        'WECHAT_NOT_INSTALLED' => '请先安装微信再使用微信验证；仍可用当前手机号登录。',
        'FAMILY_LOGIN_UNAVAILABLE' => '此登录方式暂未开放，请稍后重试或选择其他登录方式。',
        'VERIFIED_PHONE_REQUIRED' => '请先验证并绑定手机号，再创建家庭。',
        'GUARDIAN_DECLARATION_REQUIRED' => '请确认成人监护人声明后继续。',
        'AI_CONSENT_REQUIRED' => '请先阅读并同意云端智能服务说明。',
        'AI_PROVIDER_UNAVAILABLE' => '云端助手暂不可用，日常规则和报告仍可使用。',
        'AI_QUOTA_EXHAUSTED' => '本期智能服务次数已用完，下期会自动恢复。',
        'ENTITLEMENT_REQUIRED' => '此功能需要有效的家庭会员。',
        'FAMILY_DEVICE_LIMIT_REACHED' =>
          '设备名额已用完。请查看当前连接和待确认的设备，再选择保留设备或核对会员状态。',
        'FAMILY_SELECTION_NOT_REQUIRED' => '当前会员有效，无需选择保留设备。请刷新查看设备名额。',
        'FAMILY_SELECTION_DEVICE_UNAVAILABLE' => '所选设备已退出或连接状态已变化，请刷新后重新选择。',
        'FAMILY_DEVICE_RECOVERY_ONLY' =>
          '此设备当前保留恢复功能，可放宽或解除规则、必要放行和正常退出。请查看保留设备或会员状态。',
        'FAMILY_PAYMENT_UNAVAILABLE' => '当前尚未开放付款，请稍后再试。',
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
        'IDEMPOTENCY_RESULT_EXPIRED' => '原操作结果已超过 90 天保留期，无法恢复。请查看当前记录。',
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

/// Only the transport can construct this evidence. A code string alone is not
/// proof that a complete, correctly scoped HTTP 410 response was received.
final class ParentResultTerminalFailure extends ParentApiException {
  final String? _requestId;
  final String _path;
  const ParentResultTerminalFailure._(String code, String? correlationId,
      this._requestId, this._path) : super(410, code, correlationId);
  bool matchesRequest(dynamic requestId) => requestId is String &&
      requestId.isNotEmpty && (_requestId == requestId ||
          Uri.parse(_path).pathSegments.contains(requestId));
}

class ParentApi {
  final Future<String> Function() accessToken;
  final http.Client _http;
  final String baseUrl;
  final bool _ownsClient;
  final bool Function() Function()? _captureScope;

  ParentApi(this.accessToken, {http.Client? client, required this.baseUrl})
      : _http = client ?? http.Client(), _ownsClient = true, _captureScope = null;

  ParentApi._scoped(ParentApi source, bool Function() Function() capture)
      : accessToken = source.accessToken, _http = source._http,
        baseUrl = source.baseUrl, _ownsClient = false, _captureScope = (() {
          final outer = source._captureScope?.call(), inner = capture();
          return () => (outer?.call() ?? true) && inner();
        });

  /// A request captures its own scope before its first await. A later valid
  /// step-up cannot revive an older request waiting for credentials or storage.
  ParentApi scoped(bool Function() Function() capture) => ParentApi._scoped(this, capture);

  /// All sensitive reads are no-store. Writes use an explicit version and
  /// idempotency key when the endpoint supports one.
  Future<dynamic> send(String method, String path,
      {Json? body,
      int? version,
      String? idempotencyKey,
      String? clientRequestId,
      bool Function()? isCurrent,
      Future<bool> Function()? beforeDispatch,
      int? expectedStatus,
      int maxResponseBytes = 1024 * 1024}) async {
    final captured = _captureScope?.call();
    bool current() => (captured?.call() ?? true) && (isCurrent?.call() ?? true);
    if (maxResponseBytes < 1 || maxResponseBytes > 4 * 1024 * 1024) {
      throw const ParentApiException(400, 'INVALID_RESPONSE');
    }
    if (expectedStatus != null &&
        (expectedStatus < 200 || expectedStatus > 299)) {
      throw const ParentApiException(400, 'INVALID_RESPONSE');
    }
    try {
      if (!current()) throw const ParentApiException(409, 'SCOPE_DENIED');
      final token = await accessToken();
      if (!current()) throw const ParentApiException(409, 'SCOPE_DENIED');
      if (beforeDispatch != null && !await beforeDispatch()) {
        throw const ParentApiException(409, 'SCOPE_DENIED');
      }
      // A screen can lose its account or workspace while token refresh waits.
      // Check again immediately before constructing and dispatching the request.
      if (!current()) {
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
      final (status, bytes, headers, contentLength) = await (() async {
        final streamed = await _http.send(request);
        final bytes = <int>[];
        await for (final chunk in streamed.stream) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const ParentApiException(502, 'INVALID_RESPONSE');
          }
          bytes.addAll(chunk);
        }
        return (streamed.statusCode, bytes, streamed.headers, streamed.contentLength);
      })()
          .timeout(const Duration(seconds: 25));
      if (!current()) {
        throw const ParentApiException(409, 'SCOPE_DENIED');
      }
      if (contentLength != null && contentLength != bytes.length) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
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
        final code = decoded is Map ? decoded['errorCode'] : null;
        final media = headers['content-type']?.toLowerCase().split(';');
        final contentType = media?.first.trim();
        final utf8Media = media != null && media.skip(1).every((part) {
          final parameter = part.trim();
          return !parameter.startsWith('charset=') ||
              const {'charset=utf-8', 'charset="utf-8"'}.contains(parameter);
        });
        if (status == 410 && decoded is Json &&
            const {'IDEMPOTENCY_RESULT_EXPIRED', 'IDEMPOTENCY_RESPONSE_ERASED'}.contains(code) &&
            utf8Media &&
            (contentType == 'application/json' || contentType == 'application/problem+json') &&
            decoded['status'] is int && decoded['status'] == 410 &&
            (decoded['correlationId'] == null || decoded['correlationId'] is String)) {
          throw ParentResultTerminalFailure._(code as String,
              decoded['correlationId'] as String?,
              idempotencyKey ?? clientRequestId, path);
        }
        throw ParentApiException(
            status,
            decoded is Map && decoded['errorCode'] is String
                ? decoded['errorCode'] as String
                : 'REQUEST_FAILED',
            decoded is Map && decoded['correlationId'] is String
                ? decoded['correlationId'] as String
                : null);
      }
      // A 202 only acknowledges acceptance. Callers that revoke sensitive
      // state must not erase their recovery journal before definite completion.
      if (expectedStatus != null &&
          (status != expectedStatus ||
              (expectedStatus == 204 && bytes.isNotEmpty))) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
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

  Future<Json> object(String path, {bool Function()? isCurrent,
      Future<bool> Function()? beforeDispatch}) async {
    final result = await send('GET', path, isCurrent: isCurrent,
        beforeDispatch: beforeDispatch);
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

  void close() { if (_ownsClient) _http.close(); }
}
