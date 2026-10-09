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
import 'submissions.dart';

/// Foreground request owner. Context intent is persisted before network checks;
/// mutation intent is persisted before sending. No automatic mutation retries.
class ChildSubmissionReceiver implements ChildSubmissions {
  final ChildEnvironment environment;
  final DeviceIdentityView identity;
  final Future<String?> Function() credential;
  final int Function() nowMillis;
  final ChildAccessBindingStore bindingStore;
  final Future<Database> Function(String, {required bool existingDatabase})
      databaseOpener;
  final DeviceAccessTransport Function()? transportFactory;
  late final String _bindingKey, _issuer;
  Future<void> _tail = Future.value();
  Database? _database;
  AccessSubmissionJournal? _journal;
  String? _scopeKey;
  DeviceAccessTransport? _transport;
  bool _closed = false, _paused = false;
  int _epoch = 0;
  final _options = <AccessSubmissionOption>[];
  final _confirmed = <String>{};
  String? _optionsCursor, _requestsCursor;
  ChildSubmissionReceiver(
      {required this.environment,
      required this.identity,
      required this.credential,
      required this.nowMillis,
      ChildAccessBindingStore? bindingStore,
      Future<Database> Function(String, {required bool existingDatabase})?
          databaseOpener,
      this.transportFactory})
      : bindingStore = bindingStore ?? AndroidAccessBindingStore(),
        databaseOpener = databaseOpener ??
            ((key, {required existingDatabase}) =>
                openAccessDatabase(key, requireExisting: existingDatabase)) {
    if (identity.deviceId == null || identity.registrationId == null) {
      throw const AccessFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
    }
    // Purpose and immutable origin isolate both the key and the file from signed windows.
    _issuer = 'child-submissions-v1|${environment.apiRoot}';
    _bindingKey = policy.DevicePolicyScope(
            issuer: _issuer,
            tenantId: identity.tenantId,
            deviceId: identity.deviceId!,
            registrationId: identity.registrationId!)
        .storageKey;
  }
  void _check(int epoch) {
    if (_closed || _paused || epoch != _epoch) {
      throw const AccessFailure('SUBMISSION_PAUSED');
    }
  }

  Future<ChildSubmissionSnapshot> _enqueue(
      Future<ChildSubmissionSnapshot> Function(int) action) {
    final epoch = _epoch;
    final future = _tail.then((_) {
      _check(epoch);
      return action(epoch);
    });
    _tail = future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return future;
  }

  int _time() {
    final now = nowMillis();
    if (!accessInteger(now, 0)) throw const AccessFailure('CLOCK_UNTRUSTED');
    return now;
  }

  Future<_ContextBinding?> _read() async {
    try {
      final text = await bindingStore.read(_bindingKey);
      if (text == null) return null;
      if (text.length > 8192) throw const FormatException();
      final row = jsonDecode(text);
      if (row is! Map<String, dynamic> ||
          row.length != 4 ||
          row['schemaVersion'] != 1 ||
          !{'VALID', 'CHECKING', 'BLOCKED'}.contains(row['phase']) ||
          !accessInteger(row['checkedAt'], 0)) throw const FormatException();
      final context = row['context'] == null
          ? null
          : AccessDeviceContext.fromJson(
              Map<String, dynamic>.from(row['context'] as Map));
      context?.requireIdentity(
          tenantId: identity.tenantId,
          deviceId: identity.deviceId!,
          registrationId: identity.registrationId!);
      if (row['phase'] == 'VALID' && context == null) {
        throw const FormatException();
      }
      if (row['checkedAt'] > _time()) {
        throw const AccessFailure('CLOCK_UNTRUSTED');
      }
      return _ContextBinding(row['phase'], context, row['checkedAt']);
    } on AccessFailure {
      rethrow;
    } catch (_) {
      throw const AccessFailure('SUBMISSION_CONTEXT_INVALID');
    }
  }

  Future<void> _write(_ContextBinding binding) => bindingStore.write(
      _bindingKey,
      jsonEncode({
        'schemaVersion': 1,
        'phase': binding.phase,
        'checkedAt': binding.checkedAt,
        'context': binding.context == null
            ? null
            : {
                'tenantId': binding.context!.tenantId,
                'subjectId': binding.context!.subjectId,
                'deviceId': binding.context!.deviceId,
                'registrationId': binding.context!.registrationId
              }
      }));
  Future<void> _open(AccessDeviceContext context, int epoch,
      {required bool existingDatabase}) async {
    context.requireIdentity(
        tenantId: identity.tenantId,
        deviceId: identity.deviceId!,
        registrationId: identity.registrationId!);
    final scope = DeviceAccessScope(
        issuer: _issuer,
        tenantId: context.tenantId,
        subjectId: context.subjectId,
        deviceId: context.deviceId,
        registrationId: context.registrationId);
    if (_scopeKey != null && _scopeKey != scope.storageKey) {
      throw const AccessFailure('ACCESS_TARGET_CHANGED');
    }
    if (_journal != null) return;
    final db = await databaseOpener(scope.storageKey,
        existingDatabase: existingDatabase);
    try {
      _check(epoch);
    } catch (_) {
      await db.close();
      rethrow;
    }
    _database = db;
    _scopeKey = scope.storageKey;
    _journal = AccessSubmissionJournal(database: db, scope: scope);
  }

