import 'dart:async';
import 'dart:convert';
import 'package:device_identity/device_identity.dart';
import 'package:device_observation/device_observation.dart' as observation;
import 'package:device_policy/device_policy.dart' as policy;
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

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
      this.observationFactory});
  String? get pairingCode => _foreground ? _pairingCode : null;
  bool get systemEnforced => false;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _refresh() async {
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
    }
  }

  Future<void> initialize() async {
    await _run(() async {
      await _refresh();
      if (identityView?.phase == IdentityPhase.active &&
          ruleReceiverFactory != null) {
        rules = await (await _rules()).restore();
      }
    });
    initialized = true;
    _changed();
    if (observationFactory != null &&
        credentialReady &&
        !_disposed &&
        _foreground) {
      unawaited(refreshObservationAuthorization());
    }
  }

  Future<bool> _run(Future<void> Function() operation,
      {bool observationOperation = false}) async {
    if (busy || _disposed) return false;
    busy = true;
    errorCode = null;
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
    busy = false;
    _changed();
    if (_refreshObservationOnIdle &&
        _foreground &&
        !_disposed &&
        observationFactory != null &&
        credentialReady) {
      _refreshObservationOnIdle = false;
      unawaited(refreshObservationAuthorization());
    }
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
    return _receiver = await ruleReceiverFactory!(identityView!);
  }

  Future<bool> synchronizeRules() => _run(() async {
        if (await identity.activeCredential() == null) {
          throw const DeviceIdentityFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
        }
        final receiver = await _rules();
        try {
          rules = await receiver.synchronize();
        } catch (_) {
          // A failed receipt POST can follow a committed signed page. Refresh
          // local facts without pretending the whole synchronization succeeded.
          rules = await receiver.restore();
          rethrow;
        }
      });
  Future<void> setForeground(bool value) async {
    _foreground = value;
    if (!value) {
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
    if (observationFactory != null && credentialReady && !_disposed) {
      _refreshObservationOnIdle = false;
      unawaited(refreshObservationAuthorization());
    }
  }

  @override
  void dispose() {
    _disposed = true;
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
