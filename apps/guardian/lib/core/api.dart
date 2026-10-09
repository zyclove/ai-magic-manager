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
        'WORKSPACE_CHANGED' => '工作空间已切换。请关闭当前窗口，在新工作空间重新操作。',
        'OWNER_TRANSFER_REQUIRED' => '所有者不能在成员编辑中修改或撤销。请使用“所有者交接”。',
        'MEMBER_CLASS_CHANGE_REQUIRES_INVITATION' =>
          '儿童与成人身份不能直接互换。请撤销后重新邀请，由收件人完成对应身份验证。',
        'SUBJECT_SCOPE_REQUIRED' => '儿童和教师角色必须关联本工作空间内的有效档案。请重新选择档案。',
        'ROLE_SCOPE_NOT_APPLICABLE' => '角色与访问范围不匹配。教师请选择班级或单个档案，其他角色请核对档案限制。',
        'INVALID_CLASS_SCOPE' => '请选择 1–50 个班级，不能重复选择。',
        'CLASS_SCOPE_UNAVAILABLE' => '所选班级已归档或不可访问。请刷新并重新选择。',
        'CLASS_ARCHIVED' => '班级已归档，无法继续调整名册。请刷新查看状态。',
        'CLASS_CAPACITY_REACHED' => '目标班级已达到 500 人上限。请选择其他班级。',
        'CLASS_STUDENT_NOT_ENROLLED' => '该学生已不在源班级中。请刷新名册。',
        'CLASS_TRANSFER_SAME_TARGET' => '请选择不同的目标班级。',
        'ORGANIZATION_REQUIRED' => '班级管理仅适用于机构工作空间。',
        'ROLE_NOT_APPLICABLE' => '所选角色不适用于当前工作空间。请刷新后重新选择。',
        'INVITATION_UNAVAILABLE' => '邀请已使用、取消或过期。请联系管理员重新邀请。',
        'MEMBER_ALREADY_EXISTS' => '此账号已加入工作空间，无需再次接受邀请。',
        'OWNERSHIP_TRANSFER_PENDING' => '已有待确认的交接申请。请先打开现有申请，等待对方确认或撤销后重新发起。',
        'OWNERSHIP_TARGET_INELIGIBLE' =>
          '请选择已加入的成人监护人、机构管理员或审计员；儿童和范围受限教师不能接收所有权。',
        'OWNERSHIP_TRANSFER_UNAVAILABLE' => '此交接申请已结束。请刷新查看最新结果，需要时由现任所有者重新发起。',
        'OWNERSHIP_INVARIANT_FAILED' => '工作空间所有者状态异常，交接未执行。请联系管理员检查。',
        'RESOURCE_VERSION_CONFLICT' => '记录已被其他操作更新。请刷新后再修改。',
        'VALIDATION_FAILED' || 'MALFORMED_REQUEST' => '提交内容不符合要求，请检查各项输入。',
        'NETWORK_ERROR' => '无法连接服务，请检查网络后重试。',
        'ACCESS_REQUEST_PENDING' => '该设备与应用已有待审批申请，请等待处理或打开已有申请。',
        'ACCESS_EXCEPTION_EXISTS' => '该设备与应用已有尚未结束的访问窗口，请等待窗口结束。',
        'ACCESS_REQUEST_COOLDOWN' => '申请过于频繁，请稍等一分钟后重试。',
        'ACCESS_REQUEST_NOT_PENDING' => '申请状态已变化，请关闭并刷新后查看。',
        'ACCESS_TARGET_CHANGED' ||
        'BASELINE_CHANGED' =>
          '设备绑定或策略版本已变化，请刷新可申请规则后重新提交。',
        'DEVICE_NOT_ACTIVE' => '设备当前不可申请访问，请检查设备状态并刷新。',
        'EXCEPTION_RULE_INVALID' => '请选择 1–20 条当前应用支持的规则。',
        'EXCEPTION_KIND_UNSUPPORTED' => '当前只能申请应用启动与使用时段规则。',
        'GRANT_EXCEEDS_REQUEST' => '批准时长不能超过申请时长。',
        'ACCESS_SELF_DECISION_FORBIDDEN' => '不能审批本人提交的申请。',
        'INVALID_QUOTA_PERIOD' => '请填写有效日期（YYYY-MM-DD）和 IANA 时区。',
        'QUOTA_LIMIT_INVALID' => '额度应在 0–1440 分钟内，调整分钟数至少为 1。',
        'QUOTA_PERIOD_UNAVAILABLE' ||
        'QUOTA_PERIOD_CLOSED' =>
          '该额度日期已经结束，或超出可配置日期范围。请选择当前或未来日期。',
        'QUOTA_POOL_EXISTS' => '该儿童在这个日期和应用范围已有额度，请打开现有记录调整。',
        'QUOTA_TIME_ZONE_LOCKED' => '同一儿童的额度时区必须保持一致，请使用已有额度的时区。',
        'QUOTA_PLAN_EXISTS' => '此儿童和范围已有重复计划，请打开现有计划修改。',
        'QUOTA_PLAN_START_INVALID' => '新计划只能从额度时区的今天或明天开始，请重新打开表单获取当前日期。',
        'QUOTA_WEEK_INCOMPLETE' => '请完整设置一周七天的额度。',
        'QUOTA_OVERRIDE_INVALID' => '日期例外只能设置在未来 366 天以内。',
        'QUOTA_SCOPE_ALREADY_USED' =>
          '该应用当天已有租约或用量，不能再新增当日应用额度。请为下一日期设置，或调整现有总额度。',
        'QUOTA_BALANCE_CONFLICT' => '调整后的总额不能低于已结算与待确认预留之和，也不能超过 1440 分钟。',
        'QUOTA_EXECUTION_UNVERIFIED' => '这台设备的可靠计时与停止能力尚未完成验证，暂不能发放硬额度。',
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
