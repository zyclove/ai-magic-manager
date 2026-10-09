import 'dart:async';
import 'dart:convert';
import 'package:device_access/device_access.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_policy/device_policy.dart' as policy;
import 'package:sembast/sembast.dart';
import '../platform/access_database.dart';
import '../platform/secret_store.dart';
import 'access.dart';
import 'environment.dart';

typedef ChildAccessDatabaseOpener = Future<Database> Function(String scopeKey);

/// Single foreground owner of verified baseline, context intent, DB and HTTP.
/// Construction performs no I/O, so pause/dispose can cancel initialization.
class SignedAccessReceiver implements ChildAccessReceiver {
  final ChildEnvironment environment;
  final DeviceIdentityView identity;
  final Future<String?> Function() credential;
  final ChildAccessBaseline readBaseline;
  final int Function() nowMillis;
  final ChildAccessBindingStore bindingStore;
  final ChildAccessDatabaseOpener databaseOpener;
  final DeviceAccessTransport Function()? transportFactory;
  late final String _bindingKey;
  Future<void> _tail = Future.value();
  Database? _database;
  AccessWindowJournal? _journal;
  DeviceAccessScope? _scope;
  DeviceAccessTransport? _transport;
  List<policy.VerifiedConfiguration> _baseline = const [];
  bool _paused = false, _closed = false;
  int _epoch = 0;

  SignedAccessReceiver(
      {required this.environment,
      required this.identity,
      required this.credential,
      required this.readBaseline,
      required this.nowMillis,
      ChildAccessBindingStore? bindingStore,
      ChildAccessDatabaseOpener? databaseOpener,
      this.transportFactory})
      : bindingStore = bindingStore ?? AndroidAccessBindingStore(),
        databaseOpener = databaseOpener ?? openAccessDatabase {
    if (identity.deviceId == null ||
        identity.registrationId == null ||
        environment.configurationIssuer.isEmpty ||
        environment.configurationKeys == null) {
      throw const AccessFailure('ACCESS_TRUST_UNAVAILABLE');
    }
    _bindingKey = policy.DevicePolicyScope(
            issuer: '${environment.configurationIssuer}|${environment.apiRoot}',
            tenantId: identity.tenantId,
            deviceId: identity.deviceId!,
            registrationId: identity.registrationId!)
        .storageKey;
  }

  int _time() {
    final time = nowMillis();
    if (!accessInteger(time, 0)) throw const AccessFailure('CLOCK_UNTRUSTED');
    return time;
  }

  void _check(int epoch) {
    if (_closed || _paused || epoch != _epoch) {
      throw const AccessFailure('ACCESS_PAUSED');
    }
  }

