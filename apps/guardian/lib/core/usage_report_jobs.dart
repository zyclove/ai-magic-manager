import 'dart:convert';
import 'dart:typed_data';
import 'api.dart';
import 'bounded_json.dart';
import 'usage_reports.dart';

const usageReportJobRoles = {'OWNER', 'GUARDIAN', 'ORG_ADMIN'};
final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
Never _invalid() => throw const ApiFailure(502, 'INVALID_REPORT_JOB_RESPONSE');
bool _keys(dynamic v, Set<String> keys) =>
    v is Json && v.length == keys.length && v.keys.every(keys.contains);
bool _number(dynamic v, {int max = 8640000000000000}) =>
    v is int && v >= 0 && v <= max;
bool _id(dynamic v) => v is String && _uuid.hasMatch(v);

class UsageReportJobDraft {
  final List<String> deviceIds;
  final int from, to;
  final String timeZone, period;
  final UsageReportScope scope;
  UsageReportJobDraft(
      {required Iterable<String> deviceIds,
      required this.from,
      required this.to,
      required this.timeZone,
      required this.period,
      this.scope = const UsageReportScope.devices()})
      : deviceIds = List.unmodifiable(deviceIds.toList()..sort()) {
    if (this.deviceIds.isEmpty ||
        this.deviceIds.length > 200 ||
        this.deviceIds.toSet().length != this.deviceIds.length ||
        this.deviceIds.any((id) => !_id(id)) ||
        !_number(from) ||
        !_number(to) ||
        from >= to ||
        to - from > 32 * 86400000 ||
        !{'DAY', 'WEEK'}.contains(period)) {
      throw const ApiFailure(400, 'INVALID_REPORT_JOB_SELECTION');
    }
    try {
      usageLocation(timeZone);
    } catch (_) {
      throw const ApiFailure(400, 'INVALID_TIME_ZONE');
    }
  }
  Json get body => {
        'deviceIds': deviceIds,
        'from': from,
        'to': to,
        'timeZone': timeZone,
        'period': period,
        'scope': {'kind': scope.kind, 'id': scope.id, 'version': scope.version}
      };
  static UsageReportJobDraft parse(dynamic value) {
    if (!_keys(value,
            {'deviceIds', 'from', 'to', 'timeZone', 'period', 'scope'}) ||
        value['deviceIds'] is! List ||
        (value['deviceIds'] as List).any((v) => !_id(v)) ||
        !_number(value['from']) ||
        !_number(value['to']) ||
        value['timeZone'] is! String ||
        value['period'] is! String ||
        !_keys(value['scope'], {'kind', 'id', 'version'})) _invalid();
    final s = value['scope'];
    try {
      final scope =
          s['kind'] == 'DEVICES' && s['id'] == null && s['version'] == null
              ? const UsageReportScope.devices()
              : UsageReportScope(
                  kind: s['kind'],
                  id: s['id'],
                  version: s['version'],
                  label: s['kind'] == 'CLASS' ? '班级范围' : '儿童范围');
      return UsageReportJobDraft(
          deviceIds: (value['deviceIds'] as List).cast<String>(),
          from: value['from'],
          to: value['to'],
          timeZone: value['timeZone'],
          period: value['period'],
          scope: scope);
    } catch (_) {
      _invalid();
    }
  }
}

class UsageReportJobPart {
  final int ordinal, authorizationVersion;
  final String deviceId, registrationId, subjectId;
  final bool usageEnabled;
  final int? byteCount, generatedAt;
  const UsageReportJobPart(
      this.ordinal,
      this.deviceId,
      this.registrationId,
      this.subjectId,
      this.authorizationVersion,
      this.usageEnabled,
      this.byteCount,
      this.generatedAt);
  static UsageReportJobPart parse(dynamic value) {
    if (!_keys(value, {
          'ordinal',
          'deviceId',
          'registrationId',
          'subjectId',
          'authorizationVersion',
          'usageEnabled',
          'byteCount',
          'generatedAt'
        }) ||
        !_number(value['ordinal'], max: 199) ||
        !_id(value['deviceId']) ||
        !_id(value['registrationId']) ||
        !_id(value['subjectId']) ||
        !_number(value['authorizationVersion'], max: 9007199254740991) ||
        value['usageEnabled'] is! bool ||
        (value['byteCount'] == null) != (value['generatedAt'] == null) ||
        (value['byteCount'] != null &&
            (!_number(value['byteCount'], max: 8 * 1024 * 1024) ||
                value['byteCount'] == 0 ||
                !_number(value['generatedAt'])))) _invalid();
    return UsageReportJobPart(
        value['ordinal'],
        value['deviceId'],
        value['registrationId'],
        value['subjectId'],
        value['authorizationVersion'],
        value['usageEnabled'],
        value['byteCount'],
        value['generatedAt']);
  }
}

