import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../platform/family_push_platform.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';
import 'parent_session.dart';

export '../platform/family_push_platform.dart'
    show FamilyPushClick, FamilyPushState, FamilyPushPlatform;

Never _invalid() =>
    throw const ParentApiException(502, 'INVALID_NOTIFICATION_RESPONSE');
void _validateRegistration(Json result, String id) {
  if (result['installationId'] != id ||
      result['provider'] != 'ALIYUN' ||
      result['platform'] != 'ANDROID' ||
      result['notificationConsent'] != true ||
      result['permissionGranted'] != true ||
      result['deliveryVerified'] != false) _invalid();
}

class FamilyNotificationPreferences {
  final bool enabled, requests, deviceAttention, ruleExpiry;
  const FamilyNotificationPreferences(
      {required this.enabled,
      required this.requests,
      required this.deviceAttention,
      required this.ruleExpiry});
  factory FamilyNotificationPreferences.fromJson(Json value) {
    for (final key in [
      'enabled',
      'requests',
      'deviceAttention',
      'ruleExpiry'
    ]) {
      if (value[key] is! bool) _invalid();
    }
    return FamilyNotificationPreferences(
        enabled: value['enabled'],
        requests: value['requests'],
        deviceAttention: value['deviceAttention'],
        ruleExpiry: value['ruleExpiry']);
  }
  Json toJson() => {
        'enabled': enabled,
        'requests': requests,
        'deviceAttention': deviceAttention,
        'ruleExpiry': ruleExpiry
      };
  FamilyNotificationPreferences copyWith(
          {bool? enabled,
          bool? requests,
          bool? deviceAttention,
          bool? ruleExpiry}) =>
      FamilyNotificationPreferences(
          enabled: enabled ?? this.enabled,
          requests: requests ?? this.requests,
          deviceAttention: deviceAttention ?? this.deviceAttention,
          ruleExpiry: ruleExpiry ?? this.ruleExpiry);
}

class FamilyPushReadiness {
  final bool providerConfigured,
      workerEnabled,
      nativeIntegrationVerified,
      deliveryVerified;
  FamilyPushReadiness.fromJson(Json value)
      : providerConfigured = value['providerConfigured'] == true,
        workerEnabled = value['workerEnabled'] == true,
        nativeIntegrationVerified = value['nativeIntegrationVerified'] == true,
        deliveryVerified = value['deliveryVerified'] == true {
    if (value['provider'] != 'ALIYUN' || value['platform'] != 'ANDROID') {
      _invalid();
    }
    for (final key in [
      'providerConfigured',
      'workerEnabled',
      'nativeIntegrationVerified',
      'deliveryVerified'
    ]) {
      if (value[key] is! bool) _invalid();
    }
  }
}

/// One encrypted installation journal across adult accounts prevents token
/// takeover while an old DELETE is uncertain. It contains no provider token.
class FamilyNotificationCoordinator extends ChangeNotifier {
  static const _key = 'parent.family.push-installation.v1';
  final ParentSession session;
  final ParentDurableStorage storage;
  final FamilyPushPlatform platform;
  FamilyNotificationPreferences? preferences;
  FamilyPushReadiness? readiness;
  FamilyPushState? nativeState;
  Object? error;
  bool busy = false, loaded = false;
  Json? _journal;
  bool _disposed = false, _suspended = false;
  int _epoch = 0;
  Future<void> _tail = Future<void>.value();
  FamilyNotificationCoordinator(
      {required this.session,
      ParentDurableStorage? storage,
      FamilyPushPlatform? platform})
      : storage = storage ?? ParentDurableStorage(),
        platform = platform ?? const FamilyPushPlatform() {
    session.addListener(_scopeChanged);
    _rememberScope();
  }
  String? _actor, _tenant, _role;
  int? _generation;
  bool get available =>
      !_disposed &&
      !_suspended &&
      session.authenticated &&
      session.tenant?['kind'] == 'FAMILY' &&
      const {'OWNER', 'GUARDIAN'}.contains(session.role);
  bool get revocationPending => _journal?['phase'] == 'REVOKING';
  bool get deviceRegistered => loaded && _hasCurrentInstallation;
  bool get _hasCurrentInstallation =>
      available &&
      _journal?['phase'] == 'ACTIVE' &&
      _journal?['actor'] == session.profile?['subject'] &&
      _journal?['tenant'] == session.tenant?['id'];
  void _rememberScope() {
    _actor = session.profile?['subject'] as String?;
    _tenant = session.tenant?['id'] as String?;
    _role = session.role;
    _generation = session.generation;
  }

