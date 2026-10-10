import 'package:uuid/uuid.dart';
import 'api.dart';
import 'bounded_json.dart';
import 'commercial_catalog.dart';

/// Platform-only catalog API. The caller binds this repository to one authenticated actor.
class CommercialCatalogRepository {
  final Api api;
  final bool Function() current;
  static const _path = '/platform/catalog/offers';
  static const _uuid = Uuid();

  const CommercialCatalogRepository({required this.api, required this.current});

  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<CatalogOfferPage> list({String? cursor}) async {
    ensureCurrent();
    if (cursor != null && !isCatalogId(cursor)) {
      throw const ApiFailure(400, 'INVALID_CURSOR');
    }
    final query = cursor == null ? '?limit=50' : '?limit=50&cursor=$cursor';
    final result = await boundedJson(api, 'GET', '$_path$query',
        maxBytes: 256 * 1024, ensureCurrent: ensureCurrent);
    ensureCurrent();
    return CatalogOfferPage.parse(result);
  }

  Future<CatalogOffer> get(String id) async {
    ensureCurrent();
    if (!isCatalogId(id)) {
      throw const ApiFailure(400, 'INVALID_COMMERCIAL_OFFER_ID');
    }
    final result = await boundedJson(api, 'GET', '$_path/$id',
        maxBytes: 16 * 1024, ensureCurrent: ensureCurrent);
    ensureCurrent();
    final offer = CatalogOffer.parse(result);
    if (offer.id != id) throw const ApiFailure(502, 'INVALID_CATALOG_RESPONSE');
    return offer;
  }

  Future<CatalogHistoryPage> history(String id, {int? beforeRevision}) async {
    ensureCurrent();
    if (!isCatalogId(id) || (beforeRevision != null && beforeRevision < 1)) {
      throw const ApiFailure(400, 'INVALID_CATALOG_HISTORY_PAGE');
    }
    final query = beforeRevision == null
        ? '?limit=50'
        : '?limit=50&beforeRevision=$beforeRevision';
    final result = await boundedJson(api, 'GET', '$_path/$id/history$query',
        maxBytes: 512 * 1024, ensureCurrent: ensureCurrent);
    ensureCurrent();
    final page = CatalogHistoryPage.parse(result);
    if (beforeRevision != null &&
        page.items.any((entry) => entry.revision >= beforeRevision)) {
      throw const ApiFailure(502, 'INVALID_CATALOG_RESPONSE');
    }
    return page;
  }

  /// Keep [id] and [draft] unchanged when retrying an uncertain network result.
  String newId() => _uuid.v4();

  Future<CatalogOffer> create(String id, CatalogDraft draft) async {
    ensureCurrent();
    if (!isCatalogId(id)) {
      throw const ApiFailure(400, 'INVALID_COMMERCIAL_OFFER_ID');
    }
    final result = await api
        .send('POST', _path, body: {'id': id, 'offer': draft.toJson()});
    ensureCurrent();
    final offer = CatalogOffer.parse(result);
    if (offer.id != id) throw const ApiFailure(502, 'INVALID_CATALOG_RESPONSE');
    return offer;
  }

  Future<CatalogOffer> revise(CatalogOffer currentOffer, CatalogDraft draft) =>
      _write('PUT', currentOffer.id, currentOffer.revision,
          body: draft.toJson());

  Future<CatalogOffer> submit(CatalogOffer currentOffer, String reason) =>
      _write('POST', '${currentOffer.id}/submit', currentOffer.revision,
          body: {'reason': reason});

  Future<CatalogOffer> approve(CatalogOffer currentOffer, String reason) =>
      _write('POST', '${currentOffer.id}/approve', currentOffer.revision,
          body: {'reason': reason});

  Future<CatalogOffer> retire(CatalogOffer currentOffer, String reason) =>
      _write('POST', '${currentOffer.id}/retire', currentOffer.revision,
          body: {'reason': reason});

  Future<CatalogOffer> _write(String method, String suffix, int version,
      {required Json body}) async {
    ensureCurrent();
    final id = suffix.split('/').first;
    if (!isCatalogId(id)) {
      throw const ApiFailure(400, 'INVALID_COMMERCIAL_OFFER_ID');
    }
    final result =
        await api.send(method, '$_path/$suffix', body: body, version: version);
    ensureCurrent();
    final offer = CatalogOffer.parse(result);
    if (offer.id != id || offer.revision < version) {
      throw const ApiFailure(502, 'INVALID_CATALOG_RESPONSE');
    }
    return offer;
  }
}
