import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'api.dart';
import 'finance_storage_port.dart';
import 'family_finance_storage_stub.dart'
    if (dart.library.html) 'family_finance_storage_web.dart';

const familyRefundRoot = '/platform/family-subscription/refund-requests';
const familyBillRoot = '/platform/family-subscription/reconciliation/tasks';
const familyRefundStatuses = {
  'AWAITING_REVIEW',
  'REQUESTED',
  'DECLINED',
  'PROCESSING',
  'REFUNDED',
  'CLOSED',
  'ABNORMAL'
};
const familyBillStatuses = {
  'PENDING',
  'RUNNING',
  'MATCHED',
  'DIFFERENCES',
  'PARTIAL',
  'UNAVAILABLE',
  'FAILED',
  'ATTENTION',
  'INVALID_BILL'
};
final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _hash = RegExp(r'^[0-9a-f]{64}$');
Never _invalid() => throw const ApiFailure(502, 'INVALID_RESPONSE');
bool _id(dynamic value) => value is String && _uuid.hasMatch(value);
bool _nonNegative(dynamic value) => value is int && value >= 0;
bool _text(dynamic value, {int max = 200}) =>
    value is String &&
    value.trim().isNotEmpty &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(value);
bool validFinanceDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final date = DateTime.tryParse(value);
  return date != null && date.toIso8601String().substring(0, 10) == value;
}

Json _map(dynamic value) => value is Json ? value : _invalid();
Json validateFinanceRefund(dynamic raw) {
  final value = _map(raw);
  if (!_id(value['id']) ||
      !_id(value['tenantId']) ||
      !_id(value['orderId']) ||
      !familyRefundStatuses.contains(value['status']) ||
      value['reason'] is! String ||
      value['priceMinor'] is! int ||
      value['priceMinor'] <= 0 ||
      value['currency'] != 'CNY' ||
      !_nonNegative(value['createdAt']) ||
      value['canReview'] is! bool ||
      (value['reviewNote'] != null && value['reviewNote'] is! String)) {
    _invalid();
  }
  return value;
}

Json validateFinanceTask(dynamic raw) {
  final value = _map(raw);
  if (!_id(value['id']) ||
      value['billDate'] is! String ||
      !validFinanceDate(value['billDate']) ||
      !familyBillStatuses.contains(value['status']) ||
      [
        'attemptCount',
        'rowCount',
        'matchedCount',
        'ignoredCount',
        'differenceCount',
        'createdAt',
        'updatedAt'
      ].any((key) => !_nonNegative(value[key]))) _invalid();
  if (value['status'] == 'MATCHED' && value['differenceCount'] != 0) _invalid();
  return value;
}

Json validateFinanceDifference(dynamic raw) {
  final value = _map(raw);
  if (!_id(value['id']) ||
      !_text(value['kind'], max: 100) ||
      !const {'OPEN', 'ACKNOWLEDGED'}.contains(value['state']) ||
      !_nonNegative(value['createdAt']) ||
      ['tenantId', 'orderId', 'refundId']
          .any((key) => value[key] != null && !_id(value[key])) ||
      ['expectedMinor', 'actualMinor']
          .any((key) => value[key] != null && !_nonNegative(value[key]))) {
    _invalid();
  }
  return value;
}