  void _scopeChanged() {
    if (_actor != session.profile?['subject'] ||
        _tenant != session.tenant?['id'] ||
        _role != session.role ||
        _generation != session.generation) {
      _epoch++;
      _suspended = true;
      loaded = false;
      preferences = null;
      readiness = null;
      _rememberScope();
      // Dispatch this before any new-scope activation. Native shutdown also
      // cancels displayed notifications and pending clicks.
      unawaited(platform.deactivate(preserveClick: true).catchError((Object e) {
        if (!_disposed) {
          error = e;
          notifyListeners();
        }
      }));
      if (!_disposed) notifyListeners();
    }
  }

  void _check(int epoch, String actor, String tenant) {
    if (!available ||
        epoch != _epoch ||
        session.profile?['subject'] != actor ||
        session.tenant?['id'] != tenant) {
      throw const ParentApiException(409, 'WORKSPACE_CHANGED');
    }
  }

  Future<T> _run<T>(Future<T> Function() action) {
    final next = _tail.then((_) async {
      if (_disposed) throw StateError('Notification coordinator disposed');
      busy = true;
      error = null;
      notifyListeners();
      try {
        return await action();
      } catch (e) {
        error = e;
        rethrow;
      } finally {
        if (!_disposed) {
          busy = false;
          notifyListeners();
        }
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _readJournal() async {
    final value = await storage.read(key: _key);
    if (value == null) {
      _journal = null;
      return;
    }
    if (value.length > 2048) _invalid();
    final raw = jsonDecode(value);
    if (raw is! Json ||
        raw.length != 4 ||
        raw['actor'] is! String ||
        raw['tenant'] is! String ||
        !canonicalPushId(raw['installationId']) ||
        !const {'REGISTERING', 'ACTIVE', 'REVOKING'}.contains(raw['phase'])) {
      _invalid();
    }
    _journal = raw;
  }

  Future<void> _persist(Json value) async {
    await storage.write(key: _key, value: jsonEncode(value));
    _journal = Map<String, dynamic>.unmodifiable(value);
  }

  Future<void> load() => _run(() async {
        loaded = false;
        preferences = null;
        readiness = null;
        nativeState = null;
        try {
          await _loadCurrent();
          loaded = available;
        } catch (_) {
          loaded = false;
          preferences = null;
          readiness = null;
          nativeState = null;
          rethrow;
        }
      });
  Future<void> _loadCurrent() async {
    await platform.deactivate(preserveClick: true);
    _suspended = false;
    final epoch = _epoch;
    if (!available) {
      loaded = false;
      return;
    }
    final actor = session.profile!['subject'] as String,
        tenant = session.tenant!['id'] as String;
    await _readJournal();
    _check(epoch, actor, tenant);
    // Reopening a different scope never makes its old installation active.
    if (_journal != null &&
        (_journal!['actor'] != actor ||
            _journal!['tenant'] != tenant ||
            _journal!['phase'] == 'REGISTERING')) {
      await _persist({..._journal!, 'phase': 'REVOKING'});
    }
    nativeState = await platform.state();
    _check(epoch, actor, tenant);
    if (_journal != null &&
        (!nativeState!.permissionGranted || !nativeState!.channelEnabled)) {
      await _persist({..._journal!, 'phase': 'REVOKING'});
    }
    if (revocationPending) {
      try {
        await _revoke();
      } catch (e) {
        error = e;
      }
    }
    final results = await Future.wait([
      session.api.object(
          '/tenants/${Uri.encodeComponent(tenant)}/notification-preferences',
          isCurrent: () => available && epoch == _epoch),
      session.api.object(
          '/tenants/${Uri.encodeComponent(tenant)}/push-readiness',
          isCurrent: () => available && epoch == _epoch)
    ]);
    _check(epoch, actor, tenant);
    preferences = FamilyNotificationPreferences.fromJson(results[0]);
    readiness = FamilyPushReadiness.fromJson(results[1]);
    if (_hasCurrentInstallation &&
        nativeState!.configured &&
        nativeState!.permissionGranted &&
        nativeState!.channelEnabled &&
        readiness!.providerConfigured &&
        readiness!.workerEnabled) {
      // SDK identifiers may rotate between foreground sessions. Reuse the
      // same actor-bound installation only after reading its real token.
      final token = await platform.register();
      _check(epoch, actor, tenant);
      final id = _journal!['installationId'] as String;
      final result = await session.api.objectRegistration(tenant, id, token,
          isCurrent: () => available && epoch == _epoch);
      _validateRegistration(result, id);
      _check(epoch, actor, tenant);
      if (preferences!.enabled) await platform.activate(id);
    }
    _check(epoch, actor, tenant);
  }

  Future<void> enableOnDevice() => _run(() async {
        if (!loaded || !available || _journal != null) {
          throw const ParentApiException(409, 'PUSH_REGISTRATION_PENDING');
        }
        final epoch = _epoch,
            actor = session.profile!['subject'] as String,
            tenant = session.tenant!['id'] as String;
        nativeState = await platform.state();
        _check(epoch, actor, tenant);
        if (!nativeState!.configured ||
            readiness?.providerConfigured != true ||
            readiness?.workerEnabled != true) {
          throw const ParentApiException(503, 'PUSH_NOT_CONFIGURED');
        }
        nativeState = await platform.requestPermission();
        _check(epoch, actor, tenant);
        if (!nativeState!.permissionGranted || !nativeState!.channelEnabled) {
          throw const ParentApiException(409, 'PUSH_PERMISSION_REQUIRED');
        }
        final token = await platform.register();
        _check(epoch, actor, tenant);
        final id = const Uuid().v4();
        await _persist({
          'actor': actor,
          'tenant': tenant,
          'installationId': id,
          'phase': 'REGISTERING'
        });
        _check(epoch, actor, tenant);
        final result = await session.api.objectRegistration(tenant, id, token,
            isCurrent: () => available && epoch == _epoch);
        _check(epoch, actor, tenant);
        _validateRegistration(result, id);
        await _persist({..._journal!, 'phase': 'ACTIVE'});
        _check(epoch, actor, tenant);
        if (preferences!.enabled) await platform.activate(id);
        _check(epoch, actor, tenant);
      });
  Future<void> _revoke() async {
    final journal = _journal;
    if (journal == null) return;
    await platform.deactivate();
    if (journal['phase'] != 'REVOKING') {
      await _persist({...journal, 'phase': 'REVOKING'});
    }
    final actor = journal['actor'];
    if (!session.authenticated || session.profile?['subject'] != actor) {
      throw const ParentApiException(409, 'PUSH_PREVIOUS_ACCOUNT_REQUIRED');
    }
    await session.api.send('DELETE',
        '/notifications/push-installations/${journal['installationId']}',
        expectedStatus: 204,
        isCurrent: () =>
            session.authenticated && session.profile?['subject'] == actor);
    await storage.delete(key: _key);
    _journal = null;
  }

  Future<void> disableOnDevice() => _run(() async {
        await platform.deactivate();
        await _readJournal();
        await _revoke();
      });
  Future<bool> beforeScopeChange() async {
    _epoch++;
    _suspended = true;
    await platform.deactivate();
    try {
      return await _run(() async {
        await _readJournal();
        await _revoke();
        loaded = false;
        return true;
      });
    } catch (_) {
      return false;
    }
  }

  Future<void> onResume() => load();
  Future<void> savePreferences(FamilyNotificationPreferences value) =>
      _run(() async {
        if (!loaded || !available) {
          throw const ParentApiException(409, 'WORKSPACE_CHANGED');
        }
        final epoch = _epoch,
            actor = session.profile!['subject'] as String,
            tenant = session.tenant!['id'] as String;
        // An uncertain preference PUT must never leave this phone displaying
        // after the adult explicitly switched the master subscription off.
        if (!value.enabled) {
          await platform.deactivate();
          await _readJournal();
          await _revoke();
          _check(epoch, actor, tenant);
        }
        final result = await session.api.send('PUT',
            '/tenants/${Uri.encodeComponent(tenant)}/notification-preferences',
            body: value.toJson(),
            isCurrent: () => available && epoch == _epoch);
        _check(epoch, actor, tenant);
        if (result is! Json) _invalid();
        preferences = FamilyNotificationPreferences.fromJson(result);
        if (preferences!.enabled && deviceRegistered) {
          await platform.activate(_journal!['installationId']);
          _check(epoch, actor, tenant);
        }
      });
  Future<FamilyPushClick?> takeClick() async {
    if (!available || !loaded || !deviceRegistered) return null;
    final epoch = _epoch;
    final click = await platform.takeClick();
    return epoch == _epoch &&
            available &&
            click?.installationId == _journal?['installationId']
        ? click
        : null;
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_scopeChanged);
    super.dispose();
  }
}

extension on ParentApi {
  Future<Json> objectRegistration(String tenant, String id, String token,
      {required bool Function() isCurrent}) async {
    final value = await send(
        'PUT', '/tenants/${Uri.encodeComponent(tenant)}/push-installations/$id',
        expectedStatus: 200,
        body: {
          'provider': 'ALIYUN',
          'platform': 'ANDROID',
          'providerToken': token,
          'notificationConsent': true,
          'permissionGranted': true
        },
        isCurrent: isCurrent);
    if (value is! Json) _invalid();
    return value;
  }
}
