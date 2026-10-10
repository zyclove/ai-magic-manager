import 'dart:convert';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:intl/intl.dart';
import 'failure.dart';
import 'application_classification.dart';
import 'report_configurations.dart';

const usageReportRoles = {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'CHILD'};
bool _zonesReady = false;
tz.Location usageLocation(String zone) {
  if (!_zonesReady) {
    tzdata.initializeTimeZones();
    _zonesReady = true;
  }
  try {
    return tz.getLocation(zone);
  } catch (_) {
    throw const UsageReportFailure(400, 'INVALID_TIME_ZONE');
  }
}

DateTime usageLocalTime(int millis, String zone) =>
    tz.TZDateTime.fromMillisecondsSinceEpoch(usageLocation(zone), millis);
String usageTimestamp(int millis, String zone) =>
    DateFormat('yyyy-MM-dd HH:mm').format(usageLocalTime(millis, zone));
(int, int) usageCalendarWindow(DateTime first, DateTime last, String zone) {
  final location = usageLocation(zone);
  return (
    tz.TZDateTime(location, first.year, first.month, first.day)
        .millisecondsSinceEpoch,
    tz.TZDateTime(location, last.year, last.month, last.day + 1)
        .millisecondsSinceEpoch
  );
}

List<int> _bucketEnds(int from, int to, String zone, String period) {
  final location = usageLocation(zone), local = usageLocalTime(from, zone);
  var date = DateTime.utc(local.year, local.month, local.day);
  if (period == 'WEEK') date = date.subtract(Duration(days: date.weekday - 1));
  final ends = <int>[];
  var cursor = from;
  while (cursor < to) {
    date = date.add(Duration(days: period == 'WEEK' ? 7 : 1));
    final boundary = tz.TZDateTime(location, date.year, date.month, date.day)
        .millisecondsSinceEpoch;
    final end = boundary < to ? boundary : to;
    if (end <= cursor) continue;
    ends.add(end);
    cursor = end;
    if (ends.length > 33) _invalid();
  }
  return ends;
}

final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
Never _invalid() =>
    throw const UsageReportFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
bool _integer(dynamic v, [int minimum = 0, int maximum = 9007199254740991]) =>
    v is int && v >= minimum && v <= maximum;
bool _time(dynamic v) => _integer(v, 1, 8640000000000000);
bool _text(dynamic v, int max) =>
    v is String &&
    v.trim().isNotEmpty &&
    v.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]').hasMatch(v);
bool _keys(dynamic v, Set<String> keys) =>
    v is ReportJson && v.length == keys.length && v.keys.every(keys.contains);

class UsageReportTarget {
  final String deviceId, registrationId, subjectId, displayName;
  final String platform;
  const UsageReportTarget(
      this.deviceId, this.registrationId, this.subjectId, this.displayName,
      {this.platform = 'ANDROID'});
  bool get valid =>
      _uuid.hasMatch(deviceId) &&
      _uuid.hasMatch(registrationId) &&
      _uuid.hasMatch(subjectId) &&
      const {'ANDROID', 'ANDROID_TV'}.contains(platform) &&
      _text(displayName, 240);
}

class UsageReportScope {
  final String kind, label;
  final String? id;
  final int? version;
  final Set<String> subjectIds;
  const UsageReportScope.devices()
      : kind = 'DEVICES',
        label = '自由选择设备',
        id = null,
        version = null,
        subjectIds = const {};
  UsageReportScope(
      {required this.kind,
      required this.label,
      this.id,
      this.version,
      Iterable<String> subjectIds = const []})
      : subjectIds = Set.unmodifiable(
            kind == 'SUBJECT' && id != null ? [id] : subjectIds) {
    if (!{'SUBJECT', 'CLASS'}.contains(kind) ||
        id == null ||
        !_uuid.hasMatch(id!) ||
        !_text(label, 140) ||
        (kind == 'CLASS' ? !_integer(version) : version != null) ||
        this.subjectIds.length > 500 ||
        this.subjectIds.any((id) => !_uuid.hasMatch(id))) {
      throw const UsageReportFailure(400, 'INVALID_REPORT_SCOPE');
    }
  }
  String get key => '$kind:${id ?? ''}';
  bool accepts(UsageReportTarget target) =>
      kind == 'DEVICES' || subjectIds.contains(target.subjectId);
}

