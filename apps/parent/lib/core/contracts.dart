import 'dart:convert';
import 'package:commerce_contracts/commerce_contracts.dart';
import 'package:flutter/foundation.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';
export 'package:commerce_contracts/commerce_contracts.dart';

/// The same protocol is consumed by the web console; only transport adaptation is mobile-specific.
class ParentContractsRepository {
  final ParentApi api;
  final String tenant;
  final bool Function() current;
  const ParentContractsRepository(
      {required this.api, required this.tenant, required this.current});
  String get path => '/tenants/$tenant/contracts';
  T parse<T>(T Function() read) {
    try {
      return read();
    } on ContractProtocolException {
      throw const ParentApiException(502, 'INVALID_CONTRACT_RESPONSE');
    }
  }

  void ensure() {
    if (!current()) throw const ParentApiException(409, 'WORKSPACE_CHANGED');
  }

  Future<ContractReview> get(String id) async {
    ensure();
    if (!isContractId(id)) throw const FormatException('合同编号无效。');
    final raw = await api.send('GET', '$path/$id',
        isCurrent: current, maxResponseBytes: 16 * 1024);
    ensure();
    final result = parse(() => ContractReview.parse(raw, platform: false));
    if (result.id != id || result.tenantId != tenant) {
      throw const ParentApiException(502, 'INVALID_CONTRACT_RESPONSE');
    }
    return result;
  }

  Future<ContractComparison> comparison(ContractReview review) async {
    ensure();
    if (review.tenantId != tenant) {
      throw const ParentApiException(403, 'SCOPE_DENIED');
    }
    final raw = await api.send('GET', '$path/${review.id}/comparison',
        isCurrent: current, maxResponseBytes: 16 * 1024);
    ensure();
    final result = parse(() => ContractComparison.parse(raw));
    if (result.reviewId != review.id ||
        result.reviewVersion != review.version ||
        result.offerId != review.offerId ||
        result.contractOfferRevision != review.offerRevision) {
      throw const ParentApiException(502, 'INVALID_CONTRACT_RESPONSE');
    }
    return result;
  }

  Future<ContractHistoryPage> history(String id, {int? before}) async {
    ensure();
    if (!isContractId(id) || (before != null && before < 1)) {
      throw const FormatException('合同历史游标无效。');
    }
    final raw = await api.send('GET',
        '$path/$id/history?limit=50${before == null ? '' : '&beforeVersion=$before'}',
        isCurrent: current, maxResponseBytes: 128 * 1024);
    ensure();
    final result = parse(() => ContractHistoryPage.parse(raw, platform: false));
    if (before != null && result.items.any((e) => e.version >= before)) {
      throw const ParentApiException(502, 'INVALID_CONTRACT_RESPONSE');
    }
    return result;
  }

  Future<ContractReview> accept(String id, int version,
      {required bool Function() currentOperation}) async {
    ensure();
    if (!isContractId(id) || version < 1) {
      throw const FormatException('合同或版本无效。');
    }
    final raw = await api.send('POST', '$path/$id/accept',
        version: version,
        isCurrent: () => current() && currentOperation(),
        maxResponseBytes: 16 * 1024);
    ensure();
    final result = parse(() => ContractReview.parse(raw, platform: false));
    if (result.id != id ||
        result.tenantId != tenant ||
        result.version <= version ||
        result.state != 'APPLIED' ||
        result.sourceState != 'ACTIVE') {
      throw const ParentApiException(502, 'INVALID_CONTRACT_RESPONSE');
    }
    return result;
  }
}

class ContractAcceptanceStore {
  final ParentDurableStorage storage;
  ContractAcceptanceStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String key(String tenant, String actor) =>
      'parent.pending.contract.$tenant.$actor';
  void validate(Json row) {
    if (!setEquals(row.keys.toSet(), {'reviewId', 'version'}) ||
        row['reviewId'] is! String ||
        !isContractId(row['reviewId']) ||
        row['version'] is! int ||
        row['version'] < 1 ||
        row['version'] > 9007199254740991) {
      throw const FormatException('合同确认记录无效，请联系管理员。');
    }
  }

  Future<Json?> load(String tenant, String actor) async {
    final value = await storage.read(key: key(tenant, actor));
    if (value == null) return null;
    if (value.length > 1024) throw const FormatException('合同确认记录过大。');
    final row = jsonDecode(value);
    if (row is! Json) throw const FormatException('合同确认记录无效。');
    validate(row);
    return row;
  }

  Future<void> save(String tenant, String actor, Json row) async {
    validate(row);
    if (await load(tenant, actor) != null) throw StateError('请先核对上一次合同确认。');
    await storage.write(key: key(tenant, actor), value: jsonEncode(row));
  }

