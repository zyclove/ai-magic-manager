import 'dart:convert';
import 'api.dart';
import 'keys.dart';
import 'models.dart';
import 'managed_binding.dart';

/// Recoverable device identity. ONE owner per secret record, no implicit reset,
/// parent authorization, native enforcement or unbounded background loop.
class DeviceIdentityManager {
  final DeviceIdentityApi api;
  final DeviceSecretStore secrets;
  final DeviceEnrollmentKeys keys;
  final int Function() nowMillis;
  bool _busy = false;
  DeviceIdentityManager(
      {required this.api,
      required this.secrets,
      required this.nowMillis,
      this.keys = const JoseDeviceEnrollmentKeys()});

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    if (_busy) throw const DeviceIdentityFailure('IDENTITY_BUSY');
    _busy = true;
    try {
      return await operation();
    } finally {
      _busy = false;
    }
  }

  Future<T> _keyOperation<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } catch (_) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
  }

  int _time([Map<String, dynamic>? state]) {
    try {
      final now = nowMillis();
      if (!safeInteger(now, minimum: 1) || now < (state?['observedAt'] ?? 0)) {
        throw const DeviceIdentityFailure('CLOCK_UNTRUSTED');
      }
      return now;
    } catch (_) {
      throw const DeviceIdentityFailure('CLOCK_UNTRUSTED');
    }
  }

  Future<Map<String, dynamic>?> _read() async {
    String? serialized;
    try {
      serialized = await secrets.read();
    } catch (_) {
      throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
    }
    if (serialized == null) return null;
    try {
      if (serialized.length > 65536) throw const FormatException('Size');
      final value = Map<String, dynamic>.from(jsonDecode(serialized));
      if (!_validState(value)) throw const FormatException('Invalid record');
      return value;
    } catch (_) {
      throw const DeviceIdentityFailure('IDENTITY_STATE_INVALID');
    }
  }

  Future<Map<String, dynamic>> _require() async =>
      await _read() ??
      (throw const DeviceIdentityFailure('IDENTITY_NOT_FOUND'));
  Future<void> _save(Map<String, dynamic> state) async {
    state['observedAt'] = _time(state);
    if (!_validState(state)) {
      throw const DeviceIdentityFailure('IDENTITY_STATE_INVALID');
    }
    try {
      await secrets.write(jsonEncode(state));
    } catch (_) {
      throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
    }
  }

  IdentityPhase _phase(Map<String, dynamic> state) =>
      IdentityPhase.values.byName(state['phase']);
  void _allow(Map<String, dynamic> state, Set<IdentityPhase> phases) {
    if (!phases.contains(_phase(state))) {
      throw const DeviceIdentityFailure('IDENTITY_PHASE_CONFLICT');
    }
  }

  String _credential(Map<String, dynamic> state) {
    if (!validSecret(state['credential']) ||
        _time(state) >= state['credentialExpiresAt']) {
      throw const DeviceIdentityFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
    }
    return state['credential'];
  }

  Future<Map<String, dynamic>> _sendAuthenticated(IdentityOperation operation,
      Map<String, dynamic> state, String credential,
      {Map<String, dynamic> body = const {}}) async {
    try {
      return await api.send(operation, credential: credential, body: body);
    } on DeviceIdentityFailure catch (failure) {
      if ((failure.status == 401 || failure.status == 403) &&
          _phase(state) != IdentityPhase.awaitingConfirmation) {
        state['authenticationBlocked'] = true;
        await _save(state);
      }
      rethrow;
    }
  }

  Future<DeviceIdentityView> view() async {
    final state = await _require();
    return DeviceIdentityView(
        phase: _phase(state),
        tenantId: state['tenantId'],
        deviceId: state['deviceId'],
        registrationId: state['registrationId'],
        credentialExpiresAt: state['credentialExpiresAt'],
        confirmBefore: state['confirmBefore'],
        activateBefore: (state['pendingCredential'] as Map?)?['activateBefore'],
        lastHeartbeatAt: state['lastHeartbeatAt'],
        heartbeatSequence: state['heartbeatSequence'],
        heartbeatPending: state['pendingHeartbeat'] != null,
        cloudAuthenticationBlocked: state['authenticationBlocked'] == true);
  }

  /// Host-only recovery data for a cleanup already durably started. This is
  /// insufficient by itself to delete the key: the encrypted receipt journal
  /// must independently show an acknowledged AGENT_DATA_CLEARED stage.
  Future<CleanupPendingBinding?> cleanupPendingBinding() async {
    final state = await _read();
    if (state == null || _phase(state) != IdentityPhase.cleanupPending) {
      return null;
    }
    return CleanupPendingBinding(
        state['tenantId'],
        state['deviceId'],
        state['registrationId'],
        state['cleanupKeyThumbprint'],
        state['cleanupCommandHash']);
  }

  /// For an authenticated configuration transport callback. Never supplies a
  /// pending or potentially activated-but-unconfirmed credential as active.
  Future<String?> activeCredential() async {
    final state = await _read();
    if (state == null) return null;
    final now = _time(state);
    if (state['authenticationBlocked'] == true ||
        !const {
          IdentityPhase.active,
          IdentityPhase.rotationRequested,
          IdentityPhase.rotationPending
        }.contains(_phase(state)) ||
        now >= state['credentialExpiresAt']) return null;
    return state['credential'];
  }

  /// Fetch a server challenge and sign with this registration's ORIGINAL key.
  /// The result is ephemeral feedback, never proof of system enforcement.
  Future<ManagedAgentBindingProof?> managedAgentBindingProof() =>
      _exclusive(() async {
        final state = await _require();
        _allow(state, {
          IdentityPhase.active,
          IdentityPhase.rotationRequested,
          IdentityPhase.rotationPending
        });
        if (state['authenticationBlocked'] == true) {
          throw const DeviceIdentityFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
        }
        if (keys is! DeviceManagedBindingKeys) {
          throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
        }
        final credential = _credential(state);
        final original = jsonEncode(state);
        final response = await _sendAuthenticated(
            IdentityOperation.managedAgentChallenge, state, credential);
        if (response.isEmpty) return null;
        final challenge = ManagedAgentChallenge.fromJson(response);
        final now = _time(state);
        challenge.requireCurrent(now);
        final signed = await _keyOperation(() =>
            (keys as DeviceManagedBindingKeys)
                .managedBindingProof(state['keyHandle'], challenge, now));
        final proof = ManagedAgentBindingProof(signed.compact, challenge, now);
        // A parallel native owner may revoke/rotate/delete while HTTP or signing
        // is pending. Re-read before releasing feedback; never overwrite it.
        final latest = await _require();
        if (jsonEncode(latest) != original ||
            _credential(latest) != credential) {
          throw const DeviceIdentityFailure('IDENTITY_STATE_CONFLICT');
        }
        final finished = _time(latest);
        if (finished < now) {
          throw const DeviceIdentityFailure('CLOCK_UNTRUSTED');
        }
        challenge.requireCurrent(finished);
        if (finished >= proof.expiresAt) {
          throw const DeviceIdentityFailure('MANAGED_CHALLENGE_EXPIRED');
        }
        return proof;
      });

  /// Sign only for the independent cleanup channel with the original
  /// registration key. A rejected ordinary bearer is not cleanup authority;
  /// the server still requires a current, revoked registration and task.
  Future<CleanupProof> cleanupProof(
          {required String action, String? operationId}) =>
      _exclusive(() async {
        final state = await _require();
        _allow(state, {
          IdentityPhase.active,
          IdentityPhase.rotationRequested,
          IdentityPhase.rotationPending,
          IdentityPhase.activationUncertain,
          IdentityPhase.cleanupPending
        });
        final now = _time(state);
        if (keys is! DeviceCleanupKeys) {
          throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
        }
        return _keyOperation(() => (keys as DeviceCleanupKeys).cleanupProof(
            state['keyHandle'],
            state['tenantId'],
            state['deviceId'],
            state['registrationId'],
            action,
            operationId,
            now));
      });

  /// Enter the cleanup-only phase after the host has verified an exact signed
  /// command. Ordinary credentials and rotation/heartbeat intents are removed
  /// durably; the original key remains for short-lived cleanup proofs.
  Future<void> beginAgentCleanup(
          {required String tenantId,
          required String deviceId,
          required String registrationId,
          required String keyThumbprint,
          required String commandHash}) =>
      _exclusive(() async {
        if (!validUuid(tenantId) ||
            !validUuid(deviceId) ||
            !validUuid(registrationId) ||
            !validSecret(keyThumbprint) ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(commandHash)) {
          throw const DeviceIdentityFailure('IDENTITY_STATE_INVALID');
        }
        final state = await _require();
        if (state['tenantId'] != tenantId ||
            state['deviceId'] != deviceId ||
            state['registrationId'] != registrationId) {
          throw const DeviceIdentityFailure('IDENTITY_SCOPE_MISMATCH');
        }
        if (_phase(state) == IdentityPhase.cleanupPending) {
          if (state['cleanupCommandHash'] != commandHash ||
              state['cleanupKeyThumbprint'] != keyThumbprint) {
            throw const DeviceIdentityFailure('IDENTITY_SCOPE_MISMATCH');
          }
          return;
        }
        _allow(state, {
          IdentityPhase.active,
          IdentityPhase.rotationRequested,
          IdentityPhase.rotationPending,
          IdentityPhase.activationUncertain
        });
        if (keys is! DeviceCleanupKeys) {
          throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
        }
        final proof = await _keyOperation(() => (keys as DeviceCleanupKeys)
            .cleanupProof(state['keyHandle'], tenantId, deviceId,
                registrationId, 'READ', null, _time(state)));
        if (proof.keyThumbprint != keyThumbprint) {
          throw const DeviceIdentityFailure('IDENTITY_SCOPE_MISMATCH');
        }
        state['phase'] = IdentityPhase.cleanupPending.name;
        state['authenticationBlocked'] = true;
        state['cleanupCommandHash'] = commandHash;
        state['cleanupKeyThumbprint'] = keyThumbprint;
        state.remove('credential');
        state.remove('credentialExpiresAt');
        state.remove('pendingCredential');
        state.remove('pendingHeartbeat');
        await _save(state);
      });

  /// Call only after a strict AGENT_DATA_CLEARED receipt acknowledgement has
  /// been saved by the cleanup journal. Repeated removal is safe at the store
  /// boundary; no normal identity operation can run in cleanupPending.
  Future<void> finishAgentCleanup(
          {required String tenantId,
          required String deviceId,
          required String registrationId,
          required String keyThumbprint,
          required String commandHash}) =>
      _exclusive(() async {
        final state = await _require();
        if (_phase(state) != IdentityPhase.cleanupPending ||
            state['tenantId'] != tenantId ||
            state['deviceId'] != deviceId ||
            state['registrationId'] != registrationId ||
            state['cleanupKeyThumbprint'] != keyThumbprint ||
            state['cleanupCommandHash'] != commandHash) {
          throw const DeviceIdentityFailure('IDENTITY_SCOPE_MISMATCH');
        }
        if (keys is! DeviceCleanupKeyDeletion ||
            secrets is! DeviceSecretDeletion) {
          throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
        }
        await _keyOperation(() => (keys as DeviceCleanupKeyDeletion)
            .deleteOriginalHandle(state['keyHandle']));
        try {
          await (secrets as DeviceSecretDeletion).deleteIdentity();
        } catch (_) {
          throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
        }
      });

  /// Persist a 401/403 observed by a trusted device transport. Supply the exact
  /// credential used for that request, never a newly fetched one. Late replies
  /// cannot block another registration or a rotated credential. No HTTP or
  /// secret logging. A failed secure write throws rather than claiming durability.
  Future<bool> recordCredentialRejection(
          {required DeviceIdentityView scope,
          required String rejectedCredential}) =>
      _exclusive(() async {
        if (!validSecret(rejectedCredential)) {
          throw const DeviceIdentityFailure('INVALID_CREDENTIAL_REJECTION');
        }
        final state = await _read();
        if (state == null) return false;
        _time(state);
        if (!const {
              IdentityPhase.active,
              IdentityPhase.rotationRequested,
              IdentityPhase.rotationPending
            }.contains(_phase(state)) ||
            state['tenantId'] != scope.tenantId ||
            state['deviceId'] != scope.deviceId ||
            state['registrationId'] != scope.registrationId ||
            state['credential'] != rejectedCredential) return false;
        if (state['authenticationBlocked'] == true) return true;
        state['authenticationBlocked'] = true;
        await _save(state);
        return true;
      });

  /// Physical pairing UI only; caller must not log/copy it to telemetry.
  Future<String?> pairingCode() async {
    final state = await _read();
    return state != null && _phase(state) == IdentityPhase.awaitingConfirmation
        ? state['pairingCode'] as String
        : null;
  }

  Future<void> begin(EnrollmentTicket ticket,
          {required String displayName, required String osVersion}) =>
      _exclusive(() async {
        if (await _read() != null) {
          throw const DeviceIdentityFailure('IDENTITY_ALREADY_EXISTS');
        }
        final now = _time();
        if (now >= ticket.expiresAt) {
          throw const DeviceIdentityFailure('ENROLLMENT_EXPIRED');
        }
        if (!boundedText(displayName, 100) || !boundedText(osVersion, 100)) {
          throw ArgumentError('Provide a bounded display name and OS version');
        }
        final state = <String, dynamic>{
          'schemaVersion': 1,
          'kind': 'DEVICE_IDENTITY',
          'apiRoot': api.apiRoot.toString(),
          'tenantId': ticket.tenantId,
          'enrollmentId': ticket.enrollmentId,
          'enrollmentToken': ticket.token,
          'ticketExpiresAt': ticket.expiresAt,
          'keyHandle': await _keyOperation(keys.generateHandle),
          'displayName': displayName.trim(),
          'osVersion': osVersion.trim(),
          'phase': IdentityPhase.claimUncertain.name,
          'observedAt': now,
          'heartbeatSequence': 0
        };
        // If this fails, no claim is sent. A crash after it requires explicit same-key
        // claim retry or recovery; never generate another key for the same record.
        await _save(state);
        await _claim(state, false);
      });
  Future<void> retryClaim() => _exclusive(() async {
        final state = await _require();
        _allow(state, {IdentityPhase.claimUncertain});
        await _claim(state, false);
      });
  Future<void> recoverClaim() => _exclusive(() async {
        final state = await _require();
        _allow(state, {IdentityPhase.claimUncertain});
        await _claim(state, true);
      });
  Future<void> _claim(Map<String, dynamic> state, bool recovery) async {
    final now = _time(state);
    if (now >= state['ticketExpiresAt']) {
      throw const DeviceIdentityFailure('ENROLLMENT_EXPIRED');
    }
    final proof = await _keyOperation(() => keys.proof(
        state['keyHandle'],
        state['enrollmentId'],
        state['enrollmentToken'],
        recovery
            ? 'ai-manager:enrollment-recover'
            : 'ai-manager:enrollment-claim',
        now));
    await _save(state);
    final response = await api.send(
        recovery ? IdentityOperation.recover : IdentityOperation.claim,
        body: {
          'enrollmentId': state['enrollmentId'],
          'token': state['enrollmentToken'],
          'publicKeyJwk': proof.publicKeyJwk,
          'proof': proof.compact,
          if (!recovery) ...{
            'displayName': state['displayName'],
            'osVersion': state['osVersion']
          }
        });
    if (!validUuid(response['deviceId']) ||
        !validUuid(response['registrationId']) ||
        !validSecret(response['credential']) ||
        !safeInteger(response['expiresAt'], minimum: now + 1) ||
        !safeInteger(response['confirmBefore'], minimum: now + 1) ||
        response['confirmBefore'] > state['ticketExpiresAt'] ||
        response['pairingCode'] is! String ||
        !RegExp(r'^[A-Z0-9]{8}$').hasMatch(response['pairingCode']) ||
        response['state'] != 'AWAITING_CONFIRMATION' ||
        (state['deviceId'] != null &&
            (state['deviceId'] != response['deviceId'] ||
                state['registrationId'] != response['registrationId']))) {
      throw const DeviceIdentityFailure('RESPONSE_INVALID',
          outcomeUnknown: true);
    }
    state.addAll({
      'deviceId': response['deviceId'],
      'registrationId': response['registrationId'],
      'credential': response['credential'],
      'credentialExpiresAt': response['expiresAt'],
      'pairingCode': response['pairingCode'],
      'confirmBefore': response['confirmBefore'],
      'phase': IdentityPhase.awaitingConfirmation.name
    });
    await _save(state);
  }

  /// If a previous heartbeat is pending, replay it unchanged before observing a
  /// newer capability snapshot. `replayed` tells the host to schedule the new one.
  Future<HeartbeatAcknowledgement> heartbeat(
          {required String agentVersion,
          required List<Map<String, dynamic>> capabilities}) =>
      _exclusive(() async {
        final state = await _require();
        _allow(state, {
          IdentityPhase.awaitingConfirmation,
          IdentityPhase.active,
          IdentityPhase.rotationRequested,
          IdentityPhase.rotationPending
        });
        final credential = _credential(state);
        final replayed = state['pendingHeartbeat'] != null;
        if (!replayed) {
          final sequence = state['heartbeatSequence'] + 1;
          final input = {
            'sequence': sequence,
            'agentVersion': agentVersion,
            'capabilities': capabilities
          };
          if (!_validHeartbeat(input)) {
            throw ArgumentError('Invalid bounded capability snapshot');
          }
          state['pendingHeartbeat'] = jsonDecode(jsonEncode(input));
        }
        await _save(state);
        final body = Map<String, dynamic>.from(state['pendingHeartbeat']);
        final response = await _sendAuthenticated(
            IdentityOperation.heartbeat, state, credential,
            body: body);
        if (response['registrationId'] != state['registrationId'] ||
            !safeInteger(response['sequence'], minimum: 1) ||
            response['sequence'] != body['sequence'] ||
            !safeInteger(response['receivedAt'], minimum: 1)) {
          throw const DeviceIdentityFailure('RESPONSE_INVALID',
              outcomeUnknown: true);
        }
        state['heartbeatSequence'] = body['sequence'];
        state['lastHeartbeatAt'] = response['receivedAt'];
        state.remove('pendingHeartbeat');
        state.remove('authenticationBlocked');
        if (_phase(state) == IdentityPhase.awaitingConfirmation) {
          state['phase'] = IdentityPhase.active.name;
          state.remove('enrollmentToken');
          state.remove('pairingCode');
          state.remove('confirmBefore');
        }
        await _save(state);
        return HeartbeatAcknowledgement(
            body['sequence'], response['receivedAt'],
            replayed: replayed);
      });

  Future<void> rotate() => _exclusive(() async {
        final state = await _require();
        _allow(state, {IdentityPhase.active});
        final credential = _credential(state), now = _time(state);
        state['phase'] = IdentityPhase.rotationRequested.name;
        await _save(state);
        final response = await _sendAuthenticated(
            IdentityOperation.rotate, state, credential);
        if (!validUuid(response['credentialId']) ||
            !validSecret(response['credential']) ||
            response['credential'] == credential ||
            !safeInteger(response['expiresAt'], minimum: now + 1) ||
            !safeInteger(response['activateBefore'], minimum: now + 1) ||
            response['activateBefore'] > state['credentialExpiresAt'] ||
            response['activateBefore'] > response['expiresAt']) {
          throw const DeviceIdentityFailure('RESPONSE_INVALID',
              outcomeUnknown: true);
        }
        state['pendingCredential'] = {
          for (final field in [
            'credentialId',
            'credential',
            'expiresAt',
            'activateBefore'
          ])
            field: response[field]
        };
        state['phase'] = IdentityPhase.rotationPending.name;
        state.remove('authenticationBlocked');
        await _save(state);
      });
  Future<void> activateRotation() => _exclusive(() async {
        final state = await _require();
        _allow(state,
            {IdentityPhase.rotationPending, IdentityPhase.activationUncertain});
        final pending = Map<String, dynamic>.from(state['pendingCredential']);
        final now = _time(state);
        if (now >= pending['expiresAt']) {
          throw const DeviceIdentityFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
        }
        if (_phase(state) == IdentityPhase.rotationPending &&
            now >= pending['activateBefore']) {
          throw const DeviceIdentityFailure('ROTATION_WINDOW_EXPIRED');
        }
        state['phase'] = IdentityPhase.activationUncertain.name;
        await _save(state);
        await _sendAuthenticated(
            IdentityOperation.activate, state, pending['credential']);
        state['credential'] = pending['credential'];
        state['credentialExpiresAt'] = pending['expiresAt'];
        state.remove('pendingCredential');
        state.remove('authenticationBlocked');
        state['phase'] = IdentityPhase.active.name;
        await _save(state);
      });
  Future<void> cancelRotation() => _exclusive(() async {
        final state = await _require();
        _allow(state,
            {IdentityPhase.rotationRequested, IdentityPhase.rotationPending});
        final credential = _credential(state);
        await _save(state);
        await _sendAuthenticated(IdentityOperation.cancel, state, credential);
        state.remove('pendingCredential');
        state.remove('authenticationBlocked');
        state['phase'] = IdentityPhase.active.name;
        await _save(state);
      });

  bool _validState(Map<String, dynamic> s) {
    if (s['authenticationBlocked'] != null &&
        s['authenticationBlocked'] is! bool) return false;
    if (s['schemaVersion'] != 1 ||
        s['kind'] != 'DEVICE_IDENTITY' ||
        s['apiRoot'] != api.apiRoot.toString() ||
        !validUuid(s['tenantId']) ||
        !validUuid(s['enrollmentId']) ||
        !boundedText(s['keyHandle'], 8192) ||
        !boundedText(s['displayName'], 100) ||
        !boundedText(s['osVersion'], 100) ||
        !safeInteger(s['observedAt'], minimum: 1) ||
        !safeInteger(s['ticketExpiresAt'], minimum: 1) ||
        !safeInteger(s['heartbeatSequence']) ||
        !IdentityPhase.values.any((p) => p.name == s['phase'])) return false;
    final phase = _phase(s);
    if (phase == IdentityPhase.claimUncertain) {
      if (!validSecret(s['enrollmentToken']) ||
          s['deviceId'] != null ||
          s['credential'] != null) return false;
    } else if (phase == IdentityPhase.cleanupPending) {
      if (!validUuid(s['deviceId']) ||
          !validUuid(s['registrationId']) ||
          s['credential'] != null ||
          s['credentialExpiresAt'] != null ||
          s['authenticationBlocked'] != true ||
          !validSecret(s['cleanupKeyThumbprint']) ||
          s['cleanupCommandHash'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(s['cleanupCommandHash'])) {
        return false;
      }
    } else {
      if (!validUuid(s['deviceId']) ||
          !validUuid(s['registrationId']) ||
          !validSecret(s['credential']) ||
          !safeInteger(s['credentialExpiresAt'], minimum: 1)) return false;
    }
    if (phase != IdentityPhase.cleanupPending &&
        (s['cleanupKeyThumbprint'] != null ||
            s['cleanupCommandHash'] != null)) {
      return false;
    }
    if (phase == IdentityPhase.awaitingConfirmation) {
      if (!validSecret(s['enrollmentToken']) ||
          !boundedText(s['pairingCode'], 8) ||
          !RegExp(r'^[A-Z0-9]{8}$').hasMatch(s['pairingCode']) ||
          !safeInteger(s['confirmBefore'], minimum: 1) ||
          s['confirmBefore'] > s['ticketExpiresAt']) return false;
    } else if (phase != IdentityPhase.claimUncertain &&
        (s['enrollmentToken'] != null ||
            s['pairingCode'] != null ||
            s['confirmBefore'] != null)) {
      return false;
    }
    final pending = s['pendingCredential'];
    if (phase == IdentityPhase.rotationPending ||
        phase == IdentityPhase.activationUncertain) {
      if (pending is! Map<String, dynamic> ||
          !validUuid(pending['credentialId']) ||
          !validSecret(pending['credential']) ||
          pending['credential'] == s['credential'] ||
          !safeInteger(pending['expiresAt'], minimum: 1) ||
          !safeInteger(pending['activateBefore'], minimum: 1) ||
          pending['activateBefore'] > s['credentialExpiresAt'] ||
          pending['activateBefore'] > pending['expiresAt']) return false;
    } else if (pending != null) {
      return false;
    }
    if (s['lastHeartbeatAt'] != null &&
        !safeInteger(s['lastHeartbeatAt'], minimum: 1)) return false;
    final heartbeat = s['pendingHeartbeat'];
    if (heartbeat != null &&
        (heartbeat is! Map<String, dynamic> ||
            !_validHeartbeat(heartbeat) ||
            heartbeat['sequence'] != s['heartbeatSequence'] + 1 ||
            phase == IdentityPhase.claimUncertain ||
            phase == IdentityPhase.cleanupPending)) return false;
    return true;
  }

  bool _validHeartbeat(Map<String, dynamic> body) {
    if (!safeInteger(body['sequence'], minimum: 1) ||
        !boundedText(body['agentVersion'], 60)) return false;
    final reports = body['capabilities'];
    if (reports is! List || reports.length > 64) return false;
    final unique = <String>{};
    for (final report in reports) {
      if (report is! Map<String, dynamic> ||
          report['key'] is! String ||
          !RegExp(r'^[a-z][a-z0-9_.]{1,63}$').hasMatch(report['key']) ||
          !unique.add(report['key']) ||
          report['reportedSupported'] is! bool ||
          !const {
            'GRANTED',
            'DENIED',
            'NOT_REQUESTED',
            'REVOKED',
            'NOT_APPLICABLE'
          }.contains(report['grantStatus']) ||
          report.keys.any((key) => !const {
                'key',
                'reportedSupported',
                'grantStatus'
              }.contains(key))) {
        return false;
      }
    }
    return true;
  }
}
