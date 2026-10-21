import 'parent_api.dart';
import 'family_device_access.dart';

Never _invalid() => throw const ParentApiException(502, 'INVALID_RESPONSE');
String _text(dynamic value) =>
    value is String && value.isNotEmpty ? value : _invalid();
int _number(dynamic value, {int min = 0, int? max}) =>
    value is int && value >= min && (max == null || value <= max)
        ? value
        : _invalid();
Json _object(dynamic value) => value is Json ? value : _invalid();
List<dynamic> _list(dynamic value) => value is List ? value : _invalid();

class FamilyWindow {
  final List<int> days;
  final int startMinute, endMinute;
  FamilyWindow(this.days, this.startMinute, this.endMinute);
  factory FamilyWindow.fromJson(dynamic value) {
    final map = _object(value);
    final days = _list(map['daysOfWeek'])
        .map((d) => _number(d, min: 1, max: 7))
        .toList();
    final start = _number(map['startMinute'], max: 1439),
        end = _number(map['endMinute'], max: 1439);
    if (days.isEmpty || days.toSet().length != days.length || start == end) {
      _invalid();
    }
    return FamilyWindow(List.unmodifiable(days), start, end);
  }
  Json toJson() =>
      {'daysOfWeek': days, 'startMinute': startMinute, 'endMinute': endMinute};
}

class FamilyRules {
  final String subjectId, timeZoneId, deliveryState;
  final int version, dailyAllowanceSeconds;
  final bool enabled;
  final List<String> meteredPackages;
  final List<FamilyWindow> allowedWindows;
  FamilyRules(
      {required this.subjectId,
      required this.version,
      required this.enabled,
      required this.dailyAllowanceSeconds,
      required this.timeZoneId,
      required this.meteredPackages,
      required this.allowedWindows,
      required this.deliveryState});
  factory FamilyRules.fromJson(Json map) {
    if (map['enabled'] is! bool || map['timeZoneId'] != 'Asia/Shanghai') {
      _invalid();
    }
    final packages = _list(map['meteredPackages']).map(_text).toList();
    final windows =
        _list(map['allowedWindows']).map(FamilyWindow.fromJson).toList();
    if (packages.length > 100 ||
        packages.toSet().length != packages.length ||
        windows.length > 14) _invalid();
    return FamilyRules(
        subjectId: _text(map['subjectId']),
        version: _number(map['version']),
        enabled: map['enabled'],
        dailyAllowanceSeconds:
            _number(map['dailyAllowanceSeconds'], max: 86400),
        timeZoneId: map['timeZoneId'],
        meteredPackages: List.unmodifiable(packages),
        allowedWindows: List.unmodifiable(windows),
        deliveryState: _text(map['deliveryState']));
  }
  Json toBody() => {
        'enabled': enabled,
        'dailyAllowanceSeconds': dailyAllowanceSeconds,
        'timeZoneId': timeZoneId,
        'meteredPackages': meteredPackages,
        'allowedWindows': allowedWindows.map((w) => w.toJson()).toList()
      };
}

class FamilyDevice {
  final String id, displayName, registrationId, ruleState;
  final dynamic lastHeartbeatAt;
  final Json? runtime;
  FamilyDevice.fromJson(Json map)
      : id = _text(map['id']),
        displayName = _text(map['displayName']),
        registrationId = _text(map['registrationId']),
        ruleState = _text(map['ruleState']),
        lastHeartbeatAt = map['lastHeartbeatAt'],
        runtime = map['runtime'] == null ? null : _object(map['runtime']);
  // A runtime heartbeat describes assistance health, never proves observed use.
  int? get observedSeconds => runtime?['observedUsageSeconds'] is int &&
          runtime!['observedUsageSeconds'] >= 0
      ? runtime!['observedUsageSeconds'] as int
      : null;
}

