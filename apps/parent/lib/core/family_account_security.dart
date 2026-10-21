import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'parent_api.dart';
import 'parent_durable_storage.dart';
import 'parent_session.dart';

const familyAccountActions = {
  'CHANGE_PHONE',
  'BIND_WECHAT',
  'UNBIND_WECHAT',
  'RECOVER_PHONE'
};

Never _invalidAccountStatus() =>
    throw const ParentApiException(502, 'INVALID_ACCOUNT_SECURITY_RESPONSE');

/// The identity service supplies these facts; business profile fields and
/// client-side OIDC completion are never evidence of an account change.
class FamilyAccountStatus {
  final String subject;
  final String? phoneMasked;
  final bool phoneVerified, wechatBound, accountSecurityAvailable;
  final bool canChangePhone, canBindWechat, canUnbindWechat, canRecoverByWechat;
  final int identityRevision;
  final String? lastOperationId, lastOperationAction;
  final int? lastOperationAt;

  FamilyAccountStatus._(Json value)
      : subject = value['subject'],
        phoneMasked = value['phoneMasked'],
        phoneVerified = value['phoneVerified'],
        wechatBound = value['wechatBound'],
        accountSecurityAvailable = value['accountSecurityAvailable'],
        canChangePhone = value['canChangePhone'],
        canBindWechat = value['canBindWechat'],
        canUnbindWechat = value['canUnbindWechat'],
        canRecoverByWechat = value['canRecoverByWechat'],
        identityRevision = value['identityRevision'],
        lastOperationId = value['lastOperationId'],
        lastOperationAction = value['lastOperationAction'],
        lastOperationAt = value['lastOperationAt'];

  factory FamilyAccountStatus.fromJson(Json value) {
    if (!_validActor(value['subject']) ||
        value['sessionCurrent'] != true ||
        value['identityRevision'] is! int ||
        value['identityRevision'] < 1 ||
        value['identityRevision'] > 9007199254740991 ||
        const [
          'phoneVerified',
          'wechatBound',
          'accountSecurityAvailable',
          'canChangePhone',
          'canBindWechat',
          'canUnbindWechat',
          'canRecoverByWechat'
        ].any((key) => value[key] is! bool)) {
      _invalidAccountStatus();
    }
    final masked = value['phoneMasked'];
    if (masked != null &&
        (masked is! String ||
            !RegExp(r'^1[3-9][0-9]\*{4}[0-9]{4}$').hasMatch(masked))) {
      _invalidAccountStatus();
    }
    if (value['phoneVerified'] == true && masked == null ||
        value['canBindWechat'] == true && value['wechatBound'] == true ||
        (value['canBindWechat'] == true || value['canChangePhone'] == true) &&
            value['phoneVerified'] != true ||
        value['canUnbindWechat'] == true &&
            (value['wechatBound'] != true || value['phoneVerified'] != true) ||
        value['canRecoverByWechat'] == true && value['wechatBound'] != true ||
        value['accountSecurityAvailable'] == false &&
            const [
              'canChangePhone',
              'canBindWechat',
              'canUnbindWechat',
              'canRecoverByWechat'
            ].any((key) => value[key] == true)) {
      _invalidAccountStatus();
    }
    final receipt = value['lastOperationId'];
    if (receipt == null) {
      if (value['lastOperationAction'] != null ||
          value['lastOperationAt'] != null) _invalidAccountStatus();
    } else if (receipt is! String ||
        !Uuid.isValidUUID(fromString: receipt) ||
        !familyAccountActions.contains(value['lastOperationAction']) ||
        value['lastOperationAt'] is! int ||
        value['lastOperationAt'] <= 0) {
      _invalidAccountStatus();
    }
    return FamilyAccountStatus._(value);
  }

  bool permits(String action) =>
      accountSecurityAvailable &&
      switch (action) {
        'CHANGE_PHONE' => canChangePhone,
        'BIND_WECHAT' => canBindWechat,
        'UNBIND_WECHAT' => canUnbindWechat,
        'RECOVER_PHONE' => canRecoverByWechat,
        _ => false,
      };
}

