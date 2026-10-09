import 'package:device_access/device_access.dart';
import 'package:flutter/material.dart';

String submissionState(AccessSubmission value) => switch (value.state) {
      'PENDING' => '等待监护人审批',
      'APPROVED_PENDING_DELIVERY' => '已批准，等待配置同步',
      'DENIED' => '未获批准',
      'CANCELLED' => '已取消',
      'EXPIRED' => '已到期',
      'REVOKED' => '已撤回',
      _ => '已失效'
    };

String submissionTime(BuildContext context, int millis) {
  try {
    final date = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    final local = MaterialLocalizations.of(context);
    return '${local.formatFullDate(date)} ${local.formatTimeOfDay(TimeOfDay.fromDateTime(date), alwaysUse24HourFormat: true)}';
  } catch (_) {
    return '时间暂不可用';
  }
}

String submissionDuration(int seconds) =>
    seconds % 60 == 0 ? '${seconds ~/ 60} 分钟' : '$seconds 秒';

String submissionError(String? code) => switch (code) {
      'NETWORK_TIMEOUT' ||
      'CONNECTION_FAILED' ||
      'NETWORK_UNAVAILABLE' =>
        '暂时无法连接。已保存的原操作会保留，请检查网络后按原操作确认结果。',
      'ACCESS_RECOVERY_UNAVAILABLE' =>
        '暂时找不到原操作的恢复记录，结果仍待确认。请联系监护人；不要重新申请或清空记录。',
      'IDEMPOTENCY_KEY_CONFLICT' ||
      'REQUEST_IN_PROGRESS' =>
        '原操作尚未核对完成，请保留记录并联系监护人。',
      'DEVICE_UNAUTHENTICATED' ||
      'SCOPE_DENIED' ||
      'ACCESS_TARGET_CHANGED' ||
      'DEVICE_CREDENTIAL_UNAVAILABLE' ||
      'CREDENTIAL_READ_FAILED' =>
        '设备身份或授权需要重新确认，旧资料已停止展示。请先检查设备连接或联系监护人。',
      'SUBMISSION_RESTORE_FAILED' ||
      'SUBMISSION_STORAGE_FAILED' ||
      'ACCESS_KEY_UNAVAILABLE' ||
      'ACCESS_STORAGE_FAILED' ||
      'SUBMISSION_CONTEXT_INVALID' =>
        '申请记录暂时无法安全读取。请联系监护人，不要卸载应用或清空数据。',
      'BASELINE_CHANGED' ||
      'EXCEPTION_RULE_INVALID' =>
        '原规则已变化。请放弃已明确拒绝的本次操作，刷新后重新选择申请内容。',
      'ACCESS_REQUEST_COOLDOWN' => '申请过于频繁，请稍后再试。',
      'ACCESS_REQUEST_PENDING' => '已有待审批申请，请先查看并处理原申请。',
      'ACCESS_EXCEPTION_EXISTS' => '已有仍有效的批准安排，请先查看原安排。',
      'RESOURCE_VERSION_CONFLICT' ||
      'ACCESS_REQUEST_NOT_PENDING' =>
        '申请状态已变化，请刷新详情后再决定下一步。',
      'SAFETY_BASELINE_PROTECTED' ||
      'EXCEPTION_KIND_UNSUPPORTED' =>
        '这项限制不支持临时申请，请联系监护人。',
      'SUBMISSION_PAGE_LIMIT' => '本次查找已达到设备显示容量，请监护人缩小适用范围后刷新。原申请会保留。',
      'CLOCK_UNTRUSTED' => '设备时间无法确认，请监护人检查时间后再核对申请。',
      _ => '本次操作未完成，原记录会保留。请重试或联系监护人。'
    };
