import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'api.dart';
import 'family_identity_repository.dart';

abstract interface class IdentityProviderOperationStorage {
  String? read(String key);
  void write(String key, String value);
  void remove(String key);
}

class IdentityProviderMemoryStorage
    implements IdentityProviderOperationStorage {
  final _values = <String, String>{};
  @override
  String? read(String key) => _values[key];
  @override
  void write(String key, String value) => _values[key] = value;
  @override
  void remove(String key) => _values.remove(key);
}

class IdentityProviderPendingOperation {
  final String id, type;
  const IdentityProviderPendingOperation(this.id, this.type);
  Json toJson() => {'id': id, 'type': type};
  factory IdentityProviderPendingOperation.parse(String value) {
    if (value.length > 256) {
      throw const ApiFailure(409, 'IDENTITY_PROVIDER_RECOVERY_UNAVAILABLE');
    }
    final decoded = jsonDecode(value);
    if (decoded is! Json ||
        decoded.length != 2 ||
        decoded['id'] is! String ||
        !isIdentityProviderId(decoded['id']) ||
        !const {
          'VERSION',
          'RELEASE',
          'ACCEPTANCE',
          'PUBLISH',
          'ROLLBACK',
          'CHECK',
          'CANCELLATION'
        }.contains(decoded['type'])) {
      throw const ApiFailure(409, 'IDENTITY_PROVIDER_RECOVERY_UNAVAILABLE');
    }
    return IdentityProviderPendingOperation(decoded['id'], decoded['type']);
  }
}

/// The journal contains only an operation type and UUID. Secret payloads are never retained.
class FamilyIdentityController extends ChangeNotifier {
  final FamilyIdentityRepository repository;
  final String actor;
  final bool Function() current, canManage, canTest, canPublish, canRollback;
  final VoidCallback clearSensitiveInput;
  final IdentityProviderOperationStorage storage;
  IdentityProviderStatus? status;
  IdentityProviderVersion? version;
  IdentityProviderValidation? validation;
  IdentityProviderReleasePreparation? preparation;
  IdentityProviderAcceptanceRun? acceptance;
  IdentityProviderAcceptanceStatus? acceptanceStatus;
  List<IdentityProviderAcceptanceRun>? acceptanceHistory;
  IdentityProviderReleaseStatus? releaseStatus;
  IdentityProviderRuntimeCheck? runtimeCheck;
  IdentityProviderPendingOperation? pending;
  bool busy = false,
      invalidated = false,
      restored = false,
      needsReauthentication = false;
  bool _disposed = false;
  String? errorMessage, message;
  FamilyIdentityController(
      {required this.repository,
      required this.actor,
      required this.current,
      required this.canManage,
      required this.canTest,
      bool Function()? canPublish,
      bool Function()? canRollback,
      required this.clearSensitiveInput,
      IdentityProviderOperationStorage? storage})
      : storage = storage ?? IdentityProviderMemoryStorage(),
        canPublish = canPublish ?? _noPermission,
        canRollback = canRollback ?? _noPermission;
  static bool _noPermission() => false;
  String get storageKey =>
      'ai-manager.identity-providers.operation.v1.${sha256.convert(utf8.encode(actor))}';
  bool get active => !_disposed && !invalidated && current();
  bool get canSave =>
      active &&
      !needsReauthentication &&
      !busy &&
      restored &&
      pending == null &&
      canManage() &&
      status?.capabilities.canManage == true &&
      status?.capabilities.secretStorageReady == true;
  bool get canValidate =>
      active &&
      !needsReauthentication &&
      !busy &&
      restored &&
      pending == null &&
      version != null &&
      canTest() &&
      status?.capabilities.canTest == true;
  bool get canPrepare =>
      active &&
      !needsReauthentication &&
      !busy &&
      restored &&
      pending == null &&
      version != null &&
      canManage() &&
      status?.capabilities.canManage == true &&
      status?.capabilities.releasePreparationReady == true;
  bool get canStartCurrentAcceptance {
    final aggregate = acceptanceStatus,
        release = releaseStatus,
        confirmed = release?.confirmedOperation,
        latest = status;
    if (!canValidate ||
        aggregate == null ||
        release == null ||
        confirmed == null ||
        latest == null ||
        release.activeOperation != null ||
        aggregate.nextAction != 'REGISTER_RUN' ||
        aggregate.environmentId != latest.environmentId ||
        aggregate.environmentId != release.environmentId ||
        aggregate.versionId != version?.id ||
        aggregate.versionId != confirmed.versionId ||
        aggregate.confirmedOperationId != confirmed.id ||
        aggregate.runtimeRevision != release.runtimeRevision ||
        release.runtimeStatus != 'APPLIED_CLOSED') return false;
    final run = aggregate.latestRun;
    return run?.releaseOperationId != confirmed.id ||
        run!.providerJarSha256 == confirmed.providerJarSha256 &&
            run.parentApkSha256 == confirmed.parentApkSha256;
  }