bool _validActor(dynamic value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 200 &&
    !RegExp(r'[\x00-\x20\x7F-\x9F]').hasMatch(value);

class FamilyAccountIdentity {
  final String? subject;
  final int generation;
  final bool authenticated;
  const FamilyAccountIdentity(
      this.subject, this.generation, this.authenticated);

  bool same(FamilyAccountIdentity other) =>
      subject == other.subject &&
      generation == other.generation &&
      authenticated == other.authenticated;
}

/// This journal contains only a reference, never a phone, SMS code, native
/// WeChat authorization code or token. It survives browser cancellation.
class FamilyAccountPending {
  final String action, operationId;
  final String? actor;
  final int? expectedRevision;
  final int createdAt;
  const FamilyAccountPending(
      {required this.action,
      required this.operationId,
      required this.actor,
      required this.expectedRevision,
      required this.createdAt});

  Json toJson() => {
        'schema': 1,
        'action': action,
        'operationId': operationId,
        'actor': actor,
        'expectedRevision': expectedRevision,
        'createdAt': createdAt
      };

  static FamilyAccountPending? decode(String? raw) {
    if (raw == null) return null;
    try {
      final value = raw.length <= 2048 ? jsonDecode(raw) : null;
      if (value is! Json ||
          value.keys.toSet().difference(const {
            'schema',
            'action',
            'operationId',
            'actor',
            'expectedRevision',
            'createdAt'
          }).isNotEmpty ||
          value.length != 6 ||
          value['schema'] != 1 ||
          !familyAccountActions.contains(value['action']) ||
          value['operationId'] is! String ||
          !Uuid.isValidUUID(fromString: value['operationId']) ||
          value['createdAt'] is! int ||
          value['createdAt'] <= 0 ||
          value['actor'] != null && !_validActor(value['actor']) ||
          value['expectedRevision'] != null &&
              (value['expectedRevision'] is! int ||
                  value['expectedRevision'] < 1) ||
          value['action'] != 'RECOVER_PHONE' &&
              (value['actor'] == null || value['expectedRevision'] == null) ||
          (value['actor'] == null) != (value['expectedRevision'] == null)) {
        throw const FormatException();
      }
      return FamilyAccountPending(
          action: value['action'],
          operationId: value['operationId'],
          actor: value['actor'],
          expectedRevision: value['expectedRevision'],
          createdAt: value['createdAt']);
    } catch (_) {
      throw const ParentApiException(502, 'INVALID_ACCOUNT_SECURITY_RECOVERY');
    }
  }
}

typedef FamilyAccountActionRunner = Future<bool> Function(
    {required String action,
    required String operationId,
    int? expectedRevision,
    String? expectedActor});

/// Only the local secure-flow adapter can establish that no browser request
/// was dispatched. Server errors and browser cancellation do not imply this.
class FamilyAccountActionNotStarted extends ParentApiException {
  final Object? reason;
  const FamilyAccountActionNotStarted([this.reason])
      : super(400, 'ACCOUNT_OPERATION_NOT_STARTED');
}

class FamilyAccountSecurityCoordinator extends ChangeNotifier {
  static const storageKey = 'parent.account.security.pending.v1';
  static Future<void>? _storageTail;
  final ParentApi api;
  final FamilyAccountIdentity Function() identity;
  final FamilyAccountActionRunner runAction;
  final ParentDurableStorage storage;
  final DateTime Function() now;
  final String Function() createOperationId;
  final bool recoveryAvailable, actionsAvailable;
  FamilyAccountPending? pending;
  FamilyAccountStatus? status;
  Object? error;
  String? completedAction;
  bool initialized = false, busy = false, storageFailed = false;
  bool _foreground = true, _disposed = false;
  int _epoch = 0;
  FamilyAccountIdentity? _lastIdentity;
  DateTime? _abandonAfter, _statusReadAt;

  FamilyAccountSecurityCoordinator(
      {required this.api,
      required this.identity,
      required this.runAction,
      ParentDurableStorage? storage,
      DateTime Function()? now,
      String Function()? createOperationId,
      this.recoveryAvailable = true,
      this.actionsAvailable = true})
      : storage = storage ?? ParentDurableStorage(),
        now = now ?? DateTime.now,
        createOperationId = createOperationId ?? const Uuid().v4;

  factory FamilyAccountSecurityCoordinator.forSession(
          {required ParentSession session, ParentDurableStorage? storage}) =>
      FamilyAccountSecurityCoordinator(
          api: session.accountSecurityApi,
          identity: () => FamilyAccountIdentity(
              session.profile?['subject'] as String?,
              session.generation,
              session.authenticated),
          runAction: (
              {required action,
              required operationId,
              expectedRevision,
              expectedActor}) async {
            final completed = await session.runAccountAction(
                action: action,
                operationId: operationId,
                expectedRevision: expectedRevision,
                expectedActor: expectedActor);
            if (!completed &&
                !session.accountActionMayHaveStartedFor(operationId)) {
              throw FamilyAccountActionNotStarted(session.error);
            }
            return completed;
          },
          storage: storage,
          actionsAvailable:
              session.configured && session.accountSecurityEnabled,
          recoveryAvailable:
              session.configured && session.accountSecurityEnabled);

  bool get foreground => _foreground;
  bool get needsLogin =>
      !identity().authenticated ||
      error is ParentApiException &&
          (error as ParentApiException).status == 401;
  bool get pendingForAnotherAccount =>
      pending?.actor != null &&
      identity().authenticated &&
      pending!.actor != identity().subject;
  bool get canAcknowledgeCurrentState =>
      initialized &&
      !busy &&
      _foreground &&
      !storageFailed &&
      !pendingForAnotherAccount &&
      pending != null &&
      status != null &&
      identity().authenticated &&
      (pending!.expectedRevision != null &&
              status!.identityRevision > pending!.expectedRevision! ||
          _abandonAfter != null &&
              _statusReadAt != null &&
              !_statusReadAt!.isBefore(_abandonAfter!));
  bool canPerform(String action) =>
      initialized &&
      actionsAvailable &&
      !busy &&
      _foreground &&
      !storageFailed &&
      pending == null &&
      familyAccountActions.contains(action) &&
      (action == 'RECOVER_PHONE' && !identity().authenticated
          ? recoveryAvailable
          : identity().authenticated &&
              status != null &&
              status!.subject == identity().subject &&
              status!.permits(action));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void identityChanged() {
    final current = identity();
    if (_lastIdentity?.same(current) == true) return;
    _lastIdentity = current;
    _epoch++;
    status = null;
    error = null;
    completedAction = null;
    _notify();
  }

  void setForeground(bool value) {
    if (_foreground == value || _disposed) return;
    _foreground = value;
    _epoch++;
    status = null;
    completedAction = null;
    _notify();
  }

  Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _storageTail;
    final finished = Completer<void>();
    _storageTail = finished.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      finished.complete();
      if (identical(_storageTail, finished.future)) _storageTail = null;
    }
  }

  Future<void> restore() async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    storageFailed = false;
    _notify();
    try {
      await _locked(() async {
        pending =
            FamilyAccountPending.decode(await storage.read(key: storageKey));
        _abandonAfter = now().add(const Duration(minutes: 30));
        initialized = true;
      });
      if (_foreground) await _readStatus();
    } catch (failure) {
      error = failure;
      storageFailed = true;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> refresh() async {
    if (busy || !_foreground || _disposed) return;
    if (!initialized || storageFailed) return restore();
    busy = true;
    error = null;
    completedAction = null;
    _notify();
    try {
      await _locked(() async {
        final actual =
            FamilyAccountPending.decode(await storage.read(key: storageKey));
        if (actual?.operationId != pending?.operationId) {
          pending = actual;
          _abandonAfter = now().add(const Duration(minutes: 30));
        }
      });
      await _readStatus();
    } catch (failure) {
      error = failure;
      storageFailed = true;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _readStatus() async {
    status = null;
    final snapshot = identity();
    final epoch = _epoch;
    _lastIdentity = snapshot;
    if (!snapshot.authenticated ||
        snapshot.subject == null ||
        pendingForAnotherAccount ||
        !_foreground ||
        _disposed) return;
    bool current() =>
        !_disposed &&
        _foreground &&
        _epoch == epoch &&
        snapshot.same(identity());
    try {
      final raw = await api.send('GET', '/status',
          maxResponseBytes: 8192, expectedStatus: 200, isCurrent: current);
      if (!current()) return;
      if (raw is! Json) _invalidAccountStatus();
      final result = FamilyAccountStatus.fromJson(raw);
      if (result.subject != snapshot.subject) _invalidAccountStatus();
      status = result;
      _statusReadAt = now();
      error = null;
      final original = pending;
      if (original == null ||
          result.lastOperationId != original.operationId ||
          result.lastOperationAction != original.action ||
          original.actor != null && result.subject != original.actor ||
          original.expectedRevision != null &&
              result.identityRevision <= original.expectedRevision!) return;
      if (original.action == 'BIND_WECHAT' && !result.wechatBound ||
          original.action == 'UNBIND_WECHAT' && result.wechatBound) {
        _invalidAccountStatus();
      }
      await _locked(() async {
        if (!current() || pending != original) return;
        final actual =
            FamilyAccountPending.decode(await storage.read(key: storageKey));
        if (!current()) return;
        if (actual == null) {
          pending = null;
          completedAction = null;
          return;
        }
        if (actual.operationId != original.operationId) {
          initialized = false;
          return;
        }
        await storage.delete(key: storageKey);
        if (!current()) {
          initialized = false;
          return;
        }
        pending = null;
        completedAction = original.action;
      });
    } catch (failure) {
      if (current()) {
        status = null;
        error = failure;
      }
    }
  }

  Future<void> perform(String action) async {
    if (!canPerform(action)) return;
    final snapshot = identity();
    final epoch = _epoch;
    final originalStatus = status;
    final original = FamilyAccountPending(
        action: action,
        operationId: createOperationId(),
        actor: snapshot.authenticated ? snapshot.subject : null,
        expectedRevision:
            snapshot.authenticated ? originalStatus!.identityRevision : null,
        createdAt: now().millisecondsSinceEpoch);
    FamilyAccountPending.decode(jsonEncode(original.toJson()));
    busy = true;
    error = null;
    completedAction = null;
    _notify();
    try {
      await _locked(() async {
        if (await storage.read(key: storageKey) != null) {
          initialized = false;
          throw const ParentApiException(409, 'ACCOUNT_OPERATION_PENDING');
        }
        if (_disposed ||
            !_foreground ||
            _epoch != epoch ||
            !snapshot.same(identity())) {
          throw const ParentApiException(409, 'ACCOUNT_IDENTITY_CHANGED');
        }
        // Keep an in-memory reference even if the flush fails after a write.
        pending = original;
        try {
          await storage.write(
              key: storageKey, value: jsonEncode(original.toJson()));
        } catch (_) {
          storageFailed = true;
          rethrow;
        }
      });
      if (_disposed ||
          !_foreground ||
          _epoch != epoch ||
          !snapshot.same(identity())) return;
      Object? launchFailure;
      try {
        await runAction(
            action: action,
            operationId: original.operationId,
            expectedRevision: original.expectedRevision,
            expectedActor: original.actor);
      } catch (failure) {
        launchFailure = failure;
        if (failure is ParentApiException &&
            failure.code == 'ACCOUNT_OPERATION_NOT_STARTED') {
          await _locked(() async {
            final actual = FamilyAccountPending.decode(
                await storage.read(key: storageKey));
            if (_disposed || !snapshot.same(identity())) return;
            if (actual == null) {
              pending = null;
              return;
            }
            if (actual.operationId != original.operationId) {
              initialized = false;
              return;
            }
            await storage.delete(key: storageKey);
            if (!_disposed && snapshot.same(identity())) {
              pending = null;
            } else {
              initialized = false;
            }
          });
        }
        if (!_disposed) error = failure;
      }
      _abandonAfter = now().add(const Duration(minutes: 30));
      // A successful AppAuth callback only permits a fresh read. Cancellation
      // can also occur after commit, so both outcomes follow the same path.
      if (!_disposed && _foreground) await _readStatus();
      if (launchFailure != null &&
          !_disposed &&
          _foreground &&
          snapshot.subject == identity().subject &&
          completedAction == null &&
          error == null) error = launchFailure;
    } catch (failure) {
      if (!_disposed) error = failure;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> acknowledgeCurrentState() async {
    if (!canAcknowledgeCurrentState) return;
    final snapshot = identity();
    final epoch = _epoch;
    final original = pending!;
    busy = true;
    _notify();
    try {
      await _locked(() async {
        final actual =
            FamilyAccountPending.decode(await storage.read(key: storageKey));
        if (_disposed ||
            !_foreground ||
            _epoch != epoch ||
            !snapshot.same(identity())) return;
        if (actual == null) {
          pending = null;
          return;
        }
        if (actual.operationId != original.operationId) {
          initialized = false;
          return;
        }
        await storage.delete(key: storageKey);
        if (_disposed ||
            !_foreground ||
            _epoch != epoch ||
            !snapshot.same(identity())) {
          initialized = false;
          return;
        }
        pending = null;
        completedAction = null;
      });
    } catch (failure) {
      error = failure;
      storageFailed = true;
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}

String familyAccountError(Object failure) {
  if (failure is FamilyAccountActionNotStarted &&
      failure.reason is ParentApiException) {
    return (failure.reason as ParentApiException).message;
  }
  if (failure is ParentApiException) {
    if (failure.status == 401) return '登录状态已变化，请使用当前手机号或已绑定微信重新登录，再核对账号。';
    if (failure.status == 503) return '账号安全服务暂不可用，请稍后重试。家庭和会员仍保留在原账号中。';
    if (failure.code == 'INVALID_ACCOUNT_SECURITY_RECOVERY') {
      return '本机操作记录未能通过核对。请保留本机数据并联系帮助，避免重复提交。';
    }
    if (failure.code == 'INVALID_ACCOUNT_SECURITY_RESPONSE') {
      return '账号状态未能通过核对，请重新读取后再操作。';
    }
    if (failure.code == 'ACCOUNT_OPERATION_PENDING') {
      return '另一个页面已有待核对操作，请重新读取原操作。';
    }
    if (failure.code == 'ACCOUNT_OPERATION_NOT_STARTED') {
      return '尚未开始账号修改，可重新选择验证方式。';
    }
    return failure.message;
  }
  return '安全记录暂时无法保存或读取。请检查本机存储后重试，暂未继续新的账号操作。';
}
