import 'failure.dart';

const applicationCategories = <String, String>{
  'UNCLASSIFIED': '未分类',
  'EDUCATION': '学习教育',
  'PRODUCTIVITY': '效率办公',
  'GAMES': '游戏',
  'SOCIAL': '社交沟通',
  'ENTERTAINMENT': '影音娱乐',
  'TOOLS': '实用工具',
  'OTHER': '其他',
};

class ApplicationClassificationIdentity {
  final String platform, profile, packageName;
  const ApplicationClassificationIdentity(
      this.platform, this.profile, this.packageName);
  bool get valid =>
      const {'ANDROID', 'ANDROID_TV'}.contains(platform) &&
      const {'PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN'}.contains(profile) &&
      packageName.length <= 255 &&
      RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
          .hasMatch(packageName);
  bool matches(dynamic value) =>
      value is ReportJson &&
      value.length == 3 &&
      value['platform'] == platform &&
      value['profile'] == profile &&
      value['packageName'] == packageName;
}

class ApplicationClassification {
  final ApplicationClassificationIdentity identity;
  final String category, source;
  final int version;
  final int? updatedAt;
  const ApplicationClassification._(
      this.identity, this.category, this.source, this.version, this.updatedAt);
  static ApplicationClassification parse(
      dynamic value, ApplicationClassificationIdentity identity) {
    if (!identity.valid ||
        value is! ReportJson ||
        value.length != 5 ||
        !value.keys.every(const {
          'identity',
          'category',
          'source',
          'version',
          'updatedAt'
        }.contains) ||
        !identity.matches(value['identity']) ||
        !applicationCategories.containsKey(value['category']) ||
        value['version'] is! int ||
        value['version'] < 0 ||
        value['version'] > 9007199254740991 ||
        (value['version'] == 0
            ? value['category'] != 'UNCLASSIFIED' ||
                value['source'] != 'NONE' ||
                value['updatedAt'] != null
            : value['source'] != 'ADMIN_DECLARED' ||
                value['updatedAt'] is! int ||
                value['updatedAt'] <= 0 ||
                value['updatedAt'] > 8640000000000000)) {
      throw const UsageReportFailure(502, 'INVALID_CLASSIFICATION_RESPONSE');
    }
    return ApplicationClassification._(identity, value['category'],
        value['source'], value['version'], value['updatedAt']);
  }
}