  bool get _releaseReady =>
      active &&
      !needsReauthentication &&
      !busy &&
      restored &&
      pending == null &&
      releaseStatus != null;
  bool get canPublishRelease =>
      _releaseReady &&
      canPublish() &&
      releaseStatus!.executorReady &&
      releaseStatus!.activeOperation == null &&
      preparation?.status == 'PREPARED' &&
      preparation?.versionId == version?.id;
  bool get canRollbackRelease =>
      _releaseReady &&
      canRollback() &&
      releaseStatus!.executorReady &&
      releaseStatus!.activeOperation == null &&
      releaseStatus!.rollbackTargets.isNotEmpty;
  bool get canCheckRuntime =>
      _releaseReady &&
      canTest() &&
      status?.capabilities.canTest == true &&
      releaseStatus!.observationReady &&
      releaseStatus!.activeOperation?.canCheckRuntime == true;
  bool get canCancelRelease =>
      _releaseReady &&
      releaseStatus!.activeOperation?.canCancel == true &&
      releaseStatus!.activeOperation?.state == 'WAITING_EXECUTOR' &&
      (releaseStatus!.activeOperation!.kind == 'ROLLBACK'
          ? canRollback()
          : canPublish());
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _refreshReleaseStatus() async {
    final result = await repository.releaseStatus();
    if (status != null && result.environmentId != status!.environmentId) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    if (active) {
      releaseStatus = result;
      final relevantOperation =
          result.activeOperation?.id ?? result.confirmedOperation?.id;
      if (runtimeCheck != null &&
          runtimeCheck!.operationId != relevantOperation) {
        runtimeCheck = null;
      }
    }
  }

  Future<void> _refreshAcceptanceStatus() async {
    if (active) {
      acceptanceStatus = null;
      acceptanceHistory = null;
    }
    final result = await repository.acceptanceStatus();
    if (status == null || result.environmentId != status!.environmentId) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    if (active) {
      acceptanceStatus = result;
      acceptance = result.latestRun;
    }
  }

  Future<void> loadAcceptanceHistory() async {
    if (busy || !active || needsReauthentication) return;
    busy = true;
    acceptanceHistory = null;
    errorMessage = null;
    _notify();
    try {
      final runs = await repository.acceptanceRuns();
      if (status == null ||
          runs.any((run) => run.environmentId != status!.environmentId)) {
        throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
      }
      if (active) acceptanceHistory = runs;
    } catch (failure) {
      if (active) _error(failure);
    } finally {
      busy = false;
      if (active) _notify();
    }
  }

  void _error(Object failure) {
    final safe = identityProviderSafeFailure(failure);
    if (safe.status == 401) needsReauthentication = true;
    if (needsReauthentication) clearSensitiveInput();
    errorMessage =
        identityProviderErrorMessage(failure is ApiFailure ? failure : safe);
  }

  void clearInputs() {
    clearSensitiveInput();
    _notify();
  }

