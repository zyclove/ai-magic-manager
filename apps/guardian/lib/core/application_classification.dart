import 'api.dart';
import 'package:usage_reporting/usage_reporting.dart';
export 'package:usage_reporting/usage_reporting.dart'
    show
        ApplicationClassification,
        ApplicationClassificationIdentity,
        applicationCategories,
        UsageReportFailure;

ApplicationClassification _parseClassification(
    dynamic value, ApplicationClassificationIdentity identity) {
  try {
    return ApplicationClassification.parse(value, identity);
  } on UsageReportFailure catch (error) {
    throw ApiFailure(error.status, error.code);
  }
}

class ApplicationClassificationRepository {
  final Api api;
  final String root, applicationId;
  final ApplicationClassificationIdentity identity;
  final bool Function() current;
  ApplicationClassificationRepository(
      {required this.api,
      required this.root,
      required this.applicationId,
      required this.identity,
      required this.current}) {
    if (!identity.valid ||
        !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(applicationId)) {
      throw const ApiFailure(502, 'INVALID_CLASSIFICATION_RESPONSE');
    }
  }
  String get path => '$root/applications/$applicationId/classification';
  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<ApplicationClassification> load() async {
    ensureCurrent();
    final value = await api.send('GET', path);
    ensureCurrent();
    return _parseClassification(value, identity);
  }

  Future<ApplicationClassification> save(
      ApplicationClassification before, String category, String key) async {
    ensureCurrent();
    if (!applicationCategories.containsKey(category)) {
      throw const ApiFailure(400, 'VALIDATION_FAILED');
    }
    final value = await api.send('PUT', path,
        body: {'category': category}, key: key, version: before.version);
    ensureCurrent();
    final result = _parseClassification(value, identity);
    if (result.version != before.version + 1 || result.category != category) {
      throw const ApiFailure(502, 'INVALID_CLASSIFICATION_RESPONSE');
    }
    return result;
  }
}
