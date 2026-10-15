import 'api.dart';
import 'package:audit_client/audit_client.dart';
export 'package:audit_client/audit_client.dart';

class AuditRepository {
  final Api api;
  final String root;
  final bool Function() current;
  AuditRepository(
      {required this.api, required this.root, required this.current});
  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<dynamic> _get(String suffix) async {
    ensureCurrent();
    try {
      final result = await api.send('GET', '$root/audit-events$suffix',
          isCurrent: current);
      ensureCurrent();
      return result;
    } catch (_) {
      ensureCurrent();
      rethrow;
    }
  }

  Future<AuditPage> load(AuditQuery q, {String? cursor}) async {
    try {
      q.validate();
    } on AuditProtocolException {
      throw const ApiFailure(400, 'INVALID_AUDIT_QUERY');
    }
    final params = {...q.parameters, if (cursor != null) 'cursor': cursor};
    final v = await _get('/search?${Uri(queryParameters: params).query}');
    try {
      return AuditPage.parse(v, q, cursor: cursor);
    } on AuditProtocolException {
      throw const ApiFailure(502, 'INVALID_AUDIT_RESPONSE');
    }
  }

  Future<AuditEvent> detail(String id) async {
    if (!auditUuid.hasMatch(id)) {
      throw const ApiFailure(400, 'INVALID_AUDIT_ID');
    }
    final raw = await _get('/$id');
    try {
      final item = AuditEvent.parse(raw);
      if (item.id != id) throw const AuditProtocolException();
      return item;
    } on AuditProtocolException {
      throw const ApiFailure(502, 'INVALID_AUDIT_RESPONSE');
    }
  }
}