class UsageReportJob {
  final String id, state;
  final int createdAt,
      updatedAt,
      expiresAt,
      totalDevices,
      completedDevices,
      byteCount;
  final String? failureCode;
  final UsageReportJobDraft selection;
  final List<UsageReportJobPart> parts;
  UsageReportJob._(
      this.id,
      this.state,
      this.createdAt,
      this.updatedAt,
      this.expiresAt,
      this.totalDevices,
      this.completedDevices,
      this.byteCount,
      this.failureCode,
      this.selection,
      List<UsageReportJobPart> parts)
      : parts = List.unmodifiable(parts);
  bool get pending => state == 'QUEUED' || state == 'RUNNING';
  bool get ready => state == 'READY';
  bool get cancellable => pending || ready;
  String get title => const {
        'QUEUED': '等待生成',
        'RUNNING': '正在生成',
        'READY': '已生成',
        'FAILED': '生成失败',
        'CANCELLED': '已取消',
        'EXPIRED': '已到期',
        'REVOKED': '访问已失效'
      }[state]!;
  static UsageReportJob parse(dynamic value) {
    if (!_keys(value, {
          'id',
          'state',
          'createdAt',
          'updatedAt',
          'expiresAt',
          'totalDevices',
          'completedDevices',
          'byteCount',
          'failureCode',
          'selection',
          'parts'
        }) ||
        !_id(value['id']) ||
        !{
          'QUEUED',
          'RUNNING',
          'READY',
          'FAILED',
          'CANCELLED',
          'EXPIRED',
          'REVOKED'
        }.contains(value['state']) ||
        ![
          'createdAt',
          'updatedAt',
          'expiresAt',
          'totalDevices',
          'completedDevices',
          'byteCount'
        ].every((k) => _number(value[k])) ||
        value['totalDevices'] < 1 ||
        value['totalDevices'] > 200 ||
        value['completedDevices'] > value['totalDevices'] ||
        value['byteCount'] > 128 * 1024 * 1024 ||
        value['updatedAt'] < value['createdAt'] ||
        value['expiresAt'] != value['createdAt'] + 86400000 ||
        value['parts'] is! List ||
        (value['failureCode'] != null &&
            (value['failureCode'] is! String ||
                !RegExp(r'^[A-Z][A-Z0-9_]{0,99}$')
                    .hasMatch(value['failureCode'])))) _invalid();
    final selection = UsageReportJobDraft.parse(value['selection']),
        parts = (value['parts'] as List).map(UsageReportJobPart.parse).toList();
    if (selection.to > value['createdAt'] ||
        parts.length != value['totalDevices'] ||
        parts.length != selection.deviceIds.length) _invalid();
    int bytes = 0, completed = 0;
    for (int i = 0; i < parts.length; i++) {
      final p = parts[i];
      if (p.ordinal != i ||
          p.deviceId != selection.deviceIds[i] ||
          (selection.scope.kind == 'SUBJECT' &&
              p.subjectId != selection.scope.id)) _invalid();
      if (p.generatedAt != null) {
        if (i != completed ||
            p.generatedAt! < value['createdAt'] ||
            p.generatedAt! > value['updatedAt']) _invalid();
        completed++;
        bytes += p.byteCount!;
      }
    }
    if (completed != value['completedDevices'] ||
        bytes != value['byteCount'] ||
        (value['state'] == 'READY' && completed != parts.length) ||
        ({'QUEUED', 'RUNNING'}.contains(value['state']) &&
            completed == parts.length)) _invalid();
    return UsageReportJob._(
        value['id'],
        value['state'],
        value['createdAt'],
        value['updatedAt'],
        value['expiresAt'],
        value['totalDevices'],
        value['completedDevices'],
        value['byteCount'],
        value['failureCode'],
        selection,
        parts);
  }
}

class UsageReportJobPage {
  final List<UsageReportJob> items;
  final String? nextCursor;
  UsageReportJobPage(List<UsageReportJob> items, this.nextCursor)
      : items = List.unmodifiable(items);
}

