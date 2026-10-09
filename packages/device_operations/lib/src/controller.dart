import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'client.dart';
import 'journal.dart';
import 'models.dart';

/// One controller per authenticated actor, tenant, device and registration.
class ExitController extends ChangeNotifier {
  final ExitScope scope;
  final ExitGateway gateway;
  final ExitJournal journal;
  final DateTime Function() clock;
  final String Function() keyFactory;
  final Duration replayWindow;
  ExitController(
      {required this.scope,
      required this.gateway,
      required this.journal,
      DateTime Function()? clock,
      String Function()? keyFactory,
      this.replayWindow = const Duration(hours: 24)})
      : clock = clock ?? (() => DateTime.now().toUtc()),
        keyFactory = keyFactory ?? (() => const Uuid().v4());

  bool _disposed = false, _initialized = false;
  bool busy = false, acknowledged = false;
  DeviceSnapshot? device;
  ExitPreview? preview;
  ExitOperation? operation;
  PendingExit? pending;
  ExitFailure? error;
  bool get initialized => _initialized;
  bool get previewExpired =>
      preview != null && !clock().isBefore(preview!.expiresAt);
  bool get canConfirm =>
      !_disposed &&
      _initialized &&
      scope.canManage &&
      !busy &&
      pending == null &&
      preview != null &&
      preview!.understood &&
      acknowledged &&
      !previewExpired;
  bool get canPrepare =>
      !_disposed &&
      _initialized &&
      scope.canManage &&
      !busy &&
      pending == null &&
      (operation == null ||
          const {'CLEANUP_CANCELLED', 'CLEANUP_EXPIRED'}
              .contains(operation!.state));
  bool get canRetry =>
      !_disposed &&
      _initialized &&
      scope.canManage &&
      !busy &&
      pending != null &&
      !clock().isBefore(pending!.createdAt) &&
      clock().difference(pending!.createdAt) < replayWindow;
  bool get canCancel =>
      !_disposed &&
      _initialized &&
      scope.canManage &&
      !busy &&
      pending == null &&
      operation != null &&
      operation!.canCancel &&
      clock().isBefore(operation!.notAfter);

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void acknowledge(bool value) {
    if (_disposed || busy || pending != null) return;
    acknowledged =
        value && preview != null && preview!.understood && !previewExpired;
    _emit();
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_disposed || busy) return;
    busy = true;
    error = null;
    _emit();
    try {
      await task();
    } on ExitFailure catch (e) {
      error = e;
    } catch (_) {
      error = const ExitFailure('CLIENT_FAILURE', '操作未完成，请核对状态。');
    } finally {
      busy = false;
      _emit();
    }
  }

  void _checkOperation(ExitOperation value, {String? id}) {
    if (!value.matches(scope) || (id != null && value.id != id)) {
      throw const ExitFailure('RESPONSE_INVALID', '操作响应与当前设备不符，请联系管理员。',
          outcomeUnknown: true);
    }
  }

  Future<void> initialize() => _run(() async {
        _initialized = false;
        preview = null;
        acknowledged = false;
        if (!scope.canRead) {
          throw const ExitFailure('SCOPE_DENIED', '当前账号无权查看此设备的退出操作。');
        }
        try {
          pending = await journal.read(scope);
        } catch (_) {
          throw const ExitFailure('JOURNAL_UNAVAILABLE', '无法读取操作恢复记录，请检查本地存储。');
        }
        if (_disposed) return;
        if (pending != null &&
            pending!.registrationId != scope.registrationId) {
          throw const ExitFailure('JOURNAL_INVALID', '恢复记录与当前注册不符，请联系管理员。');
        }
        // A recovered write is never sent automatically.
        if (pending == null) {
          final values = await gateway.operations(scope);
          if (_disposed) return;
          for (final value in values) {
            _checkOperation(value);
          }
          if (values.isNotEmpty) {
            operation =
                values.reduce((a, b) => a.issuedAt.isAfter(b.issuedAt) ? a : b);
          }
        }
        _initialized = true;
      });
  Future<void> prepare() async {
    if (!canPrepare) return;
    await _run(() async {
      preview = null;
      acknowledged = false;
      final snapshot = await gateway.device(scope);
      if (_disposed) return;
      if (snapshot.id != scope.deviceId ||
          snapshot.registrationId != scope.registrationId ||
          !snapshot.canExit) {
        throw const ExitFailure(
            'DEPROVISION_ACTION_UNSUPPORTED', '设备模式或注册已变化，请刷新设备详情。');
      }
      device = snapshot;
      final value = await gateway.preview(scope, snapshot.version);
      if (_disposed) return;
      if (!value.matches(scope) || value.deviceVersion != snapshot.version) {
        throw const ExitFailure('RESPONSE_INVALID', '预览与当前设备不符。');
      }
      preview = value;
    });
  }

  Future<void> _persist(PendingExit value) async {
    try {
      await journal.write(scope, value);
    } catch (_) {
      throw const ExitFailure('JOURNAL_UNAVAILABLE', '无法保存操作恢复记录，尚未发送请求。');
    }
    pending = value;
  }

  Future<void> confirm() async {
    if (!canConfirm) {
      _emit();
      return;
    }
    final value = preview!;
    await _run(() async {
      await _persist(PendingExit(
          kind: PendingKind.confirm,
          key: keyFactory(),
          registrationId: scope.registrationId,
          version: value.deviceVersion,
          createdAt: clock(),
          previewId: value.id,
          previewHash: value.hash));
      if (!_disposed) await _submitPending();
    });
  }

  Future<void> retryPending() async {
    if (!canRetry) return;
    await _run(_submitPending);
  }

  Future<void> _clearPending() async {
    try {
      await journal.clear(scope);
    } catch (_) {
      throw const ExitFailure(
          'JOURNAL_UNAVAILABLE', '服务端已响应，但恢复记录未清除。请核对上次提交。');
    }
    pending = null;
  }

  Future<void> _submitPending() async {
    final request = pending!;
    ExitOperation result;
    try {
      result = request.kind == PendingKind.confirm
          ? await gateway.confirm(scope,
              previewId: request.previewId!,
              previewHash: request.previewHash!,
              deviceVersion: request.version,
              key: request.key)
          : await gateway.cancel(scope,
              operationId: request.operationId!,
              version: request.version,
              key: request.key);
      _checkOperation(result,
          id: request.kind == PendingKind.cancel ? request.operationId : null);
    } on ExitFailure catch (failure) {
      // Reauthentication/permission changes can occur after a previous request
      // committed: keep its identity until explicit reconciliation.
      if (!failure.outcomeUnknown &&
          !const {
            'REAUTH_REQUIRED',
            'SCOPE_DENIED',
            'IDEMPOTENCY_KEY_EXPIRED',
            'IDEMPOTENCY_KEY_CONFLICT'
          }.contains(failure.code)) {
        await _clearPending();
        preview = null;
        acknowledged = false;
      }
      rethrow;
    } catch (_) {
      throw const ExitFailure('SUBMISSION_UNKNOWN', '提交结果待确认，请核对上次提交。',
          outcomeUnknown: true);
    }
    if (_disposed) return;
    operation = result;
    preview = null;
    acknowledged = false;
    await _clearPending();
    if (_disposed) return;
    // Idempotency replay returns its original snapshot, not the current state.
    final current = await gateway.operation(scope, result.id);
    if (_disposed) return;
    _checkOperation(current, id: result.id);
    if (current.version < result.version) {
      throw const ExitFailure('RESPONSE_INVALID', '当前状态版本异常，请稍后刷新。');
    }
    operation = current;
  }

  Future<void> refresh() => _run(() async {
        if (!scope.canRead) {
          throw const ExitFailure('SCOPE_DENIED', '当前账号无权查看操作状态。');
        }
        if (operation == null) {
          final values = await gateway.operations(scope);
          if (_disposed) return;
          for (final value in values) {
            _checkOperation(value);
          }
          if (values.isNotEmpty) {
            operation =
                values.reduce((a, b) => a.issuedAt.isAfter(b.issuedAt) ? a : b);
          }
        } else {
          final current = await gateway.operation(scope, operation!.id);
          if (_disposed) return;
          _checkOperation(current, id: operation!.id);
          if (current.version < operation!.version) {
            throw const ExitFailure('RESPONSE_INVALID', '状态版本异常，请稍后刷新。');
          }
          operation = current;
        }
        // Viewing history is not proof that an unknown write was rejected.
      });
  Future<void> cancel({required bool acceptedWarning}) async {
    if (!acceptedWarning || !canCancel) return;
    final value = operation!;
    await _run(() async {
      await _persist(PendingExit(
          kind: PendingKind.cancel,
          key: keyFactory(),
          registrationId: scope.registrationId,
          version: value.version,
          createdAt: clock(),
          operationId: value.id));
      if (!_disposed) await _submitPending();
    });
  }
}