  Future<ChildSubmissionSnapshot> _snapshot(_ContextBinding? binding, int epoch,
      {bool online = false}) async {
    if (binding?.phase != 'VALID' || binding?.context == null) {
      return const ChildSubmissionSnapshot();
    }
    await _open(binding!.context!, epoch, existingDatabase: true);
    final view = await _journal!.inspect();
    _check(epoch);
    return ChildSubmissionSnapshot(
        journal: view,
        contextReady: true,
        onlineConfirmed: online,
        lastCheckedAt: binding.checkedAt,
        options: List.unmodifiable(_options),
        optionsCursor: _optionsCursor,
        requestsCursor: _requestsCursor,
        confirmedRequestIds: online ? Set.unmodifiable(_confirmed) : const {});
  }

  Future<ChildSubmissionSnapshot> _online(
      int epoch,
      Future<void> Function(DeviceAccessTransport, AccessDeviceContext)
          action) async {
    final previous = await _read();
    _check(epoch);
    await _write(_ContextBinding(
        'CHECKING', previous?.context, previous?.checkedAt ?? 0));
    _check(epoch);
    final transport = _transport = transportFactory?.call() ??
        DeviceAccessTransport(
            apiRoot: environment.apiRoot,
            credential: credential,
            allowLoopbackHttp: environment.allowLoopbackHttp);
    bool received = false;
    try {
      final context = await transport.context();
      received = true;
      _check(epoch);
      context.requireIdentity(
          tenantId: identity.tenantId,
          deviceId: identity.deviceId!,
          registrationId: identity.registrationId!);
      if (previous?.context != null &&
          previous!.context!.subjectId != context.subjectId) {
        throw const AccessFailure('ACCESS_TARGET_CHANGED');
      }
      await _open(context, epoch, existingDatabase: previous?.context != null);
      await _journal!.inspect();
      _check(epoch);
      final current = _ContextBinding('VALID', context, _time());
      await _write(current);
      _check(epoch);
      await action(transport, context);
      _check(epoch);
      return _snapshot(current, epoch, online: true);
    } on AccessTransportFailure catch (error) {
      if (!_closed && !_paused && epoch == _epoch) {
        if (error.status == 401 ||
            error.status == 403 ||
            {'DEVICE_CREDENTIAL_UNAVAILABLE', 'CREDENTIAL_READ_FAILED'}
                .contains(error.code)) {
          _options.clear();
          _confirmed.clear();
          await _write(_ContextBinding(
              'BLOCKED', previous?.context, previous?.checkedAt ?? 0));
        } else if (!received && error.retryable && previous?.phase == 'VALID') {
          await _write(previous!);
        }
      }
      rethrow;
    } on AccessFailure catch (error) {
      if (error.code == 'ACCESS_TARGET_CHANGED' &&
          !_closed &&
          !_paused &&
          epoch == _epoch) {
        _options.clear();
        _confirmed.clear();
        await _write(_ContextBinding(
            'BLOCKED', previous?.context, previous?.checkedAt ?? 0));
      }
      rethrow;
    } finally {
      transport.close();
      if (identical(_transport, transport)) _transport = null;
    }
  }

  String _name(String app) {
    for (final option in _options) {
      for (final item in option.applications) {
        if (item.id == app) return item.displayName;
      }
    }
    return '应用临时访问';
  }

  Future<void> _loadOptions(DeviceAccessTransport transport, int epoch,
      {required bool more}) async {
    final page =
        await transport.submissionOptions(cursor: more ? _optionsCursor : null);
    _check(epoch);
    if (!more) _options.clear();
    if (_options.length + page.items.length > 200) {
      throw const AccessFailure('SUBMISSION_PAGE_LIMIT');
    }
    _options.addAll(page.items);
    _optionsCursor = page.nextCursor;
  }

