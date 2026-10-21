import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'family.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';

const familyRefundStates = {
  'AWAITING_REVIEW',
  'REQUESTED',
  'DECLINED',
  'PROCESSING',
  'REFUNDED',
  'CLOSED',
  'ABNORMAL',
};

Json validateFamilyRefund(dynamic value, String orderId) {
  if (value is! Json ||
      value['id'] is! String ||
      (value['id'] as String).isEmpty ||
      value['orderId'] != orderId ||
      !familyRefundStates.contains(value['status']) ||
      value['priceMinor'] is! int ||
      value['priceMinor'] <= 0 ||
      value['currency'] != 'CNY' ||
      value['reason'] is! String ||
      value['createdAt'] is! int) {
    throw const ParentApiException(502, 'INVALID_RESPONSE');
  }
  return Map<String, dynamic>.unmodifiable(value);
}

/// Only an explicit confirmation sends the encrypted original operation.
/// Reading a journal never retries a refund or invents a new request.
class FamilyRefundCoordinator {
  final FamilyService service;
  final String actor, orderId;
  final ParentDurableStorage storage;
  static final _tails = <String, Future<void>>{};
  Json? _pending;
  bool loaded = false, busy = false;

  FamilyRefundCoordinator(
      {required this.service,
      required this.actor,
      required this.orderId,
      ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();

  String get key => 'parent.family.refund.${service.tenantId}.$actor.$orderId';
  String? get pendingReason => _pending?['reason'];
  bool get hasPending => _pending != null;

  Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _tails[key];
    final done = Completer<void>();
    _tails[key] = done.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      done.complete();
      if (identical(_tails[key], done.future)) _tails.remove(key);
    }
  }

  Json? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final value = raw.length <= 4096 ? jsonDecode(raw) : null;
      if (value is! Json ||
          value['schema'] != 1 ||
          value['orderId'] != orderId ||
          value['key'] is! String ||
          !Uuid.isValidUUID(fromString: value['key']) ||
          value['reason'] is! String ||
          (value['priceMinor'] != null &&
              (value['priceMinor'] is! int || value['priceMinor'] <= 0)) ||
          !_validReason(value['reason'])) {
        throw const FormatException();
      }
      return value;
    } catch (_) {
      throw const ParentApiException(502, 'INVALID_PAYMENT_RECOVERY');
    }
  }

  static bool _validReason(String value) =>
      value.trim() == value &&
      value.isNotEmpty &&
      value.length <= 200 &&
      !RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(value);

  Future<void> restore() async {
    if (busy) return;
    busy = true;
    loaded = false;
    try {
      await _locked(() async {
        service.check();
        final value = _decode(await storage.read(key: key));
        service.check();
        _pending = value;
        loaded = true;
      });
    } finally {
      busy = false;
    }
  }

  Future<Json> request(String reason, {int? priceMinor}) async {
    service.check();
    if (!loaded || busy || hasPending) throw StateError('请先核对原退款申请。');
    final normalized = reason.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (!_validReason(normalized)) throw StateError('请填写 1 至 200 字的退款原因。');
    if (priceMinor != null && priceMinor <= 0) throw StateError('请先核对订单金额。');
    busy = true;
    try {
      return await _locked(() async {
        service.check();
        if (await storage.read(key: key) != null) {
          loaded = false;
          throw StateError('另一页面已保存退款申请，请重新读取原申请。');
        }
        service.check();
        final draft = <String, dynamic>{
          'schema': 1,
          'orderId': orderId,
          'key': const Uuid().v4(),
          'reason': normalized,
          if (priceMinor != null) 'priceMinor': priceMinor,
        };
        // A failed flush may still have written the record. Never overwrite it.
        loaded = false;
        await storage.write(key: key, value: jsonEncode(draft));
        service.check();
        _pending = draft;
        loaded = true;
        return _send();
      });
    } finally {
      busy = false;
    }
  }

  Future<Json> retry() async {
    service.check();
    if (!loaded || busy || !hasPending) throw StateError('请先读取原退款申请。');
    busy = true;
    try {
      return await _locked(() async {
        service.check();
        final actual = _decode(await storage.read(key: key));
        service.check();
        if (actual == null || jsonEncode(actual) != jsonEncode(_pending)) {
          loaded = false;
          throw StateError('原申请进度已变化，请重新读取。');
        }
        return _send();
      });
    } finally {
      busy = false;
    }
  }

  Future<Json> _send() async {
    final value = validateFamilyRefund(
        await service.write(
            'POST', '/orders/${Uri.encodeComponent(orderId)}/refund-requests',
            body: {'reason': _pending!['reason']},
            idempotencyKey: _pending!['key']),
        orderId);
    if (value['reason'] != _pending!['reason'] ||
        (_pending!['priceMinor'] != null &&
            value['priceMinor'] != _pending!['priceMinor'])) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    // Authentication, scope, transport, in-progress and invalid responses all
    // retain the journal. Only the server's original successful result clears it.
    await storage.delete(key: key);
    service.check();
    _pending = null;
    return value;
  }
}
