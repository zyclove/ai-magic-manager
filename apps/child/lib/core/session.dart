import 'dart:async';
import 'dart:convert';
import 'package:device_identity/device_identity.dart';
import 'package:device_access/device_access.dart' as temporary;
import 'package:device_observation/device_observation.dart' as observation;
import 'package:device_policy/device_policy.dart' as policy;
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'access.dart';

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
  ChildSession(
      {required this.identity,
      this.ruleReceiverFactory,
      this.observations,
      this.observationFactory,
      this.accessFactory,
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
        (_accessIdentityKey != null && _accessIdentityKey != _identityKey)) {
      _clearAccess();
    }
    if (_rulesIdentityKey != null && _rulesIdentityKey != _identityKey) {
      final previous = _receiver;
      _receiver = null;
      _rulesIdentityKey = null;
      rules = const ChildRules();
      if (previous != null) {
        unawaited(previous.close().catchError((Object _) {
          _log.warning('code=RULE_STORE_CLOSE_FAILED');
        }));
      }
    }
  }

  Future<void> _refresh() async {
    final wasReady = credentialReady;
    identityReadSucceeded = false;
    credentialReady = false;
    _pairingCode = null;
    try {
      identityView = await identity.view();
      _pairingCode = _foreground ? await identity.pairingCode() : null;
      credentialReady = await identity.activeCredential() != null;
      identityReadSucceeded = true;
    } on DeviceIdentityFailure catch (failure) {
      if (failure.code == 'IDENTITY_NOT_FOUND') {
        identityView = null;
        _pairingCode = null;
        identityReadSucceeded = true;
      } else {
        rethrow;
      }
    } finally {
      _checkIdentityScope();
      if (!wasReady && credentialReady && accessFactory != null) {
        _accessSyncOnIdle = true;
      }
    }
  }

  Future<void> initialize() async {
    await _run(() async {
      await _refresh();
      if (identityView?.phase == IdentityPhase.active &&
          ruleReceiverFactory != null) {
        rules = await (await _rules()).restore();
      }
      if (accessFactory != null && credentialReady) {
        try {
          access = await (await _access()).restore();
        } catch (_) {
          access = const ChildAccessSnapshot();
          accessErrorCode = 'ACCESS_RESTORE_FAILED';
        }
      }
    });
    initialized = true;
    _changed();
    _accessSyncOnIdle = accessFactory != null && credentialReady;
    _refreshObservationOnIdle = observationFactory != null && credentialReady;
    _drain();
  }

  Future<bool> _run(Future<void> Function() operation,
      {bool observationOperation = false, bool accessOperation = false}) async {
    if (busy || _disposed) return false;
    busy = true;
    errorCode = null;
    if (accessOperation) {
      accessErrorCode = null;
      accessCorrelationId = null;
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
      errorCode = failure.code;
    } on policy.DeviceTransportFailure catch (failure) {
      errorCode = failure.code;
    } on temporary.AccessFailure catch (failure) {
      errorCode = failure.code;
    } on temporary.AccessTransportFailure catch (failure) {
      errorCode = failure.code;
      accessCorrelationId = failure.correlationId;
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
    if (_receiver != null) return _receiver!;
    if (ruleReceiverFactory == null ||
        identityView?.deviceId == null ||
        identityView?.registrationId == null) {
      throw const policy.ConfigurationFailure(
          'CONFIGURATION_TRUST_UNAVAILABLE');
    }
    _rulesIdentityKey = _identityKey;
    return _receiver = await ruleReceiverFactory!(identityView!);
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
      rules = await (await _rules()).restore();
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

  void _drain() {
    if (!initialized || busy || !_foreground || _disposed || !credentialReady) {
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
        final receiver = await _rules();
        try {
          rules = await receiver.synchronize();
          _accessRestoreOnIdle = accessFactory != null;
        } catch (_) {
          // A failed receipt POST can follow a committed signed page. Refresh
          // local facts without pretending the whole synchronization succeeded.
          rules = await receiver.restore();
          _accessRestoreOnIdle = accessFactory != null;
          rethrow;
        }
      });
  Future<void> setForeground(bool value) async {
    _foreground = value;
    if (!value) {
      _accessTimer?.cancel();
      _accessTimer = null;
      _accessReceiver?.pause();
      access = const ChildAccessSnapshot();
      _accessSyncOnIdle = accessFactory != null;
      _observationAgent?.pause();
      _refreshObservationOnIdle = true;
      _pairingCode = null;
      _changed();
      return;
    }
    if (busy || _disposed) return;
    try {
      await _refresh();
    } on DeviceIdentityFailure catch (failure) {
      errorCode = failure.code;
    }
    _changed();
    _accessSyncOnIdle = accessFactory != null;
    _refreshObservationOnIdle = observationFactory != null;
    _drain();
  }

  @override
  void dispose() {
    _disposed = true;
    _clearAccess();
    _pairingCode = null;
    identity.api.close();
    _observationAgent?.close();
    final receiver = _receiver;
    if (receiver != null) {
      unawaited(receiver.close().catchError((Object _) {
        _log.warning('code=RULE_STORE_CLOSE_FAILED');
      }));
    }
    super.dispose();
  }
}