/// An immutable applied selection, also used when retrying a failed request.
class UsageReportQuery {
  final List<UsageReportTarget> targets;
  final int from, to;
  final String timeZone, period;
  final UsageReportScope scope;
  UsageReportQuery(
      {required List<UsageReportTarget> targets,
      required this.from,
      required this.to,
      required this.timeZone,
      required this.period,
      this.scope = const UsageReportScope.devices()})
      : targets = List.unmodifiable(targets) {
    if (targets.isEmpty ||
        targets.length > 20 ||
        targets.map((v) => v.deviceId).toSet().length != targets.length ||
        targets.any((v) => !v.valid || !scope.accepts(v)) ||
        !_time(from) ||
        !_time(to) ||
        from >= to ||
        to - from > 32 * 86400000 ||
        !_text(timeZone, 100) ||
        !{'DAY', 'WEEK'}.contains(period)) {
      throw const UsageReportFailure(400, 'INVALID_USAGE_REPORT_QUERY');
    }
  }
  String get path => Uri(path: '/usage-reports', queryParameters: {
        'deviceId': targets.map((v) => v.deviceId).toList(),
        'from': '$from',
        'to': '$to',
        'timeZone': timeZone,
        'period': period,
        'scopeKind': scope.kind,
        if (scope.id != null) 'scopeId': scope.id!,
        if (scope.version != null) 'scopeVersion': '${scope.version}'
      }).toString();
}

class UsageReportBucket {
  final int start, end, coveredMillis;
  final int? lowerMillis, upperMillis;
  final String status;
  const UsageReportBucket(this.start, this.end, this.lowerMillis,
      this.upperMillis, this.coveredMillis, this.status);
  static UsageReportBucket parse(dynamic v, int cursor, int to) {
    if (!_keys(v, {
          'start',
          'end',
          'lowerMillis',
          'upperMillis',
          'coveredMillis',
          'status'
        }) ||
        v['start'] != cursor ||
        !_time(v['end']) ||
        v['end'] <= cursor ||
        v['end'] > to ||
        !_integer(v['coveredMillis'], 0, v['end'] - cursor)) _invalid();
    final duration = v['end'] - cursor as int;
    if (v['status'] == 'NO_EVIDENCE') {
      if (v['lowerMillis'] != null ||
          v['upperMillis'] != null ||
          v['coveredMillis'] != 0) _invalid();
    } else {
      if (!{'REPORTED_TOTAL', 'REPORTED_RANGE'}.contains(v['status']) ||
          !_integer(v['lowerMillis'], 0, duration) ||
          !_integer(v['upperMillis'], 0, duration) ||
          v['coveredMillis'] == 0 ||
          v['lowerMillis'] > v['upperMillis'] ||
          v['lowerMillis'] > v['coveredMillis'] ||
          v['upperMillis'] - v['lowerMillis'] < duration - v['coveredMillis'] ||
          (v['status'] == 'REPORTED_TOTAL') !=
              (v['lowerMillis'] == v['upperMillis'])) _invalid();
    }
    return UsageReportBucket(cursor, v['end'], v['lowerMillis'],
        v['upperMillis'], v['coveredMillis'], v['status']);
  }
}

class UsageReportApplication {
  final String profile, packageName, displayName;
  final int selectedIntervals, discardedOverlaps;
  final List<UsageReportBucket> buckets;
  final ApplicationClassification classification;
  const UsageReportApplication(
      this.profile,
      this.packageName,
      this.displayName,
      this.selectedIntervals,
      this.discardedOverlaps,
      this.buckets,
      this.classification);
  static UsageReportApplication parse(
      dynamic v, int from, int to, String platform) {
    if (!_keys(v, {
          'profile',
          'packageName',
          'displayName',
          'selectedIntervals',
          'discardedOverlaps',
          'buckets',
          'classification'
        }) ||
        !{'PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN'}.contains(v['profile']) ||
        !_text(v['packageName'], 255) ||
        !_text(v['displayName'], 100) ||
        !_integer(v['selectedIntervals'], 1, 100000) ||
        !_integer(v['discardedOverlaps'], 0, 100000) ||
        v['selectedIntervals'] + v['discardedOverlaps'] > 100000 ||
        v['buckets'] is! List ||
        v['buckets'].isEmpty ||
        v['buckets'].length > 33) _invalid();
    final buckets = <UsageReportBucket>[];
    int cursor = from;
    for (final raw in v['buckets']) {
      final bucket = UsageReportBucket.parse(raw, cursor, to);
      buckets.add(bucket);
      cursor = bucket.end;
    }
    if (cursor != to || buckets.every((v) => v.status == 'NO_EVIDENCE')) {
      _invalid();
    }
    return UsageReportApplication(
        v['profile'],
        v['packageName'],
        v['displayName'],
        v['selectedIntervals'],
        v['discardedOverlaps'],
        List.unmodifiable(buckets),
        ApplicationClassification.parse(
            v['classification'],
            ApplicationClassificationIdentity(
                platform, v['profile'], v['packageName'])));
  }
}