  Future<void> _loadRequests(
      DeviceAccessTransport transport, AccessDeviceContext context, int epoch,
      {required bool more}) async {
    final page = await transport.submissions(
        context: context, cursor: more ? _requestsCursor : null);
    _check(epoch);
    for (final value in page.items) {
      await _journal!
          .record(value, applicationName: _name(value.applicationId));
      _check(epoch);
      _confirmed.add(value.id);
    }
    _requestsCursor = page.nextCursor;
  }

  @override
  Future<ChildSubmissionSnapshot> restore() => _enqueue((epoch) async {
        final binding = await _read();
        _check(epoch);
        return _snapshot(binding, epoch);
      });
  @override
  Future<ChildSubmissionSnapshot> refresh() =>
      _enqueue((epoch) => _online(epoch, (transport, context) async {
            _confirmed.clear();
            await _loadOptions(transport, epoch, more: false);
            await _loadRequests(transport, context, epoch, more: false);
          }));
  @override
  Future<ChildSubmissionSnapshot> moreOptions() =>
      _enqueue((epoch) => _online(epoch, (transport, context) async {
            if (_optionsCursor != null) {
              await _loadOptions(transport, epoch, more: true);
            }
          }));
  @override
  Future<ChildSubmissionSnapshot> moreRequests() =>
      _enqueue((epoch) => _online(epoch, (transport, context) async {
            if (_requestsCursor != null) {
              await _loadRequests(transport, context, epoch, more: true);
            }
          }));
  @override
  Future<ChildSubmissionSnapshot> detail(String id) =>
      _enqueue((epoch) => _online(epoch, (transport, context) async {
            final value = await transport.submission(id, context: context);
            _check(epoch);
            await _journal!
                .record(value, applicationName: _name(value.applicationId));
            _check(epoch);
            _confirmed.add(value.id);
          }));
  Future<void> _send(DeviceAccessTransport transport,
      AccessDeviceContext context, int epoch) async {
    final current = (await _journal!.inspect()).pending;
    _check(epoch);
    if (current == null) {
      throw const AccessFailure('SUBMISSION_OPERATION_MISSING');
    }
    final operation = await _journal!.markSending(current.key);
    _check(epoch);
    try {
      final value = operation.kind == 'CREATE'
          ? await transport.createSubmission(operation.input!,
              context: context, idempotencyKey: operation.key)
          : await transport.cancelSubmission(operation.requestId!,
              context: context,
              version: operation.version!,
              idempotencyKey: operation.key);
      _check(epoch);
      await _journal!.complete(operation.key, value);
      _check(epoch);
      _confirmed.add(value.id);
    } on AccessTransportFailure catch (error) {
      if (!_closed &&
          !_paused &&
          epoch == _epoch &&
          !error.outcomeUnknown &&
          error.status != null &&
          error.status! >= 400 &&
          error.status! < 500 &&
          submissionDefinitiveRejections.contains(error.code)) {
        await _journal!.reject(operation.key, error.code);
      }
      rethrow;
    }
  }

  @override
  Future<ChildSubmissionSnapshot> create(AccessSubmissionInput input,
          {required String applicationName, required String key}) =>
      _enqueue((epoch) => _online(epoch, (transport, context) async {
            await _journal!.prepareCreate(input,
                key: key, applicationName: applicationName, now: _time());
            _check(epoch);
            await _send(transport, context, epoch);
          }));
  @override
  Future<ChildSubmissionSnapshot> cancel(AccessSubmission value,
          {required String applicationName, required String key}) =>
      _enqueue((epoch) => _online(epoch, (transport, context) async {
            await _journal!.prepareCancel(value,
                key: key, applicationName: applicationName, now: _time());
            _check(epoch);
            await _send(transport, context, epoch);
          }));
  @override
  Future<ChildSubmissionSnapshot> retry() => _enqueue((epoch) =>
      _online(epoch, (transport, context) => _send(transport, context, epoch)));
  @override
  Future<ChildSubmissionSnapshot> discard() => _enqueue((epoch) async {
        final binding = await _read();
        _check(epoch);
        if (binding?.phase != 'VALID') {
          throw const AccessFailure('SUBMISSION_CONTEXT_INVALID');
        }
        await _open(binding!.context!, epoch, existingDatabase: true);
        final pending = (await _journal!.inspect()).pending;
        _check(epoch);
        if (pending != null) {
          await _journal!.discardUnsentOrRejected(pending.key);
        }
        _check(epoch);
        return _snapshot(binding, epoch);
      });
  @override
  void pause() {
    _paused = true;
    _epoch++;
    _transport?.close();
    _options.clear();
    _confirmed.clear();
  }

  @override
  void resume() {
    if (!_closed && _paused) {
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

class _ContextBinding {
  final String phase;
  final AccessDeviceContext? context;
  final int checkedAt;
  const _ContextBinding(this.phase, this.context, this.checkedAt);
}