  Future<ChildAccessSnapshot> _enqueue(
      Future<ChildAccessSnapshot> Function(int) action) {
    final epoch = _epoch;
    final result = _tail.then((_) {
      _check(epoch);
      return action(epoch);
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<_Binding?> _read() async {
    try {
      final text = await bindingStore.read(_bindingKey);
      if (text == null) return null;
      if (text.length > 65536) throw const FormatException();
      final raw = jsonDecode(text);
      if (raw is! Map<String, dynamic> ||
          raw.length != 5 ||
          raw['schemaVersion'] != 1 ||
          !{'VALID', 'CHECKING', 'BLOCKED'}.contains(raw['phase']) ||
          !accessInteger(raw['checkedAt'], 0) ||
          raw['unresolvedRequestIds'] is! List) {
        throw const FormatException();
      }
      final ids = (raw['unresolvedRequestIds'] as List);
      if (ids.length > 256 ||
          !ids.every(accessId) ||
          ids.toSet().length != ids.length) throw const FormatException();
      final context = raw['context'] == null
          ? null
          : AccessDeviceContext.fromJson(
              Map<String, dynamic>.from(raw['context'] as Map));
      context?.requireIdentity(
          tenantId: identity.tenantId,
          deviceId: identity.deviceId!,
          registrationId: identity.registrationId!);
      if (raw['phase'] == 'VALID' && context == null) {
        throw const FormatException();
      }
      if ((raw['checkedAt'] as int) > _time()) {
        throw const AccessFailure('CLOCK_UNTRUSTED');
      }
      return _Binding(
          raw['phase'], context, raw['checkedAt'], ids.cast<String>().toSet());
    } on AccessFailure {
      rethrow;
    } catch (_) {
      throw const AccessFailure('ACCESS_CONTEXT_INVALID');
    }
  }

  Future<void> _write(_Binding value) => bindingStore.write(
      _bindingKey,
      jsonEncode({
        'schemaVersion': 1,
        'phase': value.phase,
        'checkedAt': value.checkedAt,
        'context': value.context == null
            ? null
            : {
                'tenantId': value.context!.tenantId,
                'subjectId': value.context!.subjectId,
                'deviceId': value.context!.deviceId,
                'registrationId': value.context!.registrationId
              },
        'unresolvedRequestIds': value.unresolved.toList()..sort()
      }));

  Future<void> _refreshBaseline(int epoch) async {
    _baseline = const [];
    final values = await readBaseline();
    _check(epoch);
    if (values.length > 256) throw const AccessFailure('BASELINE_UNAVAILABLE');
    final verifier = policy.ConfigurationVerifier(
        scope: policy.DevicePolicyScope(
            issuer: environment.configurationIssuer,
            tenantId: identity.tenantId,
            deviceId: identity.deviceId!,
            registrationId: identity.registrationId!),
        trustedKeys: environment.configurationKeys!,
        nowMillis: nowMillis);
    final checked = <policy.VerifiedConfiguration>[];
    for (final value in values) {
      checked.add(await verifier.verify(value.compact, restoration: true));
      _check(epoch);
    }
    _baseline = List.unmodifiable(checked);
  }

  bool _matches(VerifiedAccessWindow window) {
    final bases = _baseline
        .where((v) =>
            v.policyId == window.policyId &&
            v.versionId == window.baseVersionId &&
            v.action == 'UPSERT_CONFIGURATION')
        .toList();
    if (bases.length != 1) return false;
    final document = bases.single.document;
    final apps = (document?['applications'] as List? ?? [])
        .whereType<Map>()
        .where((a) => a['id'] == window.applicationId)
        .toList();
    if (apps.length != 1 ||
        apps.single['profile'] != 'PRIMARY' ||
        (document?['protectedPackageExemptions'] as List? ?? [])
            .contains((apps.single['packageName'] as String?)?.toLowerCase())) {
      return false;
    }
    final rules = (document?['rules'] as List? ?? []).whereType<Map>().toList();
    bool validSourceIds(Object? ids) =>
        ids is List &&
        ids.isNotEmpty &&
        ids.length <= 256 &&
        ids.every((value) =>
            value is String &&
            RegExp(r'^[a-z][a-z0-9_-]{0,49}$').hasMatch(value)) &&
        ids.toSet().length == ids.length;
    if (rules.any((r) => !validSourceIds(r['sourceRuleIds']))) return false;
    return window.ruleIds.every((id) {
      // Delivery contains compiled evaluations, not editable policy rules.
      // A group retains the original IDs; predictedEffect never proves execution.
      final candidates = rules.where((r) {
        final ids = r['sourceRuleIds'];
        return (ids as List).contains(id);
      }).toList();
      if (candidates.length != 1) return false;
      final r = candidates.single;
      return (r['applicationId'] == null ||
              r['applicationId'] == window.applicationId) &&
          (r['kind'] == 'TIME_WINDOW' && r['predictedEffect'] == 'ALLOW' ||
              r['kind'] == 'APP_LAUNCH' &&
                  r['predictedEffect'] == 'DENY' &&
                  r['applicationId'] == window.applicationId);
    });
  }

  String _name(VerifiedAccessWindow window) {
    for (final base in _baseline) {
      if (base.policyId != window.policyId ||
          base.versionId != window.baseVersionId) continue;
      for (final app in base.document?['applications'] as List? ?? []) {
        if (app is Map &&
            app['id'] == window.applicationId &&
            app['displayName'] is String) {
          final name = (app['displayName'] as String).trim();
          if (name.isNotEmpty && name.length <= 100) return name;
        }
      }
    }
    return '应用临时访问';
  }

  Future<void> _open(AccessDeviceContext context, int epoch) async {
    context.requireIdentity(
        tenantId: identity.tenantId,
        deviceId: identity.deviceId!,
        registrationId: identity.registrationId!);
    final scope = DeviceAccessScope(
        issuer: environment.configurationIssuer,
        tenantId: context.tenantId,
        subjectId: context.subjectId,
        deviceId: context.deviceId,
        registrationId: context.registrationId);
    if (_scope != null && _scope!.storageKey != scope.storageKey) {
      throw const AccessFailure('ACCESS_TARGET_CHANGED');
    }
    if (_journal != null) return;
    final db = await databaseOpener(scope.storageKey);
    try {
      _check(epoch);
    } catch (_) {
      await db.close();
      rethrow;
    }
    _database = db;
    _scope = scope;
    _journal = AccessWindowJournal(
        database: db,
        verifier: AccessWindowVerifier(
            scope: scope,
            trustedKeys: environment.configurationKeys!,
            nowMillis: nowMillis),
        baselineMatches: _matches);
  }

  Future<ChildAccessSnapshot> _snapshot(_Binding binding, int epoch,
      {bool online = false,
      bool hasMore = false,
      List<AccessSyncIssue> issues = const []}) async {
    if (binding.phase != 'VALID' || binding.context == null) {
      return const ChildAccessSnapshot();
    }
    await _refreshBaseline(epoch);
    await _open(binding.context!, epoch);
    _check(epoch);
    final records = await _journal!.inspect();
    _check(epoch);
    final pending = await _journal!.pendingReceipts();
    _check(epoch);
    return ChildAccessSnapshot(
        contextReady: true,
        onlineConfirmed: online,
        hasMore: hasMore,
        lastOnlineAt: binding.checkedAt,
        pendingReceipts: pending.length,
        issues: List.unmodifiable(issues),
        entries: List.unmodifiable(records.map((r) => ChildAccessEntry(
            r, _name(r.window),
            requiresReview: binding.unresolved.contains(r.window.requestId)))));
  }

  @override
  Future<ChildAccessSnapshot> restore() => _enqueue((epoch) async {
        final binding = await _read();
        _check(epoch);
        if (binding == null) return const ChildAccessSnapshot();
        return _snapshot(binding, epoch);
      });
  @override
  Future<ChildAccessSnapshot> synchronize() => _enqueue((epoch) async {
        final previous = await _read();
        _check(epoch);
        final intent = _Binding('CHECKING', previous?.context,
            previous?.checkedAt ?? 0, previous?.unresolved ?? {});
        await _write(intent);
        _check(epoch);
        final transport = _transport = transportFactory?.call() ??
            DeviceAccessTransport(
                apiRoot: environment.apiRoot,
                credential: credential,
                allowLoopbackHttp: environment.allowLoopbackHttp);
        bool contextReceived = false;
        try {
          final context = await transport.context();
          contextReceived = true;
          _check(epoch);
          context.requireIdentity(
              tenantId: identity.tenantId,
              deviceId: identity.deviceId!,
              registrationId: identity.registrationId!);
          if (previous?.context != null &&
              previous!.context!.subjectId != context.subjectId) {
            throw const AccessFailure('ACCESS_TARGET_CHANGED');
          }
          await _refreshBaseline(epoch);
          await _open(context, epoch);
          _check(epoch);
          final sync = DeviceAccessSynchronizer(
              journal: _journal!, transport: transport);
          final result = await sync.synchronize();
          _check(epoch);
          final unresolved = {...?previous?.unresolved}
            ..removeAll(result.observedRequestIds);
          unresolved.addAll(result.issues.map((e) => e.requestId));
          if (unresolved.length > 256) {
            throw const AccessFailure('ACCESS_STATE_LIMIT');
          }
          final checked = _Binding('VALID', context, _time(), unresolved);
          // The final snapshot must validate before restoring offline eligibility.
          final snapshot = await _snapshot(checked, epoch,
              online: true, hasMore: result.hasMore, issues: result.issues);
          await _write(checked);
          _check(epoch);
          return snapshot;
        } on AccessTransportFailure catch (error) {
          if (_paused ||
              _closed ||
              epoch != _epoch ||
              error.code == 'CLIENT_CLOSED') rethrow;
          if (error.status == 401 ||
              error.status == 403 ||
              {
                'DEVICE_CREDENTIAL_UNAVAILABLE',
                'CREDENTIAL_READ_FAILED',
                'ACCESS_TARGET_CHANGED'
              }.contains(error.code)) {
            await _write(_Binding('BLOCKED', previous?.context,
                previous?.checkedAt ?? 0, previous?.unresolved ?? {}));
          } else if (!contextReceived &&
              error.retryable &&
              previous?.phase == 'VALID') {
            await _write(previous!);
          }
          rethrow;
        } on AccessFailure catch (error) {
          if (error.code == 'ACCESS_TARGET_CHANGED') {
            await _write(_Binding('BLOCKED', previous?.context,
                previous?.checkedAt ?? 0, previous?.unresolved ?? {}));
          }
          rethrow;
        } finally {
          transport.close();
          if (identical(_transport, transport)) _transport = null;
        }
      });
  @override
  void pause() {
    _paused = true;
    _epoch++;
    _transport?.close();
  }

  @override
  void resume() {
    if (!_closed) {
      _paused = false;
      _epoch++;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    pause();
    await _tail;
    await _database?.close();
    _database = null;
    _journal = null;
  }
}

class _Binding {
  final String phase;
  final AccessDeviceContext? context;
  final int checkedAt;
  final Set<String> unresolved;
  const _Binding(this.phase, this.context, this.checkedAt, this.unresolved);
}
