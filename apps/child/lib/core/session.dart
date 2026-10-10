import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:device_identity/device_identity.dart';
import 'package:device_access/device_access.dart' as temporary;
import 'package:device_observation/device_observation.dart' as observation;
import 'package:device_policy/device_policy.dart' as policy;
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'access.dart';
import 'submissions.dart';

/// Only the administrator-issued ticket is accepted. Service origins, roles,
/// trust keys and local confirmation are never taken from pasted content.
EnrollmentTicket parseRegistrationTicket(String input) {
  try {
    if (input.length > 8192) throw const FormatException();
    final value = jsonDecode(input);
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        !value.keys
            .toSet()
            .containsAll({'tenantId', 'id', 'token', 'expiresAt'}) ||
        value['tenantId'] is! String ||
        value['id'] is! String ||
        value['token'] is! String ||
        value['expiresAt'] is! int) {
      throw const FormatException();
    }
    return EnrollmentTicket(
        tenantId: value['tenantId'],
        enrollmentId: value['id'],
        token: value['token'],
        expiresAt: value['expiresAt']);
  } catch (_) {
    throw const FormatException('Invalid registration ticket');
  }
}

class ChildRules {
  final List<policy.VerifiedConfiguration> configurations;
  final int cursor, pendingReceipts;
  final bool hasMore;
  const ChildRules(
      {this.configurations = const [],
      this.cursor = 0,
      this.pendingReceipts = 0,
      this.hasMore = false});
  bool get systemEnforced => false;
}

abstract interface class ChildRuleReceiver {
  Future<ChildRules> restore();
  Future<ChildRules> synchronize();
  Future<void> close();
}

typedef ChildRuleReceiverFactory = Future<ChildRuleReceiver> Function(
    DeviceIdentityView identity);
typedef ChildObservationFactory = Future<observation.ObservationAgent> Function(
    DeviceIdentityView identity);

/// Foreground child workflow. No adult token, reset, remote policy mutation,
/// automatic enrollment or platform enforcement is exposed by this controller.
class ChildSession extends ChangeNotifier {
  final Logger _log = Logger('child.session');
  final DeviceIdentityManager identity;
  final ChildRuleReceiverFactory? ruleReceiverFactory;
  final Future<List<Map<String, dynamic>>> Function()? observations;
  final ChildObservationFactory? observationFactory;
  final ChildAccessFactory? accessFactory;
  final ChildSubmissionFactory? submissionFactory;
  ChildSubmissionSnapshot submissions = const ChildSubmissionSnapshot();
  String? submissionErrorCode, submissionCorrelationId;
  ChildSubmissions? _submissionReceiver;
  String? _submissionIdentityKey;
  bool _submissionRefreshOnIdle = false;
  int _submissionGeneration = 0;