class FamilyChild {
  final String id, nickname, ageBand;
  final List<FamilyDevice> devices;
  final FamilyRules? rules;
  FamilyChild.fromJson(Json map)
      : id = _text(map['id']),
        nickname = _text(map['nickname']),
        ageBand = _text(map['ageBand']),
        devices = List.unmodifiable(_list(map['devices'])
            .map((d) => FamilyDevice.fromJson(_object(d)))),
        rules = map['rules'] == null
            ? null
            : FamilyRules.fromJson(_object(map['rules'])) {
    if (rules != null && rules!.subjectId != id) _invalid();
  }
}

class FamilyDashboard {
  final String tenantId;
  final dynamic generatedAt;
  final List<FamilyChild> children;
  final int pendingRequestCount, openHelpRequestCount;
  final FamilyDeviceAccessSnapshot? deviceAccess;
  FamilyDashboard.fromJson(Json map)
      : tenantId = _text(map['tenantId']),
        generatedAt = map['generatedAt'],
        children = List.unmodifiable(_list(map['children'])
            .map((c) => FamilyChild.fromJson(_object(c)))),
        pendingRequestCount = _number(map['pendingRequestCount']),
        openHelpRequestCount = _number(map['openHelpRequestCount']),
        deviceAccess = map['deviceAccess'] == null
            ? null
            : FamilyDeviceAccessSnapshot.fromJson(
                _object(map['deviceAccess'])) {
    if (map['systemEnforced'] != false ||
        generatedAt == null ||
        children.map((c) => c.id).toSet().length != children.length ||
        deviceAccess != null && deviceAccess!.tenantId != tenantId) _invalid();
  }
}

/// Every call is tied to the original adult, role and family by the caller.
class FamilyService {
  final ParentApi api;
  final String tenantId;
  final bool Function() available;
  FamilyService(
      {required this.api, required this.tenantId, required this.available});
  String get root => '/tenants/${Uri.encodeComponent(tenantId)}';
  void check() {
    if (!available()) throw const ParentApiException(409, 'SCOPE_DENIED');
  }

  Future<Json> object(String path) async {
    check();
    final value = await api.object('$root$path', isCurrent: available);
    check();
    return value;
  }

  Future<Json> write(String method, String path,
      {required Json body, int? version, String? idempotencyKey}) async {
    check();
    final result = await api.send(method, '$root$path',
        body: body,
        version: version,
        idempotencyKey: idempotencyKey,
        isCurrent: available);
    check();
    return _object(result);
  }

  Future<FamilyDashboard> dashboard() async {
    final result = FamilyDashboard.fromJson(await object('/family-dashboard'));
    if (result.tenantId != tenantId) _invalid();
    return result;
  }

  Future<FamilyRules> rules(String subjectId) async {
    final result = FamilyRules.fromJson(await object(
        '/subjects/${Uri.encodeComponent(subjectId)}/family-rules'));
    if (result.subjectId != subjectId) _invalid();
    return result;
  }

  Future<FamilyRules> saveRules(String subjectId, FamilyRules rules,
      {required String idempotencyKey}) async {
    if (rules.subjectId != subjectId || idempotencyKey.isEmpty) _invalid();
    final result = FamilyRules.fromJson(await write(
        'PUT', '/subjects/${Uri.encodeComponent(subjectId)}/family-rules',
        body: rules.toBody(),
        version: rules.version,
        idempotencyKey: idempotencyKey));
    if (result.subjectId != subjectId || result.version != rules.version + 1) {
      _invalid();
    }
    return result;
  }

  Future<Json> suggest(
      {required String task,
      required String subjectId,
      required String prompt,
      required String idempotencyKey,
      required bool cloudConsent,
      String? deviceId}) async {
    if (!cloudConsent) {
      throw const ParentApiException(400, 'AI_CONSENT_REQUIRED');
    }
    if (!const {'RULE_DRAFT', 'REPORT_EXPLANATION'}.contains(task) ||
        prompt.trim().isEmpty) _invalid();
    if (idempotencyKey.isEmpty) _invalid();
    final result = await write('POST', '/assistant/suggestions',
        idempotencyKey: idempotencyKey,
        body: {
          'task': task,
          'subjectId': subjectId,
          'prompt': prompt.trim(),
          'cloudConsent': true,
          if (deviceId != null) 'deviceId': deviceId
        });
    if (result['id'] is! String ||
        result['task'] != task ||
        !const {'READY', 'FALLBACK'}.contains(result['status']) ||
        result['summary'] is! String ||
        result['limitations'] is! List ||
        result['evidence'] is! List) _invalid();
    return result;
  }
}

