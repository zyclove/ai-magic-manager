import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'scoped_http_client.dart';

typedef Json = Map<String, dynamic>;
final _clientRequestIdPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

void _ensureCurrent(bool Function()? isCurrent) {
  if (isCurrent != null && !isCurrent()) {
    throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }
}

String requestId() {
  final random = Random.secure();
  return List.generate(
      24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Stops replay in editor UI only; this is not evidence of server execution.
bool isUnavailableOperationResult(Object? failure) =>
    failure is ApiFailure &&
    ((failure.status == 409 && failure.code == 'IDEMPOTENCY_KEY_EXPIRED') ||
        (failure.status == 410 &&
            const {'IDEMPOTENCY_RESULT_EXPIRED', 'IDEMPOTENCY_RESPONSE_ERASED'}
                .contains(failure.code)));

class ApiFailure implements Exception {
  final int status;
  final String code;
  final String? correlationId;
  const ApiFailure(this.status, this.code, [this.correlationId]);
  String get message => switch (code) {
        'INVALID_MEMBER_SCOPE_OPTIONS' => '范围选项资料不完整，请重新加载。原选择已保留。',
        'INVALID_POLICY_DIRECTORY_RESPONSE' => '规则选项资料不完整，未打开规则表单。请重新加载选项。',
        'INVALID_DOMAIN' => '请输入有效域名，不含协议、端口、路径、IP 地址或通配符。',
        'INVALID_DOMAIN_CHECK_RESPONSE' => '域名检查结果与当前草稿不一致，已隐藏结果。请重新打开策略详情后检查。',
        'INVALID_SCHEDULE_PRESETS' => '时间安排示例无法校验，未修改当前草稿。请重试或手动设置。',
        'INVALID_DOMAIN_NORMALIZATION_RESPONSE' =>
          '域名格式校验结果无法确认，未加入规则。请核对输入后重试。',
        'INVALID_RESPONSE' => '服务返回的数据无法读取，暂时不能确认结果。已提交的操作请先核对原记录，避免重复提交。',
        'SUBJECT_RESULT_UNAVAILABLE' =>
          '尚未查到原档案操作结果，不能据此判断操作未执行。请稍后再查询，或核对当前档案。',
        'APPLICATION_CREATION_RESULT_UNAVAILABLE' =>
          '尚未查到原应用登记结果，不能据此判断登记未完成。请稍后再查询，或核对当前应用目录。',
        'SCHEDULE_CREATION_RESULT_UNAVAILABLE' =>
          '尚未查到原时间计划保存结果，不能据此判断保存未完成。请稍后再查询，或核对当前时间计划。',
        'POLICY_DRAFT_RESULT_UNAVAILABLE' =>
          '尚未查到原草稿保存结果，不能据此判断保存未完成。请稍后再查询，或核对当前策略列表。',
        'INVALID_POLICY_DRAFT_CHANGE' => '草稿保存信息不完整，请关闭后重新打开并检查输入。',
        'IDEMPOTENCY_KEY_EXPIRED' => '原请求已超过有效期限，不能再次提交。请查看当前记录；请求到期不代表操作未执行。',
        'IDEMPOTENCY_RESULT_EXPIRED' =>
          '原操作结果已超过 90 天保留期限，不能再恢复。请查看当前记录；不要重复提交原操作。',
        'IDEMPOTENCY_RESPONSE_ERASED' => '原操作结果已清除，不能再恢复。清除结果不代表取消了已发生的操作。',
        'PUBLICATION_RESULT_TERMINAL' => '原操作已结束结果恢复，不能再次提交。请查看当前策略或审计记录。',
        'PREVIEW_EXPIRED' => '此预览已过期，请关闭窗口后重新预览。',
        'ERASURE_MAINTENANCE_REQUIRED' =>
          '系统正在暂停或恢复数据处理，暂时无法确认本次结果。请保留原操作内容，稍后重试。',
        'INVALID_REPORT_JOB_SELECTION' => '请选择 1–200 台设备、有效时区和不超过 32 天的时间范围。',
        'INVALID_REPORT_JOB_RESPONSE' => '任务或结果与所选设备不一致，已隐藏结果。请刷新任务后重试。',
        'INVALID_COMMERCIAL_RESPONSE' => '商业权益数据校验未通过，已隐藏结果。请刷新后重试。',
        'INVALID_CONTRACT_RESPONSE' => '合同数据校验未通过，已隐藏结果。请刷新后重试。',
        'INVALID_MANAGED_ANDROID_RESPONSE' => '受管设备资料校验未通过，已隐藏结果。请刷新后重试。',
        'INVALID_PERMISSION_CATALOG_RESPONSE' =>
          'Android 权限目录未通过校验，暂不能编辑权限规则。请刷新后重试。',
        'INVALID_WELLBEING_INSIGHT_RESPONSE' => '使用建议资料校验未通过，已隐藏结果。请刷新后重试。',
        'EMM_UNAVAILABLE' => '受管设备提供方尚未开通或暂时不可用。请先确认准入与服务配置。',
        'EMM_PROVIDER_MISMATCH' => '当前提供方与企业绑定记录不一致。请联系平台管理员核对接入配置。',
        'ENTERPRISE_BINDING_NOT_FOUND' => '尚未提交企业绑定申请。',
        'ENTERPRISE_BINDING_EXISTS' => '已有企业绑定申请，请刷新查看当前状态。',
        'ENTERPRISE_BINDING_NOT_ACTIVE' => '企业资源尚未完成独立审核。',
        'INVALID_TENANT_ID' => '请输入有效的机构工作空间 ID。',
        'INVALID_CLIENT_REQUEST_ID' => '本次操作编号无效，请关闭窗口后重新开始。',
        'INVALID_ENROLLMENT_ID' => '请输入完整的原注册编号，格式为 36 位小写字母、数字和连字符。',
        'INVALID_OWNERSHIP_EVIDENCE' => '请填写 8–200 字的权属证明索引。',
        'INVALID_BINDING_REASON' => '请填写 5–500 字的审核或撤销理由。',
        'ENTERPRISE_BINDING_NOT_PENDING' => '申请状态已变化，请刷新后再审核。',
        'MANAGED_ANDROID_CONTRACT_REQUIRED' => '当前机构合同尚未授予有效的受管 Android 权益。',
        'MANAGED_ENROLLMENT_ALREADY_PENDING' => '此儿童档案已有待处理注册资料，请先查看或取消。',
        'MANAGED_PAID_CAPACITY_REACHED' =>
          '当前机构合同名额已用尽或仍被待核对注册占用。请核对受管设备和合同后重试。',
        'MANAGED_ENROLLMENT_RATE_LIMITED' ||
        'MANAGED_ENROLLMENT_CAPACITY_REACHED' =>
          '注册资料申请过于频繁或已达到机构上限，请稍后再试。',
        'MANAGED_ENROLLMENT_POLICY_CHANGED' => '初始设备策略在注册过程中发生变化，请联系平台核对后重试。',
        'EMM_DEVICE_IDENTITY_MISMATCH' => '提供方设备身份与本次注册资料不匹配，未完成核对。',
        'MANAGED_ENROLLMENT_NOT_VERIFIED' => '需先完成提供方注册身份核对，才能读取当前状态。',
        'EMM_DEVICE_IDENTITY_INVALID' ||
        'EMM_DEVICE_STATE_INVALID' =>
          '提供方设备资料不完整或身份异常，当前状态未被采信。',
        'CONTRACT_PROVIDER_UNAVAILABLE' =>
          '机构合同签发方当前不可用，提交、审批和机构确认已暂停；已有记录仍可查看。',
        'CONTRACT_ACTIVE_SUBMISSIONS_PAUSED' =>
          '新机构合同受理已暂停。已签名的撤销事实仍可提交；请先核对当前合同状态。',
        'INVALID_CONTRACT_EVIDENCE' => '签名断言无效、过期或与可信来源不一致，请重新从签发方获取。',
        'INVALID_CONTRACT_REASON' => '请填写 5–500 字的审核原因。',
        'CONTRACT_REVIEW_EXISTS' => '同一合同来源版本或证据已提交，请刷新列表查看。',
        'CONTRACT_NOT_PENDING' ||
        'CONTRACT_NOT_AWAITING_CUSTOMER' =>
          '合同状态已变化，请刷新后再操作。',
        'CONTRACT_OFFER_MISMATCH' ||
        'CONTRACT_NOT_ACTIVE' =>
          '合同与当前报价或有效期不匹配，请联系平台核实。',
        'CONTRACT_SOURCE_NOT_ACTIVE' => '撤销目标不是当前生效的合同来源，请刷新后核实。',
        'REPORT_JOB_NOT_READY' => '这份报表暂时无法查看。请刷新任务状态，必要时重新生成。',
        'REPORT_ARTIFACT_UNAVAILABLE' ||
        'REPORT_JOB_UNAVAILABLE' =>
          '报表结果暂时无法读取，请稍后刷新重试。',
        'REPORT_JOB_CAPACITY_REACHED' => '提交过于频繁或任务数已满。请等候一分钟，或取消不再需要的任务后重试。',
        'REPORT_ATTEMPTS_EXHAUSTED' => '多次生成仍未成功，请稍后重新创建任务。',
        'REPORT_JOB_BYTE_LIMIT_EXCEEDED' ||
        'REPORT_TOO_LARGE' =>
          '报表数据量超出上限，请减少设备或缩短时间范围后重新生成。',
        'REPORT_JOB_EXPIRED' => '报表已到期，请重新生成。',
        'INVALID_CLASSIFICATION_RESPONSE' => '分类响应与当前应用不一致，已隐藏结果。请重新加载。',
        'INVALID_REPORT_SCOPE' => '请选择有效的儿童或班级范围，并刷新当前名册后重试。',
        'REPORT_SCOPE_CHANGED' => '班级名册或设备所属档案已变化。请刷新设备与范围后重新生成报表。',
        'INVALID_USAGE_REPORT_QUERY' ||
        'INVALID_REPORT_SELECTION' =>
          '请选择 1–20 台设备、有效时区和不超过 32 天的时间范围。',
        'USAGE_REPORT_TOO_LARGE' => '所选范围的数据量较大，请减少设备数量或缩短时间范围后重试。',
        'USAGE_REPORT_DATA_UNAVAILABLE' => '部分观察数据暂时无法读取，请稍后重试或联系管理员。',
        'INVALID_USAGE_REPORT_RESPONSE' => '报表响应与当前设备或查询范围不一致，已隐藏结果。请刷新后重试。',
        'REAUTH_REQUIRED' => '此操作需要近期多因素认证。请完成安全验证后重试。',
        'EXPORT_ARTIFACT_UNAVAILABLE' => '导出文件暂时不可用，请稍后重试或联系管理员检查导出服务。',
        'EXPORT_NOT_READY' => '此导出当前无法下载。请刷新任务状态，必要时重新生成。',
        'EXPORT_RATE_LIMITED' => '导出提交过于频繁，请等待一分钟后重试。',
        'EXPORT_CAPACITY_REACHED' =>
          '导出提交过于频繁或任务数已满。请稍等一分钟；如仍受限，可取消不再需要的任务后重试。',
        'INVALID_EXPORT_RESPONSE' => '导出数据校验未通过，未保存文件。请刷新后重试。',
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
        'INVALID_DEVICE_GROUP_NAME' => '请输入 1–100 字的设备组名称，不能包含控制字符。',
        'INVALID_DEVICE_GROUP_RESPONSE' => '设备组数据校验未通过，已隐藏结果。请刷新后重试。',
        'DEVICE_GROUP_NAME_EXISTS' => '本机构已有同名设备组，请使用其他名称。',
        'DEVICE_GROUP_ARCHIVED' => '设备组已归档，无法继续修改。请刷新查看最新状态。',
        'DEVICE_GROUP_DEVICE_UNAVAILABLE' => '设备未激活或注册周期已变化，请刷新设备后重新选择。',
        'DEVICE_GROUP_STALE_MEMBERSHIP' => '设备组中的注册周期已变化，请刷新成员后核对。',
        'DEVICE_GROUP_MEMBER_UNAVAILABLE' => '所选设备已不在该组，请刷新成员列表后重新选择。',
        'INVALID_DEVICE_GROUP_STATUS' => '成员状态筛选无效，请刷新页面后重新选择。',
        'DEVICE_GROUP_SUMMARY_INCONSISTENT' => '设备组统计暂时无法核对，请稍后刷新。',
        'DEVICE_GROUP_CAPACITY_REACHED' => '设备组已达到 5000 台上限，请使用其他设备组。',
        'INVALID_DEVICE_GROUP_BATCH' => '单次请选择 1–50 台不同的设备，并核对当前注册身份。',
        'POLICY_GROUP_SELECTION_UNAVAILABLE' =>
          '该设备组没有可用设备，或成员状态已变化。请刷新设备组后重新选择。',
        'POLICY_GROUP_TOO_MANY_ELIGIBLE_DEVICES' =>
          '该组当前有效设备超过 50 台。请拆分设备组，或手动选择不超过 50 台预览。',
        'POLICY_GROUP_CHANGED' => '设备组成员或状态已变化。请重新选择目标并生成预览。',
        'INVALID_POLICY_PREVIEW_RESPONSE' => '策略预览目标与选择不一致，已停止发布。请刷新后重试。',
        'ORGANIZATION_REQUIRED' => '此功能仅适用于机构工作空间。',
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
        'HELP_REQUEST_UNAVAILABLE' => '求助记录不可用，请刷新并核对设备状态。',
        'HELP_REQUEST_ID_REUSED' => '这次求助编号已用于其他内容，请恢复原请求。',
        'HELP_REQUEST_RATE_LIMITED' => '短时间内求助次数过多。请直接联系可信任的成人；有即时危险时使用当地紧急服务。',
        'DEVICE_REVOKE_RESULT_UNKNOWN' =>
          '连接中断，云端撤销可能已提交。请关闭窗口并刷新设备状态，再决定是否需要重试。此结果不代表设备本地数据已清理。',
        'EXCEPTION_RULE_INVALID' => '请选择 1–20 条当前应用支持的规则。',
        'EXCEPTION_KIND_UNSUPPORTED' => '当前只能申请应用启动与使用时段规则。',
        'INVALID_CONNECTION_FILTER' => '连接筛选条件无效，请切换为“全部设备”后重试。',
        'GRANT_EXCEEDS_REQUEST' => '批准时长不能超过申请时长。',
        'INVALID_APPROVAL_DURATION' => '请填写有效的分钟和秒，合计至少 1 秒，且不超过申请时长。',
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
  final Map<String, String> _pendingWrites;
  final bool Function()? _boundScope;
  final Future<http.Client> Function() client;
  final String baseUrl;
  Api(this.client,
      {this.baseUrl = const String.fromEnvironment('API_URL',
          defaultValue: 'http://localhost:8082/api/v1')})
      : _pendingWrites = <String, String>{},
        _boundScope = null;

  Api._bound(this.client, this.baseUrl, this._pendingWrites, this._boundScope);

  /// A borrowed API view shares pending writes and retains every parent guard.
  Api scoped(bool Function() isCurrent) {
    final current = _withScope(isCurrent)!;
    Future<http.Client> boundClient() async {
      _ensureCurrent(current);
      final authenticated = await client();
      _ensureCurrent(current);
      return ScopeBindingClient(authenticated, isCurrent: current);
    }

    return Api._bound(boundClient, baseUrl, _pendingWrites, current);
  }

  bool Function()? _withScope(bool Function()? isCurrent) {
    final bound = _boundScope;
    if (bound == null) return isCurrent;
    return () => bound() && (isCurrent == null || isCurrent());
  }

  Future<dynamic> send(String method, String path,
      {Json? body,
      int? version,
      String? key,
      String? clientRequestId,
      bool Function()? isCurrent}) async {
    final current = _withScope(isCurrent);
    final abort = Completer<void>();
    void abortRequest() {
      if (!abort.isCompleted) abort.complete();
    }

    try {
      _ensureCurrent(current);
      if (clientRequestId != null) {
        final match = _clientRequestIdPattern.firstMatch(clientRequestId);
        if (match == null || match.end != clientRequestId.length) {
          throw const ApiFailure(400, 'INVALID_CLIENT_REQUEST_ID');
        }
      }
      final signature =
          jsonEncode([method, path, version, body, clientRequestId]);
      if (key != null &&
          _pendingWrites.containsKey(key) &&
          _pendingWrites[key] != signature) {
        throw const ApiFailure(409, 'PENDING_OPERATION_UNCHANGED');
      }
      final uri = Uri.parse('$baseUrl$path');
      final req = ScopeGuardedRequest(method, uri,
          isCurrent: current ?? () => true,
          abortTrigger: abort.future,
          isAborted: () => abort.isCompleted);
      req.headers['Accept'] = 'application/json';
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      if (version != null) req.headers['If-Match'] = '"$version"';
      if (key != null) req.headers['Idempotency-Key'] = key;
      if (clientRequestId != null) {
        req.headers['Client-Request-Id'] = clientRequestId;
      }
      if (key != null) _pendingWrites[key] = signature;
      final response = await (() async {
        final authenticated = await client();
        _ensureCurrent(current);
        // Authentication may finish after the caller has already timed out.
        // Never dispatch a new write after that deadline.
        if (abort.isCompleted) {
          throw TimeoutException('Request deadline elapsed');
        }
        final streamed = await authenticated.send(req);
        if (abort.isCompleted) {
          _discardResponse(streamed);
          throw TimeoutException('Request deadline elapsed');
        }
        try {
          _ensureCurrent(current);
        } catch (_) {
          _discardResponse(streamed);
          rethrow;
        }
        final value = await http.Response.fromStream(streamed);
        _ensureCurrent(current);
        return value;
      })()
          .timeout(const Duration(seconds: 25), onTimeout: () {
        // package:http aborts only this request, including a streaming body;
        // the authenticated client remains owned by the session.
        abortRequest();
        throw TimeoutException('Request deadline elapsed');
      });
      dynamic decoded;
      if (response.bodyBytes.isNotEmpty) {
        try {
          decoded = jsonDecode(utf8.decode(response.bodyBytes));
        } on FormatException {
          if (response.statusCode < 400) {
            throw const ApiFailure(502, 'INVALID_RESPONSE');
          }
        }
      }
      if (key != null && response.statusCode < 500) _pendingWrites.remove(key);
      if (response.statusCode >= 400) {
        final errorCode = decoded is Map ? decoded['errorCode'] : null;
        final correlationId = decoded is Map ? decoded['correlationId'] : null;
        throw ApiFailure(
            response.statusCode,
            errorCode is String ? errorCode : 'REQUEST_FAILED',
            correlationId is String ? correlationId : null);
      }
      return decoded;
    } on ApiFailure {
      rethrow;
    } on ScopeChangedException {
      abortRequest();
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    } on TimeoutException {
      _ensureCurrent(current);
      throw const ApiFailure(0, 'NETWORK_ERROR');
    } on http.ClientException {
      _ensureCurrent(current);
      throw const ApiFailure(0, 'NETWORK_ERROR');
    }
  }

  // Custom transports may deliver late headers without honoring Abortable.
  // Discard their body without awaiting cleanup or closing the shared client.
  void _discardResponse(http.StreamedResponse response) {
    unawaited(Future<void>.sync(() async {
      try {
        await response.stream
            .listen(null, onError: (Object _, StackTrace __) {})
            .cancel();
      } catch (_) {
        // Cleanup must not replace the deadline/scope error.
      }
    }));
  }

  Future<PageResult> page(String path,
      {String? cursor, bool Function()? isCurrent}) async {
    final current = _withScope(isCurrent);
    _ensureCurrent(current);
    final separator = path.contains('?') ? '&' : '?';
    final result = await send('GET',
        '$path${separator}limit=50${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}',
        isCurrent: current);
    _ensureCurrent(current);
    if (result is! Map || result['items'] is! List) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    final nextCursor = result['nextCursor'];
    if (nextCursor != null &&
        (nextCursor is! String || nextCursor.isEmpty || nextCursor == cursor)) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    final items = <Json>[];
    for (final item in result['items'] as List) {
      if (item is! Map || item.keys.any((key) => key is! String)) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      items.add(Map<String, dynamic>.from(item));
    }
    return PageResult(items, nextCursor as String?);
  }

  Future<List<Json>> all(String path, {bool Function()? isCurrent}) async {
    final current = _withScope(isCurrent);
    final items = <Json>[];
    String? cursor;
    final seen = <String>{};
    do {
      _ensureCurrent(current);
      final next = await page(path, cursor: cursor, isCurrent: current);
      _ensureCurrent(current);
      items.addAll(next.items);
      cursor = next.nextCursor;
      if (cursor != null && !seen.add(cursor)) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      if (items.length > 10000) throw const ApiFailure(400, 'TOO_MANY_RESULTS');
    } while (cursor != null);
    _ensureCurrent(current);
    return items;
  }
}
