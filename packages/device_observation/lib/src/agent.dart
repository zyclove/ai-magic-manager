import 'models.dart';
import 'journal.dart';
import 'payloads.dart';
import 'package:device_policy/device_policy.dart'
    show DeviceTransportFailure, maxSafeInteger, freezeJson;
import 'package:uuid/uuid.dart';
import 'permission_snapshot.dart';

/// 每个注册周期仅一个实例。先取得实时授权再采集，先持久化原请求再上传。
class ObservationAgent {
  final ObservationScope scope;
  final ObservationStore store;
  final ObservationApi api;
  final ObservationSource source;
  final PermissionObservationApi? permissionApi;
  final PermissionObservationSource? permissionSource;
  final int Function() nowMillis;
  bool _busy = false, _closed = false;
  int _generation = 0;
  ObservationAgent(
      {required this.scope,
      required this.store,
      required this.api,
      required this.source,
      this.permissionApi,
      this.permissionSource,
      required this.nowMillis}) {
    if (!validScope(scope)) throw ArgumentError('Invalid observation scope');
  }
  void _check(int generation) {
    if (_closed || generation != _generation) {
      throw const ObservationFailure('OBSERVATION_PAUSED');
    }
  }

  Future<ObservationView> synchronize({bool collect = true}) async {
    if (_closed) throw const ObservationFailure('OBSERVATION_PAUSED');
    if (_busy) throw const ObservationFailure('OBSERVATION_BUSY');
    _busy = true;
    final generation = _generation, journal = ObservationJournal(scope, store);
    try {
      await journal.load();
      _check(generation);
      final facts = await source.inspect();
      _check(generation);
      if (!profiles.contains(facts.profile)) invalid();
      // 即使断网，系统授权撤回也应先清除本地待上传的使用载荷。
      if (!facts.usageGranted || !facts.unlocked || !facts.usageSupported) {
        journal.pendingUsage = null;
        journal.usageCount = 0;
        journal.lastUsageAt = null;
        if (!facts.unlocked) {
          journal.pendingInventory = null;
          journal.pendingInventoryAt = null;
        }
        await journal.save();
        _check(generation);
      }
      final authorization =
          ObservationAuthorization.parse(await api.settings(), scope);
      _check(generation);
      if (authorization.version < (journal.authorization?.version ?? 0)) {
        throw const ObservationFailure('OBSERVATION_AUTHORIZATION_ROLLBACK');
      }
      if (journal.authorization?.version != authorization.version) {
        journal.forgetReports();
      }
      journal.authorization = authorization;
      if (permissionApi != null) {
        final permissionAuthorization =
            PermissionObservationAuthorization.parse(
                await permissionApi!.permissionSettings(), scope);
        _check(generation);
        if (permissionAuthorization.version <
            (journal.permissionAuthorization?.version ?? 0)) {
          throw const ObservationFailure('PERMISSION_AUTHORIZATION_ROLLBACK');
        }
        if (journal.permissionAuthorization?.version !=
            permissionAuthorization.version) {
          journal.forgetPermissionReports();
        }
        journal.permissionAuthorization = permissionAuthorization;
        if (!permissionAuthorization.enabled ||
            !authorization.inventoryEnabled) {
          journal.forgetPermissionReports();
        }
      } else {
        journal.forgetPermissionReports();
        journal.permissionAuthorization = null;
      }
      if (!authorization.inventoryEnabled) {
        journal.pendingInventory = null;
        journal.pendingInventoryAt = null;
        journal.inventoryCount = 0;
        journal.lastInventoryAt = null;
        journal.forgetPermissionReports();
      }
      if (!authorization.usageEnabled) {
        journal.pendingUsage = null;
        journal.usageCount = 0;
        journal.lastUsageAt = null;
      }
      final pendingAt = journal.pendingUsage?['observedAt'] as int?;
      final now = nowMillis();
      if (!safeNumber(now, minimum: 3600001)) {
        throw const ObservationFailure('CLOCK_UNTRUSTED');
      }
      final inventoryAt = journal.pendingInventoryAt;
      if (inventoryAt != null && inventoryAt > now + 300000) {
        throw const ObservationFailure('CLOCK_UNTRUSTED');
      }
      if (inventoryAt != null && now - inventoryAt > 15 * 60000) {
        journal.pendingInventory = null;
        journal.pendingInventoryAt = null;
      }
      if (pendingAt != null && now - pendingAt > 7 * dayMillis) {
        journal.pendingUsage = null;
      }
      if (pendingAt != null && pendingAt > now + 300000) {
        throw const ObservationFailure('CLOCK_UNTRUSTED');
      }
      // 先确认授权记录可持久化，磁盘不可用时不能开始敏感查询。
      await journal.save();
      _check(generation);
      if (!collect || !facts.unlocked) {
        return journal.view(platform: facts, online: true);
      }
      if (authorization.inventoryEnabled) {
        if (journal.pendingInventory == null &&
            (journal.lastInventoryAt == null ||
                now - journal.lastInventoryAt! >= 60000)) {
          final apps = inventoryApplications(await source.inventory());
          _check(generation);
          if (journal.inventorySequence >= maxSafeInteger) {
            throw const ObservationFailure('OBSERVATION_SEQUENCE_EXHAUSTED');
          }
          journal.pendingInventory = freezeJson({
            'sequence': ++journal.inventorySequence,
            'authorizationVersion': authorization.version,
            'visibility': 'VISIBLE_PACKAGES',
            'applications': apps
          });
          journal.pendingInventoryAt = nowMillis();
          await journal.save();
          _check(generation);
        }
        if (journal.pendingInventory != null) {
          final body = journal.pendingInventory!;
          final ack = await api.inventory(body);
          _check(generation);
          _ack(ack, body, false);
          journal.lastInventoryAt = ack['receivedAt'];
          journal.inventoryCount = (body['applications'] as List).length;
          journal.pendingInventory = null;
          journal.pendingInventoryAt = null;
          await journal.save();
          _check(generation);
        }
      }
      if (authorization.usageEnabled &&
          facts.usageGranted &&
          facts.usageSupported) {
        if (journal.pendingUsage == null &&
            (journal.lastUsageAt == null ||
                now - journal.lastUsageAt! >= 60000)) {
          // Android INTERVAL_DAILY 以设备本地日为桶。请求最近一小时仍会返回
          // 当天的聚合，进而把日报的覆盖时长错误标成一小时。
          final localNow = DateTime.fromMillisecondsSinceEpoch(now);
          final dayStart = DateTime(localNow.year, localNow.month, localNow.day)
              .millisecondsSinceEpoch;
          if (dayStart >= now) {
            return journal.view(platform: facts, online: true);
          }
          final sample =
              await source.usage(queryStart: dayStart, queryEnd: now);
          _check(generation);
          if (sample.profile != facts.profile ||
              sample.observedAt > nowMillis() + 300000 ||
              sample.observedAt < nowMillis() - 7 * dayMillis) invalid();
          if (journal.usageSequence >= maxSafeInteger) {
            throw const ObservationFailure('OBSERVATION_SEQUENCE_EXHAUSTED');
          }
          journal.pendingUsage = usagePayload(sample, ++journal.usageSequence,
              authorization.version, const Uuid().v4());
          await journal.save();
          _check(generation);
        }
        if (journal.pendingUsage != null) {
          // 查询后系统权限可能已撤回；上传前再次核对，不读取额外使用数据。
          final current = await source.inspect();
          _check(generation);
          if (!current.usageGranted ||
              !current.unlocked ||
              !current.usageSupported) {
            journal.pendingUsage = null;
            journal.usageCount = 0;
            journal.lastUsageAt = null;
            await journal.save();
            return journal.view(platform: current, online: true);
          }
          final body = journal.pendingUsage!;
          final ack = await api.usage(body);
          _check(generation);
          _ack(ack, body, true);
          journal.lastUsageAt = ack['receivedAt'];
          journal.usageCount = (body['applications'] as List).length;
          journal.pendingUsage = null;
          await journal.save();
          _check(generation);
        }
      }
      return journal.view(platform: facts, online: true);
    } on DeviceTransportFailure catch (failure) {
      if (failure.status == 401 ||
          failure.status == 403 ||
          failure.code == 'OBSERVATION_AUTHORIZATION_CHANGED') {
        journal.forgetReports(forgetAuthorization: true);
        await journal.save();
      } else if (failure.status == 400) {
        journal.pendingUsage = null;
        journal.pendingInventory = null;
        journal.pendingInventoryAt = null;
        journal.pendingPermission = null;
        await journal.save();
      }
      rethrow;
    } on ObservationFailure {
      rethrow;
    } catch (_) {
      throw const ObservationFailure('OBSERVATION_NATIVE_FAILED');
    } finally {
      _busy = false;
    }
  }