class UsageReportDevice {
  final String deviceId, registrationId, subjectId, displayName, status;
  final int authorizationVersion,
      retentionFrom,
      sourceBatchCount,
      queryCoverageMillis,
      uncoveredQueryMillis;
  final List<String> sourceTimeZones;
  final int? latestObservedAt, latestReceivedAt;
  final List<UsageReportApplication> applications;
  final ReportConfigurationState configurationState;
  const UsageReportDevice(
      this.deviceId,
      this.registrationId,
      this.subjectId,
      this.displayName,
      this.status,
      this.authorizationVersion,
      this.retentionFrom,
      this.sourceBatchCount,
      this.sourceTimeZones,
      this.latestObservedAt,
      this.latestReceivedAt,
      this.queryCoverageMillis,
      this.uncoveredQueryMillis,
      this.applications,
      this.configurationState);
  static UsageReportDevice parse(
      dynamic v, UsageReportTarget target, int from, int to, int generated) {
    if (!_keys(v, {
          'deviceId',
          'registrationId',
          'subjectId',
          'displayName',
          'status',
          'authorizationVersion',
          'retentionFrom',
          'sourceBatchCount',
          'sourceTimeZones',
          'latestObservedAt',
          'latestReceivedAt',
          'queryCoverageMillis',
          'uncoveredQueryMillis',
          'applications',
          'configurationState'
        }) ||
        v['deviceId'] != target.deviceId ||
        v['registrationId'] != target.registrationId ||
        v['subjectId'] != target.subjectId ||
        !_text(v['displayName'], 100) ||
        !{'NOT_AUTHORIZED', 'NO_DATA', 'OBSERVED'}.contains(v['status']) ||
        !_integer(v['authorizationVersion']) ||
        !_time(v['retentionFrom']) ||
        v['retentionFrom'] > generated ||
        !_integer(v['sourceBatchCount'], 0, 1024) ||
        v['sourceTimeZones'] is! List ||
        v['sourceTimeZones'].length > v['sourceBatchCount'] ||
        !(v['sourceTimeZones'] as List).every((z) => _text(z, 100)) ||
        v['sourceTimeZones'].toSet().length != v['sourceTimeZones'].length ||
        !_integer(v['queryCoverageMillis'], 0, to - from) ||
        !_integer(v['uncoveredQueryMillis'], 0, to - from) ||
        v['queryCoverageMillis'] + v['uncoveredQueryMillis'] != to - from ||
        v['applications'] is! List ||
        v['applications'].length > 2000) _invalid();
    if (v['status'] == 'OBSERVED') {
      if (v['sourceBatchCount'] == 0 ||
          v['sourceTimeZones'].isEmpty ||
          v['authorizationVersion'] == 0 ||
          !_time(v['latestObservedAt']) ||
          !_time(v['latestReceivedAt']) ||
          v['latestReceivedAt'] < v['retentionFrom'] ||
          v['latestReceivedAt'] > generated ||
          v['latestObservedAt'] > v['latestReceivedAt'] + 300000) _invalid();
    } else if (v['sourceBatchCount'] != 0 ||
        v['sourceTimeZones'].isNotEmpty ||
        v['latestObservedAt'] != null ||
        v['latestReceivedAt'] != null ||
        v['queryCoverageMillis'] != 0 ||
        v['applications'].isNotEmpty) {
      _invalid();
    }
    final apps = <UsageReportApplication>[], seen = <String>{};
    List<int>? boundaries;
    for (final raw in v['applications']) {
      final app = UsageReportApplication.parse(raw, from, to, target.platform);
      if (!seen.add('${app.profile}|${app.packageName}')) _invalid();
      final ends = app.buckets.map((b) => b.end).toList();
      if (boundaries != null && jsonEncode(boundaries) != jsonEncode(ends)) {
        _invalid();
      }
      boundaries = ends;
      apps.add(app);
    }
    return UsageReportDevice(
        v['deviceId'],
        v['registrationId'],
        v['subjectId'],
        v['displayName'],
        v['status'],
        v['authorizationVersion'],
        v['retentionFrom'],
        v['sourceBatchCount'],
        List<String>.unmodifiable(v['sourceTimeZones']),
        v['latestObservedAt'],
        v['latestReceivedAt'],
        v['queryCoverageMillis'],
        v['uncoveredQueryMillis'],
        List.unmodifiable(apps),
        ReportConfigurationState.parse(v['configurationState'], generated));
  }
}