  /// Forms use this generation to discard private drafts after scope/lifecycle changes.
  int get submissionGeneration => _submissionGeneration;
  bool get foreground => _foreground && !_disposed;
  final int Function() nowMillis;
  ChildAccessSnapshot access = const ChildAccessSnapshot();
  String? accessErrorCode, accessCorrelationId;
  ChildAccessReceiver? _accessReceiver;
  String? _accessIdentityKey, _rulesIdentityKey;
  Timer? _accessTimer;
  bool _accessSyncOnIdle = false, _accessRestoreOnIdle = false;
  int? _accessTimeFloor;
  observation.ObservationView observationView =
      const observation.ObservationView();
  String? observationErrorCode;
  observation.ObservationAgent? _observationAgent;
  bool _refreshObservationOnIdle = false;
  DeviceIdentityView? identityView;
  ChildRules rules = const ChildRules();
  bool initialized = false, busy = false, _foreground = true, _disposed = false;
  bool identityReadSucceeded = false, credentialReady = false;
  String? errorCode, _pairingCode;
  ChildRuleReceiver? _receiver;
  int _rulesGeneration = 0;
  bool _rulesRestoreOnIdle = false, _rulesCloseFailed = false;
  Future<void> _rulesClosing = Future.value();
  // Await only actual close work. An already-completed chain may belong to an
  // earlier async zone and must not delay unrelated request/UI operations.
  int _rulesClosingCount = 0;
  ChildSession(
      {required this.identity,
      this.ruleReceiverFactory,
      this.observations,
      this.observationFactory,
      this.accessFactory,
      this.submissionFactory,
      int Function()? nowMillis})
      : nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);
  String? get pairingCode => _foreground ? _pairingCode : null;
  bool get systemEnforced => false;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  String? get _identityKey => identityView?.deviceId == null ||
          identityView?.registrationId == null
      ? null
      : '${identityView!.tenantId}/${identityView!.deviceId}/${identityView!.registrationId}';
  void _clearAccess() {
    _accessTimer?.cancel();
    _accessTimer = null;
    final receiver = _accessReceiver;
    _accessReceiver = null;
    _accessIdentityKey = null;
    access = const ChildAccessSnapshot();
    _accessTimeFloor = null;
    _accessSyncOnIdle = false;
    _accessRestoreOnIdle = false;
    if (receiver != null) {
      receiver.pause();
      unawaited(receiver.close().catchError((Object _) {
        _log.warning('code=ACCESS_STORE_CLOSE_FAILED');
      }));
    }
  }

  void _checkIdentityScope() {
    if (!credentialReady ||
        !identityReadSucceeded ||
        (_submissionIdentityKey != null &&
            _submissionIdentityKey != _identityKey)) {
      _clearSubmissions();
    }
    if (!credentialReady ||
        !identityReadSucceeded ||
        (_accessIdentityKey != null && _accessIdentityKey != _identityKey)) {
      _clearAccess();
    }
    if (!credentialReady ||
        !identityReadSucceeded ||
        (_rulesIdentityKey != null && _rulesIdentityKey != _identityKey)) {
      _clearRules();
    }
  }

  /// Hide private projections immediately; preserve the signed database. Wait
  /// for the previous owner to close before opening the same SDK database again.
  void _clearRules() {
    _rulesGeneration++;
    final previous = _receiver;
    _receiver = null;
    _rulesIdentityKey = null;
    _rulesRestoreOnIdle = false;
    rules = const ChildRules();
    if (previous != null) {
      _rulesClosingCount++;
      _rulesClosing =
          _rulesClosing.then((_) => previous.close()).catchError((Object _) {
        _rulesCloseFailed = true;
        _log.warning('code=RULE_STORE_CLOSE_FAILED');
      }).whenComplete(() => _rulesClosingCount--);
    }
  }

  Future<void> _refresh() async {
    final wasReady = credentialReady;
    _pairingCode = null;
    try {
      // Publish a complete verified identity snapshot. A slow secure-store read
      // must not look like credential revocation to an in-flight private form.
      // The enclosing action stays busy and cannot mutate before this completes.
      final nextView = await identity.view();
      final nextPairing = _foreground ? await identity.pairingCode() : null;
      final nextReady = await identity.activeCredential() != null;
      identityView = nextView;
      _pairingCode = _foreground ? nextPairing : null;
      credentialReady = nextReady;
      identityReadSucceeded = true;
    } on DeviceIdentityFailure catch (failure) {
      identityReadSucceeded = false;
      credentialReady = false;
      if (failure.code == 'IDENTITY_NOT_FOUND') {
        identityView = null;
        _pairingCode = null;
        identityReadSucceeded = true;
      } else {
        rethrow;
      }
    } catch (_) {
      identityReadSucceeded = false;
      credentialReady = false;
      rethrow;
    } finally {
      _checkIdentityScope();
      if (!wasReady && credentialReady && ruleReceiverFactory != null) {
        _rulesRestoreOnIdle = true;
      }
      if (!wasReady && credentialReady && accessFactory != null) {
        _accessSyncOnIdle = true;
      }
      if (!wasReady && credentialReady && submissionFactory != null) {
        _submissionRefreshOnIdle = true;
      }
    }
  }

  Future<void> initialize() async {
    await _run(() async {
      await _refresh();
      if (identityView?.phase == IdentityPhase.active &&
          ruleReceiverFactory != null) {
        rules = await _readRules();
      }
      if (accessFactory != null && credentialReady) {
        try {
          access = await (await _access()).restore();
        } catch (_) {
          access = const ChildAccessSnapshot();
          accessErrorCode = 'ACCESS_RESTORE_FAILED';
        }
      }
      if (submissionFactory != null && credentialReady) {
        try {
          final generation = _submissionGeneration;
          final restored = await (await _requests()).restore();
          if (foreground && generation == _submissionGeneration) {
            submissions = restored;
          }
        } catch (_) {
          submissions = const ChildSubmissionSnapshot();
          submissionErrorCode = 'SUBMISSION_RESTORE_FAILED';
        }
      }
    });
    if (_disposed) return;
    initialized = true;
    _changed();
    _accessSyncOnIdle = accessFactory != null && credentialReady;
    _refreshObservationOnIdle = observationFactory != null && credentialReady;
    _submissionRefreshOnIdle = submissionFactory != null && credentialReady;
    _drain();
  }

  Future<bool> _run(Future<void> Function() operation,
      {bool observationOperation = false,
      bool accessOperation = false,
      bool submissionOperation = false}) async {
    if (busy || _disposed) return false;
    busy = true;
    errorCode = null;
    if (accessOperation) {
      accessErrorCode = null;
      accessCorrelationId = null;
    }
    if (submissionOperation) {
      submissionErrorCode = null;
      submissionCorrelationId = null;
    }
    _changed();
    var success = false;
    try {
      await operation();
      success = true;
    } on FormatException {
      errorCode = 'INVALID_REGISTRATION_TICKET';
    } on DeviceIdentityFailure catch (failure) {
      errorCode = failure.status == 401 &&
              identityView?.phase == IdentityPhase.awaitingConfirmation
          ? 'AWAITING_GUARDIAN'
          : failure.code;
    } on policy.ConfigurationFailure catch (failure) {
      errorCode = failure.code == 'CONFIGURATION_PAUSED' ? null : failure.code;
    } on policy.DeviceTransportFailure catch (failure) {
      errorCode = failure.code;
    } on temporary.AccessFailure catch (failure) {
      errorCode = failure.code;
    } on temporary.AccessTransportFailure catch (failure) {
      errorCode = failure.code;
      if (submissionOperation) {
        submissionCorrelationId = failure.correlationId;
      } else {
        accessCorrelationId = failure.correlationId;
      }
    } on observation.ObservationFailure catch (failure) {
      errorCode = failure.code;
    } catch (_) {
      errorCode = 'LOCAL_OPERATION_FAILED';
    }
    if (observationOperation) {
      observationErrorCode =
          errorCode == 'OBSERVATION_PAUSED' ? null : errorCode;
      errorCode = null;
    }
    if (accessOperation) {
      accessErrorCode = errorCode == 'ACCESS_PAUSED' ? null : errorCode;
      errorCode = null;
    }
    if (submissionOperation) {
      submissionErrorCode = errorCode == 'SUBMISSION_PAUSED' ? null : errorCode;
      errorCode = null;
    }
    if (_disposed) {
      if (_rulesClosingCount > 0) await _rulesClosing;
      busy = false;
      return false;
    }
    try {
      await _refresh();
    } on DeviceIdentityFailure catch (failure) {
      errorCode = failure.code;
      success = false;
    } catch (_) {
      errorCode = 'LOCAL_OPERATION_FAILED';
      success = false;
    }
    if (errorCode != null) _log.warning('code=$errorCode');
    if (observationOperation && observationErrorCode != null) {
      _log.warning('code=$observationErrorCode');
    }
    if (accessOperation && accessErrorCode != null) {
      _log.warning('code=$accessErrorCode');
    }
    if (submissionOperation && submissionErrorCode != null) {
      _log.warning('code=$submissionErrorCode');
    }
    if (_rulesClosingCount > 0) await _rulesClosing;
    busy = false;
    _changed();
    _scheduleAccess();
    _drain();
    return success;
  }

  Future<bool> pair(String ticket,
          {required String displayName, required String osVersion}) =>
      _run(() => identity.begin(parseRegistrationTicket(ticket),
          displayName: displayName, osVersion: osVersion));
  Future<bool> checkConnection() => _run(() async {
        await identity.heartbeat(
            agentVersion: 'child/0.1.0',
            capabilities: await observations?.call() ?? const []);
        _refreshObservationOnIdle = observationFactory != null;
        _accessSyncOnIdle = accessFactory != null;
        _submissionRefreshOnIdle = submissionFactory != null;
      });
  Future<bool> recoverClaim() => _run(identity.recoverClaim);
  Future<bool> reloadIdentity() => _run(_refresh);
  Future<bool> retryClaim() => _run(identity.retryClaim);
  Future<bool> requestRotation() => _run(identity.rotate);
  Future<bool> cancelRotation() => _run(identity.cancelRotation);
  Future<bool> activateRotation() => _run(identity.activateRotation);

  Future<observation.ObservationAgent> _observer() async {
    if (_observationAgent != null) return _observationAgent!;
    if (observationFactory == null ||
        identityView?.deviceId == null ||
        identityView?.registrationId == null) {
      throw const observation.ObservationFailure(
          'OBSERVATION_NATIVE_UNAVAILABLE');
    }
    return _observationAgent = await observationFactory!(identityView!);
  }

  Future<bool> _observe({required bool collect, bool openSettings = false}) =>
      _run(() async {
        if (!_foreground || !credentialReady) {
          throw const DeviceIdentityFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
        }
        final observer = await _observer();
        if (!_foreground) {
          observer.pause();
          throw const observation.ObservationFailure('OBSERVATION_PAUSED');
        }
        try {
          if (openSettings) {
            await observer.openUsageSettings();
            observationView = await observer.restore();
          } else {
            observationView = await observer.synchronize(collect: collect);
          }
        } catch (_) {
          observationView = await observer.restore();
          rethrow;
        }
      }, observationOperation: true);
  Future<bool> refreshObservationAuthorization() => _observe(collect: false);
  Future<bool> synchronizeObservations() => _observe(collect: true);
  Future<bool> openObservationSettings() =>
      _observe(collect: false, openSettings: true);

  Future<ChildRuleReceiver> _rules() async {
    if (!_foreground || _disposed) {
      throw const policy.ConfigurationFailure('CONFIGURATION_PAUSED');
    }
    if (_receiver != null) return _receiver!;
    if (ruleReceiverFactory == null ||
        !credentialReady ||
        !identityReadSucceeded ||
        identityView?.deviceId == null ||
        identityView?.registrationId == null) {
      throw const policy.ConfigurationFailure(
          'CONFIGURATION_TRUST_UNAVAILABLE');
    }
    final generation = _rulesGeneration, scope = _identityKey;
    if (_rulesClosingCount > 0) await _rulesClosing;
    if (_rulesCloseFailed) {
      throw const policy.ConfigurationFailure('STORAGE_FAILURE');
    }
    _requireRulesCurrent(generation, scope);
    _rulesIdentityKey = scope;
    final receiver = await ruleReceiverFactory!(identityView!);
    try {
      _requireRulesCurrent(generation, scope);
    } catch (_) {
      try {
        await receiver.close();
      } catch (_) {
        _rulesCloseFailed = true;
        _log.warning('code=RULE_STORE_CLOSE_FAILED');
      }
      rethrow;
    }
    return _receiver = receiver;
  }

  void _requireRulesCurrent(int generation, String? scope,
      [ChildRuleReceiver? receiver]) {
    if (_disposed ||
        !_foreground ||
        !credentialReady ||
        !identityReadSucceeded ||
        generation != _rulesGeneration ||
        scope == null ||
        scope != _identityKey ||
        (receiver != null && !identical(receiver, _receiver))) {
      throw const policy.ConfigurationFailure('CONFIGURATION_PAUSED');
    }
  }

  Future<ChildRules> _readRules({bool synchronize = false}) async {
    final generation = _rulesGeneration, scope = _identityKey;
    final receiver = await _rules();
    _requireRulesCurrent(generation, scope, receiver);
    try {
      final next =
          synchronize ? await receiver.synchronize() : await receiver.restore();
      _requireRulesCurrent(generation, scope, receiver);
      _rulesRestoreOnIdle = false;
      return next;
    } catch (error) {
      if (error is DeviceIdentityFailure ||
          error is policy.DeviceTransportFailure &&
              (error.status == 401 ||
                  error.status == 403 ||
                  {'CREDENTIAL_READ_FAILED', 'DEVICE_CREDENTIAL_UNAVAILABLE'}
                      .contains(error.code))) {
        _clearRules();
        rethrow;
      }
      if (synchronize) {
        try {
          // A receipt failure can follow a committed, verified page. Only the
          // current foreground owner may expose that persisted fact.
          _requireRulesCurrent(generation, scope, receiver);
          final stored = await receiver.restore();
          _requireRulesCurrent(generation, scope, receiver);
          rules = stored;
          _accessRestoreOnIdle = accessFactory != null;
        } catch (_) {
          /* Never publish an old owner or replace the first error. */
        }
      }
      rethrow;
    }
  }

  Future<ChildAccessReceiver> _access() async {
    if (!_foreground || _disposed) {
      throw const temporary.AccessFailure('ACCESS_PAUSED');
    }
    if (_accessReceiver != null) return _accessReceiver!;
    if (accessFactory == null || !credentialReady || _identityKey == null) {
      throw const temporary.AccessFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
    }
    final scopeKey = _accessIdentityKey = _identityKey;
    final receiver = await accessFactory!(identityView!, () async {
      rules = await _readRules();
      return rules.configurations;
    });
    if (_disposed ||
        !_foreground ||
        !credentialReady ||
        scopeKey != _identityKey ||
        scopeKey != _accessIdentityKey) {
      receiver.pause();
      try {
        await receiver.close();
      } catch (_) {
        _log.warning('code=ACCESS_STORE_CLOSE_FAILED');
      }
      throw const temporary.AccessFailure('ACCESS_PAUSED');
    }
    return _accessReceiver = receiver;
  }

  bool _fatalAccess(Object error) =>
      error is temporary.AccessTransportFailure &&
          (error.status == 401 ||
              error.status == 403 ||
              {
                'DEVICE_CREDENTIAL_UNAVAILABLE',
                'CREDENTIAL_READ_FAILED',
                'ACCESS_TARGET_CHANGED'
              }.contains(error.code)) ||
      error is temporary.AccessFailure &&
          {'ACCESS_TARGET_CHANGED', 'DEVICE_CREDENTIAL_UNAVAILABLE'}
              .contains(error.code);
  Future<bool> synchronizeAccess() => _run(() async {
        if (!_foreground || !credentialReady) {
          throw const temporary.AccessFailure('ACCESS_PAUSED');
        }
        final receiver = await _access();
        receiver.resume();
        try {
          access = await receiver.synchronize();
        } catch (error) {
          access = const ChildAccessSnapshot();
          if (_fatalAccess(error)) {
            receiver.pause();
          } else if (_foreground && !_disposed) {
            try {
              access = await receiver.restore();
            } catch (_) {/* No unverified fallback. */}
          }
          rethrow;
        }
        if (!_foreground || _disposed) {
          access = const ChildAccessSnapshot();
          return;
        }
        _accessTimeFloor = nowMillis();
      }, accessOperation: true);
  Future<bool> refreshAccess() => _run(() async {
        if (!_foreground || !credentialReady) {
          throw const temporary.AccessFailure('ACCESS_PAUSED');
        }
        try {
          access = await (await _access()).restore();
          _accessTimeFloor = nowMillis();
        } catch (_) {
          access = const ChildAccessSnapshot();
          rethrow;
        }
        if (!_foreground || _disposed) access = const ChildAccessSnapshot();
      }, accessOperation: true);

  void _clearSubmissions() {
    final receiver = _submissionReceiver;
    _submissionReceiver = null;
    _submissionIdentityKey = null;
    _submissionRefreshOnIdle = false;
    _submissionGeneration++;
    submissions = const ChildSubmissionSnapshot();
    if (receiver != null) {
      receiver.pause();
      unawaited(receiver.close().catchError((Object _) {
        _log.warning('code=SUBMISSION_STORE_CLOSE_FAILED');
      }));
    }
  }

  Future<ChildSubmissions> _requests() async {
    if (!foreground) throw const temporary.AccessFailure('SUBMISSION_PAUSED');
    if (_submissionReceiver != null) return _submissionReceiver!;
    if (submissionFactory == null || !credentialReady || _identityKey == null) {
      throw const temporary.AccessFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
    }
    final scope = _submissionIdentityKey = _identityKey;
    final generation = _submissionGeneration;
    final receiver = await submissionFactory!(identityView!);
    if (!foreground ||
        !credentialReady ||
        generation != _submissionGeneration ||
        scope != _identityKey ||
        scope != _submissionIdentityKey) {
      receiver.pause();
      try {
        await receiver.close();
      } catch (_) {
        _log.warning('code=SUBMISSION_STORE_CLOSE_FAILED');
      }
      throw const temporary.AccessFailure('SUBMISSION_PAUSED');
    }
    return _submissionReceiver = receiver;
  }

  Future<bool> _requestAction(
          Future<ChildSubmissionSnapshot> Function(ChildSubmissions) action) =>
      _run(() async {
        if (!foreground) {
          throw const temporary.AccessFailure('SUBMISSION_PAUSED');
        }
        await _refresh();
        final receiver = await _requests();
        final generation = _submissionGeneration;
        receiver.resume();
        try {
          final updated = await action(receiver);
          if (foreground && generation == _submissionGeneration) {
            submissions = updated;
          }
        } catch (error) {
          submissions = const ChildSubmissionSnapshot();
          if (_fatalAccess(error)) {
            receiver.pause();
            _submissionGeneration++;
          } else if (foreground && generation == _submissionGeneration) {
            try {
              final restored = await receiver.restore();
              if (foreground && generation == _submissionGeneration) {
                submissions = restored;
              }
            } catch (_) {/* Never fall back to unverified or old-scope data. */}
          }
          rethrow;
        }
      }, submissionOperation: true);

  String _submissionKey() => base64UrlEncode(
          List<int>.generate(24, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  Future<bool> refreshSubmissions() => _requestAction((r) => r.refresh());
  Future<bool> moreSubmissionOptions() =>
      _requestAction((r) => r.moreOptions());
  Future<bool> moreSubmissions() => _requestAction((r) => r.moreRequests());
  Future<bool> submissionDetail(String id) =>
      _requestAction((r) => r.detail(id));
  Future<bool> createSubmission(temporary.AccessSubmissionInput input,
          {required String applicationName}) =>
      _requestAction((r) => r.create(input,
          applicationName: applicationName, key: _submissionKey()));
  Future<bool> cancelSubmission(temporary.AccessSubmission value,
          {required String applicationName}) =>
      _requestAction((r) => r.cancel(value,
          applicationName: applicationName, key: _submissionKey()));
  Future<bool> retrySubmission() => _requestAction((r) => r.retry());
  Future<bool> discardSubmission() => _requestAction((r) => r.discard());

  void _drain() {
    if (!initialized || busy || !_foreground || _disposed || !credentialReady) {
      return;
    }
    if (_rulesRestoreOnIdle && ruleReceiverFactory != null) {
      _rulesRestoreOnIdle = false;
      unawaited(_run(() async {
        rules = await _readRules();
      }));
      return;
    }
    if (_accessSyncOnIdle && accessFactory != null) {
      _accessSyncOnIdle = false;
      _accessRestoreOnIdle = false;
      unawaited(synchronizeAccess());
      return;
    }
    if (_accessRestoreOnIdle && accessFactory != null) {
      _accessRestoreOnIdle = false;
      unawaited(refreshAccess());
      return;
    }
    if (_submissionRefreshOnIdle && submissionFactory != null) {
      _submissionRefreshOnIdle = false;
      unawaited(refreshSubmissions());
      return;
    }
    if (_refreshObservationOnIdle && observationFactory != null) {
      _refreshObservationOnIdle = false;
      unawaited(refreshObservationAuthorization());
    }
  }

  void _scheduleAccess() {
    _accessTimer?.cancel();
    _accessTimer = null;
    if (_disposed ||
        !_foreground ||
        !credentialReady ||
        accessFactory == null) {
      return;
    }
    try {
      final now = nowMillis();
      if (!temporary.accessInteger(now, 0) ||
          _accessTimeFloor != null && now < _accessTimeFloor!) {
        access = const ChildAccessSnapshot();
        accessErrorCode = 'CLOCK_UNTRUSTED';
        _changed();
        return;
      }
      final ends = access.entries
          .where((e) => e.record.state == temporary.AccessEntryState.stored)
          .map((e) => e.record.window.absoluteNotAfter)
          .toList()
        ..sort();
      if (ends.isEmpty) return;
      var delay = ends.first - now;
      if (delay < 1) delay = 1;
      if (delay > 30000) delay = 30000;
      _accessTimer = Timer(Duration(milliseconds: delay), () {
        if (_disposed || !_foreground) return;
        try {
          final current = nowMillis();
          if (!temporary.accessInteger(current, 0) ||
              _accessTimeFloor != null && current < _accessTimeFloor!) {
            access = const ChildAccessSnapshot();
            accessErrorCode = 'CLOCK_UNTRUSTED';
            _changed();
            return;
          } else {
            access = ChildAccessSnapshot(
                contextReady: access.contextReady,
                onlineConfirmed: access.onlineConfirmed,
                lastOnlineAt: access.lastOnlineAt,
                pendingReceipts: access.pendingReceipts,
                issues: access.issues,
                hasMore: access.hasMore,
                entries: List.unmodifiable(access.entries.map((e) =>
                    e.record.state == temporary.AccessEntryState.stored &&
                            current >= e.record.window.absoluteNotAfter
                        ? ChildAccessEntry(
                            temporary.AccessJournalEntry(e.record.window,
                                temporary.AccessEntryState.expired,
                                pendingAcknowledgement:
                                    e.record.pendingAcknowledgement,
                                reasonCode: e.record.reasonCode),
                            e.applicationName,
                            requiresReview: e.requiresReview)
                        : e)));
          }
        } catch (_) {
          access = const ChildAccessSnapshot();
          accessErrorCode = 'CLOCK_UNTRUSTED';
          _changed();
          return;
        }
        _changed();
        _accessRestoreOnIdle = true;
        _drain();
      });
    } catch (_) {
      access = const ChildAccessSnapshot();
      accessErrorCode = 'CLOCK_UNTRUSTED';
      _changed();
    }
  }

  Future<bool> synchronizeRules() => _run(() async {
        if (await identity.activeCredential() == null) {
          throw const DeviceIdentityFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
        }
        rules = await _readRules(synchronize: true);
        _accessRestoreOnIdle = accessFactory != null;
      });
  Future<void> setForeground(bool value) async {
    if (_disposed) return;
    _foreground = value;
    if (!value) {
      _rulesGeneration++;
      rules = const ChildRules();
      _rulesRestoreOnIdle = ruleReceiverFactory != null;
      _accessTimer?.cancel();
      _accessTimer = null;
      _accessReceiver?.pause();
      access = const ChildAccessSnapshot();
      _accessSyncOnIdle = accessFactory != null;
      _submissionReceiver?.pause();
      submissions = const ChildSubmissionSnapshot();
      _submissionGeneration++;
      _submissionRefreshOnIdle = submissionFactory != null;
      _observationAgent?.pause();
      _refreshObservationOnIdle = true;
      _pairingCode = null;
      _changed();
      return;
    }
    _rulesRestoreOnIdle = ruleReceiverFactory != null;
    if (busy) return;
    try {
      await _refresh();
    } on DeviceIdentityFailure catch (failure) {
      errorCode = failure.code;
    }
    _changed();
    _accessSyncOnIdle = accessFactory != null;
    _refreshObservationOnIdle = observationFactory != null;
    _submissionRefreshOnIdle = submissionFactory != null;
    _drain();
  }

  @override
  void dispose() {
    _disposed = true;
    _clearAccess();
    _clearSubmissions();
    _clearRules();
    _pairingCode = null;
    identity.api.close();
    _observationAgent?.close();
    super.dispose();
  }
}
