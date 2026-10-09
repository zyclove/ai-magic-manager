import 'package:device_observation/device_observation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'generated/observation.g.dart';

/// Pigeon 负责跨语言序列化；此层只转换领域模型和固定诊断。
class AndroidObservationSource implements ObservationSource {
  final AndroidObservationApi api;
  AndroidObservationSource({AndroidObservationApi? api})
      : api = api ?? AndroidObservationApi();
  Future<T> _native<T>(Future<T> Function() call) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const ObservationFailure('OBSERVATION_NATIVE_UNAVAILABLE');
    }
    try {
      return await call().timeout(const Duration(seconds: 20));
    } on PlatformException catch (error) {
      const codes = {
        'OBSERVATION_NATIVE_UNAVAILABLE',
        'OBSERVATION_ACCESS_DENIED',
        'OBSERVATION_NATIVE_FAILED',
        'OBSERVATION_NATIVE_BUSY',
        'OBSERVATION_DEVICE_LOCKED',
        'OBSERVATION_SAMPLE_INVALID',
        'OBSERVATION_LIMIT_EXCEEDED',
        'USAGE_ACCESS_NOT_GRANTED',
        'OBSERVATION_USAGE_UNAVAILABLE',
        'OBSERVATION_SETTINGS_UNAVAILABLE'
      };
      throw ObservationFailure(codes.contains(error.code)
          ? error.code
          : 'OBSERVATION_NATIVE_FAILED');
    } on ObservationFailure {
      rethrow;
    } catch (_) {
      throw const ObservationFailure('OBSERVATION_NATIVE_FAILED');
    }
  }

  @override
  Future<ObservationPlatformState> inspect() => _native(() async {
        final facts = await api.inspect();
        return ObservationPlatformState(
            usageGranted: facts.usageGranted,
            usageSupported: facts.usageSupported,
            usageGrantStatus: facts.usageGrantStatus,
            unlocked: facts.unlocked,
            television: facts.television,
            profile: facts.profile);
      });
  @override
  Future<List<Map<String, dynamic>>> inventory() => _native(() async {
        final values = await api.inventory();
        if (values.any((v) => v == null)) {
          throw const ObservationFailure('OBSERVATION_SAMPLE_INVALID');
        }
        return values
            .map((v) => {
                  'packageName': v!.packageName,
                  'displayName': v.displayName,
                  'profile': v.profile,
                  'signingDigests': v.signingDigests,
                  'versionCode': v.versionCode,
                  'systemApplication': v.systemApplication
                })
            .toList();
      });
  @override
  Future<UsageSample> usage({required int queryStart, required int queryEnd}) =>
      _native(() async {
        final value = await api.usage(queryStart, queryEnd);
        if (value.applications.any((v) => v == null)) {
          throw const ObservationFailure('OBSERVATION_SAMPLE_INVALID');
        }
        return UsageSample(
            queryStart: value.queryStart,
            queryEnd: value.queryEnd,
            observedAt: value.observedAt,
            timeZone: value.timeZone,
            profile: value.profile,
            applications: value.applications
                .map((v) => {
                      'packageName': v!.packageName,
                      'displayName': v.displayName,
                      'firstTimeStamp': v.firstTimeStamp,
                      'lastTimeStamp': v.lastTimeStamp,
                      'foregroundMillis': v.foregroundMillis
                    })
                .toList());
      });
  @override
  Future<void> openUsageSettings() => _native(api.openUsageSettings);
}
