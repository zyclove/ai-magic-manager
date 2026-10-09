import 'dart:convert';
import 'dart:async';
import 'package:device_observation/device_observation.dart';
import 'package:device_policy/device_policy.dart' show DeviceTransportFailure;
import 'package:test/test.dart';

const tenant = '11111111-1111-1111-1111-111111111111';
const device = '22222222-2222-2222-2222-222222222222';
const registration = '33333333-3333-3333-3333-333333333333';
const scope = ObservationScope(tenant, device, registration);
const initialNow = 1800000000000;

class MemoryStore implements ObservationStore {
  String? value;
  bool fail = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async {
    if (fail) throw StateError('disk failure must not leak');
    value = next;
  }
}

class Source implements ObservationSource {
  int inventoryReads = 0, usageReads = 0;
  bool granted = true, unlocked = true;
  Future<void> Function()? beforeUsage;
  @override
  Future<ObservationPlatformState> inspect() async => ObservationPlatformState(
      usageGranted: granted, unlocked: unlocked, profile: 'PRIMARY');
  @override
  Future<List<Map<String, dynamic>>> inventory() async {
    inventoryReads++;
    return [
      {
        'packageName': 'org.example.reader',
        'displayName': '阅读',
        'profile': 'PRIMARY',
        'signingDigests': ['a' * 64],
        'versionCode': 1,
        'systemApplication': false
      }
    ];
  }

  @override
  Future<UsageSample> usage(
      {required int queryStart, required int queryEnd}) async {
    usageReads++;
    await beforeUsage?.call();
    return UsageSample(
        queryStart: queryStart,
        queryEnd: queryEnd,
        observedAt: queryEnd,
        timeZone: 'UTC',
        profile: 'PRIMARY',
        applications: [
          {
            'packageName': 'org.example.reader',
            'displayName': '阅读',
            'firstTimeStamp': queryStart,
            'lastTimeStamp': queryEnd,
            'foregroundMillis': 1000
          }
        ]);
  }

  @override
  Future<void> openUsageSettings() async {}
}

class Api implements ObservationApi {
  int version = 0, reports = 0;
  bool inventoryEnabled = false,
      usageEnabled = false,
      offline = false,
      loseAck = false,
      wrongAck = false;
  final bodies = <Map<String, dynamic>>[];
  final MemoryStore store;
  int? rejectStatus;
  Api(this.store);
  @override
  Future<Map<String, dynamic>> settings() async {
    if (offline) throw const DeviceTransportFailure('CONNECTION_FAILED');
    return {
      'deviceId': device,
      'registrationId': registration,
      'version': version,
      'inventoryEnabled': inventoryEnabled,
      'usageEnabled': usageEnabled,
      'updatedAt': version == 0 ? null : initialNow
    };
  }

  Future<Map<String, dynamic>> submit(Map<String, dynamic> body) async {
    expect(store.value, contains(jsonEncode(body)), reason: '原请求必须先加密持久化');
    bodies.add(jsonDecode(jsonEncode(body)) as Map<String, dynamic>);
    reports++;
    if (rejectStatus != null) {
      throw DeviceTransportFailure('OBSERVATION_NOT_AUTHORIZED',
          status: rejectStatus);
    }
    if (loseAck) {
      throw const DeviceTransportFailure('NETWORK_TIMEOUT',
          outcomeUnknown: true);
    }
    return {
      'registrationId': wrongAck ? tenant : registration,
      'sequence': body['sequence'],
      if (body.containsKey('reportId')) 'reportId': body['reportId'],
      'receivedAt': initialNow
    };
  }

  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> body) =>
      submit(body);
  @override
  Future<Map<String, dynamic>> usage(Map<String, dynamic> body) => submit(body);
  @override
  void close() {}
}

