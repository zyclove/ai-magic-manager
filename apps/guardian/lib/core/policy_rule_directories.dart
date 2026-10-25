import 'api.dart';

enum _Directory {
  applications('applications', 'displayName'),
  schedules('schedules', 'name');

  final String path, label;
  const _Directory(this.path, this.label);
}

/// Small, lifetime-bound option caches for the policy rule editor.
/// Missing, successful-empty and failed reads remain distinct states.
class PolicyRuleDirectories {
  final String _root;
  final bool Function() _parentCurrent;
  late final Api _api;
  final _cache = <_Directory, List<Json>>{};
  final _pending = <_Directory, Future<void>>{};
  final _requested = <_Directory>{};
  bool _revoked = false;

  PolicyRuleDirectories({
    required Api api,
    required String root,
    required bool Function() current,
    List<Json>? applications,
    List<Json>? schedules,
  })  : _root = root,
        _parentCurrent = current {
    _api = api.scoped(_isCurrent);
    if (!_isCurrent()) return;
    if (applications != null) {
      _cache[_Directory.applications] =
          _options(applications, _Directory.applications);
    }
    if (schedules != null) {
      _cache[_Directory.schedules] = _options(schedules, _Directory.schedules);
    }
  }

  List<Json> get applications => _readCache(_Directory.applications);
  List<Json> get schedules => _readCache(_Directory.schedules);
  bool get hasRequested => _isCurrent() && _requested.isNotEmpty;

  bool _isCurrent() {
    if (_revoked) return false;
    try {
      if (_parentCurrent()) return true;
    } catch (_) {
      // A lost owner cannot make its old option data usable again.
    }
    revoke();
    return false;
  }

  void _requireCurrent() {
    if (!_isCurrent()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  List<Json> _readCache(_Directory directory) =>
      _isCurrent() ? _cache[directory] ?? const <Json>[] : const <Json>[];

  Future<void> forRule(String kind) async {
    _requireCurrent();
    if (kind == 'DOMAIN_ACCESS') return;
    if (!const {
      'APP_LAUNCH',
      'APP_INSTALL',
      'APP_UNINSTALL',
      'RUNTIME_PERMISSION',
      'SPECIAL_ACCESS',
      'DAILY_QUOTA',
      'TIME_WINDOW',
      'USAGE_REMINDER'
    }.contains(kind)) {
      throw const ApiFailure(400, 'INVALID_RULE_KIND');
    }
    await Future.wait<void>([
      _load(_Directory.applications),
      if (kind == 'TIME_WINDOW') _load(_Directory.schedules),
    ], eagerError: true);
  }

  Future<void> forReferences(Iterable<Json> rules) async {
    _requireCurrent();
    var applications = false, schedules = false;
    for (final rule in rules) {
      final app = rule['applicationId'], schedule = rule['scheduleId'];
      applications |= app is String && app.isNotEmpty;
      schedules |= schedule is String && schedule.isNotEmpty;
    }
    await Future.wait<void>([
      if (applications) _load(_Directory.applications),
      if (schedules) _load(_Directory.schedules),
    ], eagerError: true);
  }

  Future<void> reloadRequested() async {
    _requireCurrent();
    await Future.wait<void>([
      for (final directory in _requested.toList())
        _load(directory, refresh: true),
    ], eagerError: true);
  }

  Future<void> _load(_Directory directory, {bool refresh = false}) {
    _requireCurrent();
    _requested.add(directory);
    final pending = _pending[directory];
    if (pending != null) return pending;
    if (!refresh && _cache.containsKey(directory)) return Future<void>.value();
    late final Future<void> read;
    read = _fetch(directory).whenComplete(() {
      if (identical(_pending[directory], read)) _pending.remove(directory);
    });
    _pending[directory] = read;
    return read;
  }

  Future<void> _fetch(_Directory directory) async {
    try {
      final rows = await _api.all('$_root/${directory.path}');
      _requireCurrent();
      final projected = _options(rows, directory);
      _requireCurrent();
      _cache[directory] = projected;
    } catch (failure) {
      if (failure is ApiFailure &&
          (failure.code == 'WORKSPACE_CHANGED' ||
              failure.status == 403 ||
              (failure.status == 401 && failure.code != 'REAUTH_REQUIRED'))) {
        revoke();
      }
      rethrow;
    }
  }

  static List<Json> _options(List<Json> rows, _Directory directory) {
    final ids = <String>{};
    final options = <Json>[];
    for (final row in rows) {
      final id = row['id'], label = row[directory.label];
      if (id is! String ||
          id.trim().isEmpty ||
          id.length > 100 ||
          !ids.add(id) ||
          label is! String ||
          label.trim().isEmpty ||
          label.length > 100) {
        throw const ApiFailure(502, 'INVALID_POLICY_DIRECTORY_RESPONSE');
      }
      options.add(Map<String, dynamic>.unmodifiable(
          {'id': id, directory.label: label}));
    }
    return List<Json>.unmodifiable(options);
  }

  void revoke() {
    _revoked = true;
    _cache.clear();
    _requested.clear();
  }
}