  void prepareReauthentication() {
    clearSensitiveInput();
  }

  void invalidate() {
    if (_disposed || invalidated) return;
    invalidated = true;
    clearSensitiveInput();
    status = null;
    version = null;
    validation = null;
    preparation = null;
    acceptance = null;
    acceptanceStatus = null;
    acceptanceHistory = null;
    releaseStatus = null;
    runtimeCheck = null;
    errorMessage = null;
    message = null;
    _notify();
  }

  void _restore() {
    try {
      final value = storage.read(storageKey);
      pending =
          value == null ? null : IdentityProviderPendingOperation.parse(value);
      restored = true;
    } catch (_) {
      throw const ApiFailure(409, 'IDENTITY_PROVIDER_RECOVERY_UNAVAILABLE');
    }
  }

  Future<void> load() async {
    if (busy || !active) return;
    busy = true;
    acceptanceStatus = null;
    acceptanceHistory = null;
    if (canPublish()) preparation = null;
    errorMessage = null;
    _notify();
    try {
      if (!restored) _restore();
      final result = await repository.status();
      if (active) {
        if (version?.id != result.version?.id) {
          validation = null;
          preparation = null;
          acceptance = null;
        }
        status = result;
        version = result.version;
        needsReauthentication = false;
        try {
          if (canPublish() && result.version != null) {
            final prepared =
                await repository.releasePreparations(result.version!.id);
            if (active) {
              for (final item in prepared) {
                if (item.status == 'PREPARED') {
                  preparation = item;
                  break;
                }
              }
            }
          }
          await _refreshReleaseStatus();
        } catch (failure) {
          if (active) {
            releaseStatus = null;
            runtimeCheck = null;
            _error(failure);
          }
        }
        try {
          if (!needsReauthentication) await _refreshAcceptanceStatus();
        } catch (failure) {
          if (active) _error(failure);
        }
      }
    } catch (failure) {
      if (active) {
        releaseStatus = null;
        runtimeCheck = null;
        _error(failure);
      }
    } finally {
      busy = false;
      if (active) _notify();
    }
  }

  void _remember(IdentityProviderPendingOperation operation) {
    try {
      storage.write(storageKey, jsonEncode(operation.toJson()));
      pending = operation;
    } catch (_) {
      restored = false;
      throw const ApiFailure(409, 'IDENTITY_PROVIDER_RECOVERY_UNAVAILABLE');
    }
  }

  void _forget() {
    try {
      storage.remove(storageKey);
      pending = null;
    } catch (_) {
      restored = false;
      throw const ApiFailure(409, 'IDENTITY_PROVIDER_RECOVERY_UNAVAILABLE');
    }
  }

  Future<void> _write(String type, Future<void> Function(String) operation,
      {bool Function()? stillPending}) async {
    if (busy || !active) return;
    if (!restored || pending != null) {
      errorMessage = identityProviderErrorMessage(
          const ApiFailure(409, 'IDENTITY_PROVIDER_OPERATION_PENDING'));
      _notify();
      return;
    }
    busy = true;
    errorMessage = null;
    message = null;
    needsReauthentication = false;
    _notify();
    final id = const Uuid().v4();
    try {
      _remember(IdentityProviderPendingOperation(id, type));
      await operation(id);
      if (active && stillPending?.call() != true) _forget();
    } catch (failure) {
      if (active) {
        if (failure is ApiFailure &&
            failure.status >= 400 &&
            failure.status < 500 &&
            failure.code != 'IDENTITY_PROVIDER_RECOVERY_UNAVAILABLE') {
          try {
            _forget();
          } catch (_) {
            restored = false;
          }
        }
        _error(failure);
      }
    } finally {
      busy = false;
      if (active) _notify();
    }
  }

