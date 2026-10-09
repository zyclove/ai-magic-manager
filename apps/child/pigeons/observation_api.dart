import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/platform/generated/observation.g.dart',
  kotlinOut:
      'android/app/src/main/kotlin/com/aimanager/child/ObservationApi.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.aimanager.child'),
  dartPackageName: 'child',
))
class NativeObservationFacts {
  NativeObservationFacts(
      {required this.usageGranted,
      required this.usageSupported,
      required this.usageGrantStatus,
      required this.unlocked,
      required this.television,
      required this.profile});
  bool usageGranted;
  bool usageSupported;
  String usageGrantStatus;
  bool unlocked;
  bool television;
  String profile;
}

class NativeObservedApplication {
  NativeObservedApplication(
      {required this.packageName,
      required this.displayName,
      required this.profile,
      required this.signingDigests,
      required this.versionCode,
      required this.systemApplication});
  String packageName;
  String displayName;
  String profile;
  List<String?> signingDigests;
  int versionCode;
  bool systemApplication;
}

class NativeUsageEntry {
  NativeUsageEntry(
      {required this.packageName,
      required this.displayName,
      required this.firstTimeStamp,
      required this.lastTimeStamp,
      required this.foregroundMillis});
  String packageName;
  String displayName;
  int firstTimeStamp;
  int lastTimeStamp;
  int foregroundMillis;
}

class NativeUsageSample {
  NativeUsageSample(
      {required this.queryStart,
      required this.queryEnd,
      required this.observedAt,
      required this.timeZone,
      required this.profile,
      required this.applications});
  int queryStart;
  int queryEnd;
  int observedAt;
  String timeZone;
  String profile;
  List<NativeUsageEntry?> applications;
}

@HostApi()
abstract class AndroidObservationApi {
  @async
  NativeObservationFacts inspect();
  @async
  List<NativeObservedApplication?> inventory();
  @async
  NativeUsageSample usage(int queryStart, int queryEnd);
  @async
  void openUsageSettings();
}
