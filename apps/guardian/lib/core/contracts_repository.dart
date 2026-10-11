import 'package:uuid/uuid.dart';
import 'api.dart';
import 'bounded_json.dart';
import 'contracts.dart';

/// Contract reads stay bound to the actor and workspace that opened the page.
class ContractsRepository {
  final Api api;
  final bool Function() current;
  final String? tenantId;
  final bool platform;
  static const _uuid = Uuid();

  const ContractsRepository.platform({required this.api, required this.current})
      : tenantId = null,
        platform = true;

  const ContractsRepository.tenant(
      {required this.api, required this.current, required this.tenantId})
      : platform = false;

  String get _path =>
      platform ? '/platform/contracts' : '/tenants/$tenantId/contracts';

  void _ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  String newId() => _uuid.v4();

  Future<dynamic> _read(String path, int maxBytes) async {
    try {
      return await boundedJson(api, 'GET', path,
          ensureCurrent: _ensureCurrent, maxBytes: maxBytes);
    } on ApiFailure catch (failure) {
      if (failure.status == 502) {
        throw const ApiFailure(502, 'INVALID_CONTRACT_RESPONSE');
      }
      rethrow;
    }
  }

  Future<ContractCapabilities> capabilities() async {
    if (!platform) throw const ApiFailure(403, 'SCOPE_DENIED');
    _ensureCurrent();
    final raw = await _read('$_path/capabilities', 4096);
    _ensureCurrent();
    return ContractCapabilities.parse(raw);
  }

  Future<ContractReviewPage> list({String? cursor}) async {
    _ensureCurrent();
    if (cursor != null && !isContractId(cursor)) {
      throw const ApiFailure(400, 'INVALID_CURSOR');
    }
    final query = cursor == null ? '?limit=50' : '?limit=50&cursor=$cursor';
    final raw = await _read('$_path$query', 256 * 1024);
    _ensureCurrent();
    final page = ContractReviewPage.parse(raw, platform: platform);
    if (!platform && page.items.any((item) => item.tenantId != tenantId)) {
      throw const ApiFailure(502, 'INVALID_CONTRACT_RESPONSE');
    }
    return page;
  }

  Future<ContractReview> get(String id) async {
    _ensureCurrent();
    if (!isContractId(id)) {
      throw const ApiFailure(400, 'INVALID_CONTRACT_REVIEW_ID');
    }
    final raw = await _read('$_path/$id', 16 * 1024);
    _ensureCurrent();
    final review = ContractReview.parse(raw, platform: platform);
    if (review.id != id || (!platform && review.tenantId != tenantId)) {
      throw const ApiFailure(502, 'INVALID_CONTRACT_RESPONSE');
    }
    return review;
  }

  Future<ContractHistoryPage> history(String id, {int? beforeVersion}) async {
    _ensureCurrent();
    if (!isContractId(id) || (beforeVersion != null && beforeVersion < 1)) {
      throw const ApiFailure(400, 'INVALID_CONTRACT_HISTORY_PAGE');
    }
    final query = beforeVersion == null
        ? '?limit=50'
        : '?limit=50&beforeVersion=$beforeVersion';
    final raw = await _read('$_path/$id/history$query', 128 * 1024);
    _ensureCurrent();
    final page = ContractHistoryPage.parse(raw, platform: platform);
    if (beforeVersion != null &&
        page.items.any((event) => event.version >= beforeVersion)) {
      throw const ApiFailure(502, 'INVALID_CONTRACT_RESPONSE');
    }
    return page;
  }

  Future<ContractComparison> comparison(ContractReview review) async {
    _ensureCurrent();
    if (!platform && review.tenantId != tenantId) {
      throw const ApiFailure(403, 'SCOPE_DENIED');
    }
    final raw = await _read('$_path/${review.id}/comparison', 16 * 1024);
    _ensureCurrent();
    final result = ContractComparison.parse(raw);
    if (result.reviewId != review.id ||
        result.reviewVersion != review.version ||
        result.offerId != review.offerId ||
        result.contractOfferRevision != review.offerRevision) {
      throw const ApiFailure(502, 'INVALID_CONTRACT_RESPONSE');
    }
    return result;
  }

  /// The caller keeps the same ID and JWS for an uncertain network retry.
  Future<ContractReview> create(String id, String compactJws) async {
    if (!platform) throw const ApiFailure(403, 'SCOPE_DENIED');
    _ensureCurrent();
    if (!isContractId(id) || compactJws.isEmpty || compactJws.length > 16384) {
      throw const ApiFailure(400, 'INVALID_CONTRACT_EVIDENCE');
    }
    final raw =
        await api.send('POST', _path, body: {'id': id, 'evidence': compactJws});
    _ensureCurrent();
    final review = ContractReview.parse(raw, platform: true);
    if (review.id != id) {
      throw const ApiFailure(502, 'INVALID_CONTRACT_RESPONSE');
    }
    return review;
  }

  Future<ContractReview> approve(ContractReview review, String reason) =>
      _platformAction(review, 'approve', reason);

  Future<ContractReview> reject(ContractReview review, String reason) =>
      _platformAction(review, 'reject', reason);

  Future<ContractReview> _platformAction(
      ContractReview review, String action, String reason) async {
    if (!platform) throw const ApiFailure(403, 'SCOPE_DENIED');
    _ensureCurrent();
    final raw = await api.send('POST', '$_path/${review.id}/$action',
        version: review.version, body: {'reason': reason});
    _ensureCurrent();
    final next = ContractReview.parse(raw, platform: true);
    if (next.id != review.id || next.version <= review.version) {
      throw const ApiFailure(502, 'INVALID_CONTRACT_RESPONSE');
    }
    return next;
  }

  Future<ContractReview> accept(ContractReview review) async {
    if (platform || review.tenantId != tenantId) {
      throw const ApiFailure(403, 'SCOPE_DENIED');
    }
    _ensureCurrent();
    final raw = await api.send('POST', '$_path/${review.id}/accept',
        version: review.version);
    _ensureCurrent();
    final next = ContractReview.parse(raw, platform: false);
    if (next.id != review.id ||
        next.tenantId != tenantId ||
        next.version <= review.version ||
        next.state != 'APPLIED') {
      throw const ApiFailure(502, 'INVALID_CONTRACT_RESPONSE');
    }
    return next;
  }
}
