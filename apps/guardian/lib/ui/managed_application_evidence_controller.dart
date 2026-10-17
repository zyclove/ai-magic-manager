import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/managed_application_evidence.dart';

/// A single application check in one fixed binding and authorization lifetime.
/// Requests are explicit; a timer can update presentation but never send HTTP.
class ManagedApplicationEvidenceController extends ChangeNotifier {
  final ManagedApplicationEvidenceRepository repository;
  final bool Function() current;
  final Listenable? accessChanges;
  final DateTime Function() clock;
  late final ManagedApplicationEvidenceRepository _requests =
      repository.scoped(_requestCurrent, onDenied: _onDenied);

  List<ManagedEvidenceApplication> _items = const [];
  String? _nextCursor;
  ManagedEvidenceApplication? _selected;
  ManagedApplicationEvidence? _evidence;
  Object? _error;
  bool _busy = false;
  bool _active = true;
  bool _disposed = false;
  bool _unknownOutcome = false;
  bool _needsReauth = false;
  bool _needsParentRefresh = false;
  bool _requiresRead = false;
  int _generation = 0;
  Timer? _transitionTimer;

  ManagedApplicationEvidenceController(
      {required this.repository,
      required this.current,
      this.accessChanges,
      DateTime Function()? clock})
      : clock = clock ?? DateTime.now {
    accessChanges?.addListener(_accessChanged);
    _accessCurrent();
  }

  List<ManagedEvidenceApplication> get items {
    _accessCurrent();
    return _items;
  }

  String? get nextCursor {
    _accessCurrent();
    return _nextCursor;
  }

  ManagedEvidenceApplication? get selected {
    _accessCurrent();
    return _selected;
  }

  ManagedApplicationEvidence? get evidence {
    _accessCurrent();
    return _evidence;
  }

  Object? get error => _error;
  bool get busy => hasAccess && _busy;
  bool get hasAccess => _accessCurrent();
  bool get unknownOutcome => _unknownOutcome;
  bool get needsReauth => _needsReauth;
  bool get needsParentRefresh => _needsParentRefresh;

  bool get canCheck =>
      hasAccess && !_busy && !_needsParentRefresh && _selected != null;

  bool get canRefresh {
    if (!canCheck ||
        _unknownOutcome ||
        _requiresRead ||
        _needsReauth ||
        _evidence == null ||
        _evidence!.state == 'PENDING') {
      return false;
    }
    final next = _evidence!.nextRefreshAt;
    return next == null || next <= clock().millisecondsSinceEpoch;
  }

  bool get canChoose =>
      hasAccess &&
      !_busy &&
      !_needsParentRefresh &&
      !_unknownOutcome &&
      !_requiresRead &&
      _evidence?.state != 'PENDING';

  bool _accessCurrent({bool notify = false}) {
    if (_disposed || !_active) {
      return false;
    }
    if (!current() || !repository.isCurrent) {
      _revoke(const ApiFailure(409, 'WORKSPACE_CHANGED'), notify: notify);
      return false;
    }
    return true;
  }

  // This guard also wraps the borrowed Api, so invalidation while awaiting an
  // authenticated client or token still blocks the eventual physical dispatch.
  bool _requestCurrent() =>
      _accessCurrent(notify: true) && !_needsParentRefresh;

  void _accessChanged() {
    _accessCurrent(notify: true);
  }

  void _onDenied(ApiFailure failure) {
    if (_disposed || !_active) {
      return;
    }
    _revoke(failure);
  }

  void _clearEvidence() {
    _transitionTimer?.cancel();
    _transitionTimer = null;
    _evidence = null;
  }

  void _clearPrivateState() {
    _clearEvidence();
    _items = const [];
    _nextCursor = null;
    _selected = null;
    _unknownOutcome = false;
    _requiresRead = false;
    _needsReauth = false;
  }

  void _revoke(ApiFailure failure, {bool notify = true}) {
    if (_disposed || !_active) {
      return;
    }
    _active = false;
    _generation++;
    _busy = false;
    accessChanges?.removeListener(_accessChanged);
    _clearPrivateState();
    if (!_needsParentRefresh) {
      _error = failure;
    }
    if (notify) {
      notifyListeners();
    }
  }

  void invalidate() => _revoke(const ApiFailure(409, 'WORKSPACE_CHANGED'));

  Future<void> loadApplications() async {
    if (!canChoose) {
      return;
    }
    _clearPrivateState();
    await _run<ManagedEvidenceApplicationPage>(
        repositoryCall: () => _requests.applicationPage(),
        accept: (page) {
          _items = List.unmodifiable(page.items);
          _nextCursor = page.nextCursor;
        });
  }