  Future<void> save(IdentityProviderSettings settings,
      {Map<String, String> replacements = const {},
      bool clearSmsSecurityToken = false}) async {
    if (busy || !active) return;
    if (!canSave) {
      clearSensitiveInput();
      _error(const ApiFailure(403, 'SCOPE_DENIED'));
      _notify();
      return;
    }
    final baseVersion = version?.version ?? 0;
    final outgoing = Map<String, String>.of(replacements);
    clearSensitiveInput();
    await _write('VERSION', (id) async {
      final result = await repository.saveVersion(id, baseVersion, settings,
          replacements: outgoing, clearSmsSecurityToken: clearSmsSecurityToken);
      if (active) {
        version = result;
        validation = null;
        preparation = null;
        acceptance = null;
        acceptanceStatus = null;
        acceptanceHistory = null;
        message = '配置版本已保存；运行服务仍需受控发布。';
      }
    });
  }

  Future<void> validate() async {
    if (!canValidate) return;
    busy = true;
    errorMessage = null;
    message = null;
    _notify();
    try {
      final result = await repository.validate(version!.id);
      if (active) {
        validation = result;
        message = '配置检查已完成；真实短信和微信仍需联调。';
      }
    } catch (failure) {
      if (active) _error(failure);
    } finally {
      busy = false;
      if (active) _notify();
    }
  }

  Future<void> prepareRelease() async {
    if (!canPrepare) return;
    final versionId = version!.id;
    await _write('RELEASE', (id) async {
      final result = await repository.prepareRelease(id, versionId);
      if (active) {
        preparation = result;
        message = result.status == 'PREPARED'
            ? '发布准备已生成，请由部署管理员受控应用；尚未生效。'
            : '发布准备尚未完成，请检查准备条件。';
      }
    });
  }

  Future<void> startAcceptance(
      String environmentId, String jarSha256, String apkSha256) async {
    if (!canValidate) return;
    final versionId = version!.id;
    await _write('ACCEPTANCE', (id) async {
      final result = await repository.startAcceptance(
          id, versionId, environmentId, jarSha256, apkSha256);
      if (active) {
        acceptance = result;
        message = '已建立联调清单；12 项真实验收仍待完成。';
      }
    });
  }

  Future<void> startCurrentAcceptance() async {
    if (!canStartCurrentAcceptance) return;
    final confirmed = releaseStatus!.confirmedOperation!,
        aggregate = acceptanceStatus!,
        revision = releaseStatus!.runtimeRevision;
    await _write('ACCEPTANCE', (id) async {
      final result = await repository.startAcceptance(
          id,
          confirmed.versionId,
          aggregate.environmentId,
          confirmed.providerJarSha256,
          confirmed.parentApkSha256,
          releaseOperationId: confirmed.id,
          expectedRuntimeRevision: revision);
      if (active) {
        acceptance = result;
        await _refreshAcceptanceStatus();
        message = '本次验收已登记，真实结果仍待核对；购买保持关闭。';
      }
    });
  }

  Future<void> publish(String providerJarSha256, String parentApkSha256) async {
    if (!canPublishRelease) return;
    final targetVersion = version!.id,
        preparationId = preparation!.id,
        revision = releaseStatus!.runtimeRevision;
    await _write('PUBLISH', (id) async {
      await repository.requestRelease(id, 'PUBLISH', targetVersion,
          preparationId, revision, providerJarSha256, parentApkSha256);
      if (active) {
        message = '发布请求已登记，等待部署执行和实例核对；登录入口保持关闭。';
        await _refreshReleaseStatus();
      }
    });
  }

  Future<void> rollback(IdentityProviderReleaseTarget target) async {
    if (!canRollbackRelease) return;
    final offered = releaseStatus!.rollbackTargets.any((item) =>
        item.versionId == target.versionId &&
        item.preparationId == target.preparationId &&
        item.providerJarSha256 == target.providerJarSha256 &&
        item.parentApkSha256 == target.parentApkSha256 &&
        item.confirmedAt == target.confirmedAt);
    if (!offered) {
      _error(const ApiFailure(409, 'IDENTITY_PROVIDER_ROLLBACK_NOT_ALLOWED'));
      _notify();
      return;
    }
    final revision = releaseStatus!.runtimeRevision;
    await _write('ROLLBACK', (id) async {
      await repository.requestRelease(
          id,
          'ROLLBACK',
          target.versionId,
          target.preparationId,
          revision,
          target.providerJarSha256,
          target.parentApkSha256);
      if (active) {
        message = '回退请求已登记，等待部署执行和实例核对；登录入口保持关闭。';
        await _refreshReleaseStatus();
      }
    });
  }