class FamilyFinanceRepository {
  final Api api;
  final bool Function() available;
  FamilyFinanceRepository({required this.api, required this.available});
  void _check() {
    if (!available()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<PageResult> _page(String path, Json Function(dynamic) parse,
      {String? cursor}) async {
    _check();
    final result = await api.page(path, cursor: cursor, isCurrent: available);
    _check();
    if (result.items.length > 50 ||
        result.nextCursor != null &&
            (result.nextCursor!.isEmpty || result.nextCursor!.length > 2048)) {
      _invalid();
    }
    return PageResult(result.items.map(parse).toList(), result.nextCursor);
  }

  Future<PageResult> refunds(
      {String status = 'AWAITING_REVIEW', String? orderId, String? cursor}) {
    if (!familyRefundStatuses.contains(status) ||
        orderId != null && !_id(orderId)) _invalid();
    return _page(
        '$familyRefundRoot?status=$status${orderId == null ? '' : '&orderId=${Uri.encodeQueryComponent(orderId)}'}',
        validateFinanceRefund,
        cursor: cursor);
  }

  Future<Json> refund(String id) async {
    if (!_id(id)) _invalid();
    _check();
    final value = validateFinanceRefund(
        await api.send('GET', '$familyRefundRoot/$id', isCurrent: available));
    _check();
    if (value['id'] != id) _invalid();
    return value;
  }

  Future<Json> preview(String id) async {
    if (!_id(id)) _invalid();
    _check();
    final value = _map(await api.send('GET', '$familyRefundRoot/$id/preview',
        isCurrent: available));
    _check();
    final order = _map(value['order']);
    final preserved = value['preservedOrders'];
    if (value['id'] != id ||
        value['status'] != 'AWAITING_REVIEW' ||
        value['reason'] is! String ||
        !_id(order['id']) ||
        order['price_minor'] is! int ||
        order['price_minor'] <= 0 ||
        order['currency'] != 'CNY' ||
        order['status'] != 'PAID' ||
        !_nonNegative(order['period_start']) ||
        !_nonNegative(order['period_end']) ||
        order['period_end'] <= order['period_start'] ||
        preserved is! List ||
        preserved.length > 100 ||
        value['consequence'] is! String ||
        value['previewHash'] is! String ||
        !_hash.hasMatch(value['previewHash'])) _invalid();
    for (final row in preserved) {
      final map = _map(row);
      if (!_id(map['id']) ||
          map['id'] == order['id'] ||
          map['status'] is! String ||
          !_nonNegative(map['period_start']) ||
          !_nonNegative(map['period_end'])) _invalid();
    }
    return value;
  }

  Future<PageResult> tasks({String? cursor}) =>
      _page(familyBillRoot, validateFinanceTask, cursor: cursor);
  Future<Json> task(String id) async {
    if (!_id(id)) _invalid();
    _check();
    final value = validateFinanceTask(
        await api.send('GET', '$familyBillRoot/$id', isCurrent: available));
    _check();
    if (value['id'] != id) _invalid();
    return value;
  }

  Future<PageResult> differences(String taskId, {String? cursor}) {
    if (!_id(taskId)) _invalid();
    return _page(
        '$familyBillRoot/$taskId/differences', validateFinanceDifference,
        cursor: cursor);
  }
}

/// One non-secret, actor-bound, explicit operation per browser tab. Original
/// paths, keys and bodies survive uncertain responses and OIDC step-up.
class FamilyFinanceOperations {
  final Api api;
  final String actor;
  final bool Function() available, canReviewRefunds, canManageFinance;
  final FinanceStringStorage storage;
  static final _tails = <String, Future<void>>{};
  Json? _pending;
  Json? get pending =>
      _pending == null ? null : Map<String, dynamic>.unmodifiable(_pending!);
  bool loaded = false, busy = false;
  FamilyFinanceOperations(
      {required this.api,
      required this.actor,
      required this.available,
      bool Function()? canReviewRefunds,
      bool Function()? canManageFinance,
      FinanceStringStorage? storage})
      : canReviewRefunds = canReviewRefunds ?? (() => true),
        canManageFinance = canManageFinance ?? (() => true),
        storage = storage ?? createFinanceStorage();
  String get actorHash => sha256.convert(utf8.encode(actor)).toString();
  String get storageKey => 'ai-manager.family-finance.pending.v1.$actorHash';
  void _check() {
    if (!available()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<T> _locked<T>(Future<T> Function() action) async {
    final before = _tails[storageKey], done = Completer<void>();
    _tails[storageKey] = done.future;
    try {
      if (before != null) await before;
      return await action();
    } finally {
      done.complete();
      if (identical(_tails[storageKey], done.future)) _tails.remove(storageKey);
    }
  }

  Json? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final value = raw.length <= 4096 ? jsonDecode(raw) : null;
      if (value is! Json ||
          value.keys.toSet().difference(
              {'schema', 'actorHash', 'key', 'path', 'body'}).isNotEmpty ||
          value.length != 5 ||
          value['schema'] != 1 ||
          value['actorHash'] != actorHash ||
          !_id(value['key']) ||
          value['path'] is! String ||
          value['body'] is! Json) _invalid();
      _validateOperation(value['path'], value['body']);
      return value;
    } catch (_) {
      throw const ApiFailure(409, 'FINANCE_RECOVERY_INVALID');
    }
  }

  String _validateOperation(String path, Json body) {
    final refund =
        RegExp('^$familyRefundRoot/([0-9a-f-]{36})/(reviews|verifications)\$')
            .firstMatch(path);
    if (refund != null && _id(refund.group(1))) {
      if (refund.group(2) == 'verifications' && body.isEmpty) return 'REFUND';
      if (refund.group(2) == 'reviews' &&
          body.length == 3 &&
          const {'APPROVE', 'DENY'}.contains(body['decision']) &&
          body['previewHash'] is String &&
          _hash.hasMatch(body['previewHash']) &&
          _text(body['note'])) return 'REFUND';
      _invalid();
    }
    if (path == familyBillRoot &&
        body.length == 1 &&
        body['billDate'] is String &&
        validFinanceDate(body['billDate'])) return 'FINANCE';
    final task =
        RegExp('^$familyBillRoot/([0-9a-f-]{36})/retries\$').firstMatch(path);
    if (task != null && _id(task.group(1)) && body.isEmpty) return 'FINANCE';
    final diff = RegExp(
            '^$familyBillRoot/([0-9a-f-]{36})/differences/([0-9a-f-]{36})/(acknowledgements|verifications)\$')
        .firstMatch(path);
    if (diff != null &&
        _id(diff.group(1)) &&
        _id(diff.group(2)) &&
        ((diff.group(3) == 'verifications' && body.isEmpty) ||
            (diff.group(3) == 'acknowledgements' &&
                body.length == 1 &&
                _text(body['note'])))) return 'FINANCE';
    _invalid();
  }

  void _authorize(String path, Json body) {
    _check();
    final kind = _validateOperation(path, body);
    if (kind == 'REFUND' && !canReviewRefunds() ||
        kind == 'FINANCE' && !canManageFinance()) {
      throw const ApiFailure(403, 'SCOPE_DENIED');
    }
  }

  Future<void> restore() async {
    if (busy) return;
    busy = true;
    loaded = false;
    try {
      await _locked(() async {
        _check();
        try {
          _pending = _decode(storage.read(storageKey));
        } on ApiFailure {
          rethrow;
        } catch (_) {
          throw const ApiFailure(409, 'FINANCE_RECOVERY_UNAVAILABLE');
        }
        _check();
        loaded = true;
      });
    } finally {
      busy = false;
    }
  }

  Future<Json> _start(String path, Json body) async {
    _authorize(path, body);
    if (!loaded || busy || _pending != null) {
      throw const ApiFailure(409, 'FINANCE_RECOVERY_PENDING');
    }
    busy = true;
    try {
      return await _locked(() async {
        _authorize(path, body);
        try {
          if (storage.read(storageKey) != null) {
            loaded = false;
            throw const ApiFailure(409, 'FINANCE_RECOVERY_PENDING');
          }
          final value = <String, dynamic>{
            'schema': 1,
            'actorHash': actorHash,
            'key': const Uuid().v4(),
            'path': path,
            'body': body
          };
          loaded = false;
          storage.write(storageKey, jsonEncode(value));
          _pending = value;
          loaded = true;
        } on ApiFailure {
          rethrow;
        } catch (_) {
          throw const ApiFailure(409, 'FINANCE_RECOVERY_UNAVAILABLE');
        }
        return _send();
      });
    } finally {
      busy = false;
    }
  }

  Future<Json> review(String id,
          {required String decision,
          required String previewHash,
          required String note}) =>
      _start('$familyRefundRoot/$id/reviews', {
        'decision': decision,
        'previewHash': previewHash,
        'note': note.trim()
      });
  Future<Json> verifyRefund(String id) =>
      _start('$familyRefundRoot/$id/verifications', {});
  Future<Json> requestBill(String billDate) =>
      _start(familyBillRoot, {'billDate': billDate});
  Future<Json> retryBill(String id) =>
      _start('$familyBillRoot/$id/retries', {});
  Future<Json> acknowledge(String task, String diff, String note) => _start(
      '$familyBillRoot/$task/differences/$diff/acknowledgements',
      {'note': note.trim()});
  Future<Json> verifyDifference(String task, String diff) =>
      _start('$familyBillRoot/$task/differences/$diff/verifications', {});
  Future<Json> retry() async {
    _check();
    if (!loaded || busy || _pending == null) {
      throw const ApiFailure(409, 'FINANCE_RECOVERY_PENDING');
    }
    busy = true;
    try {
      return await _locked(() async {
        _check();
        final current = _decode(storage.read(storageKey));
        if (current == null || jsonEncode(current) != jsonEncode(_pending)) {
          loaded = false;
          throw const ApiFailure(409, 'FINANCE_RECOVERY_PENDING');
        }
        return _send();
      });
    } finally {
      busy = false;
    }
  }

  Future<Json> _send() async {
    final original = _pending!,
        path = original['path'] as String,
        body = original['body'] as Json;
    _authorize(path, body);
    try {
      final value = _map(await api.send('POST', path,
          body: body,
          key: original['key'],
          isCurrent: () =>
              available() &&
              (_validateOperation(path, body) == 'REFUND'
                  ? canReviewRefunds()
                  : canManageFinance())));
      _authorize(path, body);
      if (path.endsWith('/reviews')) {
        final target = path.split('/')[4];
        if (value['id'] != target ||
            value['status'] !=
                (body['decision'] == 'APPROVE' ? 'REQUESTED' : 'DECLINED') ||
            value['externalRefundSubmitted'] != false) _invalid();
      } else if (path == familyBillRoot || path.endsWith('/retries')) {
        validateFinanceTask(value);
        if (path == familyBillRoot && value['billDate'] != body['billDate']) {
          _invalid();
        }
        if (path != familyBillRoot && value['id'] != path.split('/')[5]) {
          _invalid();
        }
      } else if (path.endsWith('/acknowledgements')) {
        validateFinanceDifference(value);
        if (value['id'] != path.split('/')[7] ||
            value['state'] != 'ACKNOWLEDGED') _invalid();
      } else if (path.endsWith('/verifications')) {
        if (value['queued'] != true || !_id(value['resourceId'])) _invalid();
        if (path.startsWith('$familyRefundRoot/') &&
            value['resourceId'] != path.split('/')[4]) _invalid();
      }
      storage.remove(storageKey);
      _pending = null;
      return value;
    } on ApiFailure catch (error) {
      if (error.status == 409 &&
          ((path.endsWith('/retries') &&
                  error.code == 'FAMILY_BILL_ATTEMPTS_EXHAUSTED') ||
              (path.endsWith('/acknowledgements') &&
                  error.code == 'FAMILY_BILL_ACKNOWLEDGEMENT_IMMUTABLE'))) {
        storage.remove(storageKey);
        _pending = null;
      }
      if (error.status == 400 &&
          error.code == 'FAMILY_BILL_DATE_UNAVAILABLE' &&
          (path == familyBillRoot || path.endsWith('/retries'))) {
        storage.remove(storageKey);
        _pending = null;
      }
      if (error.status == 409 &&
          const {
            'PREVIEW_STALE',
            'REFUND_PREVIEW_STALE',
            'REFUND_PREVIEW_CHANGED',
            'REFUND_REVIEW_NOT_PENDING'
          }.contains(error.code)) {
        storage.remove(storageKey);
        _pending = null;
      }
      rethrow;
    } catch (_) {
      throw const ApiFailure(409, 'FINANCE_RECOVERY_UNAVAILABLE');
    }
  }
}