  Future<void> loadMore() async {
    if (!canChoose || _nextCursor == null) {
      return;
    }
    final cursor = _nextCursor!;
    await _run<ManagedEvidenceApplicationPage>(
        repositoryCall: () => _requests.applicationPage(cursor: cursor),
        accept: (page) {
          final ids = _items.map((item) => item.id).toSet();
          _items = List.unmodifiable(
              [..._items, ...page.items.where((item) => ids.add(item.id))]);
          _nextCursor = page.nextCursor;
        });
  }

  Future<void> selectApplication(ManagedEvidenceApplication application) async {
    if (!canChoose ||
        !_items.any((item) => identical(item, application)) ||
        identical(_selected, application)) {
      return;
    }
    _selected = application;
    _clearEvidence();
    await _read(application.id);
  }

  Future<void> check() async {
    if (!canCheck) {
      return;
    }
    final applicationId = _selected!.id;
    _clearEvidence();
    await _read(applicationId);
  }

  Future<void> _read(String applicationId) => _run<ManagedApplicationEvidence>(
      repositoryCall: () => _requests.read(applicationId),
      accept: _acceptEvidence);

  Future<void> refresh() async {
    if (!canRefresh) {
      return;
    }
    final applicationId = _selected!.id;
    _clearEvidence();
    await _run<ManagedApplicationEvidence>(
        repositoryCall: () => _requests.refresh(applicationId),
        accept: _acceptEvidence,
        write: true);
  }

  void _acceptEvidence(ManagedApplicationEvidence value) {
    _evidence = value;
    _unknownOutcome = false;
    _requiresRead = false;
    _needsReauth = false;
  }

  bool _canComplete(int generation) =>
      _requestCurrent() && generation == _generation;

  Future<void> _run<T>(
      {required Future<T> Function() repositoryCall,
      required void Function(T) accept,
      bool write = false}) async {
    final generation = ++_generation;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final result = await repositoryCall();
      if (_canComplete(generation)) {
        accept(result);
      }
    } catch (failure) {
      if (_canComplete(generation)) {
        _receiveFailure(failure, write: write);
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _busy = false;
        _scheduleTransition();
        notifyListeners();
      }
    }
  }

  void _receiveFailure(Object failure, {required bool write}) {
    _error = failure;
    if (failure is ApiFailure) {
      if ((failure.status == 401 && failure.code != 'REAUTH_REQUIRED') ||
          failure.status == 403 ||
          (failure.status == 409 && failure.code == 'WORKSPACE_CHANGED')) {
        _revoke(failure);
        return;
      }
      if (failure.status == 412) {
        _needsParentRefresh = true;
        _clearPrivateState();
        return;
      }
      if (failure.status == 401 && failure.code == 'REAUTH_REQUIRED') {
        _needsReauth = true;
        if (write) {
          _unknownOutcome = false;
        }
        return;
      }
      if (write && failure.status == 429) {
        _requiresRead = true;
        return;
      }
      if (write && (failure.status == 0 || failure.status >= 500)) {
        _unknownOutcome = true;
        _requiresRead = true;
      }
    } else if (write) {
      _unknownOutcome = true;
      _requiresRead = true;
    }
  }

  void _scheduleTransition() {
    _transitionTimer?.cancel();
    _transitionTimer = null;
    final value = _evidence;
    if (!_requestCurrent() || value == null) {
      return;
    }
    final now = clock().millisecondsSinceEpoch;
    final deadlines = [
      if (value.state == 'VERIFIED_IDENTITY') value.expiresAt,
      value.nextRefreshAt
    ].whereType<int>().where((deadline) => deadline > now).toList()
      ..sort();
    if (deadlines.isEmpty) {
      return;
    }
    final deadline = deadlines.first;
    // Very distant server dates must not overflow browser timer limits. A
    // bounded wake-up only rechecks the clock; it cannot query the server.
    final remaining = deadline - now;
    const maximumDelay = Duration.millisecondsPerDay;
    _transitionTimer = Timer(
        Duration(
            milliseconds: remaining > maximumDelay ? maximumDelay : remaining),
        () {
      _transitionTimer = null;
      if (!_requestCurrent()) {
        return;
      }
      if (clock().millisecondsSinceEpoch >= deadline) {
        notifyListeners();
      }
      _scheduleTransition();
    });
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _active = false;
    _generation++;
    _busy = false;
    accessChanges?.removeListener(_accessChanged);
    _clearPrivateState();
    _error = null;
    super.dispose();
  }
}
