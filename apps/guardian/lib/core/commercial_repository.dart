import 'api.dart';
import 'bounded_json.dart';
import 'commercial_entitlements.dart';

/// Tenant-bound read of commercial rights; the authenticated Session owns the HTTP client.
class CommercialRepository {
  static final _rootPattern = RegExp(
      r'^/tenants/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$');
  final Api api;
  final String root;
  final bool Function() current;

  CommercialRepository(
      {required this.api, required this.root, required this.current});

  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<CommercialEntitlements> load() async {
    ensureCurrent();
    final match = _rootPattern.firstMatch(root);
    if (match == null) {
      throw const ApiFailure(502, 'INVALID_COMMERCIAL_RESPONSE');
    }
    try {
      final result = await boundedJson(
          api, 'GET', '$root/commercial-entitlements',
          maxBytes: 16384, ensureCurrent: ensureCurrent);
      ensureCurrent();
      return CommercialEntitlements.parse(result, match.group(1)!);
    } on ApiFailure catch (error) {
      if (error.code == 'INVALID_REPORT_JOB_RESPONSE') {
        throw const ApiFailure(502, 'INVALID_COMMERCIAL_RESPONSE');
      }
      rethrow;
    }
  }
}