  Future<void> checkReleaseRuntime() async {
    if (!canCheckRuntime) return;
    final operation = releaseStatus!.activeOperation!;
    var checking = false;
    await _write('CHECK', (id) async {
      final result = await repository.checkRuntime(id, operation.id);
      if (result.versionId != operation.versionId) {
        throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
      }
      if (active) {
        checking = result.state == 'CHECKING';
        runtimeCheck = result;
        message = checking
            ? '实例核对仍在进行，请查询原检查结果。'
            : result.state == 'CONFIRMED'
                ? '全部身份实例已确认加载，登录入口仍待真实联调验收。'
                : '尚未确认全部实例生效，请查看待处理项目后再核对。';
        await _refreshReleaseStatus();
      }
    }, stillPending: () => checking);
  }

  Future<void> cancelRelease() async {
    if (!canCancelRelease) return;
    final operation = releaseStatus!.activeOperation!,
        revision = releaseStatus!.runtimeRevision;
    await _write('CANCELLATION', (id) async {
      await repository.cancelRelease(id, operation.id, revision);
      if (active) {
        message = '尚未领取的部署任务已取消，当前已确认配置保持原状。';
        await _refreshReleaseStatus();
      }
    });
  }

  Future<void> recover() async {
    if (busy || !active) return;
    if (!restored) {
      try {
        _restore();
      } catch (failure) {
        _error(failure);
        _notify();
        return;
      }
    }
    final original = pending;
    if (original == null) return;
    busy = true;
    errorMessage = null;
    message = null;
    _notify();
    try {
      switch (original.type) {
        case 'VERSION':
          final result = await repository.version(original.id);
          if (active &&
              (version == null || result.version >= version!.version)) {
            version = result;
          }
        case 'RELEASE':
          final result = await repository.releasePreparation(original.id);
          if (active) {
            preparation = result.versionId == version?.id ? result : null;
          }
        case 'ACCEPTANCE':
          final result = await repository.acceptanceRun(original.id);
          if (active) {
            acceptance = result.versionId == version?.id ? result : null;
          }
          if (result.releaseOperationId != null) {
            await _refreshAcceptanceStatus();
          }
        case 'PUBLISH':
        case 'ROLLBACK':
          final operation = await repository.releaseOperation(original.id);
          if (operation.kind != original.type) {
            throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
          }
          await _refreshReleaseStatus();
        case 'CHECK':
          final check = await repository.runtimeCheck(original.id);
          await _refreshReleaseStatus();
          if (active) {
            runtimeCheck = check.operationId ==
                    (releaseStatus?.activeOperation?.id ??
                        releaseStatus?.confirmedOperation?.id)
                ? check
                : null;
            if (check.state == 'CHECKING') {
              message = '原实例核对仍在进行，请稍后再次查询。';
              return;
            }
          }
        case 'CANCELLATION':
          await repository.cancellation(original.id);
          await _refreshReleaseStatus();
      }
      if (active) {
        _forget();
        message = '原操作结果已核对，没有重新提交。';
      }
    } catch (failure) {
      if (active) {
        if (failure is ApiFailure && failure.status == 404) {
          try {
            _forget();
          } catch (_) {
            restored = false;
          }
          message = '未找到原操作；请刷新当前配置，再重新填写。';
        } else {
          _error(failure);
        }
      }
    } finally {
      busy = false;
      if (active) _notify();
    }
  }

  @override
  void dispose() {
    if (!_disposed) clearSensitiveInput();
    _disposed = true;
    super.dispose();
  }
}
