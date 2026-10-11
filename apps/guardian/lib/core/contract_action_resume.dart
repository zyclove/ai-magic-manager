import 'dart:convert';
import 'api.dart';
import 'contracts.dart';

/// Keeps only the contract pointer across an OIDC step-up in the same browser tab.
/// A restored pointer opens a fresh review; it never repeats a write or stores a JWS.
class ContractActionResume {
  final String reviewId, action;
  const ContractActionResume(this.reviewId, this.action);

  String encode(
          {required String actor,
          required String scope,
          required String tenantId,
          required String role,
          required int now}) =>
      jsonEncode({
        'version': 1,
        'actor': actor,
        'scope': scope,
        'tenantId': tenantId,
        'role': role,
        'createdAt': now,
        'reviewId': reviewId,
        'action': action
      });

  static ContractActionResume? decode(String? text,
      {required String actor,
      required String scope,
      required String tenantId,
      required String role,
      required int now}) {
    if (text == null || text.length > 1024) return null;
    try {
      final raw = jsonDecode(text);
      if (raw is! Json ||
          raw.length != 8 ||
          raw['version'] != 1 ||
          raw['actor'] != actor ||
          raw['scope'] != scope ||
          raw['tenantId'] != tenantId ||
          raw['role'] != role ||
          raw['createdAt'] is! int ||
          now < raw['createdAt'] ||
          now - raw['createdAt'] > 600000 ||
          raw['reviewId'] is! String ||
          !isContractId(raw['reviewId']) ||
          !['approve', 'reject', 'accept'].contains(raw['action']) ||
          (scope == 'platform' && raw['action'] == 'accept') ||
          (scope == 'tenant' && raw['action'] != 'accept')) return null;
      return ContractActionResume(raw['reviewId'], raw['action']);
    } catch (_) {
      return null;
    }
  }
}