  void _ack(Map<String, dynamic> ack, Map<String, dynamic> body, bool usage) {
    if (!exactKeys(
            ack,
            usage
                ? {'registrationId', 'sequence', 'reportId', 'receivedAt'}
                : {'registrationId', 'sequence', 'receivedAt'}) ||
        ack['registrationId'] != scope.registrationId ||
        ack['sequence'] is! int ||
        ack['sequence'] != body['sequence'] ||
        !safeNumber(ack['receivedAt'], minimum: 1) ||
        (usage && ack['reportId'] != body['reportId'])) {
      throw const ObservationFailure('OBSERVATION_ACK_INVALID');
    }
  }

  Future<ObservationView> restore() async {
    final journal = ObservationJournal(scope, store);
    await journal.load();
    return journal.view();
  }

  Future<void> openUsageSettings() async {
    final view = await synchronize(collect: false);
    if (view.authorization?.usageEnabled != true) {
      throw const ObservationFailure('OBSERVATION_NOT_AUTHORIZED');
    }
    try {
      await source.openUsageSettings();
    } on ObservationFailure {
      rethrow;
    } catch (_) {
      throw const ObservationFailure('OBSERVATION_SETTINGS_UNAVAILABLE');
    }
  }

  Future<PermissionCandidates> permissionCandidates() async {
    if (permissionApi == null || permissionSource == null) {
      throw const ObservationFailure('PERMISSION_OBSERVATION_UNAVAILABLE');
    }
    final view = await synchronize(collect: false);
    if (view.authorization?.inventoryEnabled != true ||
        view.permissionAuthorization?.enabled != true ||
        view.platform?.unlocked != true) {
      throw const ObservationFailure('PERMISSION_OBSERVATION_NOT_AUTHORIZED');
    }
    if (_closed || _busy) throw const ObservationFailure('OBSERVATION_BUSY');
    _busy = true;
    final generation = _generation;
    try {
      final facts = await source.inspect();
      _check(generation);
      if (!facts.unlocked) {
        throw const ObservationFailure('OBSERVATION_DEVICE_LOCKED');
      }
      final apps = inventoryApplications(await source.inventory());
      _check(generation);
      return PermissionCandidates(
          view,
          List.unmodifiable(apps.map((app) => PermissionCandidate(
              app['packageName'] as String,
              app['displayName'] as String,
              app['profile'] as String))));
    } finally {
      _busy = false;
    }
  }