String familyError(Object error) {
  if (error is ParentApiException) {
    final message = switch (error.code) {
      'ENTITLEMENT_REQUIRED' => '当前家庭权益不支持此操作。请在“我的”核对试用或会员状态。',
      'FAMILY_OFFER_CHANGED' => '方案报价已变化，请重新读取会员方案后核对；不会按新价格自动下单。',
      'VERIFIED_PHONE_REQUIRED' => '请先通过手机号登录完成服务端验证，再核对激活和试用资格。',
      'WECHAT_NOT_INSTALLED' => '此设备尚未安装微信，请安装后返回原订单重试。未确认支付成功。',
      'WECHAT_PAY_NOT_CONFIGURED' => '当前应用尚未配置已审核的微信 AppID，无法调起支付。',
      'WECHAT_PAY_VERSION_UNSUPPORTED' => '微信版本不支持当前支付，请更新微信后核对原订单。',
      'WECHAT_PAY_PLATFORM_UNAVAILABLE' => '微信支付调用仅在已配置的 Android 客户端提供。',
      'INVALID_PAYMENT_PARAMETERS' => '支付参数未通过校验，已停止调用微信。请核对原订单。',
      'WECHAT_PAY_DISPATCH_FAILED' ||
      'WECHAT_PAY_REGISTRATION_FAILED' =>
        '未能打开微信支付，请核对微信安装、应用配置和原订单状态。',
      'PAYMENT_RECOVERY_UNAVAILABLE' ||
      'INVALID_PAYMENT_RECOVERY' =>
        '无法确认原支付进度，已停止创建新操作。请稍后重试。',
      'PAYMENT_PROVIDER_UNAVAILABLE' ||
      'PAYMENT_NOT_CONFIGURED' =>
        '微信支付尚未开放，请稍后再查看。未产生成功支付。',
      'AI_PROVIDER_UNAVAILABLE' => '云端助手暂不可用，请稍后重试或手动设置。',
      'AI_CONSENT_REQUIRED' => '请先确认本次云端处理授权。',
      'AI_QUOTA_EXCEEDED' || 'AI_QUOTA_EXHAUSTED' => '本期助手次数已用完。仍可手动设置规则和查看报告。',
      'REAUTH_REQUIRED' => '此操作需要近期手机号安全验证，请验证后重新打开原订单。',
      'REFUND_REVIEW_REQUIRED' => '退款申请已保留，正在等待人工审核。审核通过后才能发起原路退款。',
      'ASSISTANT_DEVICE_REQUIRED' => '请先选择要解释报告的设备。多台设备分别查看。',
      'UNSAFE_FAMILY_APPLICATION' => '所选应用包含系统安全或紧急联系应用，请重新选择。',
      'FAMILY_APPLICATION_REQUIRED' => '请先选择至少一个需要辅助限制的应用。',
      'INVALID_FAMILY_WINDOW' => '请核对可用时段；开始和结束时间不能相同。',
      'INVALID_FAMILY_RULES' => '规则内容未通过校验，请核对用时、应用和时段。',
      _ => error.message,
    };
    return error.correlationId == null
        ? message
        : '$message\n问题编号：${error.correlationId}';
  }
  return '$error';
}

String familyDate(dynamic value) {
  final time = value is int
      ? DateTime.fromMillisecondsSinceEpoch(value).toLocal()
      : value is String
          ? DateTime.tryParse(value)?.toLocal()
          : null;
  return time == null
      ? '待核对'
      : '${time.year}/${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}