void main() {
  late MemoryStore store;
  late Source source;
  late Api api;
  late int now;
  ObservationAgent agent() => ObservationAgent(
      scope: scope,
      store: store,
      api: api,
      source: source,
      nowMillis: () => now);
  setUp(() {
    store = MemoryStore();
    source = Source();
    api = Api(store);
    now = initialNow;
  });
  test('默认关闭不读取任何应用或使用记录', () async {
    final view = await agent().synchronize();
    expect(view.authorization!.version, 0);
    expect(source.inventoryReads, 0);
    expect(source.usageReads, 0);
    expect(api.reports, 0);
  });
  test('云端授权后原请求先持久化并校验注册周期回执', () async {
    api
      ..version = 1
      ..inventoryEnabled = true
      ..usageEnabled = true;
    final view = await agent().synchronize();
    expect(source.inventoryReads, 1);
    expect(source.usageReads, 1);
    expect(view.pendingReports, 0);
    expect(view.inventoryCount, 1);
    expect(view.usageCount, 1);
    expect(api.bodies.every((b) => b['authorizationVersion'] == 1), isTrue);
  });
  test('系统访问未授予时即使云端授权也不查询使用记录', () async {
    api
      ..version = 1
      ..usageEnabled = true;
    source.granted = false;
    final view = await agent().synchronize();
    expect(view.platform!.usageGranted, isFalse);
    expect(source.usageReads, 0);
    expect(api.reports, 0);
  });
  test('重启后丢失回执重放同一原请求且不重新查询', () async {
    api
      ..version = 1
      ..usageEnabled = true
      ..loseAck = true;
    await expectLater(
        agent().synchronize(), throwsA(isA<DeviceTransportFailure>()));
    final original = api.bodies.single;
    api.loseAck = false;
    now += 2000;
    final view = await agent().synchronize();
    expect(api.bodies.last, equals(original));
    expect(source.usageReads, 1);
    expect(view.pendingReports, 0);
  });
  test('重新授权版本变化删除旧 pending 后采集新的版本', () async {
    api
      ..version = 1
      ..usageEnabled = true
      ..loseAck = true;
    await expectLater(
        agent().synchronize(), throwsA(isA<DeviceTransportFailure>()));
    final original = api.bodies.single;
    api
      ..version = 3
      ..loseAck = false;
    now += 2000;
    await agent().synchronize();
    expect(api.bodies.last['authorizationVersion'], 3);
    expect(api.bodies.last['reportId'], isNot(original['reportId']));
    expect(
        api.bodies.last['sequence'], greaterThan(original['sequence'] as int));
  });
  test('离线时不新增采集，系统撤回仍清除本地 pending', () async {
    api
      ..version = 1
      ..usageEnabled = true
      ..loseAck = true;
    await expectLater(
        agent().synchronize(), throwsA(isA<DeviceTransportFailure>()));
    source.granted = false;
    api.offline = true;
    await expectLater(
        agent().synchronize(), throwsA(isA<DeviceTransportFailure>()));
    expect((await agent().restore()).pendingReports, 0);
    expect(source.usageReads, 1);
  });
  test('错误注册周期 ACK 保留 pending 并拒绝假成功', () async {
    api
      ..version = 1
      ..usageEnabled = true
      ..wrongAck = true;
    await expectLater(
        agent().synchronize(),
        throwsA(isA<ObservationFailure>()
            .having((e) => e.code, 'code', 'OBSERVATION_ACK_INVALID')));
    expect((await agent().restore()).pendingReports, 1);
  });
  test('存储失败时不允许采集或上传', () async {
    api
      ..version = 1
      ..usageEnabled = true;
    store.fail = true;
    await expectLater(
        agent().synchronize(),
        throwsA(isA<ObservationFailure>()
            .having((e) => e.code, 'code', 'OBSERVATION_STORAGE_FAILED')));
    expect(source.usageReads, 0);
    expect(api.reports, 0);
  });
  test('跨设备和类型不精确的授权响应均拒绝', () {
    final json = {
      'deviceId': device,
      'registrationId': registration,
      'version': 1,
      'inventoryEnabled': true,
      'usageEnabled': false,
      'updatedAt': initialNow
    };
    expect(
        () => ObservationAuthorization.parse(
            {...json, 'registrationId': tenant}, scope),
        throwsA(isA<ObservationFailure>()));
    expect(
        () => ObservationAuthorization.parse({...json, 'version': 1.0}, scope),
        throwsA(isA<ObservationFailure>()));
    expect(
        () => ObservationAuthorization.parse(
            {...json, 'adminSecret': 'secret'}, scope),
        throwsA(isA<ObservationFailure>()));
  });
  test('已接收更高授权版本后拒绝服务器版本回退', () async {
    api
      ..version = 3
      ..usageEnabled = true
      ..loseAck = true;
    await expectLater(
        agent().synchronize(), throwsA(isA<DeviceTransportFailure>()));
    api
      ..version = 1
      ..loseAck = false;
    await expectLater(
        agent().synchronize(),
        throwsA(isA<ObservationFailure>().having(
            (e) => e.code, 'code', 'OBSERVATION_AUTHORIZATION_ROLLBACK')));
    expect(source.usageReads, 1);
    expect(api.reports, 1);
  });
  test('过期的待发清单重新采集，不能以新接收时间伪装旧观察', () async {
    api
      ..version = 1
      ..inventoryEnabled = true
      ..loseAck = true;
    await expectLater(
        agent().synchronize(), throwsA(isA<DeviceTransportFailure>()));
    final sequence = api.bodies.single['sequence'] as int;
    now += 20 * 60000;
    api.loseAck = false;
    await agent().synchronize();
    expect(source.inventoryReads, 2);
    expect(api.bodies.last['sequence'], greaterThan(sequence));
  });
  test('上传时服务器撤回授权清理全部 pending 及缓存授权', () async {
    api
      ..version = 1
      ..usageEnabled = true
      ..rejectStatus = 403;
    await expectLater(
        agent().synchronize(), throwsA(isA<DeviceTransportFailure>()));
    final view = await agent().restore();
    expect(view.pendingReports, 0);
    expect(view.authorization, isNull);
  });
  test('暂停进行中的敏感查询后不保存或上传，同一实例拒绝并发', () async {
    api
      ..version = 1
      ..usageEnabled = true;
    final started = Completer<void>(), release = Completer<void>();
    source.beforeUsage = () {
      started.complete();
      return release.future;
    };
    final service = agent();
    final running = service.synchronize();
    await started.future;
    await expectLater(
        service.synchronize(),
        throwsA(isA<ObservationFailure>()
            .having((e) => e.code, 'code', 'OBSERVATION_BUSY')));
    service.pause();
    release.complete();
    await expectLater(
        running,
        throwsA(isA<ObservationFailure>()
            .having((e) => e.code, 'code', 'OBSERVATION_PAUSED')));
    expect(api.reports, 0);
    expect((await service.restore()).pendingReports, 0);
  });
  test('损坏或类型不精确的加密记录不能自动重置', () async {
    await agent().synchronize();
    final json = jsonDecode(store.value!) as Map<String, dynamic>;
    json['schema'] = 1.0;
    store.value = jsonEncode(json);
    final original = store.value;
    await expectLater(
        agent().synchronize(),
        throwsA(isA<ObservationFailure>()
            .having((e) => e.code, 'code', 'OBSERVATION_STORAGE_FAILED')));
    expect(store.value, original);
    expect(source.usageReads, 0);
  });
}
