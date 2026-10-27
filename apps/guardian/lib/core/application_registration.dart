import 'api.dart';
import 'application_classification.dart' show ApplicationClassificationIdentity;

final _plainDigest = RegExp(r'^[0-9a-fA-F]{64}$');
final _colonDigest = RegExp(r'^(?:[0-9a-fA-F]{2}:){31}[0-9a-fA-F]{2}$');
final _storedDigest = RegExp(r'^[0-9a-f]{64}$');
final _applicationId = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

bool _matches(RegExp expression, String value) =>
    expression.firstMatch(value)?.end == value.length;

String? validateAndroidPackageName(String? value) {
  final packageName = value?.trim() ?? '';
  return ApplicationClassificationIdentity('ANDROID', 'PRIMARY', packageName).valid
      ? null : '请输入合法的 Android 包名，例如 com.example.app；包名区分大小写。';
}

List<String> _parseDigests(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return const [];
  final entries = text.split(RegExp(r'[,，]|\r?\n'));
  if (entries.length > 8) {
    throw const FormatException('最多填写 8 份签名摘要，请删除多余项。');
  }
  final digests = <String>[];
  final seen = <String>{};
  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index].trim();
    if (entry.isEmpty) {
      throw FormatException('第 ${index + 1} 份签名为空，请删除多余的逗号或空行。');
    }
    if (!_matches(_plainDigest, entry) && !_matches(_colonDigest, entry)) {
      throw FormatException('第 ${index + 1} 份签名格式不正确；请填写 64 位十六进制 SHA-256，或用冒号分隔的 32 组字节。');
    }
    final digest = entry.replaceAll(':', '').toLowerCase();
    if (!seen.add(digest)) {
      throw FormatException('第 ${index + 1} 份签名与已有摘要重复，请删除重复项。');
    }
    digests.add(digest);
  }
  digests.sort();
  return List<String>.unmodifiable(digests);
}

String? validateApplicationSigningDigests(String? value) {
  try {
    _parseDigests(value);
    return null;
  } on FormatException catch (failure) {
    return failure.message;
  }
}

Json _readDeclaration(Map source) {
  final name = source['displayName'], platform = source['platform'],
      packageName = source['packageName'], profile = source['profile'],
      hashes = source['signingDigests'];
  if (name is! String || name.trim().isEmpty || name != name.trim() || name.length > 100 ||
      platform is! String || packageName is! String || profile is! String ||
      !ApplicationClassificationIdentity(platform, profile, packageName).valid ||
      hashes is! List || hashes.length > 8) {
    throw const FormatException('Invalid application declaration.');
  }
  final digests = <String>[];
  final seen = <String>{};
  for (final hash in hashes) {
    if (hash is! String || !_matches(_storedDigest, hash) || !seen.add(hash)) {
      throw const FormatException('Invalid application signing digests.');
    }
    digests.add(hash);
  }
  digests.sort();
  return Map<String, dynamic>.unmodifiable({
    'displayName': name, 'platform': platform, 'packageName': packageName,
    'profile': profile, 'signingDigests': List<String>.unmodifiable(digests),
  });
}

/// Captures only the backend declaration fields; package identity keeps its case.
Json applicationRegistrationPayload(Json form) {
  try {
    final name = form['displayName'], packageName = form['packageName'],
        rawDigests = form['digests'];
    if (name is! String || packageName is! String ||
        rawDigests != null && rawDigests is! String) {
      throw const FormatException('Invalid application fields.');
    }
    return _readDeclaration({
      'displayName': name.trim(), 'packageName': packageName.trim(),
      'platform': form['platform'], 'profile': form['profile'],
      'signingDigests': _parseDigests(rawDigests as String?),
    });
  } on FormatException {
    throw const ApiFailure(400, 'VALIDATION_FAILED');
  }
}

/// A declaration result must describe the complete frozen original identity.
Json requireApplicationRegistrationResult(Object? raw, Json body) {
  try {
    if (raw is! Map || raw['id'] is! String ||
        !_matches(_applicationId, raw['id'] as String) ||
        raw['evidenceStatus'] != 'ADMIN_DECLARED') {
      throw const FormatException('Invalid application result.');
    }
    final actual = _readDeclaration(raw), expected = _readDeclaration(body);
    for (final key in ['displayName', 'platform', 'packageName', 'profile']) {
      if (actual[key] != expected[key]) {
        throw const FormatException('Application result does not match the declaration.');
      }
    }
    final actualDigests = actual['signingDigests'] as List<String>,
        expectedDigests = expected['signingDigests'] as List<String>;
    if (actualDigests.length != expectedDigests.length) {
      throw const FormatException('Application signing digests do not match.');
    }
    for (var index = 0; index < actualDigests.length; index++) {
      if (actualDigests[index] != expectedDigests[index]) {
        throw const FormatException('Application signing digests do not match.');
      }
    }
    return Map<String, dynamic>.unmodifiable({
      'id': raw['id'], ...actual, 'evidenceStatus': 'ADMIN_DECLARED',
    });
  } on FormatException {
    throw const ApiFailure(502, 'INVALID_RESPONSE');
  }
}