class UsageReport {
  final int generatedAt, from, to;
  final String timeZone, period;
  final List<UsageReportDevice> devices;
  final UsageReportScope scope;
  const UsageReport(this.generatedAt, this.from, this.to, this.timeZone,
      this.period, this.devices, this.scope);
  static UsageReport parse(dynamic v, UsageReportQuery query) {
    if (!_keys(v, {
          'schemaVersion',
          'scope',
          'generatedAt',
          'from',
          'to',
          'requestedTo',
          'timeZone',
          'period',
          'precision',
          'evidenceStatus',
          'devices'
        }) ||
        v['schemaVersion'] != 1 ||
        !_keys(v['scope'], {'kind', 'id', 'version'}) ||
        v['scope']['kind'] != query.scope.kind ||
        v['scope']['id'] != query.scope.id ||
        (v['scope']['version'] != null && !_integer(v['scope']['version'])) ||
        v['scope']['version'] != query.scope.version ||
        !_time(v['generatedAt']) ||
        v['from'] != query.from ||
        v['requestedTo'] != query.to ||
        v['timeZone'] != query.timeZone ||
        v['period'] != query.period ||
        !_time(v['to']) ||
        v['to'] <= query.from ||
        v['to'] !=
            (query.to < v['generatedAt'] ? query.to : v['generatedAt']) ||
        v['precision'] != 'OS_AGGREGATE' ||
        v['evidenceStatus'] != 'AGENT_REPORTED_UNVERIFIED' ||
        v['devices'] is! List ||
        v['devices'].length != query.targets.length) _invalid();
    final targets = {for (final t in query.targets) t.deviceId: t},
        seen = <String>{},
        devices = <UsageReportDevice>[];
    int count = 0;
    final expectedEnds =
        _bucketEnds(query.from, v['to'], query.timeZone, query.period);
    for (final raw in v['devices']) {
      if (raw is! ReportJson ||
          raw['deviceId'] is! String ||
          !targets.containsKey(raw['deviceId']) ||
          !seen.add(raw['deviceId'])) _invalid();
      final device = UsageReportDevice.parse(raw, targets[raw['deviceId']]!,
          query.from, v['to'], v['generatedAt']);
      for (final app in device.applications) {
        if (jsonEncode(app.buckets.map((b) => b.end).toList()) !=
            jsonEncode(expectedEnds)) _invalid();
      }
      count += device.applications.length;
      if (count > 2000) _invalid();
      devices.add(device);
    }
    return UsageReport(v['generatedAt'], v['from'], v['to'], v['timeZone'],
        v['period'], List.unmodifiable(devices), query.scope);
  }
}

String _seconds(int value) {
  final hours = value ~/ 3600,
      minutes = (value % 3600) ~/ 60,
      seconds = value % 60;
  return [
    if (hours > 0) '$hours 小时',
    if (minutes > 0) '$minutes 分钟',
    if (seconds > 0 || value == 0) '$seconds 秒'
  ].join(' ');
}

String usageRange(UsageReportBucket bucket) {
  if (bucket.lowerMillis == null) return '无观测证据';
  final lower = bucket.lowerMillis!, upper = bucket.upperMillis!;
  if (lower == upper && lower % 1000 == 0) return _seconds(lower ~/ 1000);
  return '${_seconds(lower ~/ 1000)} – ${_seconds((upper + 999) ~/ 1000)}';
}