  Future<void> clear(String tenant, String actor, Json expected) async {
    final row = await load(tenant, actor);
    if (row != null && !mapEquals(row, expected)) {
      throw StateError('合同确认记录已变化。');
    }
    await storage.delete(key: key(tenant, actor));
  }
}

/// Existing acceptance uses a version precondition, not an idempotency receipt API.
/// Recovery reads current state only, never claims who accepted it or automatically retries.
class ContractAcceptance extends ChangeNotifier {
  final ParentContractsRepository repository;
  final ContractAcceptanceStore store;
  final String actor;
  final bool Function() isCurrent;
  bool busy = false, loaded = false, queried = false, _disposed = false;
  int _epoch = 0;
  Json? pending;
  ContractReview? latest;
  Object? error;
  ContractAcceptance(
      {required this.repository,
      required this.store,
      required this.actor,
      required this.isCurrent});
  bool get current => !_disposed && isCurrent();
  void suspend() {
    _epoch++;
  }

  void notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }

  Future<void> load() async {
    if (!current || busy) return;
    busy = true;
    loaded = false;
    error = null;
    notify();
    try {
      final row = await store.load(repository.tenant, actor);
      if (current) {
        pending = row;
        latest = null;
        queried = false;
        loaded = true;
      }
    } catch (e) {
      if (current) error = e;
    } finally {
      busy = false;
      notify();
    }
  }

  Future<void> submit(
      ContractReview review, ContractComparison comparison) async {
    if (!current || busy || !loaded || pending != null) return;
    busy = true;
    error = null;
    final epoch = _epoch;
    notify();
    try {
      if (review.tenantId != repository.tenant ||
          review.state != 'AWAITING_CUSTOMER' ||
          review.sourceState != 'ACTIVE' ||
          review.expiresAt <= DateTime.now().millisecondsSinceEpoch ||
          comparison.reviewId != review.id ||
          comparison.reviewVersion != review.version ||
          comparison.offerId != review.offerId ||
          comparison.contractOfferRevision != review.offerRevision ||
          !comparison.factsMatch) {
        throw const FormatException('合同或报价已变化，请刷新并重新核对。');
      }
      final row = <String, dynamic>{
        'reviewId': review.id,
        'version': review.version
      };
      await store.save(repository.tenant, actor, row);
      if (!current || epoch != _epoch) {
        loaded = false;
        return;
      }
      pending = row;
      final result = await repository.accept(review.id, review.version,
          currentOperation: () => current && epoch == _epoch);
      if (current && epoch == _epoch) {
        latest = result;
        queried = true;
      }
    } catch (e) {
      if (current) {
        error = e;
        if (pending == null) loaded = false;
      }
    } finally {
      busy = false;
      notify();
    }
  }

  Future<void> recover() async {
    if (!current || busy || pending == null) return;
    busy = true;
    error = null;
    notify();
    try {
      final result = await repository.get(pending!['reviewId']);
      if (current) {
        if (result.version < pending!['version']) {
          throw const ParentApiException(502, 'INVALID_CONTRACT_RESPONSE');
        }
        latest = result;
        queried = true;
      }
    } catch (e) {
      if (current) error = e;
    } finally {
      busy = false;
      notify();
    }
  }

  Future<bool> clear() async {
    if (!current || busy || pending == null || !queried) return false;
    busy = true;
    error = null;
    notify();
    try {
      await store.clear(repository.tenant, actor, pending!);
      if (!current) return false;
      pending = null;
      latest = null;
      queried = false;
      return true;
    } catch (e) {
      if (current) error = e;
      return false;
    } finally {
      busy = false;
      notify();
    }
  }
}

String contractError(Object error) {
  if (error is! ParentApiException) return '$error';
  final message = switch (error.code) {
    'INVALID_CONTRACT_RESPONSE' => '合同数据与当前选择不一致，请重新读取。',
    'CONTRACT_NOT_AWAITING_CUSTOMER' => '合同状态已变化，请查询当前状态后核对。',
    'CONTRACT_NOT_ACTIVE' => '合同服务期已结束或来源已撤销，请联系机构采购负责人。',
    'CONTRACT_ACTIVE_SUBMISSIONS_PAUSED' => '合同服务暂未开放确认，请联系服务方。',
    'CONTRACT_OFFER_MISMATCH' => '当前报价与合同不一致，请重新核对并联系服务方。',
    _ => error.message
  };
  return error.correlationId == null
      ? message
      : '$message\n问题编号：${error.correlationId}';
}