  /// Explicit foreground action for one visible app. Never runs from heartbeat or boot.
  Future<ObservationView> observePermission(String packageName) async {
    if (permissionApi == null || permissionSource == null) {
      throw const ObservationFailure('PERMISSION_OBSERVATION_UNAVAILABLE');
    }
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
            .hasMatch(packageName) ||
        packageName.length > 255) invalid();
    await synchronize(collect: false);
    if (_closed || _busy) throw const ObservationFailure('OBSERVATION_BUSY');
    _busy = true;
    final generation = _generation, journal = ObservationJournal(scope, store);
    try {
      await journal.load();
      _check(generation);
      if (journal.authorization?.inventoryEnabled != true ||
          journal.permissionAuthorization?.enabled != true) {
        throw const ObservationFailure('PERMISSION_OBSERVATION_NOT_AUTHORIZED');
      }
      final facts = await source.inspect();
      _check(generation);
      if (!facts.unlocked) {
        throw const ObservationFailure('OBSERVATION_DEVICE_LOCKED');
      }
      if (journal.pendingInventory != null) {
        final priorInventory = journal.pendingInventory!;
        final priorAck = await api.inventory(priorInventory);
        _check(generation);
        _ack(priorAck, priorInventory, false);
        journal.lastInventoryAt = priorAck['receivedAt'];
        journal.inventoryCount =
            (priorInventory['applications'] as List).length;
        journal.pendingInventory = null;
        journal.pendingInventoryAt = null;
        await journal.save();
        _check(generation);
      }
      final pending = journal.pendingPermission;
      if (pending != null) {
        final age = nowMillis() - (pending['observedAt'] as int);
        // The server rejects new reports after 15 minutes. Leave a minute for
        // transport latency; a late acknowledgement can be replaced by a fresh
        // report with the next sequence rather than trapping foreground retries.
        if (age < -300000 || age >= 14 * 60000) {
          journal.pendingPermission = null;
          await journal.save();
          _check(generation);
        } else {
          final ack = await permissionApi!.permissionReport(pending);
          _check(generation);
          _ack(ack, pending, false);
          journal.lastPermissionAt = ack['receivedAt'];
          journal.lastPermissionPackage = pending['packageName'];
          journal.pendingPermission = null;
          await journal.save();
          _check(generation);
          if (pending['packageName'] == packageName) {
            return journal.view(platform: facts, online: true);
          }
        }
      }
      // The backend checks a recent inventory with matching version and signers.
      // Refresh it here even when an older inventory report has been acknowledged.
      final applications = inventoryApplications(await source.inventory());
      _check(generation);
      final matches = applications.where((app) =>
          app['packageName'] == packageName && app['profile'] == facts.profile);
      if (matches.length != 1) {
        throw const ObservationFailure('OBSERVATION_APPLICATION_NOT_VISIBLE');
      }
      if (journal.inventorySequence >= maxSafeInteger) {
        throw const ObservationFailure('OBSERVATION_SEQUENCE_EXHAUSTED');
      }
      journal.pendingInventory = freezeJson({
        'sequence': ++journal.inventorySequence,
        'authorizationVersion': journal.authorization!.version,
        'visibility': 'VISIBLE_PACKAGES',
        'applications': applications
      });
      journal.pendingInventoryAt = nowMillis();
      await journal.save();
      _check(generation);
      final inventoryAck = await api.inventory(journal.pendingInventory!);
      _check(generation);
      _ack(inventoryAck, journal.pendingInventory!, false);
      journal.lastInventoryAt = inventoryAck['receivedAt'];
      journal.inventoryCount = applications.length;
      journal.pendingInventory = null;
      journal.pendingInventoryAt = null;
      await journal.save();
      _check(generation);
      final snapshot = await permissionSource!.permissionSnapshot(packageName);
      _check(generation);
      final expected = matches.single;
      if (snapshot.profile != facts.profile ||
          snapshot.versionCode != expected['versionCode'] ||
          snapshot.signingDigests.join('|') !=
              (expected['signingDigests'] as List).join('|')) invalid();
      final now = nowMillis();
      if (snapshot.observedAt < now - 15 * 60000 ||
          snapshot.observedAt > now + 300000) invalid();
      if (journal.permissionSequence >= maxSafeInteger) {
        throw const ObservationFailure('OBSERVATION_SEQUENCE_EXHAUSTED');
      }
      final body = snapshot.report(++journal.permissionSequence,
          journal.permissionAuthorization!.version, const Uuid().v4());
      journal.pendingPermission = freezeJson(body);
      await journal.save();
      _check(generation);
      // Permission consent can be withdrawn while PackageManager is reading.
      final current = PermissionObservationAuthorization.parse(
          await permissionApi!.permissionSettings(), scope);
      _check(generation);
      if (current.version < journal.permissionAuthorization!.version) {
        throw const ObservationFailure('PERMISSION_AUTHORIZATION_ROLLBACK');
      }
      if (!current.enabled ||
          current.version != journal.permissionAuthorization!.version) {
        journal.permissionAuthorization = current;
        journal.forgetPermissionReports();
        await journal.save();
        throw const ObservationFailure(
            'PERMISSION_OBSERVATION_AUTHORIZATION_CHANGED');
      }
      final ack =
          await permissionApi!.permissionReport(journal.pendingPermission!);
      _check(generation);
      _ack(ack, journal.pendingPermission!, false);
      journal.lastPermissionAt = ack['receivedAt'];
      journal.lastPermissionPackage = packageName;
      journal.pendingPermission = null;
      await journal.save();
      return journal.view(platform: facts, online: true);
    } on DeviceTransportFailure catch (failure) {
      if (failure.status == 401 ||
          failure.status == 403 ||
          failure.code == 'PERMISSION_OBSERVATION_AUTHORIZATION_CHANGED') {
        journal.forgetPermissionReports();
        journal.permissionAuthorization = null;
        await journal.save();
      } else if (failure.status == 400) {
        journal.pendingPermission = null;
        await journal.save();
      }
      rethrow;
    } finally {
      _busy = false;
    }
  }

  void pause() => _generation++;
  void close() {
    _closed = true;
    pause();
    api.close();
  }
}