class UsageReportJobRepository {
  final Api api;
  final String root;
  final bool Function() current;
  UsageReportJobRepository(
      {required this.api, required this.root, required this.current});
  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<dynamic> _send(String method, String suffix,
          {Json? body, String? key, int status = 200}) =>
      boundedJson(api, method, '$root/usage-report-jobs$suffix',
          body: body,
          key: key,
          successStatus: status,
          ensureCurrent: ensureCurrent);
  Future<UsageReportJob> create(UsageReportJobDraft draft, String key) async {
    final result = UsageReportJob.parse(
        await _send('POST', '', body: draft.body, key: key, status: 202));
    final expected = {
      ...draft.body,
      'to': draft.to < result.createdAt ? draft.to : result.createdAt
    };
    if (jsonEncode(result.selection.body) != jsonEncode(expected)) _invalid();
    return result;
  }

  Future<UsageReportJob> get(String id) async {
    if (!_id(id)) _invalid();
    final job = UsageReportJob.parse(await _send('GET', '/$id'));
    if (job.id != id) _invalid();
    return job;
  }

  Future<UsageReportJob> cancel(String id) async {
    if (!_id(id)) _invalid();
    final job = UsageReportJob.parse(await _send('POST', '/$id/cancel'));
    if (job.id != id || job.cancellable) _invalid();
    return job;
  }

  Future<UsageReportJobPage> load({String? cursor}) async {
    if (cursor != null && !_id(cursor)) _invalid();
    final value = await _send(
        'GET', '?limit=20${cursor == null ? '' : '&cursor=$cursor'}');
    if (!_keys(value, {'items', 'nextCursor'}) ||
        value['items'] is! List ||
        (value['items'] as List).length > 20 ||
        (value['nextCursor'] != null &&
            (!_id(value['nextCursor']) || value['nextCursor'] == cursor))) {
      _invalid();
    }
    final items = (value['items'] as List).map(UsageReportJob.parse).toList();
    if (value['nextCursor'] != null &&
        (items.length != 20 || items.last.id != value['nextCursor'])) {
      _invalid();
    }
    final ids = <String>{};
    UsageReportJob? previous;
    for (final job in items) {
      if (!ids.add(job.id) ||
          (previous != null &&
              (previous.createdAt < job.createdAt ||
                  (previous.createdAt == job.createdAt &&
                      previous.id.compareTo(job.id) <= 0)))) _invalid();
      previous = job;
    }
    return UsageReportJobPage(items, value['nextCursor']);
  }

  Future<UsageReport> result(UsageReportJob job, UsageReportJobPart part,
          UsageReportTarget target) async =>
      (await _read(job, part, target)).report;

  Future<Uint8List> download(UsageReportJob job, UsageReportJobPart part,
      UsageReportTarget target) async {
    final result = await _read(job, part, target);
    ensureCurrent();
    final bytes = utf8.encode(jsonEncode(result.body));
    if (bytes.length > 8 * 1024 * 1024) _invalid();
    return Uint8List.fromList(bytes);
  }

  Future<({UsageReport report, Json body})> _read(UsageReportJob job,
      UsageReportJobPart part, UsageReportTarget target) async {
    ensureCurrent();
    if (!job.ready ||
        part.ordinal >= job.parts.length ||
        !identical(job.parts[part.ordinal], part) ||
        target.deviceId != part.deviceId ||
        target.registrationId != part.registrationId ||
        target.subjectId != part.subjectId ||
        !target.valid) _invalid();
    final s = job.selection.scope;
    final scope = s.kind == 'DEVICES'
        ? s
        : UsageReportScope(
            kind: s.kind,
            id: s.id,
            version: s.version,
            label: s.label,
            subjectIds: job.parts.map((p) => p.subjectId));
    final query = UsageReportQuery(
        targets: [target],
        from: job.selection.from,
        to: job.selection.to,
        timeZone: job.selection.timeZone,
        period: job.selection.period,
        scope: scope);
    final value = await boundedJson(
        api, 'GET', '$root/usage-report-jobs/${job.id}/parts/${part.ordinal}',
        maxBytes: 8 * 1024 * 1024,
        expectedBytes: part.byteCount,
        ensureCurrent: ensureCurrent);
    try {
      final report = UsageReport.parse(value, query),
          device = report.devices.single;
      if (report.generatedAt != part.generatedAt ||
          device.authorizationVersion != part.authorizationVersion ||
          (device.status == 'NOT_AUTHORIZED') == part.usageEnabled) _invalid();
      return (report: report, body: value as Json);
    } on UsageReportFailure catch (e) {
      throw ApiFailure(e.status, e.code);
    }
  }
}
