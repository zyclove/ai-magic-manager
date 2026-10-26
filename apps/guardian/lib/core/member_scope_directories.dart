import 'api.dart';

enum MemberScopeDirectory { subjects, classes }

/// Option caches belong to one captured member flow, never a global directory.
class MemberScopeDirectories {
  final String _root;
  final bool Function() _parentCurrent;
  late final Api _api;
  final _cache = <MemberScopeDirectory, Map<String, String>>{};
  final _pending = <MemberScopeDirectory, Future<void>>{};
  bool _revoked = false;

  MemberScopeDirectories({required Api api, required String root,
      required bool Function() current})
      : _root = root, _parentCurrent = current {
    _api = api.scoped(_isCurrent);
    _isCurrent();
  }

  Map<String, String>? get subjects => _read(MemberScopeDirectory.subjects);
  Map<String, String>? get classes => _read(MemberScopeDirectory.classes);
  bool get current => _isCurrent();

  bool _isCurrent() {
    if (_revoked) return false;
    try {
      if (_parentCurrent()) return true;
    } catch (_) {
      // A disposed or otherwise unavailable owner cannot restore old options.
    }
    revoke();
    return false;
  }

  void _requireCurrent() {
    if (!_isCurrent()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Map<String, String>? _read(MemberScopeDirectory directory) =>
      _isCurrent() ? _cache[directory] : null;

  Future<void> load(MemberScopeDirectory directory, {bool refresh = false}) async {
    _requireCurrent();
    final pending = _pending[directory];
    if (pending != null) {
      await pending;
      return;
    }
    if (!refresh && _cache.containsKey(directory)) return;
    late final Future<void> read;
    read = _fetch(directory).whenComplete(() {
      if (identical(_pending[directory], read)) _pending.remove(directory);
    });
    _pending[directory] = read;
    await read;
  }

  Future<void> _fetch(MemberScopeDirectory directory) async {
    try {
      final rows = await _api.all('$_root/${directory.name}');
      _requireCurrent();
      final projected = _options(rows, directory);
      _requireCurrent();
      _cache[directory] = projected;
    } catch (failure) {
      if (failure is ApiFailure &&
          (failure.code == 'WORKSPACE_CHANGED' || failure.status == 403 ||
              (failure.status == 401 && failure.code != 'REAUTH_REQUIRED'))) {
        revoke();
      }
      rethrow;
    }
  }

  static Map<String, String> _options(
      List<Json> rows, MemberScopeDirectory directory) {
    final subjects = directory == MemberScopeDirectory.subjects;
    final label = subjects ? 'nickname' : 'name';
    final maximumNameLength = subjects ? 60 : 100;
    final ids = <String>{};
    final options = <String, String>{};
    for (final row in rows) {
      final id = row['id'], name = row[label];
      if (id is! String || id.trim().isEmpty || id.length > 100 ||
          !ids.add(id) || name is! String || name.trim().isEmpty ||
          name.length > maximumNameLength) {
        throw const ApiFailure(502, 'INVALID_MEMBER_SCOPE_OPTIONS');
      }
      final archived = subjects
          ? row['archived'] == true || row['archivedAt'] != null
          : row['state'] == 'ARCHIVED';
      if (!archived) options[id] = name;
    }
    return Map<String, String>.unmodifiable(options);
  }

  void revoke() {
    _revoked = true;
    _cache.clear();
  }
}
