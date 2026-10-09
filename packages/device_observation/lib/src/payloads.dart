import 'package:device_policy/device_policy.dart' show freezeJson;
import 'models.dart';

const profiles = {'PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN'};
const dayMillis = 86400000;
bool text(dynamic value, int limit) =>
    value is String &&
    value.trim().isNotEmpty &&
    value.length <= limit &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
bool packageName(dynamic value) =>
    text(value, 255) &&
    RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
        .hasMatch(value as String);
Never invalid() => throw const ObservationFailure('OBSERVATION_SAMPLE_INVALID');

List<Map<String, dynamic>> inventoryApplications(dynamic input) {
  if (input is! List || input.length > 500) invalid();
  final result = <Map<String, dynamic>>[], seen = <String>{};
  for (final raw in input) {
    if (raw is! Map<String, dynamic> ||
        !exactKeys(raw, {
          'packageName',
          'displayName',
          'profile',
          'signingDigests',
          'versionCode',
          'systemApplication'
        }) ||
        !packageName(raw['packageName']) ||
        !text(raw['displayName'], 100) ||
        !profiles.contains(raw['profile']) ||
        !safeNumber(raw['versionCode']) ||
        raw['systemApplication'] is! bool) invalid();
    final digests = raw['signingDigests'];
    if (digests is! List ||
        digests.length > 8 ||
        digests.any(
            (d) => d is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(d)) ||
        digests.toSet().length != digests.length ||
        !seen.add('${raw['packageName']}|${raw['profile']}')) invalid();
    result.add({
      ...raw,
      'displayName': (raw['displayName'] as String).trim(),
      'signingDigests': digests.cast<String>().toList()..sort()
    });
  }
  result.sort((a, b) => '${a['packageName']}|${a['profile']}'
      .compareTo('${b['packageName']}|${b['profile']}'));
  return List.unmodifiable(result.map(freezeJson));
}

List<Map<String, dynamic>> usageApplications(dynamic input, int observedAt) {
  if (input is! List || input.length > 500) invalid();
  final result = <Map<String, dynamic>>[], seen = <String>{};
  for (final raw in input) {
    if (raw is! Map<String, dynamic> ||
        !exactKeys(raw, {
          'packageName',
          'displayName',
          'firstTimeStamp',
          'lastTimeStamp',
          'foregroundMillis'
        }) ||
        !packageName(raw['packageName']) ||
        !text(raw['displayName'], 100) ||
        !safeNumber(raw['firstTimeStamp'], minimum: 1) ||
        !safeNumber(raw['lastTimeStamp'], minimum: 1) ||
        !safeNumber(raw['foregroundMillis'])) invalid();
    final first = raw['firstTimeStamp'] as int,
        last = raw['lastTimeStamp'] as int,
        duration = raw['foregroundMillis'] as int;
    if (first > last ||
        first < observedAt - 7 * dayMillis ||
        last > observedAt + 300000 ||
        duration > last - first ||
        duration > 7 * dayMillis ||
        !seen.add('${raw['packageName']}|$first|$last')) invalid();
    result.add({...raw, 'displayName': (raw['displayName'] as String).trim()});
  }
  result.sort((a, b) {
    final c =
        (a['packageName'] as String).compareTo(b['packageName'] as String);
    if (c != 0) return c;
    final f =
        (a['firstTimeStamp'] as int).compareTo(b['firstTimeStamp'] as int);
    return f != 0
        ? f
        : (a['lastTimeStamp'] as int).compareTo(b['lastTimeStamp'] as int);
  });
  return List.unmodifiable(result.map(freezeJson));
}

Map<String, dynamic> usagePayload(
    UsageSample sample, int sequence, int version, String reportId) {
  if (!safeNumber(sample.queryStart, minimum: 1) ||
      !safeNumber(sample.queryEnd, minimum: 1) ||
      !safeNumber(sample.observedAt, minimum: 1) ||
      sample.queryStart >= sample.queryEnd ||
      sample.queryEnd > sample.observedAt ||
      sample.queryEnd - sample.queryStart > 2 * dayMillis ||
      !profiles.contains(sample.profile) ||
      !text(sample.timeZone, 100)) invalid();
  return freezeJson({
    'reportId': reportId,
    'sequence': sequence,
    'authorizationVersion': version,
    'source': 'ANDROID_USAGE_STATS',
    'profile': sample.profile,
    'queryStart': sample.queryStart,
    'queryEnd': sample.queryEnd,
    'observedAt': sample.observedAt,
    'timeZone': sample.timeZone,
    'applications': usageApplications(sample.applications, sample.observedAt)
  });
}
